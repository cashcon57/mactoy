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

    // MARK: Partition style (issue #11)

    private func disk(_ bsd: String, bytes: UInt64) -> DiskTarget {
        DiskTarget(bsdName: bsd, sizeInBytes: bytes, isExternal: true, isRemovable: true,
                   mediaName: "Test Disk \(bsd)", volumes: [])
    }

    @Test("install defaults to MBR, follows the user's choice, and is forced to GPT past 2 TiB")
    func partitionStyleDefaults() {
        let state = makeState()
        let small = disk("disk5"), huge = disk("disk6", bytes: 4_000_787_030_016)
        #expect(state.effectiveInstallPartitionStyle(for: small) == .mbr)
        #expect(state.effectiveInstallPartitionStyle(for: nil) == .mbr)
        #expect(state.effectiveInstallPartitionStyle(for: huge) == .gpt)

        state.installPartitionStyleChoice = .gpt
        #expect(state.effectiveInstallPartitionStyle(for: small) == .gpt)

        state.installPartitionStyleChoice = .mbr
        #expect(state.effectiveInstallPartitionStyle(for: huge) == .gpt, "MBR can't address it, whatever was chosen")
    }

    @Test("the partition style is captured at confirmation")
    func partitionStyleCaptured() {
        let state = makeState()
        state.disks = [disk("disk5")]
        state.selectedDiskBSD = "disk5"
        state.mode = .installVentoy
        state.requestRun()
        #expect(state.pendingEraseConfirmation?.partitionStyle == .mbr)

        state.cancelRun()
        state.installPartitionStyleChoice = .gpt
        state.requestRun()
        #expect(state.pendingEraseConfirmation?.partitionStyle == .gpt)
        // Changing the choice after the sheet is up doesn't change what it captured.
        state.installPartitionStyleChoice = .mbr
        #expect(state.pendingEraseConfirmation?.partitionStyle == .gpt)
    }

    @Test("the 2 TiB boundary: last MBR-addressable size stays MBR, one sector more is GPT")
    func partitionStyleBoundary() {
        let state = makeState()
        #expect(state.effectiveInstallPartitionStyle(for: disk("disk5", bytes: 0xFFFF_FFFF * 512)) == .mbr)
        #expect(state.effectiveInstallPartitionStyle(for: disk("disk5", bytes: 0x1_0000_0000 * 512)) == .gpt)
    }

    @Test("switching Install → Update → Install captures the style the card shows")
    func partitionStyleAcrossModes() {
        let state = makeState()
        state.disks = [disk("disk5")]
        state.selectedDiskBSD = "disk5"
        state.installPartitionStyleChoice = .gpt
        state.mode = .installVentoy
        state.requestRun(); state.cancelRun()
        state.mode = .updateVentoy
        state.applyProbeResult(probe("disk5", isVentoy: true, secureBoot: true))
        state.requestRun(); state.cancelRun()
        state.mode = .installVentoy
        state.requestRun()
        #expect(state.pendingEraseConfirmation?.partitionStyle == state.effectiveInstallPartitionStyle(for: state.selectedDisk))
        #expect(state.pendingEraseConfirmation?.partitionStyle == .gpt)
    }

    /// The disk is fictitious, so `run()` stops at its live re-probe
    /// (Layer 4) before reaching the helper — nothing is written. That
    /// leaves the captured pair in place for Retry, which is the path
    /// under test.
    @Test("Retry uses the captured partition style, not a choice changed after the failure")
    func retryUsesCapturedPartitionStyle() async {
        let state = makeState()
        let d = disk("disk97")
        state.disks = [d]
        state.selectedDiskBSD = d.bsdName
        state.mode = .installVentoy
        state.installPartitionStyleChoice = .gpt
        state.requestRun()
        state.confirmRun()
        var waited = 0
        while !state.canRetryRun && waited < 300 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        #expect(state.canRetryRun)
        #expect(state.runRequestCount == 1)
        #expect(state.lastRunRequest?.partitionStyle == .gpt)

        state.installPartitionStyleChoice = .mbr     // user changes their mind after the failure
        await state.retryRun()
        #expect(state.runRequestCount == 2, "retry must actually re-enter run()")
        #expect(state.lastRunRequest?.partitionStyle == .gpt)
        #expect(state.lastRunRequest?.bsdName == "disk97")
    }

    @Test("the plan carries the confirmed style and Secure Boot choice, whatever the live toggles say")
    func planCarriesConfirmedChoices() throws {
        let state = makeState()
        state.installPartitionStyleChoice = .gpt
        state.installSecureBoot = true
        let d = disk("disk5")
        let install = try #require(state.makePlan(target: d, mode: .installVentoy, secureBoot: false, partitionStyle: .mbr))
        #expect(install.partitionStyle == .mbr)
        #expect(install.secureBoot == false)
        #expect(install.ventoyOperation == .freshInstall)
        let gpt = try #require(state.makePlan(target: d, mode: .installVentoy, secureBoot: true, partitionStyle: .gpt))
        #expect(gpt.partitionStyle == .gpt)
        let update = try #require(state.makePlan(target: d, mode: .updateVentoy, secureBoot: true, partitionStyle: .mbr))
        #expect(update.ventoyOperation == .updateInPlace)
        #expect(state.makePlan(target: d, mode: .manageDisk, secureBoot: true, partitionStyle: .mbr) == nil)
        #expect(state.makePlan(target: d, mode: .flashImage, secureBoot: true, partitionStyle: .mbr) == nil, "no image picked")
    }
}
