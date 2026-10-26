import Testing
import Foundation
@testable import Mactoy
import MactoyKit

/// Time Machine drives are listed but locked (PR #13 follow-up, v0.6.0):
/// nothing writes to one unless the user unlocks that drive for the
/// session.
@MainActor
@Suite("Time Machine drive guard")
struct TimeMachineGuardTests {

    private func disk(_ bsd: String, size: UInt64 = 2_000_000_000_000, name: String = "Backup Drive") -> DiskTarget {
        DiskTarget(bsdName: bsd, sizeInBytes: size, isExternal: true, isRemovable: true, mediaName: name, volumes: [])
    }

    private func state() -> AppState {
        let s = AppState()
        s.ventoyProber = { .unknownDisk(bsdName: $0, reason: "stub") }
        s.usedBytesEstimator = { _ in nil }
        s.timeMachineLookup = { [] }
        return s
    }

    @Test("a Time Machine drive is listed, marked, and locked for every writing mode")
    func lockedByDefault() {
        let s = state()
        let tm = disk("disk4")
        s.applyDiskList([tm], timeMachine: ["disk4"])
        #expect(s.disks == [tm])
        #expect(s.selectedDiskBSD == "disk4", "listed and selectable, just not writable")
        #expect(s.isTimeMachineBackup(tm) && s.isLockedBackup(tm))
        for mode in [AppMode.installVentoy, .flashImage, .updateVentoy] {
            s.mode = mode
            s.selectedImagePath = "/tmp/x.iso"
            #expect(!s.canRun, "\(mode) must be blocked")
        }
        s.mode = .installVentoy
        s.requestRun()
        #expect(s.pendingEraseConfirmation == nil)
    }

    @Test("unlocking allows an install and the sheet says backups will be erased; locking again blocks it")
    func unlockAndRelock() {
        let s = state()
        let tm = disk("disk4")
        s.applyDiskList([tm], timeMachine: ["disk4"])
        s.mode = .installVentoy
        s.unlockBackupDisk(tm)
        #expect(s.canRun)
        s.requestRun()
        #expect(s.pendingEraseConfirmation?.isTimeMachineBackup == true)
        s.cancelRun()
        s.lockBackupDisk(tm)
        #expect(!s.canRun)
    }

    @Test("an unlock ends when the drive leaves the list; replugging it is locked again")
    func unlockEndsOnUnplug() {
        let s = state()
        let tm = disk("disk4")
        s.applyDiskList([tm], timeMachine: ["disk4"])
        s.unlockBackupDisk(tm)
        s.applyDiskList([], timeMachine: [])
        s.applyDiskList([tm], timeMachine: ["disk4"])
        #expect(s.isLockedBackup(tm))
    }

    @Test("an unlock is tied to the drive's identity, not just its BSD name")
    func unlockIsPerIdentity() {
        let s = state()
        let tm = disk("disk4")
        s.applyDiskList([tm], timeMachine: ["disk4"])
        s.unlockBackupDisk(tm)
        let other = disk("disk4", size: 1_000_000_000_000, name: "Other Backup")
        s.applyDiskList([other], timeMachine: ["disk4"])
        #expect(s.isLockedBackup(other))
    }

    @Test("auto-select prefers a drive that isn't a Time Machine backup")
    func autoSelectSkipsBackups() {
        let s = state()
        s.applyDiskList([disk("disk4"), disk("disk6", size: 64_000_000_000, name: "USB Stick")], timeMachine: ["disk4"])
        #expect(s.selectedDiskBSD == "disk6")
    }

    @Test("unlocking a drive that isn't a Time Machine backup does nothing")
    func unlockOnlyBackups() {
        let s = state()
        let stick = disk("disk6", size: 64_000_000_000, name: "USB Stick")
        s.applyDiskList([stick], timeMachine: [])
        s.unlockBackupDisk(stick)
        #expect(s.unlockedBackupDisks.isEmpty)
    }

    @Test("run() itself refuses a locked Time Machine drive — covers Retry and the approval resume")
    func runRefusesLockedBackup() async {
        let s = state()
        let tm = disk("disk4")
        s.applyDiskList([tm], timeMachine: ["disk4"])
        await s.run(confirmedTarget: tm, confirmedMode: .installVentoy, confirmedSecureBoot: true, confirmedPartitionStyle: .mbr)
        guard case .failed(let message) = s.status else {
            Issue.record("expected a refusal, got \(s.status)")
            return
        }
        #expect(message.contains("Time Machine"))
    }

    @Test("the Time Machine mark updates while a confirmation is open; the selection stays frozen")
    func markUpdatesDuringConfirmation() {
        let s = state()
        let stick = disk("disk6", size: 64_000_000_000, name: "USB Stick")
        s.applyDiskList([stick], timeMachine: [])
        s.mode = .installVentoy
        s.requestRun()
        #expect(s.pendingEraseConfirmation != nil)
        let tm = disk("disk4")
        s.applyDiskList([tm, stick], timeMachine: ["disk4"])
        #expect(s.selectedDiskBSD == "disk6")
        #expect(s.isTimeMachineBackup(tm))
    }

    // MARK: Review round: live check, failed polls

    @Test("run() re-checks live: a drive the last poll didn't mark is still refused")
    func runLiveCheckCatchesUnmarkedBackup() async {
        let s = state()
        let tm = disk("disk4")
        s.applyDiskList([tm], timeMachine: [])       // poll raced the container attaching
        s.timeMachineLookup = { ["disk4"] }          // the live lookup sees it
        await s.run(confirmedTarget: tm, confirmedMode: .installVentoy, confirmedSecureBoot: true, confirmedPartitionStyle: .mbr)
        guard case .failed(let message) = s.status else { Issue.record("expected a refusal"); return }
        #expect(message.contains("Time Machine"))
        #expect(s.isTimeMachineBackup(tm))
    }

    @Test("run() refuses when the live Time Machine lookup fails")
    func runRefusesWhenLookupFails() async {
        let s = state()
        let stick = disk("disk6", size: 64_000_000_000, name: "USB Stick")
        s.applyDiskList([stick], timeMachine: [])
        s.timeMachineLookup = { throw DriverError.diskIO("diskutil hung") }
        await s.run(confirmedTarget: stick, confirmedMode: .flashImage, confirmedSecureBoot: true, confirmedPartitionStyle: .mbr)
        guard case .failed(let message) = s.status else { Issue.record("expected a refusal"); return }
        #expect(message.contains("Nothing was written"))
    }

    @Test("a failed poll keeps the last list and selection, and is counted; a good poll resets the count")
    func failedPollKeepsList() {
        let s = state()
        let stick = disk("disk6", size: 64_000_000_000, name: "USB Stick")
        s.applyScan(DiskInfo.ExternalDiskScan(disks: [stick], timeMachineDisks: []))
        s.applyScan(nil); s.applyScan(nil); s.applyScan(nil)
        #expect(s.disks == [stick])
        #expect(s.selectedDiskBSD == "disk6")
        #expect(s.failedDiskPolls == 3)
        s.applyScan(DiskInfo.ExternalDiskScan(disks: [stick], timeMachineDisks: []))
        #expect(s.failedDiskPolls == 0)
    }

    // MARK: Second review round

    @Test("an unlocked backup drive gets past the guard (the run then stops at the next layer, not here)")
    func unlockedPassesGuard() async {
        let s = state()
        let tm = disk("disk97")                      // fictitious: Layer 4's live probe stops the run
        s.applyDiskList([tm], timeMachine: ["disk97"])
        s.timeMachineLookup = { ["disk97"] }
        s.unlockBackupDisk(tm)
        await s.run(confirmedTarget: tm, confirmedMode: .installVentoy, confirmedSecureBoot: true, confirmedPartitionStyle: .mbr)
        guard case .failed(let message) = s.status else { Issue.record("expected the later layer to stop it"); return }
        #expect(!message.contains("Time Machine"), "the Time Machine guard must not be what stopped it")
    }

    @Test("a failed live lookup keeps the run available for Retry")
    func lookupFailureKeepsRetry() async {
        let s = state()
        let stick = disk("disk97", size: 64_000_000_000, name: "USB Stick")
        s.applyDiskList([stick], timeMachine: [])
        s.timeMachineLookup = { throw DriverError.diskIO("diskutil hung") }
        s.mode = .installVentoy
        s.requestRun()
        s.confirmRun()
        var waited = 0
        while !s.canRetryRun && waited < 300 { try? await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        #expect(s.canRetryRun)
    }

    @Test("while the live check runs the app is busy: no second run can start")
    func busyDuringLookup() async {
        let s = state()
        let stick = disk("disk97", size: 64_000_000_000, name: "USB Stick")
        s.applyDiskList([stick], timeMachine: [])
        s.timeMachineLookup = { try? await Task.sleep(nanoseconds: 500_000_000); return [] }
        s.mode = .installVentoy
        s.requestRun()
        s.confirmRun()
        try? await Task.sleep(nanoseconds: 150_000_000)   // inside the lookup
        guard case .preparing = s.status else { Issue.record("expected .preparing during the check, got \(s.status)"); return }
        #expect(!s.canRun)
        #expect(!s.canRetryRun)
        #expect(s.runRequestCount == 1)
    }
}
