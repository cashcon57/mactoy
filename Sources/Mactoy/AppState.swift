import Foundation
import Observation
import MactoyKit

enum AppMode: String, CaseIterable, Hashable {
    case installVentoy
    case flashImage
    case manageDisk

    var displayName: String {
        switch self {
        case .installVentoy: return "Install Ventoy"
        case .flashImage:    return "Flash Image"
        case .manageDisk:    return "Manage Disk"
        }
    }

    var symbol: String {
        switch self {
        case .installVentoy: return "externaldrive.badge.plus"
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

@MainActor
@Observable
final class AppState {
    // disk enumeration
    var disks: [DiskTarget] = []
    var selectedDiskBSD: String?

    // mode
    var mode: AppMode = .installVentoy

    // ventoy mode
    var ventoyVersionInput: String = ""    // empty = latest
    var latestVentoyVersion: String?
    var availableVentoyVersions: [String] = []
    var useCustomVentoyVersion: Bool = false
    var customVentoyVersion: String = ""

    // flash mode
    var selectedImagePath: String?

    // helper lifecycle
    var helperStatus: HelperStatus = .notRegistered
    var uninstallHelperAfterRun: Bool = true  // default: leave system clean
    var showHelperExplainer: Bool = false     // drives the pre-register sheet
    var isAwaitingHelperApproval: Bool = false
    var showFullDiskAccessSheet: Bool = false // drives the FDA remediation sheet

    // run state
    var status: InstallStatus = .idle
    var log: [ProgressUpdate] = []

    var selectedDisk: DiskTarget? {
        guard let b = selectedDiskBSD else { return nil }
        return disks.first { $0.bsdName == b }
    }

    var canRun: Bool {
        guard case .idle = status else { return false }
        guard selectedDisk != nil else { return false }
        switch mode {
        case .installVentoy: return true
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
        helperStatus = HelperLifecycle.status
        // Default the uninstall-after-run checkbox: if the helper is
        // already installed, leave it alone by default (unchecked). If we
        // are about to install the helper for the first time, prefer to
        // clean up after ourselves (checked).
        if helperStatus == .enabled {
            uninstallHelperAfterRun = false
        } else {
            uninstallHelperAfterRun = true
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
                    self.status = .failed("Helper registration failed: \(err)\n\nIf Mactoy already appears in Login Items & Extensions, turn its toggle on manually.")
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
                    self.helperStatus = HelperLifecycle.status
                    if self.helperStatus == .enabled {
                        self.isAwaitingHelperApproval = false
                        self.helperPollTask = nil
                        // If the user was waiting to run an install after
                        // approval, kick it off now.
                        Task { @MainActor in await self.run() }
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
        self.disks = disks
        if let sel = selectedDiskBSD, !disks.contains(where: { $0.bsdName == sel }) {
            selectedDiskBSD = nil
        }
        if selectedDiskBSD == nil, let first = disks.first {
            selectedDiskBSD = first.bsdName
        }
    }

    private func setLatestVentoyVersion(_ v: String) {
        self.latestVentoyVersion = v
    }

    private func setAvailableVentoyVersions(_ versions: [String]) {
        self.availableVentoyVersions = versions
        if self.latestVentoyVersion == nil {
            self.latestVentoyVersion = versions.first
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

    func run() async {
        guard canRun, let target = selectedDisk else { return }

        log = []
        status = .preparing("Preparing install plan...")

        let source: InstallSource
        let driver: DriverID
        switch mode {
        case .installVentoy:
            driver = .ventoy
            let v = effectiveVentoyVersion
            source = .ventoyVersion(v.isEmpty ? (latestVentoyVersion ?? "") : v)
        case .flashImage:
            driver = .rawImage
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
            workDir: workDir.path
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
                    workDir: plan.workDir
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
                    self.log.append(update)
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
        } catch let err as HelperInvoker.HelperError where isFullDiskAccessError(err) {
            // TCC is blocking raw-disk access from the daemon. Users have
            // to grant Full Disk Access to Mactoy.app; TCC propagates
            // that grant to the daemon via AssociatedBundleIdentifiers.
            showFullDiskAccessSheet = true
            status = .failed("Full Disk Access is required — see the popup.")
        } catch let err as HelperInvoker.HelperError where isLookupFailure(err) {
            // BTM says the toggle is on but launchd has no registration
            // (happens after `sudo launchctl bootout` or a stale
            // BTM entry). Try to re-submit the daemon plist to launchd
            // and retry the install automatically.
            status = .preparing("Helper daemon lost — re-registering…")
            do {
                try? await HelperLifecycle.unregister()
                try HelperLifecycle.register()
                // Brief pause for launchd to pick up the new submission.
                try? await Task.sleep(nanoseconds: 500_000_000)
                try await HelperInvoker.run(
                    plan: plan,
                    onUpdate: { [weak self] update in
                        self?.log.append(update)
                        self?.status = .running(update)
                    }
                )
                status = .success("Install complete")
            } catch {
                status = .failed("Helper daemon could not be reached and auto-recovery failed.\n\nIn System Settings → General → Login Items & Extensions, turn the Mactoy toggle OFF and back ON, then try again.\n\nUnderlying error: \(error.localizedDescription)")
            }
        } catch {
            status = .failed(error.localizedDescription)
        }

        // Honour the "remove helper after this run" checkbox. We do this
        // whether the install succeeded or failed so the system is left
        // in a clean state. Silent failure on unregister is fine — the
        // daemon may already be gone (e.g. user toggled off manually).
        if uninstallHelperAfterRun {
            try? await HelperLifecycle.unregister()
            helperStatus = HelperLifecycle.status
        }
    }

    func reset() {
        status = .idle
        log = []
    }
}
