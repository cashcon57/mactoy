import Foundation
import Combine
import MactoyKit
import os

enum AppMode: String, CaseIterable, Hashable {
    case installVentoy
    case updateVentoy
    case flashImage
    case manageDisk

    var displayName: String {
        switch self {
        case .installVentoy: return "Install Ventoy"
        case .updateVentoy:  return "Update Ventoy"
        case .flashImage:    return "Flash Image"
        case .manageDisk:    return "Manage Disk"
        }
    }

    var symbol: String {
        switch self {
        case .installVentoy: return "externaldrive.badge.plus"
        case .updateVentoy:  return "arrow.triangle.2.circlepath"
        case .flashImage:    return "bolt.horizontal.circle"
        case .manageDisk:    return "folder.badge.gearshape"
        }
    }
}

enum InstallStatus {
    case idle
    case preparing(String)
    case running(ProgressUpdate)
    case success(String)
    case failed(String)
}

/// Payload for the "you're about to wipe this drive" confirmation
/// sheet. Captured when the user clicks Install / Flash so the dialog
/// can describe the exact disk + usage at that moment.
struct EraseConfirmation: Identifiable {
    let id = UUID()
    let mode: AppMode
    let disk: DiskTarget
    let usedBytes: UInt64?   // nil = couldn't measure (no mounted volumes)
    let totalBytes: UInt64
}

@MainActor
final class AppState: ObservableObject {
    /// Cap on the in-memory progress `log` to bound memory during
    /// long-running flashes. v0.2.0 shipped unbounded; a multi-GB
    /// install could push thousands of `ProgressUpdate` entries
    /// before the user closed the run, none of which were rendered
    /// in the UI but all of which kept @Published thrashing.
    private static let maxLogEntries = 500
    private static let log = Logger(subsystem: "com.mactoy", category: "appstate")

    // disk enumeration
    @Published var disks: [DiskTarget] = []
    @Published var selectedDiskBSD: String?

    // mode
    @Published var mode: AppMode = .installVentoy

    // ventoy mode
    @Published var ventoyVersionInput: String = ""    // empty = latest
    @Published var latestVentoyVersion: String?
    @Published var availableVentoyVersions: [String] = []
    @Published var useCustomVentoyVersion: Bool = false
    @Published var customVentoyVersion: String = ""

    // flash mode
    @Published var selectedImagePath: String?

    // helper lifecycle
    @Published var helperStatus: HelperStatus = .notRegistered
    @Published var uninstallHelperAfterRun: Bool = true  // default: leave system clean
    @Published var showHelperExplainer: Bool = false     // drives the pre-register sheet
    @Published var isAwaitingHelperApproval: Bool = false
    @Published var showFullDiskAccessSheet: Bool = false // drives the FDA remediation sheet

    // erase confirmation
    @Published var pendingEraseConfirmation: EraseConfirmation?

    // run state
    @Published var status: InstallStatus = .idle
    @Published var log: [ProgressUpdate] = []

    // Ventoy probe — populated whenever the selected disk changes (and
    // the helper is reachable). Drives the Update Ventoy panel: shows
    // an Update CTA when `isVentoyDisk == true`, a Repair-via-fresh-
    // install CTA when `looksLikeBrokenVentoy == true`, or the "no
    // Ventoy here" empty state otherwise.
    @Published var detectedVentoy: VentoyProbeResult?
    /// Non-nil when the most recent probe attempt for the currently-
    /// selected disk failed (XPC unreachable, decode error, daemon not
    /// approved). Drives the UpdateVentoyPanel's "probe-failed" hint
    /// state. Cleared whenever a fresh probe is fired or succeeds.
    @Published var probeError: String?
    private var probeTask: Task<Void, Never>?

    /// Captured target + mode from the user's most recent confirmation,
    /// preserved across the helper-approval gap. The first run() call
    /// returns early if the helper isn't enabled; the helper-poll task
    /// re-invokes run() once the toggle flips. Both invocations must
    /// use the SAME captured disk — never re-derive from
    /// `selectedDisk`. Cleared on successful start, cancellation, or
    /// terminal failure.
    private var pendingRunTarget: DiskTarget?
    private var pendingRunMode: AppMode?

    var selectedDisk: DiskTarget? {
        guard let b = selectedDiskBSD else { return nil }
        return disks.first { $0.bsdName == b }
    }

    var canRun: Bool {
        guard case .idle = status else { return false }
        guard selectedDisk != nil else { return false }
        switch mode {
        case .installVentoy: return true
        case .updateVentoy:  return detectedVentoy?.isVentoyDisk == true
        case .flashImage:    return selectedImagePath != nil
        case .manageDisk:    return false
        }
    }

    private var enumeratorTask: Task<Void, Never>?
    private var helperPollTask: Task<Void, Never>?

    /// Heuristic: did the XPC layer fail because launchd has no live
    /// registration for our mach service? Usually means the daemon was
    /// booted out or BTM + launchd fell out of sync.
    private func isLookupFailure(_ err: HelperInvoker.HelperError) -> Bool {
        guard case .xpcUnreachable(let m) = err else { return false }
        return m.contains("No such process")
            || m.contains("4099")
            || m.contains("Connection init failed at lookup")
    }

    private func isFullDiskAccessError(_ err: HelperInvoker.HelperError) -> Bool {
        guard case .executionFailed(let m) = err else { return false }
        return m.contains("blocked by macOS (Operation not permitted)")
    }

    func refreshHelperStatus() {
        let new = HelperLifecycle.status
        if helperStatus != new {
            helperStatus = new
            Self.log.info("helperStatus -> \(String(describing: new), privacy: .public)")
        }
        // Default the uninstall-after-run checkbox: if the helper is
        // already installed, leave it alone by default (unchecked). If we
        // are about to install the helper for the first time, prefer to
        // clean up after ourselves (checked).
        let nextUninstall = (new != .enabled)
        if uninstallHelperAfterRun != nextUninstall {
            uninstallHelperAfterRun = nextUninstall
        }
    }

    /// Register the daemon, open the Login Items settings pane, and poll
    /// for the toggle flip. Resolves when `.enabled` (or the user closes
    /// the sheet).
    func beginHelperApproval() {
        guard !isAwaitingHelperApproval else { return }
        isAwaitingHelperApproval = true

        Task { [weak self] in
            guard let self else { return }

            // SMAppService can refuse register() with "Operation not
            // permitted" when BTM already holds an entry for the same
            // label from a previously-signed build. Unregister first to
            // clear any lingering record; ignore failure (nothing to
            // remove is fine).
            try? await HelperLifecycle.unregister()

            // register() may still fail — either the cleanup above
            // didn't actually remove a stale BTM entry, or the user
            // denied the implicit prompt. Either way we still open
            // Login Items so they can toggle whatever entry IS there,
            // and fall back to polling. Register failures surface only
            // if the poll times out (handled by the user cancelling).
            let registerError: String?
            do {
                try HelperLifecycle.register()
                registerError = nil
            } catch {
                registerError = error.localizedDescription
            }

            await MainActor.run {
                HelperLifecycle.openLoginItemsSettings()
                self.helperStatus = HelperLifecycle.status
                if self.helperStatus == .notRegistered, let err = registerError {
                    self.status = .failed("Helper registration failed: \(err)\n\nIf Mactoy already appears in \(SystemSettingsStrings.loginItemsPane), turn its toggle on manually.")
                    self.isAwaitingHelperApproval = false
                }
            }
            if await MainActor.run(body: { self.helperStatus == .notRegistered && registerError != nil }) {
                return
            }
            self.startHelperPoll()
        }
    }

    private func startHelperPoll() {

        helperPollTask?.cancel()
        helperPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                await MainActor.run {
                    let new = HelperLifecycle.status
                    if self.helperStatus != new {
                        self.helperStatus = new
                    }
                    if self.helperStatus == .enabled {
                        self.isAwaitingHelperApproval = false
                        self.helperPollTask = nil
                        // If the user was waiting to run an install after
                        // approval, kick it off now — using the SAME
                        // captured target/mode they confirmed before
                        // the helper-approval detour. NEVER re-derive
                        // from selectedDisk here; that re-derivation is
                        // exactly the bug that caused the wrong-disk
                        // wipe in v0.3.0.
                        if let target = self.pendingRunTarget, let mode = self.pendingRunMode {
                            Task { @MainActor in
                                await self.run(confirmedTarget: target, confirmedMode: mode)
                            }
                        } else {
                            Self.log.warning("helper poll: helperStatus=enabled but no pending run captured")
                        }
                    }
                }
                if await MainActor.run(body: { self.helperStatus == .enabled }) { return }
            }
        }
    }

    func cancelHelperApproval() {
        helperPollTask?.cancel()
        helperPollTask = nil
        isAwaitingHelperApproval = false
        // Clear the captured target/mode — if the user cancelled the
        // approval flow, they are not opting into an install on the
        // disk they confirmed earlier. Don't let a future helper-poll
        // resume fire on stale state.
        pendingRunTarget = nil
        pendingRunMode = nil
    }

    func startDiskEnumeration() {
        enumeratorTask?.cancel()
        enumeratorTask = Task { [weak self] in
            while !Task.isCancelled {
                let disks = (try? DiskInfo.enumerateExternal()) ?? []
                await self?.applyDiskList(disks)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        Task { [weak self] in
            if let versions = try? await VentoyDownloader().recentVersions(limit: 20), !versions.isEmpty {
                await self?.setAvailableVentoyVersions(versions)
            } else if let v = try? await VentoyDownloader().latestVersion() {
                await self?.setLatestVentoyVersion(v)
            }
        }
    }

    private func applyDiskList(_ disks: [DiskTarget]) {
        // Skip the assign when nothing changed — every @Published write
        // fires `objectWillChange` regardless of equality, invalidating
        // every @EnvironmentObject subscriber. The disk poll runs every
        // 2s and produces an identical list most of the time.
        if self.disks != disks {
            self.disks = disks
        }

        // **Iron-clad targeting defense (issue #1, v0.3.1).**
        // While the user has a confirmation sheet open, do NOT mutate
        // `selectedDiskBSD` — even if the originally-selected disk
        // momentarily drops off the bus. The user has already
        // committed to a specific disk via `requestRun()`; sneakily
        // re-targeting them mid-confirmation caused Mactoy to wipe
        // disk6 after the user confirmed disk5. The captured disk is
        // authoritative until they confirm or cancel.
        if pendingEraseConfirmation != nil {
            return
        }

        let prevSelection = selectedDiskBSD
        if let sel = selectedDiskBSD, !disks.contains(where: { $0.bsdName == sel }) {
            selectedDiskBSD = nil
        }
        if selectedDiskBSD == nil, let first = disks.first {
            selectedDiskBSD = first.bsdName
        }
        // Re-probe when the selection actually changed. The probe runs
        // off-MainActor; the UI updates when it returns.
        if selectedDiskBSD != prevSelection {
            triggerVentoyProbe()
        }
    }

    /// Kick off (or restart) the Ventoy probe for the currently-
    /// selected disk. Cancels any in-flight probe so rapid selection
    /// changes don't pile up XPC round trips. Debounced 300 ms so a
    /// keyboard-arrowing user who flips through 5 disks in 100 ms only
    /// triggers one probe at the end.
    func triggerVentoyProbe() {
        probeTask?.cancel()
        let bsd = selectedDiskBSD
        // Clear stale result immediately — UI shouldn't show last
        // disk's probe data while the new probe is in flight.
        detectedVentoy = nil
        probeError = nil
        guard let bsd else { return }
        probeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            do {
                let result = try await HelperInvoker.probeVentoy(bsdName: bsd)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    // Confirm the selection is still the disk we
                    // probed; user may have moved on while we waited.
                    if self.selectedDiskBSD == bsd {
                        self.detectedVentoy = result
                        self.probeError = nil
                    }
                }
            } catch {
                // Probe failure (helper not registered, XPC failure,
                // disk vanished). Surface to UI so the user sees a
                // diagnostic hint instead of a perpetual spinner.
                Self.log.info("Ventoy probe failed for \(bsd, privacy: .public): \(error.localizedDescription, privacy: .private)")
                if Task.isCancelled { return }
                let message = Self.probeErrorMessage(for: error)
                await MainActor.run {
                    guard let self else { return }
                    if self.selectedDiskBSD == bsd {
                        self.probeError = message
                    }
                }
            }
        }
    }

    /// Translate a probe error into user-facing copy. The most likely
    /// cause for a clean install is "helper not approved yet" (no
    /// daemon listening on the mach service). We surface that as the
    /// default message and let the user know they can resolve it via
    /// the Install Ventoy flow which kicks off helper registration.
    private static func probeErrorMessage(for error: Error) -> String {
        if let helperErr = error as? HelperInvoker.HelperError {
            switch helperErr {
            case .xpcUnreachable:
                return "Couldn't reach the Mactoy helper to probe this disk. The helper may not be approved yet — try a fresh install on the **Install Ventoy** tab once to register it, then come back here."
            case .executionFailed(let m):
                return "Probe failed: \(m)"
            }
        }
        return "Probe failed: \(error.localizedDescription)"
    }

    private func setLatestVentoyVersion(_ v: String) {
        if self.latestVentoyVersion != v {
            self.latestVentoyVersion = v
        }
    }

    private func setAvailableVentoyVersions(_ versions: [String]) {
        if self.availableVentoyVersions != versions {
            self.availableVentoyVersions = versions
        }
        if self.latestVentoyVersion == nil, let first = versions.first {
            self.latestVentoyVersion = first
        }
        // If the persisted selection no longer exists in the list, snap to latest.
        if !useCustomVentoyVersion,
           !ventoyVersionInput.isEmpty,
           !versions.contains(ventoyVersionInput) {
            ventoyVersionInput = ""
        }
    }

    /// Resolves the version the user effectively wants to install.
    /// Empty string means "latest at install time".
    var effectiveVentoyVersion: String {
        if useCustomVentoyVersion {
            return customVentoyVersion.trimmingCharacters(in: .whitespaces)
        }
        let sel = ventoyVersionInput.trimmingCharacters(in: .whitespaces)
        return sel // empty = latest
    }

    /// User clicked the primary action. Gather the "this many bytes of
    /// data will be erased" summary and present the confirmation sheet.
    /// The actual install kicks off only if they hit **Erase**.
    func requestRun() {
        guard canRun, let target = selectedDisk else { return }
        guard mode != .manageDisk else { return }
        pendingEraseConfirmation = EraseConfirmation(
            mode: mode,
            disk: target,
            usedBytes: DiskInfo.estimatedUsedBytes(bsdName: target.bsdName),
            totalBytes: target.sizeInBytes
        )
    }

    func cancelRun() {
        pendingEraseConfirmation = nil
        // Also clear the captured target/mode so a stale helper-poll
        // resume can't fire an install the user has since cancelled.
        pendingRunTarget = nil
        pendingRunMode = nil
    }

    func confirmRun() {
        guard let confirmation = pendingEraseConfirmation else { return }
        pendingEraseConfirmation = nil
        // **Iron-clad targeting (Layer 3, issue #1):** pass the
        // captured `EraseConfirmation` through to `run()` explicitly.
        // `run()` MUST NOT re-read `selectedDisk` from here on — that
        // re-read is what allowed Mactoy to wipe disk6 after the user
        // confirmed disk5 in v0.3.0. We also store the captured pair
        // in `pendingRunTarget/pendingRunMode` so the helper-poll auto-
        // resume path uses the same target across the approval gap.
        let capturedTarget = confirmation.disk
        let capturedMode = confirmation.mode
        pendingRunTarget = capturedTarget
        pendingRunMode = capturedMode
        Task { @MainActor in await self.run(confirmedTarget: capturedTarget, confirmedMode: capturedMode) }
    }

    /// Execute the install / update / flash that the user confirmed.
    ///
    /// **Targeting safety (v0.3.1, issue #1):** `confirmedTarget` is
    /// the disk the user explicitly approved in the confirmation sheet.
    /// This function does NOT re-derive the target from
    /// `selectedDiskBSD` / `selectedDisk` — those are presentation-
    /// layer state that can drift between confirmation and execution
    /// (USB hub hiccups, sleep/wake, the disk poll snapping the
    /// selection to a different disk). Re-deriving the target here is
    /// what caused the wrong-disk wipe in v0.3.0; we now require the
    /// caller to thread the captured target through explicitly.
    func run(confirmedTarget: DiskTarget, confirmedMode: AppMode) async {
        let target = confirmedTarget

        // Layer 6 (BSD-name guard): even if the rest of the
        // fingerprint coincidentally matches a different live disk
        // with the same `bsdName`, refuse if the captured BSD name
        // differs from what the disk list currently believes is
        // selected. The selection-freeze in `applyDiskList` should
        // already prevent drift, but defense-in-depth wins here.
        if let liveSelection = selectedDiskBSD, liveSelection != target.bsdName {
            status = .failed(
                "Refusing to run: the selected disk changed between confirmation and execution. " +
                "Confirmed /dev/\(target.bsdName), but the sidebar now shows /dev/\(liveSelection) selected. " +
                "This usually means a USB drive was plugged or unplugged during the confirmation. Please re-select the disk and try again."
            )
            Self.log.error("run() aborted: selection drifted (confirmed=\(target.bsdName, privacy: .public), live=\(liveSelection, privacy: .public))")
            return
        }

        log = []
        status = .preparing("Preparing install plan...")
        Self.log.info("run() begin: mode=\(confirmedMode.rawValue, privacy: .public) target=/dev/\(target.bsdName, privacy: .public)")

        // Layer 4 (app-side re-verification): probe the live disk and
        // assert its identity matches what the user confirmed.
        // Anything mismatched (size, mediaName, external/removable
        // flags, BSD name) means the disk that's at /dev/<bsd> right
        // now is NOT the disk the user confirmed. Abort hard — better
        // a clear error than a silent wrong-disk write.
        do {
            let live = try DiskInfo.probe(bsdName: target.bsdName)
            if let mismatch = target.fingerprintMismatch(against: live) {
                status = .failed(
                    "Refusing to run: the disk at /dev/\(target.bsdName) is not the same disk you confirmed. \(mismatch). " +
                    "This typically means a USB device was unplugged or replugged after you clicked the confirm button. Please re-select your target disk and try again."
                )
                Self.log.error("run() aborted: fingerprint mismatch — \(mismatch, privacy: .public)")
                return
            }
        } catch {
            status = .failed(
                "Refusing to run: could not re-verify /dev/\(target.bsdName) before writing. \(error.localizedDescription) " +
                "Please re-select the disk and try again."
            )
            Self.log.error("run() aborted: probe failed — \(error.localizedDescription, privacy: .private)")
            return
        }

        let source: InstallSource
        let driver: DriverID
        let ventoyOperation: VentoyOperation
        switch confirmedMode {
        case .installVentoy:
            driver = .ventoy
            ventoyOperation = .freshInstall
            let v = effectiveVentoyVersion
            source = .ventoyVersion(v.isEmpty ? (latestVentoyVersion ?? "") : v)
        case .updateVentoy:
            driver = .ventoy
            ventoyOperation = .updateInPlace
            let v = effectiveVentoyVersion
            source = .ventoyVersion(v.isEmpty ? (latestVentoyVersion ?? "") : v)
        case .flashImage:
            driver = .rawImage
            ventoyOperation = .freshInstall  // unused for raw image
            guard let p = selectedImagePath else { return }
            source = .localImage(path: p)
        case .manageDisk:
            return
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactoy-\(UUID().uuidString.prefix(8))")

        var plan = InstallPlan(
            driver: driver,
            target: target,
            source: source,
            filesystem: .exfat,
            workDir: workDir.path,
            ventoyOperation: ventoyOperation
        )

        do {
            try plan.validate()
        } catch {
            status = .failed("\(error)")
            return
        }

        // Resolve latest Ventoy version if blank
        if case .ventoyVersion(let v) = plan.source, v.isEmpty {
            do {
                let latest = try await VentoyDownloader().latestVersion()
                plan = InstallPlan(
                    driver: plan.driver,
                    target: plan.target,
                    source: .ventoyVersion(latest),
                    filesystem: plan.filesystem,
                    workDir: plan.workDir,
                    ventoyOperation: plan.ventoyOperation
                )
            } catch {
                status = .failed("Failed to resolve latest Ventoy version: \(error)")
                return
            }
        }

        // Gate on helper being enabled. If not, surface the explainer
        // sheet; after the user accepts we register + open Settings +
        // poll, and auto-resume run() when the toggle flips.
        refreshHelperStatus()
        if helperStatus != .enabled {
            showHelperExplainer = true
            status = .idle
            return
        }

        do {
            try await HelperInvoker.run(
                plan: plan,
                onUpdate: { [weak self] update in
                    guard let self else { return }
                    self.appendBoundedLog(update)
                    // Only treat progress updates as running status. A
                    // terminal `.failed` or `.done` update means the
                    // daemon is about to exit — the real outcome is
                    // decided by the XPC reply (thrown error or success
                    // below), and letting the update clobber it caused
                    // a UI race where "Failed" + progress bar +
                    // "Working…" button all showed at once.
                    switch update.phase {
                    case .failed, .done: return
                    default: self.status = .running(update)
                    }
                }
            )
            status = .success("Install complete")
            Self.log.info("run() success")
        } catch let err as HelperInvoker.HelperError where isFullDiskAccessError(err) {
            // TCC is blocking raw-disk access from the daemon. Users have
            // to grant Full Disk Access to Mactoy.app; TCC propagates
            // that grant to the daemon via AssociatedBundleIdentifiers.
            showFullDiskAccessSheet = true
            status = .failed("Full Disk Access is required — see the popup.")
            Self.log.error("run() failed: TCC blocked raw disk access (Full Disk Access required)")
        } catch let err as HelperInvoker.HelperError where isLookupFailure(err) {
            // BTM says the toggle is on but launchd has no registration
            // (happens after `sudo launchctl bootout` or a stale
            // BTM entry). Try to re-submit the daemon plist to launchd
            // and retry the install automatically.
            // .private redacts in shared log output (e.g. when a user
            // pastes `log show` into a public GitHub issue) but stays
            // visible to the local user running `log show` themselves.
            Self.log.error("run() XPC lookup failure — retrying after re-register: \(err.localizedDescription, privacy: .private)")
            status = .preparing("Helper daemon lost — re-registering…")
            do {
                try? await HelperLifecycle.unregister()
                try HelperLifecycle.register()
                // Brief pause for launchd to pick up the new submission.
                try? await Task.sleep(nanoseconds: 500_000_000)
                try await HelperInvoker.run(
                    plan: plan,
                    onUpdate: { [weak self] update in
                        guard let self else { return }
                        self.appendBoundedLog(update)
                        switch update.phase {
                        case .failed, .done: return
                        default: self.status = .running(update)
                        }
                    }
                )
                status = .success("Install complete")
            } catch {
                status = .failed("Helper daemon could not be reached and auto-recovery failed.\n\nIn System Settings → General → \(SystemSettingsStrings.loginItemsPane), turn the Mactoy toggle OFF and back ON, then try again.\n\nUnderlying error: \(error.localizedDescription)")
            }
        } catch {
            status = .failed(error.localizedDescription)
            // Error descriptions can include the user's home-dir paths
            // (e.g. when flashing from ~/Downloads). Redact in shared
            // `log show` output; full text is still visible locally.
            Self.log.error("run() failed: \(error.localizedDescription, privacy: .private)")
        }

        // Honour the "remove helper after this run" checkbox. We do this
        // whether the install succeeded or failed so the system is left
        // in a clean state. Silent failure on unregister is fine — the
        // daemon may already be gone (e.g. user toggled off manually).
        if uninstallHelperAfterRun {
            try? await HelperLifecycle.unregister()
            helperStatus = HelperLifecycle.status
        }

        // Clear the captured target/mode now that this run reached a
        // terminal outcome. They survived the helper-approval gap if
        // needed (handled by the helper-poll resume path); they are
        // not allowed to survive a completed run.
        pendingRunTarget = nil
        pendingRunMode = nil
    }

    func reset() {
        status = .idle
        log = []
    }

    /// Append a progress update to `log`, capping total entries at
    /// `maxLogEntries`. Drops the oldest entries when over the cap. The
    /// log is not currently rendered in any view, but a future
    /// "diagnostics export" feature will consume it; we keep the most
    /// recent updates because terminal failures are usually the most
    /// useful for triage.
    ///
    /// Note for future readers: the bulk-drop strategy (drop 25% in one
    /// shot, then resume appending) trades amortized O(1) appends for a
    /// single 125-element shift every 125 appends. If a future view
    /// renders `log` via `ForEach`, the bulk drop will visually jump 125
    /// rows at a time. If that becomes a problem, switch to a circular
    /// buffer (or `Deque` from swift-collections) and adapt the export
    /// path accordingly.
    private func appendBoundedLog(_ update: ProgressUpdate) {
        if log.count >= Self.maxLogEntries {
            let dropCount = Self.maxLogEntries / 4
            log.removeFirst(dropCount)
        }
        log.append(update)
    }
}
