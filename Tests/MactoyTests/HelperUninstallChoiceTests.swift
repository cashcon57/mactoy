import Testing
@testable import Mactoy
import MactoyKit

/// "Remove the helper after this install" (HelperExplainerSheet) must
/// survive until the run it was chosen for finishes. Before v0.5.1,
/// `refreshHelperStatus()` re-applied the default on every call, so the
/// run that resumes after approval unticked it and the helper was never
/// removed.
@MainActor
@Suite("Remove-helper-after-install choice")
struct HelperUninstallChoiceTests {

    private func state(source: HelperStatus) -> AppState {
        let s = AppState()
        s.helperStatusSource = { source }
        return s
    }

    @Test("the resumed run keeps a ticked choice (the v0.5.0 bug)")
    func resumeKeepsTickedChoice() {
        let s = state(source: .enabled)
        s.uninstallHelperAfterRun = true     // user left it ticked in the sheet
        s.helperStatus = .enabled            // approval poll saw the toggle flip
        s.refreshHelperStatus()              // run() resumes and refreshes
        #expect(s.uninstallHelperAfterRun == true)
    }

    @Test("the resumed run keeps an unticked choice")
    func resumeKeepsUntickedChoice() {
        let s = state(source: .enabled)
        s.uninstallHelperAfterRun = false
        s.helperStatus = .enabled
        s.refreshHelperStatus()
        #expect(s.uninstallHelperAfterRun == false)
    }

    @Test("launch with the helper already installed: unticked by default")
    func launchWithHelperInstalled() {
        let s = state(source: .enabled)
        s.refreshHelperStatus()
        #expect(s.helperStatus == .enabled)
        #expect(s.uninstallHelperAfterRun == false)
    }

    @Test("launch without the helper: ticked by default")
    func launchWithoutHelper() {
        let s = state(source: .notRegistered)
        s.refreshHelperStatus()
        #expect(s.uninstallHelperAfterRun == true)
    }

    @Test("helper removed since last check (e.g. by the previous run): ticked again for the next sheet")
    func helperRemovedRedefaults() {
        let s = state(source: .notRegistered)
        s.helperStatus = .enabled
        s.uninstallHelperAfterRun = false
        s.refreshHelperStatus()
        #expect(s.helperStatus == .notRegistered)
        #expect(s.uninstallHelperAfterRun == true)
    }

    // MARK: Update tab when the helper has been removed

    private func disk() -> MactoyKit.DiskTarget {
        DiskTarget(bsdName: "disk5", sizeInBytes: 64_000_000_000, isExternal: true,
                   isRemovable: true, mediaName: "Stick", volumes: [])
    }

    @Test("a probe that can't reach the helper offers to set it up; a later success clears that")
    func probeOffersHelperSetup() async {
        let s = state(source: .notRegistered)
        s.disks = [disk()]
        s.selectedDiskBSD = "disk5"
        s.ventoyProber = { _ in throw HelperInvoker.HelperError.xpcUnreachable("Connection init failed at lookup") }
        s.triggerVentoyProbe()
        var waited = 0
        while s.probeError == nil && waited < 200 { try? await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        #expect(s.probeNeedsHelper)
        #expect(s.probeError?.contains("fresh install") == false, "must not point users at an erase")

        s.applyProbeResult(.unknownDisk(bsdName: "disk5", reason: "not ventoy"))
        #expect(!s.probeNeedsHelper)
    }

    @Test("other probe failures don't offer helper setup")
    func otherProbeFailures() async {
        let s = state(source: .enabled)
        s.disks = [disk()]
        s.selectedDiskBSD = "disk5"
        s.ventoyProber = { _ in throw HelperInvoker.HelperError.executionFailed("decode failed") }
        s.triggerVentoyProbe()
        var waited = 0
        while s.probeError == nil && waited < 200 { try? await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        #expect(s.probeError != nil)
        #expect(!s.probeNeedsHelper)
    }

    // MARK: Set Up Helper must never start or resume a run

    /// A failed fresh install with its target still captured for Retry,
    /// on a fictitious disk (the run stops at the live re-probe, so
    /// nothing reaches a helper or a real disk).
    private func stateWithFailedInstall() async -> AppState {
        let s = state(source: .enabled)
        s.ventoyProber = { _ in throw HelperInvoker.HelperError.xpcUnreachable("Connection init failed at lookup") }
        let d = DiskTarget(bsdName: "disk97", sizeInBytes: 64_000_000_000, isExternal: true,
                           isRemovable: true, mediaName: "Stick", volumes: [])
        s.disks = [d]
        s.selectedDiskBSD = "disk97"
        s.mode = .installVentoy
        s.requestRun()
        s.confirmRun()
        var waited = 0
        while !s.canRetryRun && waited < 500 { try? await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        // The Update tab's probe then fails for want of a helper.
        s.mode = .updateVentoy
        s.triggerVentoyProbe()
        waited = 0
        while !s.probeNeedsHelper && waited < 500 { try? await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        #expect(s.canRetryRun && s.probeNeedsHelper, "setup didn't reach a failed run plus a helper-less probe")
        return s
    }

    @Test("approving via Set Up Helper doesn't restart a failed install that's waiting for Retry")
    func setUpHelperNeverResumesRun() async {
        let s = await stateWithFailedInstall()
        #expect(s.canRetryRun)
        #expect(s.runRequestCount == 1)
        #expect(s.canSetUpHelperForProbe)

        s.setUpHelperForProbe()
        #expect(s.showHelperExplainer)
        s.showHelperExplainer = false               // Allow
        s.helperRegistrar = HelperRegistrar(unregister: {}, register: {}, openSettings: {})
        s.helperStatusSource = { .enabled }         // user approves in Settings
        s.beginHelperApproval()
        var waited = 0
        while s.isAwaitingHelperApproval && waited < 500 { try? await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        #expect(!s.isAwaitingHelperApproval, "the approval must actually complete for this test to mean anything")
        try? await Task.sleep(nanoseconds: 200_000_000)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(s.runRequestCount == 1, "no run may start")
        #expect(s.canRetryRun, "the failed run is still there for an explicit Retry")
    }

    @Test("cancelling a Set Up Helper approval keeps the failed run's Retry")
    func setUpHelperCancelKeepsRetry() async {
        let s = await stateWithFailedInstall()
        s.setUpHelperForProbe()
        s.cancelHelperApproval()
        #expect(s.canRetryRun)
    }

    @Test("an approval started by a run still resumes that run")
    func runApprovalResumes() async {
        let s = await stateWithFailedInstall()
        // As run(...) does when the helper isn't enabled: explainer with
        // the "resume" purpose. Approval then resumes the run.
        s.helperApprovalCompleted(resumesRun: true)
        var waited = 0
        while s.runRequestCount < 2 && waited < 300 { try? await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        #expect(s.runRequestCount == 2)
    }

    @Test("Set Up Helper isn't offered while a run is in progress or an approval is under way")
    func setUpHelperGating() {
        let s = state(source: .notRegistered)
        s.probeNeedsHelper = true
        #expect(s.canSetUpHelperForProbe)
        s.status = .preparing("…")
        #expect(!s.canSetUpHelperForProbe)
        s.setUpHelperForProbe()
        #expect(!s.showHelperExplainer)
        s.status = .idle
        s.isAwaitingHelperApproval = true
        #expect(!s.canSetUpHelperForProbe)
    }

    // MARK: Cancelling mid-approval (round-2 finding)

    @MainActor final class Calls { var register = 0; var openSettings = 0 }

    /// Unregister takes 300 ms, so a cancel can land in the middle of it.
    private func slowRegistrar(_ calls: Calls) -> HelperRegistrar {
        HelperRegistrar(
            unregister: { try? await Task.sleep(nanoseconds: 300_000_000) },
            register: { calls.register += 1 },
            openSettings: { calls.openSettings += 1 }
        )
    }

    @Test("cancelling Set Up Helper while it's registering stops it cold — no Settings, no poll, no run")
    func cancelMidRegistration() async {
        let s = await stateWithFailedInstall()
        let calls = Calls()
        s.helperRegistrar = slowRegistrar(calls)
        s.helperStatusSource = { .enabled }          // as if the user flipped the toggle anyway

        s.setUpHelperForProbe()
        s.showHelperExplainer = false                // explainer's Allow button
        s.beginHelperApproval()
        #expect(s.isAwaitingHelperApproval)
        s.cancelHelperApproval()                     // Cancel on the waiting sheet, mid-unregister

        try? await Task.sleep(nanoseconds: 1_600_000_000)   // past unregister + one poll interval
        #expect(calls.register == 0)
        #expect(calls.openSettings == 0)
        #expect(s.runRequestCount == 1, "the failed install must not restart")
        #expect(s.canRetryRun)
    }

    @Test("a completed Set Up Helper approval re-checks the disk and never resumes the failed run")
    func fullSetUpApprovalFlow() async {
        let s = await stateWithFailedInstall()
        let calls = Calls()
        s.helperRegistrar = HelperRegistrar(unregister: {}, register: { calls.register += 1 },
                                            openSettings: { calls.openSettings += 1 })
        s.helperStatusSource = { .enabled }
        s.setUpHelperForProbe()
        s.showHelperExplainer = false
        s.beginHelperApproval()
        var waited = 0
        while s.isAwaitingHelperApproval && waited < 300 { try? await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        #expect(!s.isAwaitingHelperApproval)
        #expect(calls.register == 1 && calls.openSettings == 1)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(s.runRequestCount == 1)
        #expect(s.canRetryRun)
    }

    @Test("a run's approval, completed through the real poll, resumes exactly that run once")
    func fullRunApprovalFlow() async {
        let s = await stateWithFailedInstall()
        s.helperRegistrar = HelperRegistrar(unregister: {}, register: {}, openSettings: {})
        s.helperStatusSource = { .enabled }
        s.beginHelperApproval()                      // as run(...) does, purpose = resume
        var waited = 0
        while s.runRequestCount < 2 && waited < 300 { try? await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(s.runRequestCount == 2)
    }

    @Test("Set Up Helper isn't offered while the explainer is already up")
    func setUpHelperHiddenWithExplainer() {
        let s = state(source: .notRegistered)
        s.probeNeedsHelper = true
        s.showHelperExplainer = true
        #expect(!s.canSetUpHelperForProbe)
    }

    @Test("cancel, then a new approval straight away: the old one's late unregister changes nothing")
    func cancelThenRestart() async {
        let s = await stateWithFailedInstall()
        let calls = Calls()
        s.helperRegistrar = slowRegistrar(calls)
        s.helperStatusSource = { .notRegistered }    // nobody approves yet

        s.setUpHelperForProbe(); s.showHelperExplainer = false
        s.beginHelperApproval()
        s.cancelHelperApproval()                     // first approval cancelled mid-unregister
        s.setUpHelperForProbe(); s.showHelperExplainer = false
        s.beginHelperApproval()                      // second one starts immediately

        var waited = 0
        while calls.register == 0 && waited < 500 { try? await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        try? await Task.sleep(nanoseconds: 700_000_000)     // give a stale task every chance to act
        #expect(calls.register == 1, "only the live approval registers")
        #expect(calls.openSettings == 1)
        #expect(s.isAwaitingHelperApproval)
        s.cancelHelperApproval()
        #expect(s.runRequestCount == 1)
        #expect(s.canRetryRun)
    }
}
