import Testing
import Foundation
@testable import Mactoy
import MactoyKit

/// Sidebar selection (issue #7) and the probe → Secure Boot toggle
/// seeding (issue #9).
@MainActor
@Suite("AppState selection + probe seeding")
struct AppStateSelectionTests {

    private func disk(_ bsd: String) -> DiskTarget {
        DiskTarget(
            bsdName: bsd,
            sizeInBytes: 100_000_000_000,
            isExternal: true,
            isRemovable: true,
            mediaName: "Test Disk \(bsd)",
            volumes: []
        )
    }

    /// AppState with the XPC probe stubbed out — selection changes fire
    /// a probe, and the real one talks to the root daemon.
    private func makeState() -> AppState {
        let state = AppState()
        state.ventoyProber = { bsd in .unknownDisk(bsdName: bsd, reason: "stub") }
        return state
    }

    private func probe(_ bsd: String, isVentoy: Bool, secureBoot: Bool) -> VentoyProbeResult {
        VentoyProbeResult(
            bsdName: bsd,
            isVentoyDisk: isVentoy,
            detectedVersion: isVentoy ? "1.1.17" : nil,
            secureBootEnabled: secureBoot,
            partitionStyle: .gpt,
            partition2StartSector: 1000,
            layoutIssues: isVentoy ? [] : ["not ventoy"],
            looksLikeBrokenVentoy: false
        )
    }

    @Test("selecting another disk moves the selection and drops the previous disk's probe result")
    func selectDropsStaleProbe() {
        let state = makeState()
        state.disks = [disk("disk5"), disk("disk6")]
        state.selectedDiskBSD = "disk5"
        state.applyProbeResult(probe("disk5", isVentoy: true, secureBoot: true))
        #expect(state.detectedVentoy != nil)

        state.selectDisk("disk6")

        #expect(state.selectedDiskBSD == "disk6")
        // Pre-v0.4.0 this still held disk5's result, so the Update tab
        // described the wrong drive.
        #expect(state.detectedVentoy == nil)
    }

    @Test("selecting a disk that isn't in the list is ignored")
    func selectUnknownIgnored() {
        let state = makeState()
        state.disks = [disk("disk5")]
        state.selectedDiskBSD = "disk5"
        state.selectDisk("disk9")
        #expect(state.selectedDiskBSD == "disk5")
    }

    @Test("re-selecting the current disk doesn't throw away its probe result")
    func reselectKeepsProbe() {
        let state = makeState()
        state.disks = [disk("disk5")]
        state.selectedDiskBSD = "disk5"
        state.applyProbeResult(probe("disk5", isVentoy: true, secureBoot: true))
        state.selectDisk("disk5")
        #expect(state.detectedVentoy != nil)
    }

    @Test("a Ventoy probe seeds the update toggle from the drive; install toggle is untouched")
    func probeSeedsUpdateToggle() {
        let state = makeState()
        #expect(state.installSecureBoot == true)
        #expect(state.updateSecureBoot == true)

        state.applyProbeResult(probe("disk5", isVentoy: true, secureBoot: false))
        #expect(state.updateSecureBoot == false)
        #expect(state.installSecureBoot == true)

        state.applyProbeResult(probe("disk5", isVentoy: true, secureBoot: true))
        #expect(state.updateSecureBoot == true)
    }

    @Test("a non-Ventoy probe leaves the update toggle alone")
    func nonVentoyProbeDoesNotSeed() {
        let state = makeState()
        state.updateSecureBoot = false
        state.applyProbeResult(probe("disk5", isVentoy: false, secureBoot: true))
        #expect(state.updateSecureBoot == false)
    }

    @Test("the Secure Boot choice is captured at confirmation, not read live at run time")
    func secureBootCapturedAtConfirmation() {
        let state = makeState()
        state.disks = [disk("disk5")]
        state.selectedDiskBSD = "disk5"
        state.mode = .updateVentoy
        state.applyProbeResult(probe("disk5", isVentoy: true, secureBoot: true))
        state.updateSecureBoot = false          // user flips it off…

        state.requestRun()                       // …and clicks Update
        #expect(state.pendingEraseConfirmation?.secureBoot == false)

        state.mode = .installVentoy
        state.cancelRun()
        state.requestRun()
        #expect(state.pendingEraseConfirmation?.secureBoot == true, "install uses its own toggle")
    }

    @Test("a re-probe under a captured run doesn't re-seed the update toggle")
    func noReseedWhileRunCaptured() {
        let state = makeState()
        state.disks = [disk("disk5")]
        state.selectedDiskBSD = "disk5"
        state.mode = .updateVentoy
        state.applyProbeResult(probe("disk5", isVentoy: true, secureBoot: true))
        state.updateSecureBoot = false
        state.requestRun()
        state.confirmRun()                       // captures target/mode/secureBoot

        // Stick re-enumerates after the write attempt and is re-probed:
        state.applyProbeResult(probe("disk5", isVentoy: true, secureBoot: true))
        #expect(state.updateSecureBoot == false)
    }

    @Test("selectDisk honours the confirmation freeze")
    func selectFrozenDuringConfirmation() {
        let state = makeState()
        state.disks = [disk("disk5"), disk("disk6")]
        state.selectedDiskBSD = "disk5"
        state.requestRun()
        #expect(state.pendingEraseConfirmation != nil)
        state.selectDisk("disk6")
        #expect(state.selectedDiskBSD == "disk5")
    }
}
