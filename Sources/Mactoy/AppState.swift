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
    /// nil = not measured (yet, or no mounted volumes). Filled in after
    /// the sheet opens; measuring can block on slow volumes, so it never
    /// runs on the main thread.
    var usedBytes: UInt64?
    let totalBytes: UInt64
    /// Secure Boot support as the toggle stood when the user clicked
    /// the action button. Captured for the same reason `disk` is: what
    /// the sheet describes must be what runs. Ignored for Flash Image.
    var secureBoot: Bool = true
    /// Partition table for a fresh install, captured the same way.
    /// Ignored for Update and Flash Image. No default, for the same
    /// reason `InstallPlan` has none.
    let partitionStyle: VentoyPartitionStyle
    /// The disk is a Time Machine backup the user unlocked; the sheet
    /// says its backups will be erased.
    var isTimeMachineBackup: Bool = false
    /// Boot theme for a fresh install, captured like `secureBoot`. Always
    /// `.ventoyDefault` for Update and Flash Image.
    var theme: ThemeChoice = .ventoyDefault
    /// The theme already on the drive, when it is one Mactoy can keep and
    /// an Install would erase. Filled in after the sheet opens (reading the
    /// drive can block), for Install only.
    var driveThemeName: String?
    /// The mounted volume that theme was read from.
    var driveThemeVolume: URL?
    /// The sheet's "save it first" box, ticked unless the user clears it.
    /// Only means something while `driveThemeName` is set.
    var saveDriveThemeFirst: Bool = true
    /// The drive-theme probe for this confirmation hasn't answered yet (and
    /// its cap hasn't run out). The sheet keeps Erase disabled meanwhile,
    /// so a theme the user would have wanted kept can't be erased before
    /// the offer to save it has had its chance.
    var driveThemeProbePending: Bool = false
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
    /// Listed disks that hold a Time Machine backup (PR #13). Mactoy won't
    /// install, update or flash one unless the user unlocks it.
    @Published private(set) var timeMachineDisks: Set<String> = []
    /// Time Machine drives the user chose to unlock, by identity, for
    /// this session only. A drive that disappears from the list is
    /// dropped, so replugging it locks it again.
    @Published private(set) var unlockedBackupDisks: Set<DiskIdentity> = []

    /// What identifies "the same drive" for an unlock: the fields the
    /// wrong-disk defence fingerprints, minus the flags.
    struct DiskIdentity: Hashable {
        let bsdName: String
        let sizeInBytes: UInt64
        let mediaName: String?
        /// So an unlock doesn't carry over to another backup drive of the same model (#21).
        let serialNumber: String?
        init(_ disk: DiskTarget) {
            bsdName = disk.bsdName
            sizeInBytes = disk.sizeInBytes
            mediaName = disk.mediaName
            serialNumber = disk.serialNumber
        }
    }

    func isTimeMachineBackup(_ disk: DiskTarget) -> Bool {
        timeMachineDisks.contains(disk.bsdName)
    }

    /// A Time Machine drive the user hasn't unlocked: nothing may write to it.
    func isLockedBackup(_ disk: DiskTarget) -> Bool {
        isTimeMachineBackup(disk) && !unlockedBackupDisks.contains(DiskIdentity(disk))
    }

    /// The user confirmed they want to erase this backup drive anyway.
    func unlockBackupDisk(_ disk: DiskTarget) {
        guard isTimeMachineBackup(disk) else { return }
        unlockedBackupDisks.insert(DiskIdentity(disk))
        Self.log.info("Time Machine drive unlocked for this session: /dev/\(disk.bsdName, privacy: .public)")
    }

    func lockBackupDisk(_ disk: DiskTarget) {
        unlockedBackupDisks.remove(DiskIdentity(disk))
    }

    // mode
    @Published var mode: AppMode = .installVentoy

    // ventoy mode
    @Published var ventoyVersionInput: String = ""    // empty = latest
    @Published var latestVentoyVersion: String?
    @Published var availableVentoyVersions: [String] = []
    @Published var useCustomVentoyVersion: Bool = false
    @Published var customVentoyVersion: String = ""
    /// Secure Boot support for a fresh install (issue #9). On matches
    /// Ventoy2Disk's default.
    @Published var installSecureBoot: Bool = true
    /// Secure Boot support for an in-place update. Re-seeded from the
    /// drive's current layout every time a probe lands, so an update
    /// keeps what the stick has unless the user flips it.
    @Published var updateSecureBoot: Bool = true
    /// Partition style the user picked for a fresh install (issue #11).
    /// `nil` = not chosen; `effectiveInstallPartitionStyle` then uses the
    /// recommended style for the selected disk.
    @Published var installPartitionStyleChoice: VentoyPartitionStyle?

    /// Mactoy's pick for new drives; the Install tab says so and how to opt out.
    static let defaultInstallTheme: ThemeChoice = .catalog(id: "catppuccin-mocha")
    static let installThemeKey = "installTheme"
    private let defaults: UserDefaults

    /// Boot theme to add after a fresh install. Saved so an opt-out sticks;
    /// a custom theme isn't, since My Themes can lose it.
    @Published var installTheme: ThemeChoice {
        didSet {
            guard !isFallingBack else { return }
            switch installTheme {
            case .ventoyDefault: defaults.set("ventoy-default", forKey: Self.installThemeKey)
            case .catalog(let id): defaults.set("catalog:\(id)", forKey: Self.installThemeKey)
            case .custom: break
            }
        }
    }

    /// True while `resetInstallThemeIfUnavailable` puts the pick back: falling back
    /// is not the user choosing, so it stores nothing.
    private var isFallingBack = false

    /// The choice kept in `defaults`; nil when nothing is stored or what is stored isn't one we wrote.
    private static func storedInstallTheme(in defaults: UserDefaults) -> ThemeChoice? {
        switch defaults.string(forKey: installThemeKey) {
        case "ventoy-default": return .ventoyDefault
        case let saved? where saved.hasPrefix("catalog:"): return .catalog(id: String(saved.dropFirst("catalog:".count)))
        default: return nil
        }
    }

    /// Moves the pick off a theme that is gone: a saved theme removed from My Themes,
    /// or a catalog theme that isn't in the online catalog (the bundled and cached
    /// copies can lag behind it, so they never reset a pick). The app calls it
    /// whenever either list changes.
    ///
    /// It goes back to what the user last chose and kept (read from the saved
    /// choice again), so a removed custom theme doesn't silently replace an
    /// opt-out or a catalog pick. Only when nothing usable is stored (nothing at
    /// all, or a catalog theme that is itself gone) does it use `defaultInstallTheme`,
    /// and then a stale stored value is dropped so the next launch doesn't start
    /// from it. The fallback never stores a choice: the stored value stays as it
    /// was and the default stays unsaved.
    func resetInstallThemeIfUnavailable(_ available: ThemeAvailability) {
        // A pick that is fine is left alone and never written again.
        guard !available.isAvailable(installTheme) else { return }
        let fallback: ThemeChoice
        if let stored = Self.storedInstallTheme(in: defaults), available.isAvailable(stored) {
            fallback = stored
        } else {
            fallback = Self.defaultInstallTheme
            defaults.removeObject(forKey: Self.installThemeKey)
        }
        guard fallback != installTheme else { return }
        isFallingBack = true
        defer { isFallingBack = false }
        installTheme = fallback
    }

    /// Adds a theme to a freshly installed disk; says whether it was added (with
    /// any warnings) or why not. Set by the app to `ThemeStore.applyAfterInstall`;
    /// a seam so tests don't touch disks or the network.
    /// Until the app sets it, it reports a problem: a missing hookup must show
    /// up, not claim a theme that was never added.
    var installThemeApplier: @MainActor (ThemeChoice, DiskTarget) async -> PostInstallThemeResult = { _, _ in
        .notApplied(problem: "theme support isn't set up.")
    }
    /// Looks for a theme worth keeping on the disk an Install is about to
    /// erase. Set by the app to `ThemeStore.savableDriveTheme`; a seam so
    /// tests touch no disks. It reads a drive, so it never runs on the main actor.
    var driveThemeProbe: @Sendable (DiskTarget) async -> (name: String, volume: URL)? = { _ in nil }
    /// Keeps the theme on that volume in My Themes. Set by the app to
    /// `ThemeStore.saveDriveTheme`; throws if it can't.
    var driveThemeSaver: @MainActor (URL) async throws -> Void = { _ in }
    /// How long the erase sheet waits for `driveThemeProbe` before it lets the
    /// user go ahead without the offer. Seam for tests.
    var driveThemeProbeCap: UInt64 = 3_000_000_000
    /// Which disk a mounted volume is on ("disk7s2"), read off the main
    /// actor (diskutil can stall on a drive mid-eject). Seam for tests.
    var driveVolumeIdentifier: @Sendable (URL) async -> String? = { volume in
        await Task.detached(priority: .userInitiated) { VentoyVolumeLocator.deviceIdentifier(of: volume) }.value
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Property observers don't fire during init, so reading the saved
        // choice doesn't write it back.
        installTheme = Self.storedInstallTheme(in: defaults) ?? Self.defaultInstallTheme
    }

    // flash mode
    @Published var selectedImagePath: String? {
        // A checksum belongs to one image.
        didSet { if selectedImagePath != oldValue { flashChecksumInput = "" } }
    }
    /// The SHA-256 the user pasted or loaded for the image (#26). Empty: no check.
    @Published var flashChecksumInput: String = ""
    /// Read the drive back after flashing and compare (#26).
    @Published var flashVerifyAfterWriting: Bool = true

    /// The checksum to check, or nil when the field is empty or invalid. A whole line pasted
    /// from a checksum file (`<hash>  name`) counts too.
    var flashChecksum: String? {
        ImageChecksum.normalized(flashChecksumInput)
            ?? ImageChecksum.sha256(for: selectedImagePath ?? "", in: flashChecksumInput)
    }
    /// For the plan: the checksum, the raw entry when it's invalid, or nil when empty.
    var flashChecksumForPlan: String? {
        let trimmed = flashChecksumInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (flashChecksum ?? trimmed)
    }
    /// Something is in the checksum field, but it isn't a SHA-256.
    var flashChecksumIsInvalid: Bool {
        !flashChecksumInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && flashChecksum == nil
    }

    // helper lifecycle
    /// Takes the helper off the Mac after a run (the "remove helper after this run" choice). Seam for tests.
    /// The helper removal in progress, if any. `run()` and a helper approval wait for it.
    @Published private(set) var helperRemoval: Task<Void, Never>?
    var helperRemover: @MainActor () async -> Void = {
        await AppState.removeHelper(clearDownloads: { try await HelperInvoker.clearDownloads() },
                                    unregister: { try await HelperLifecycle.unregister() })
    }

    /// The helper's Ventoy downloads belong to root, so only the helper can delete them, and once
    /// it's removed nothing would (issue #22). So it clears them first. Neither step's failure
    /// stops the other: the daemon may already be gone (e.g. the user toggled it off manually).
    static func removeHelper(clearDownloads: () async throws -> UInt64,
                             unregister: () async throws -> Void) async {
        _ = try? await clearDownloads()
        try? await unregister()
    }
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
    /// The last probe failed because the helper isn't reachable — e.g.
    /// it was removed after an install, as the explainer sheet offers.
    /// The Update tab then offers to set it up again (v0.5.1).
    @Published var probeNeedsHelper = false
    private var probeTask: Task<Void, Never>?
    /// Seam for tests: selection changes fire a probe, and the real one
    /// is an XPC call to the root daemon.
    var ventoyProber: @Sendable (String) async throws -> VentoyProbeResult = { bsd in
        try await HelperInvoker.probeVentoy(bsdName: bsd)
    }
    /// Seams for tests: one poll of the external disks, and a live
    /// Time Machine lookup for `run()`'s last check.
    var diskScanner: @Sendable () async -> DiskInfo.ExternalDiskScan? = {
        await Task.detached(priority: .utility) { try? DiskInfo.scanExternal() }.value
    }
    var timeMachineLookup: @Sendable () async throws -> Set<String> = {
        try await Task.detached(priority: .userInitiated) { try DiskInfo.timeMachineWholeDisks() }.value
    }
    /// Consecutive disk polls that failed. The sidebar says so after a
    /// few, instead of silently showing a list that may be stale.
    @Published private(set) var failedDiskPolls = 0
    /// Seam for tests. `estimatedUsedBytes` shells out to diskutil and
    /// stats mounted volumes, which blocks for seconds while a volume is
    /// busy (Time Machine, a sleeping drive), so it runs detached.
    var usedBytesEstimator: @Sendable (String) async -> UInt64? = { bsd in
        await Task.detached(priority: .userInitiated) {
            DiskInfo.estimatedUsedBytes(bsdName: bsd)
        }.value
    }

    /// Captured target + mode from the user's most recent confirmation,
    /// preserved across the helper-approval gap. The first run() call
    /// returns early if the helper isn't enabled; the helper-poll task
    /// re-invokes run() once the toggle flips. Both invocations must
    /// use the SAME captured disk — never re-derive from
    /// `selectedDisk`. Cleared on successful start, cancellation, or
    /// terminal failure.
    private var pendingRunTarget: DiskTarget?
    private var pendingRunMode: AppMode?
    /// Travels with the pair above. Without it, a failed update could
    /// re-enumerate the stick → re-probe → re-seed `updateSecureBoot`
    /// from the drive, and Retry would write the layout the user had
    /// just switched away from.
    private var pendingRunSecureBoot: Bool = true
    private var pendingRunPartitionStyle: VentoyPartitionStyle = .mbr
    private var pendingRunTheme: ThemeChoice = .ventoyDefault
    /// The volume whose theme the user asked to keep before the erase.
    /// Cleared the moment that save succeeds: Retry means the drive may
    /// already be partly erased, and must never save from it.
    private var pendingRunSaveThemeVolume: URL?
    /// Set once Mactoy has re-registered its helper because of a version
    /// mismatch; a further mismatch then fails instead of looping through
    /// the approval sheet. Carried across the approval detour (that's the
    /// loop it guards); cleared whenever the user starts a run themselves
    /// (confirm or Retry), and when a run succeeds or is cancelled.
    private var didReregisterForVersionMismatch = false

    /// What the most recent `run(...)` was asked to do, recorded on entry
    /// before any check can bail out. Diagnostics and test support only:
    /// nothing in the app reads these, and they never influence a run.
    /// Tests use them to confirm retry/resume pass the captured choices
    /// rather than the live toggles.
    struct RunRequest: Equatable {
        let bsdName: String
        let mode: AppMode
        let secureBoot: Bool
        let partitionStyle: VentoyPartitionStyle
        let theme: ThemeChoice
        let saveThemeFrom: URL?
    }
    private(set) var lastRunRequest: RunRequest?
    private(set) var runRequestCount = 0

    var selectedDisk: DiskTarget? {
        guard let b = selectedDiskBSD else { return nil }
        return disks.first { $0.bsdName == b }
    }

    var canRun: Bool {
        guard case .idle = status else { return false }
        guard let disk = selectedDisk else { return false }
        if mode != .manageDisk, isLockedBackup(disk) { return false }
        switch mode {
        case .installVentoy: return true
        case .updateVentoy:  return detectedVentoy?.isVentoyDisk == true
        case .flashImage:    return selectedImagePath != nil && !flashChecksumIsInvalid
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

    /// The registered helper belongs to a different Mactoy version —
    /// typically this copy was opened from the DMG while an older one in
    /// /Applications still owns the registration. Re-registering points
    /// launchd at this app's bundled helper.
    private func isVersionMismatch(_ err: HelperInvoker.HelperError) -> Bool {
        if case .versionMismatch = err { return true }
        return false
    }

    private func isFullDiskAccessError(_ err: HelperInvoker.HelperError) -> Bool {
        guard case .executionFailed(let m) = err else { return false }
        return m.contains("blocked by macOS (Operation not permitted)")
    }

    /// Seam for tests: where `refreshHelperStatus()` reads the helper's
    /// registration state.
    var helperStatusSource: () -> HelperStatus = { HelperLifecycle.status }

    func refreshHelperStatus() {
        let new = helperStatusSource()
        guard helperStatus != new else { return }
        helperStatus = new
        Self.log.info("helperStatus -> \(String(describing: new), privacy: .public)")

        // Default the "Remove the helper when done" checkbox,
        // only when the helper's state actually changes: unticked if it's
        // already installed (the user kept it before), ticked if it's
        // about to be installed. Before v0.5.1 this ran on every call,
        // so the run that resumes after approval — which calls this and
        // sees `.enabled` — silently unticked the user's choice and the
        // helper was never removed. The approval poll sets `helperStatus`
        // itself, so by then there's no change and the choice survives.
        let nextUninstall = (new != .enabled)
        if uninstallHelperAfterRun != nextUninstall {
            uninstallHelperAfterRun = nextUninstall
        }
    }

    /// Register the daemon, open the Login Items settings pane, and poll
    /// for the toggle flip. Resolves when `.enabled` (or the user closes
    /// the sheet).
    /// One run of the approval flow. Its purpose is fixed when it starts,
    /// and every later step checks it's still the current one, so a
    /// cancelled approval can't open Settings, start polling, or resume a
    /// run afterwards (v0.5.1).
    private struct HelperApproval {
        let id: Int
        let resumesRun: Bool
    }
    private var currentApproval: HelperApproval?
    private var approvalCounter = 0
    /// The latest approval's task. A new approval waits for it, so a
    /// cancelled approval's slow unregister can't land after the new
    /// one has registered.
    private var approvalTask: Task<Void, Never>?

    /// Seams for tests: the SMAppService calls the approval flow makes.
    var helperRegistrar = HelperRegistrar.live

    private func isCurrent(_ approval: HelperApproval) -> Bool {
        isAwaitingHelperApproval && currentApproval?.id == approval.id
    }

    func beginHelperApproval() {
        guard !isAwaitingHelperApproval else { return }
        isAwaitingHelperApproval = true
        approvalCounter += 1
        let approval = HelperApproval(id: approvalCounter, resumesRun: approvalResumesRun)
        currentApproval = approval
        approvalResumesRun = true      // the purpose now lives in `approval`
        let registrar = helperRegistrar
        let previous = approvalTask

        approvalTask = Task { @MainActor [weak self] in
            await previous?.value
            // Approval re-registers the helper; a removal finishing afterwards would undo it.
            if let removal = self?.helperRemoval { await removal.value }
            guard self?.isCurrent(approval) == true else { return }
            // SMAppService can refuse register() with "Operation not
            // permitted" when BTM already holds an entry for the same
            // label from a previously-signed build. Unregister first to
            // clear any lingering record; ignore failure (nothing to
            // remove is fine).
            try? await registrar.unregister()
            guard let self, self.isCurrent(approval) else { return }   // cancelled meanwhile

            // register() may still fail — either the cleanup above
            // didn't actually remove a stale BTM entry, or the user
            // denied the implicit prompt. Either way we still open
            // Login Items so they can toggle whatever entry IS there,
            // and fall back to polling.
            let registerError: String?
            do {
                try registrar.register()
                registerError = nil
            } catch {
                registerError = error.localizedDescription
            }

            registrar.openSettings()
            self.helperStatus = self.helperStatusSource()
            if self.helperStatus == .notRegistered, let err = registerError {
                let message = "Helper registration failed: \(err)\n\nIf Mactoy already appears in \(SystemSettingsStrings.loginItemsPane), turn its toggle on manually."
                if approval.resumesRun {
                    self.status = .failed(message)
                } else {
                    // Set Up Helper from the Update tab: report it there,
                    // and leave any failed run's banner (and its Retry)
                    // as it was.
                    self.probeError = message
                }
                self.isAwaitingHelperApproval = false
                self.currentApproval = nil
                return
            }
            self.startHelperPoll(for: approval)
        }
    }

    private func startHelperPoll(for approval: HelperApproval) {
        helperPollTask?.cancel()
        helperPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isCurrent(approval) else { return }
                let new = self.helperStatusSource()
                if self.helperStatus != new {
                    self.helperStatus = new
                }
                if self.helperStatus == .enabled {
                    self.helperApprovalCompleted(resumesRun: approval.resumesRun)
                    return
                }
            }
        }
    }

    func cancelHelperApproval() {
        // The approval under way (if it got that far) decides; otherwise
        // the purpose set for the explainer that's being cancelled.
        let resumes = currentApproval?.resumesRun ?? approvalResumesRun
        currentApproval = nil          // any in-flight step now stops
        helperPollTask?.cancel()
        helperPollTask = nil
        isAwaitingHelperApproval = false
        if resumes {
            // Clear the captured target/mode — if the user cancelled the
            // approval flow, they are not opting into an install on the
            // disk they confirmed earlier. Don't let a future helper-poll
            // resume fire on stale state.
            pendingRunTarget = nil
            pendingRunMode = nil
            pendingRunSaveThemeVolume = nil
            didReregisterForVersionMismatch = false
        }
        // A Set Up Helper approval never touched the captured run (it may
        // be a failed one the user can still Retry), so leave it alone.
        approvalResumesRun = true
    }

    /// Whether the approval in progress was started by `run(...)` (resume
    /// the captured run once approved) or by the Update tab's Set Up
    /// Helper button (only re-read the disk). Without this, approving the
    /// helper from the Update tab after a failed install would restart
    /// that install — an erase — with no confirmation.
    private var approvalResumesRun = true

    /// Update tab: the disk probe can't reach the helper (e.g. it was
    /// removed after an install). Show the approval sheet — with its
    /// remove-after choice — and re-read the disk once approved. Never
    /// starts or resumes a run. Refused while a run is in progress, since
    /// approval begins by unregistering the helper.
    func setUpHelperForProbe() {
        guard canSetUpHelperForProbe else { return }
        // So the sheet's remove-when-done box starts from the helper's
        // real state (re-defaults only if it changed).
        refreshHelperStatus()
        approvalResumesRun = false
        showHelperExplainer = true
    }

    /// Set Up Helper is offered only when the probe couldn't reach the
    /// helper, no approval is already under way, and no run is in
    /// progress.
    var canSetUpHelperForProbe: Bool {
        switch status {
        case .preparing, .running: return false
        default: return probeNeedsHelper && !isAwaitingHelperApproval && !showHelperExplainer && helperRemoval == nil
        }
    }

    /// The approval poll saw the helper become enabled. `resumesRun` is
    /// the purpose captured when that approval started. Internal so tests
    /// can drive it without SMAppService.
    func helperApprovalCompleted(resumesRun resumes: Bool) {
        isAwaitingHelperApproval = false
        helperPollTask = nil
        currentApproval = nil
        approvalResumesRun = true
        // Approved from the Update tab: re-read the disk, nothing else —
        // even if a failed run is still captured for Retry.
        guard resumes else {
            Self.log.info("helper approved from the Update tab — re-probing selected disk")
            triggerVentoyProbe()
            return
        }
        // If the user was waiting to run an install after approval, kick
        // it off now — using the SAME captured target/mode they confirmed
        // before the helper-approval detour. NEVER re-derive from
        // selectedDisk here; that re-derivation is exactly the bug that
        // caused the wrong-disk wipe in v0.3.0.
        if let target = pendingRunTarget, let mode = pendingRunMode {
            let secureBoot = pendingRunSecureBoot
            let partitionStyle = pendingRunPartitionStyle
            let theme = pendingRunTheme
            let saveThemeFrom = pendingRunSaveThemeVolume
            Task { @MainActor in
                await self.run(
                    confirmedTarget: target,
                    confirmedMode: mode,
                    confirmedSecureBoot: secureBoot,
                    confirmedPartitionStyle: partitionStyle,
                    confirmedTheme: theme,
                    confirmedSaveThemeFrom: saveThemeFrom
                )
            }
        } else {
            Self.log.warning("helper poll: helperStatus=enabled but no pending run captured")
        }
    }

    func startDiskEnumeration() {
        enumeratorTask?.cancel()
        enumeratorTask = Task { [weak self] in
            while !Task.isCancelled {
                // Detached: this Task inherits MainActor from AppState, and
                // enumerateExternal runs one diskutil per disk. A busy disk
                // (Time Machine backing up) froze the whole UI.
                // A failed poll keeps the last good list instead of applying
                // an empty one, which would clear the user's selection and
                // let the next poll re-select whichever disk comes first.
                guard let scanner = self?.diskScanner else { break }
                let scan = await scanner()
                if Task.isCancelled { break }
                self?.applyScan(scan)
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

    /// The partition style a fresh install on `disk` will use: GPT when
    /// the disk is too large for MBR, whatever the user chose otherwise,
    /// and the recommended style (MBR) if they haven't chosen.
    func effectiveInstallPartitionStyle(for disk: DiskTarget?) -> VentoyPartitionStyle {
        if let disk, !VentoyPartitionStyle.mbrCanAddress(diskBytes: disk.sizeInBytes) {
            return .gpt
        }
        return installPartitionStyleChoice
            ?? VentoyPartitionStyle.recommended(forDiskBytes: disk?.sizeInBytes ?? 0)
    }

    /// User picked a disk in the sidebar. Goes through here rather than
    /// writing `selectedDiskBSD` directly so the Ventoy probe follows
    /// the selection — before v0.4.0 a click left the Update tab
    /// showing the previously-selected disk's probe result (issue #7).
    func selectDisk(_ bsdName: String) {
        // Same freeze `applyDiskList` honours (Layer 2). The sheet is
        // modal so a click can't get here today; don't depend on that.
        guard pendingEraseConfirmation == nil else { return }
        guard selectedDiskBSD != bsdName, disks.contains(where: { $0.bsdName == bsdName }) else { return }
        selectedDiskBSD = bsdName
        triggerVentoyProbe()
    }

    /// One poll's result. A failed poll (`nil`) keeps the last list.
    func applyScan(_ scan: DiskInfo.ExternalDiskScan?) {
        guard let scan else {
            failedDiskPolls += 1
            return
        }
        if failedDiskPolls != 0 { failedDiskPolls = 0 }
        applyDiskList(scan.disks, timeMachine: scan.timeMachineDisks)
    }

    // Internal (not private) so MactoyTests can drive this directly to
    // verify Layer 2 of the iron-clad targeting defense (the selection
    // freeze while a confirmation is pending). v0.3.1 issue #1.
    // `timeMachine` has no default: it's a safety input.
    func applyDiskList(_ disks: [DiskTarget], timeMachine: Set<String>) {
        if timeMachineDisks != timeMachine {
            timeMachineDisks = timeMachine
        }
        // An unlock only lasts while that exact drive stays listed.
        let present = Set(disks.map(DiskIdentity.init))
        if !unlockedBackupDisks.isSubset(of: present) {
            unlockedBackupDisks.formIntersection(present)
        }

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
        // Auto-select a disk that isn't a Time Machine backup if there is
        // one; a backup drive is only selected if it's all there is.
        if selectedDiskBSD == nil,
           let first = disks.first(where: { !timeMachine.contains($0.bsdName) }) ?? disks.first {
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
        probeNeedsHelper = false
        guard let bsd else { return }
        probeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            do {
                guard let prober = self?.ventoyProber else { return }
                let result = try await prober(bsd)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    // Confirm the selection is still the disk we
                    // probed; user may have moved on while we waited.
                    if self.selectedDiskBSD == bsd {
                        self.applyProbeResult(result)
                    }
                }
            } catch {
                // Probe failure (helper not registered, XPC failure,
                // disk vanished). Surface to UI so the user sees a
                // diagnostic hint instead of a perpetual spinner.
                Self.log.info("Ventoy probe failed for \(bsd, privacy: .public): \(error.localizedDescription, privacy: .private)")
                if Task.isCancelled { return }
                let message = Self.probeErrorMessage(for: error)
                let needsHelper: Bool
                if case .xpcUnreachable? = error as? HelperInvoker.HelperError { needsHelper = true } else { needsHelper = false }
                await MainActor.run {
                    guard let self else { return }
                    if self.selectedDiskBSD == bsd {
                        self.probeError = message
                        self.probeNeedsHelper = needsHelper
                    }
                }
            }
        }
    }

    // Internal (not private) so MactoyTests can drive it without XPC.
    func applyProbeResult(_ result: VentoyProbeResult) {
        detectedVentoy = result
        probeError = nil
        probeNeedsHelper = false
        // Don't re-seed under a captured run (awaiting helper approval,
        // or failed and offering Retry): the stick re-enumerating after
        // a write re-probes it, and the toggle on screen should keep
        // showing what that run was asked to do.
        if result.isVentoyDisk, pendingRunTarget == nil {
            updateSecureBoot = result.secureBootEnabled
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
                return "Mactoy's helper isn't set up or can't be reached, so it can't read this disk. That's normal if you haven't used Mactoy to write a drive yet, or if the helper was removed after the last one. Set it up to check this disk for Ventoy — macOS will ask you to approve it. Nothing is written to the disk."
            case .executionFailed(let m):
                return "Probe failed: \(m)"
            case .versionMismatch:
                // Not thrown by the probe today (it doesn't ping), but
                // keep the message useful if that changes.
                return "Probe failed: \(helperErr.localizedDescription)"
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
        let confirmation = EraseConfirmation(
            mode: mode,
            disk: target,
            usedBytes: nil,
            totalBytes: target.sizeInBytes,
            secureBoot: mode == .updateVentoy ? updateSecureBoot : installSecureBoot,
            partitionStyle: effectiveInstallPartitionStyle(for: target),
            isTimeMachineBackup: isTimeMachineBackup(target),
            theme: mode == .installVentoy ? installTheme : .ventoyDefault,
            driveThemeProbePending: mode == .installVentoy
        )
        pendingEraseConfirmation = confirmation
        // The sheet opens now; the used-space line fills in when the
        // measurement returns, if this same confirmation is still open.
        let estimator = usedBytesEstimator
        Task { [weak self] in
            let used = await estimator(target.bsdName)
            guard let self, self.pendingEraseConfirmation?.id == confirmation.id else { return }
            self.pendingEraseConfirmation?.usedBytes = used.map { min($0, target.sizeInBytes) }
        }
        // Same for a theme on the drive: only an Install erases it, and
        // finding it reads the drive, so it fills in after the sheet is up.
        guard mode == .installVentoy else { return }
        let probe = driveThemeProbe
        Task { [weak self] in
            let found = await probe(target)
            guard let self, self.pendingEraseConfirmation?.id == confirmation.id else { return }
            self.pendingEraseConfirmation?.driveThemeProbePending = false
            guard let found else { return }
            self.pendingEraseConfirmation?.driveThemeName = found.name
            self.pendingEraseConfirmation?.driveThemeVolume = found.volume
        }
        // A drive that never answers must not hold Erase shut. After the cap
        // the button works; an answer that comes later still adds the box.
        let cap = driveThemeProbeCap
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: cap)
            guard let self, self.pendingEraseConfirmation?.id == confirmation.id else { return }
            self.pendingEraseConfirmation?.driveThemeProbePending = false
        }
    }

    func cancelRun() {
        pendingEraseConfirmation = nil
        didReregisterForVersionMismatch = false
        // Also clear the captured target/mode so a stale helper-poll
        // resume can't fire an install the user has since cancelled.
        pendingRunTarget = nil
        pendingRunMode = nil
        pendingRunSaveThemeVolume = nil
    }

    func confirmRun() {
        guard let confirmation = pendingEraseConfirmation else { return }
        didReregisterForVersionMismatch = false
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
        let capturedSecureBoot = confirmation.secureBoot
        let capturedPartitionStyle = confirmation.partitionStyle
        let capturedTheme = confirmation.theme
        // The box counts only if the sheet found a theme to keep, and only
        // for an Install: nothing else erases the drive's theme.
        let capturedSaveThemeFrom: URL? = capturedMode == .installVentoy && confirmation.saveDriveThemeFirst
            ? confirmation.driveThemeVolume : nil
        pendingRunTarget = capturedTarget
        pendingRunMode = capturedMode
        pendingRunSecureBoot = capturedSecureBoot
        pendingRunPartitionStyle = capturedPartitionStyle
        pendingRunTheme = capturedTheme
        pendingRunSaveThemeVolume = capturedSaveThemeFrom
        Task { @MainActor in
            await self.run(
                confirmedTarget: capturedTarget,
                confirmedMode: capturedMode,
                confirmedSecureBoot: capturedSecureBoot,
                confirmedPartitionStyle: capturedPartitionStyle,
                confirmedTheme: capturedTheme,
                confirmedSaveThemeFrom: capturedSaveThemeFrom
            )
        }
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
    ///
    /// `confirmedSecureBoot`, `confirmedPartitionStyle`, `confirmedTheme`
    /// and `confirmedSaveThemeFrom` are threaded the same way, for the
    /// same reason: the live toggles are presentation state (the update
    /// one is re-seeded by every probe).
    func run(
        confirmedTarget: DiskTarget,
        confirmedMode: AppMode,
        confirmedSecureBoot: Bool,
        confirmedPartitionStyle: VentoyPartitionStyle,
        confirmedTheme: ThemeChoice = .ventoyDefault,
        confirmedSaveThemeFrom: URL? = nil
    ) async {
        // A Retry pressed while the last run is still removing the helper waits for that to
        // finish. Otherwise the removal could stop the helper partway through this run.
        if let removal = helperRemoval {
            // Busy while waiting, so Retry and Done go away instead of looking dead.
            status = .preparing("Removing the helper from the last run…")
            await removal.value
        }
        cancelRequested = false
        cancelRefusedNote = nil
        runningMode = confirmedMode
        defer {
            cancelRequested = false
            cancelRefusedNote = nil
            runningMode = nil
        }
        let target = confirmedTarget
        runRequestCount += 1
        lastRunRequest = RunRequest(
            bsdName: target.bsdName,
            mode: confirmedMode,
            secureBoot: confirmedSecureBoot,
            partitionStyle: confirmedPartitionStyle,
            theme: confirmedTheme,
            saveThemeFrom: confirmedSaveThemeFrom
        )

        // Layer 6 (BSD-name guard), in `passesBSDNameGuard`. Also run
        // again after a pre-erase theme save, which can take a while.
        guard passesBSDNameGuard(target) else { return }

        // Time Machine guard (PR #13, v0.6.0): never write to a backup
        // drive the user hasn't unlocked. `canRun` already hides the
        // button; this also covers Retry and the approval resume, and
        // re-checks live rather than trusting the last poll (a container
        // can attach a moment after its disk is listed). A lookup that
        // fails refuses the run.
        if confirmedMode != .manageDisk {
            // Busy before the first await, so Install/Retry/Done can't
            // start a second run or reset the UI while this check runs
            // (it can take seconds on a busy backup volume).
            status = .preparing("Checking the drive…")
            do {
                let live = try await timeMachineLookup()
                if live.contains(target.bsdName), !timeMachineDisks.contains(target.bsdName) {
                    timeMachineDisks.insert(target.bsdName)
                }
            } catch {
                status = .failed("Refusing to run: couldn't check whether /dev/\(target.bsdName) holds Time Machine backups (\(error.localizedDescription)). Nothing was written. Try again in a moment.")
                Self.log.error("run() aborted: Time Machine lookup failed")
                return
            }
        }
        if confirmedMode != .manageDisk, isLockedBackup(target) {
            status = .failed(
                "Refusing to run: /dev/\(target.bsdName) holds Time Machine backups and hasn't been unlocked. " +
                "Select it and use Unlock This Drive… if you really mean to erase it."
            )
            Self.log.error("run() aborted: target is a locked Time Machine drive (\(target.bsdName, privacy: .public))")
            return
        }

        log = []
        status = .preparing("Preparing install plan...")
        Self.log.info("run() begin: mode=\(confirmedMode.rawValue, privacy: .public) target=/dev/\(target.bsdName, privacy: .public) secureBoot=\(confirmedSecureBoot, privacy: .public) partitionStyle=\(confirmedPartitionStyle.rawValue, privacy: .public)")

        // Layer 4 (app-side re-verification), in `passesLiveFingerprintCheck`.
        // Also run again after a pre-erase theme save.
        guard passesLiveFingerprintCheck(target) else { return }

        guard var plan = makePlan(
            target: target,
            mode: confirmedMode,
            secureBoot: confirmedSecureBoot,
            partitionStyle: confirmedPartitionStyle
        ) else { return }

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
                    ventoyOperation: plan.ventoyOperation,
                    secureBoot: plan.secureBoot,
                    partitionStyle: plan.partitionStyle,
                    expectedImageSHA256: plan.expectedImageSHA256,
                    verifyAfterWriting: plan.verifyAfterWriting
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
            approvalResumesRun = true
            showHelperExplainer = true
            status = .idle
            return
        }

        // Keep the drive's theme before anything is erased, if the user
        // asked. Deliberately after every check above (Layers 4 to 6, the
        // Time Machine check), so those still stop a wrong-disk run first,
        // and right before the helper, so nothing is sent if it fails. It
        // is cleared once saved, so Retry after a failed erase can't save
        // from a half-erased drive.
        if confirmedMode == .installVentoy, let themeVolume = confirmedSaveThemeFrom {
            // The helper is enabled by now, so a run that stops here still owes
            // the user's "remove helper after this run" choice.
            guard await saveDriveThemeBeforeErase(from: themeVolume, on: target) else {
                await removeHelperIfAsked()
                return
            }
            // The save can take a while on a slow stick, and Layer 4 is meant
            // to run immediately before the plan goes to the helper: check
            // the selection and the live disk again. Only after a save; a run
            // without one has only the plan, version lookup and helper gate in
            // between, as before.
            guard passesBSDNameGuard(target), passesLiveFingerprintCheck(target) else {
                await removeHelperIfAsked()
                return
            }
            // "Saving the drive's boot theme…" is over; it must not stay up while the helper erases.
            status = .preparing("Preparing install plan...")
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
            status = .success(Self.successMessage(for: plan))
            await addThemeAfterInstall(confirmedTheme, mode: confirmedMode, to: target)
            Self.log.info("run() success")
        } catch let err as HelperInvoker.HelperError where isFullDiskAccessError(err) {
            // TCC is blocking raw-disk access from the daemon. Users have
            // to grant Full Disk Access to Mactoy.app; TCC propagates
            // that grant to the daemon via AssociatedBundleIdentifiers.
            showFullDiskAccessSheet = true
            status = .failed("Full Disk Access is required — see the popup.")
            Self.log.error("run() failed: TCC blocked raw disk access (Full Disk Access required)")
        } catch let err as HelperInvoker.HelperError where isLookupFailure(err) || isVersionMismatch(err) {
            // Either BTM says the toggle is on but launchd has no
            // registration (after `sudo launchctl bootout` or a stale BTM
            // entry), or the registered helper belongs to another Mactoy
            // copy — older or newer (v0.5.0). Both are fixed by
            // re-submitting this app's daemon plist to launchd and
            // retrying once. Taking the helper over is always safe: the
            // retry again requires an exact version match before any plan
            // is sent, so nothing is written by a mismatched helper.
            // .private redacts in shared log output (e.g. when a user
            // pastes `log show` into a public GitHub issue) but stays
            // visible to the local user running `log show` themselves.
            Self.log.error("run() helper registration problem — retrying after re-register: \(err.localizedDescription, privacy: .private)")

            // Already re-registered for a version mismatch once in this
            // run's life (possibly before an approval detour) and it
            // still doesn't match: stop instead of looping.
            if isVersionMismatch(err) && didReregisterForVersionMismatch {
                status = .failed("\(err.localizedDescription)\n\nAnother copy of Mactoy on this Mac keeps taking over the helper. Quit it and move it to the Trash (keep only one copy, ideally in Applications), then try again.")
            } else {
                status = .preparing(isVersionMismatch(err)
                    ? "Helper is from another Mactoy version — switching it to this one…"
                    : "Helper daemon lost — re-registering…")

                var registered = false
                do {
                    try? await HelperLifecycle.unregister()
                    try HelperLifecycle.register()
                    registered = true
                    if isVersionMismatch(err) { didReregisterForVersionMismatch = true }
                } catch {
                    status = .failed(isVersionMismatch(err)
                        ? "Couldn't switch the helper over to this copy of Mactoy: \(error.localizedDescription)\n\nNothing was written. Quit any other copy of Mactoy and move it to the Trash, then try again."
                        : "Helper daemon could not be reached and auto-recovery failed.\n\nIn System Settings → General → \(SystemSettingsStrings.loginItemsPane), turn the Mactoy toggle OFF and back ON, then try again.\n\nUnderlying error: \(error.localizedDescription)")
                }

                if registered {
                    // Re-registering (especially from another bundle path)
                    // can leave the helper waiting for the user's approval.
                    // Hand over to the normal approval flow, which resumes
                    // this captured run once approved. Return straight away
                    // so the "uninstall helper after this run" cleanup
                    // below can't remove the helper mid-approval. (Set
                    // directly, like the approval poll does, so the user's
                    // uninstall choice isn't re-defaulted.)
                    helperStatus = HelperLifecycle.status
                    if helperStatus != .enabled {
                        Self.log.info("run(): helper needs approval after re-register — showing explainer")
                        status = .idle
                        approvalResumesRun = true
                        showHelperExplainer = true
                        return
                    }
                    // Brief pause for launchd to pick up the new submission.
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    do {
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
                        status = .success(Self.successMessage(for: plan))
                        await addThemeAfterInstall(confirmedTheme, mode: confirmedMode, to: target)
                    } catch let retryErr as HelperInvoker.HelperError where isFullDiskAccessError(retryErr) {
                        // Same handling as a first attempt.
                        showFullDiskAccessSheet = true
                        status = .failed("Full Disk Access is required — see the popup.")
                    } catch let retryErr as HelperInvoker.HelperError where isVersionMismatch(retryErr) {
                        // Could be another copy taking the helper back, or
                        // just the old helper process not having exited yet.
                        status = .failed("\(retryErr.localizedDescription)\n\nIf another copy of Mactoy is on this Mac, quit it and move it to the Trash (keep only one copy, ideally in Applications). Otherwise, wait a few seconds and press Retry.")
                    } catch let retryErr as HelperInvoker.HelperError where isLookupFailure(retryErr) {
                        status = .failed("Helper daemon could not be reached and auto-recovery failed.\n\nIn System Settings → General → \(SystemSettingsStrings.loginItemsPane), turn the Mactoy toggle OFF and back ON, then try again.\n\nUnderlying error: \(retryErr.localizedDescription)")
                    } catch {
                        // Anything else came from the helper actually
                        // running the plan — report it as it is.
                        status = .failed(error.localizedDescription)
                    }
                }
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
        await removeHelperIfAsked()

        // Clear the captured target/mode now — with one exception.
        // On terminal .failed we KEEP them so the "Retry" button in
        // the failure banner (v0.3.2, issue #5) can re-invoke run()
        // against the SAME captured disk without going through the
        // confirmation sheet again. Layers 4/5/6 of the iron-clad
        // targeting defense still verify the disk hasn't drifted at
        // retry time, so this doesn't reopen the wrong-disk race —
        // it just spares the user another confirmation click after
        // a hardware-level failure.
        //
        // On .success and .idle (helper-not-enabled early-return),
        // we do NOT clear here either: helper-approval resume needs
        // the pair, and success is followed by reset() which does
        // the clear.
        if case .failed = status {
            // keep pendingRunTarget/pendingRunMode for retry
        } else if case .success = status {
            pendingRunTarget = nil
            pendingRunMode = nil
            didReregisterForVersionMismatch = false
            // An unlocked backup drive has now been erased; if it ever
            // becomes a backup drive again it starts out locked.
            unlockedBackupDisks.remove(DiskIdentity(target))
        }
        // .idle (helper-not-enabled) leaves them alone — the helper-
        // poll resume path needs them.
    }

    /// Layer 6 (BSD-name guard): even if the rest of the
    /// fingerprint coincidentally matches a different live disk
    /// with the same `bsdName`, refuse if the captured BSD name
    /// differs from what the disk list currently believes is
    /// selected. The selection-freeze in `applyDiskList` should
    /// already prevent drift, but defense-in-depth wins here.
    /// Sets `.failed` and returns false when it refuses.
    private func passesBSDNameGuard(_ target: DiskTarget) -> Bool {
        if let liveSelection = selectedDiskBSD, liveSelection != target.bsdName {
            status = .failed(
                "Refusing to run: the selected disk changed between confirmation and execution. " +
                "Confirmed /dev/\(target.bsdName), but the sidebar now shows /dev/\(liveSelection) selected. " +
                "This usually means a USB drive was plugged or unplugged during the confirmation. Please re-select the disk and try again."
            )
            Self.log.error("run() aborted: selection drifted (confirmed=\(target.bsdName, privacy: .public), live=\(liveSelection, privacy: .public))")
            return false
        }
        return true
    }

    /// Layer 4 (app-side re-verification): probe the live disk and
    /// assert its identity matches what the user confirmed.
    /// Anything mismatched (size, mediaName, external/removable
    /// flags, BSD name, serial number) means the disk that's at /dev/<bsd> right
    /// now is NOT the disk the user confirmed. Abort hard — better
    /// a clear error than a silent wrong-disk write.
    /// Sets `.failed` and returns false when it refuses.
    private func passesLiveFingerprintCheck(_ target: DiskTarget) -> Bool {
        do {
            let live = try DiskInfo.probe(bsdName: target.bsdName)
            if let mismatch = target.fingerprintMismatch(against: live) {
                status = .failed(
                    "Refusing to run: the disk at /dev/\(target.bsdName) is not the same disk you confirmed. \(mismatch). " +
                    "This typically means a USB device was unplugged or replugged after you clicked the confirm button. Please re-select your target disk and try again."
                )
                Self.log.error("run() aborted: fingerprint mismatch — \(mismatch, privacy: .public)")
                return false
            }
        } catch {
            status = .failed(
                "Refusing to run: could not re-verify /dev/\(target.bsdName) before writing. \(error.localizedDescription) " +
                "Please re-select the disk and try again."
            )
            Self.log.error("run() aborted: probe failed — \(error.localizedDescription, privacy: .private)")
            return false
        }
        return true
    }

    /// The plan `run(...)` hands to the helper, built from the choices
    /// captured at confirmation. `nil` for modes that don't run (Manage
    /// Disk) or a Flash Image run with no image picked. Internal so
    /// tests can check what reaches the plan.
    /// What a finished run says. A flash says whether the drive was read back (#26).
    static func successMessage(for plan: InstallPlan) -> String {
        guard plan.driver == .rawImage else { return "Install complete" }
        return plan.verifyAfterWriting
            ? "Flash complete. Mactoy read the drive back and it matches the image."
            : "Flash complete."
    }

    func makePlan(
        target: DiskTarget,
        mode: AppMode,
        secureBoot: Bool,
        partitionStyle: VentoyPartitionStyle
    ) -> InstallPlan? {
        let source: InstallSource
        let driver: DriverID
        let ventoyOperation: VentoyOperation
        switch mode {
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
            guard let p = selectedImagePath else { return nil }
            source = .localImage(path: p)
        case .manageDisk:
            return nil
        }

        // Vestigial since v0.4.0: the daemon keeps its own tarball cache
        // and scratch space (issue #8) and ignores this. Still sent
        // because `InstallPlan.workDir` is a required key for any
        // older daemon that's still registered.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactoy-\(UUID().uuidString.prefix(8))")

        return InstallPlan(
            driver: driver,
            target: target,
            source: source,
            filesystem: .exfat,
            workDir: workDir.path,
            ventoyOperation: ventoyOperation,
            secureBoot: secureBoot,
            partitionStyle: partitionStyle,
            // An invalid entry goes in as typed, so validate() stops the run. Dropping it would
            // flash with no check after a Retry or an approval, which don't go through canRun.
            expectedImageSHA256: mode == .flashImage ? flashChecksumForPlan : nil,
            verifyAfterWriting: mode == .flashImage && flashVerifyAfterWriting
        )
    }

    /// Honours the "remove helper after this run" checkbox, for a run that has
    /// got past the helper gate: the end of `run()` and its early exits after
    /// the gate all use this. Silent failure on unregister is fine; the daemon
    /// may already be gone (e.g. the user toggled it off manually).
    /// Internal so tests can check it.
    func removeHelperIfAsked() async {
        guard uninstallHelperAfterRun else { return }
        let removal = Task { @MainActor in await helperRemover() }
        helperRemoval = removal
        await removal.value
        if helperRemoval == removal { helperRemoval = nil }
        helperStatus = HelperLifecycle.status
    }

    // MARK: - Cancel (#21)

    /// The mode of the run in progress, set by `run()`. Internal so tests can set it.
    var runningMode: AppMode?
    /// Seam for tests: asks the helper to stop the run in progress.
    var helperRunCanceller: @Sendable () async throws -> Bool = { try await HelperInvoker.cancelCurrentRun() }
    /// The user pressed Cancel and the helper accepted; the run ends at its next safe point.
    @Published private(set) var cancelRequested = false
    /// The helper said it's too late to stop. Shown under the progress bar.
    @Published private(set) var cancelRefusedNote: String?

    /// Cancel is offered while the helper is running the plan and stopping is still safe: a
    /// Ventoy install or update until it starts writing, a flash at any point.
    var canCancelRun: Bool {
        guard case .running(let update) = status, !cancelRequested else { return false }
        if runningMode == .flashImage { return update.phase != .done && update.phase != .failed }
        return [.preparing, .downloading, .extracting].contains(update.phase)
    }

    /// Stopping a flash partway through writing leaves the drive unusable, so the app asks first.
    var cancelNeedsConfirmation: Bool {
        guard case .running(let update) = status else { return false }
        return runningMode == .flashImage && update.phase == .writing
    }

    func cancelRunInProgress() async {
        guard canCancelRun else { return }
        cancelRequested = true
        cancelRefusedNote = nil
        let accepted = (try? await helperRunCanceller()) ?? false
        if !accepted {
            cancelRequested = false
            // Still running means the helper got past the point where stopping is safe.
            if case .running = status {
                cancelRefusedNote = "Too late to cancel: Mactoy has started writing the drive, and stopping now would leave it unusable."
            }
        }
    }

    // MARK: - Clear Ventoy downloads (issue #22)

    /// Seams for tests: the helper's cache (root's, so only the helper can delete it), this
    /// account's cache, and whether the helper's cache is there at all.
    var helperDownloadClearer: @Sendable () async throws -> UInt64 = { try await HelperInvoker.clearDownloads() }
    var localDownloadClearer: @Sendable () throws -> UInt64 = { try VentoyDownloader.clearCache() }
    var helperDownloadsExist: @Sendable () -> Bool = {
        FileManager.default.fileExists(atPath: VentoyDownloader.helperCacheRoot.path)
    }
    /// What the last Clear Ventoy Downloads did. Drives an alert.
    @Published var clearDownloadsReport: String?

    /// Not while a drive is being written (that run may be using the cache), while the helper is
    /// being removed, or while a sheet is open: the result alert can't show over a sheet.
    var canClearDownloads: Bool {
        guard helperRemoval == nil, !showHelperExplainer, !isAwaitingHelperApproval,
              !showFullDiskAccessSheet, pendingEraseConfirmation == nil else { return false }
        switch status {
        case .preparing, .running: return false
        case .idle, .success, .failed: return true
        }
    }

    func clearVentoyDownloads() async {
        guard canClearDownloads else { return }
        var freed: UInt64 = 0
        var notes: [String] = []
        do {
            freed += try localDownloadClearer()
        } catch {
            // "\(error)": DriverError's description is readable; its localizedDescription isn't.
            notes.append("Couldn't clear the downloads in your Caches folder: \(error)")
        }
        // Read directly rather than through refreshHelperStatus(), which would also reset the
        // "remove helper after this run" choice of a run waiting on approval.
        if helperStatusSource() == .enabled {
            do {
                freed += try await helperDownloadClearer()
            } catch HelperInvoker.HelperError.versionMismatch {
                notes.append("Mactoy's helper is from another version of Mactoy, so the downloads it keeps weren't cleared. Mactoy updates the helper at the next install.")
            } catch HelperInvoker.HelperError.xpcUnreachable {
                notes.append("Mactoy couldn't reach its helper, so the downloads it keeps weren't cleared. They're cleared the next time Mactoy removes the helper after an install.")
            } catch {
                notes.append("Couldn't clear the downloads Mactoy's helper keeps: \(error.localizedDescription)")
            }
        } else if helperDownloadsExist() {
            notes.append("Mactoy's helper isn't set up right now, so the downloads it keeps in /Library/Application Support/Mactoy weren't cleared. Mactoy clears them when it removes the helper after an install.")
        }
        let summary = freed > 0
            ? "Cleared \(ByteCountFormatter.string(fromByteCount: Int64(clamping: freed), countStyle: .file)) of Ventoy downloads."
            : (notes.isEmpty ? "There were no Ventoy downloads to clear." : "")
        clearDownloadsReport = ([summary] + notes).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    func reset() {
        status = .idle
        didReregisterForVersionMismatch = false
        log = []
        pendingRunTarget = nil
        pendingRunMode = nil
        pendingRunSaveThemeVolume = nil
    }

    /// Before an Install erases the drive: keep the theme it has in My
    /// Themes, if the user ticked the box. Returns false, with the run
    /// failed and nothing erased, when that didn't work: a theme the user
    /// asked to keep must not be erased unsaved.
    ///
    /// Re-checks that the volume still belongs to the confirmed disk
    /// first: the URL was found when the sheet opened, and a different
    /// drive may be mounted under the same name by now.
    func saveDriveThemeBeforeErase(from volume: URL, on target: DiskTarget) async -> Bool {
        status = .preparing("Saving the drive's boot theme…")
        do {
            guard let id = await driveVolumeIdentifier(volume), id.hasPrefix(target.bsdName + "s") else {
                throw DriveThemeSaveError.notOnConfirmedDisk(target.bsdName)
            }
            try await driveThemeSaver(volume)
        } catch {
            // The reason is spliced into a sentence of its own.
            var reason = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            while reason.hasSuffix(".") { reason.removeLast() }
            status = .failed("Couldn't save the drive's boot theme: \(reason). Nothing was erased. Choose Retry to try saving again, or choose Done and start the install again with the option unticked to erase without saving.")
            Self.log.error("run() aborted: couldn't save the drive's theme before the erase")
            return false
        }
        pendingRunSaveThemeVolume = nil
        return true
    }

    private enum DriveThemeSaveError: LocalizedError {
        case notOnConfirmedDisk(String)
        var errorDescription: String? {
            switch self {
            case .notOnConfirmedDisk(let bsd): return "the drive's Ventoy volume is no longer mounted from /dev/\(bsd)"
            }
        }
    }

    /// After a fresh install succeeds, add the boot theme the user picked.
    /// The install already worked, so a theme problem is reported as part
    /// of the success message, never as a failure (which would offer a
    /// Retry that erases the drive again). Warnings from a theme that was
    /// added are a note on the success, not a problem.
    func addThemeAfterInstall(_ theme: ThemeChoice, mode: AppMode, to target: DiskTarget) async {
        guard mode == .installVentoy, theme != .ventoyDefault else { return }
        status = .preparing("Adding the boot theme…")
        switch await installThemeApplier(theme, target) {
        case .applied(let warnings):
            let notes = warnings.map(Self.asSentence).filter { !$0.isEmpty }
            status = .success(notes.isEmpty
                ? "Install complete, with your boot theme"
                : "Install complete, with your boot theme. Note: \(notes.joined(separator: " "))")
        case .notApplied(let problem):
            status = .success("Install complete. The boot theme wasn't added: \(Self.asSentence(problem)) You can add it from Manage Disk.")
        case .themeUnavailable(let problem):
            // Adding the same theme later would fail the same way.
            status = .success("Install complete. The boot theme wasn't added: \(Self.asSentence(problem)) You can pick another theme from Manage Disk.")
        }
    }

    /// `text` as a finished sentence, for splicing into a longer message: surrounding
    /// whitespace dropped, and a period added unless it ends in ".", "!" or "?".
    /// Empty stays empty.
    static func asSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?".contains(last) else { return trimmed }
        return trimmed + "."
    }

    /// True when a failed run has a captured target we can retry
    /// against. Used by the ActionBar's failure state to decide
    /// whether to show the Retry button next to Done.
    var canRetryRun: Bool {
        if case .failed = status {
            return pendingRunTarget != nil && pendingRunMode != nil
        }
        return false
    }

    /// Re-invoke the last failed run against the same captured target
    /// and mode. Does NOT re-derive from `selectedDisk` — same iron-
    /// clad targeting rules as `confirmRun()`. Layers 4/5/6 in run()
    /// still verify the disk's fingerprint hasn't drifted.
    func retryRun() async {
        guard let target = pendingRunTarget, let mode = pendingRunMode else {
            Self.log.warning("retryRun called with no captured target — ignoring")
            return
        }
        didReregisterForVersionMismatch = false
        Self.log.info("retryRun: re-invoking run() with captured target /dev/\(target.bsdName, privacy: .public)")
        await run(
            confirmedTarget: target,
            confirmedMode: mode,
            confirmedSecureBoot: pendingRunSecureBoot,
            confirmedPartitionStyle: pendingRunPartitionStyle,
            confirmedTheme: pendingRunTheme,
            confirmedSaveThemeFrom: pendingRunSaveThemeVolume
        )
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
