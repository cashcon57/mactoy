import Foundation
import Testing
@testable import Mactoy
import MactoyKit

/// #21: Cancel is offered only while stopping is safe, and asks first mid-flash.
@MainActor
@Suite("Cancel a run")
struct CancelRunTests {
    final class Calls: @unchecked Sendable { var n = 0 }

    private func state(mode: AppMode, phase: ProgressUpdate.Phase, accepted: Bool = true, calls: Calls = Calls()) -> AppState {
        let s = AppState()
        s.timeMachineLookup = { [] }
        s.ventoyProber = { .unknownDisk(bsdName: $0, reason: "stub") }
        s.runningMode = mode
        s.status = .running(.init(phase: phase, message: "…"))
        s.helperRunCanceller = { calls.n += 1; return accepted }
        return s
    }

    private let disk = DiskTarget(bsdName: "disk7", sizeInBytes: 32_000_000_000, isExternal: true, isRemovable: true, mediaName: "Stick")

    @Test("Ventoy: offered while downloading and extracting, not once writing has started")
    func ventoyPhases() {
        for phase: ProgressUpdate.Phase in [.preparing, .downloading, .extracting] {
            #expect(state(mode: .installVentoy, phase: phase).canCancelRun, "\(phase)")
            #expect(state(mode: .updateVentoy, phase: phase).canCancelRun, "\(phase)")
        }
        for phase: ProgressUpdate.Phase in [.unmounting, .writing, .formatting, .verifying] {
            #expect(!state(mode: .installVentoy, phase: phase).canCancelRun, "\(phase)")
        }
    }

    @Test("Flash: offered throughout, and asks first only while writing")
    func flashPhases() {
        for phase: ProgressUpdate.Phase in [.preparing, .verifying, .writing] {
            #expect(state(mode: .flashImage, phase: phase).canCancelRun, "\(phase)")
        }
        #expect(!state(mode: .flashImage, phase: .formatting).canCancelRun, "nothing left to stop")
        #expect(state(mode: .flashImage, phase: .writing).cancelNeedsConfirmation)
        #expect(!state(mode: .flashImage, phase: .verifying).cancelNeedsConfirmation)
        #expect(!state(mode: .installVentoy, phase: .downloading).cancelNeedsConfirmation)
    }

    @Test("not offered when nothing is running")
    func notWhenIdle() {
        let s = state(mode: .flashImage, phase: .writing)
        s.status = .idle
        #expect(!s.canCancelRun)
        s.status = .preparing("Removing the helper…")
        #expect(!s.canCancelRun)
    }

    @Test("an accepted cancel shows Stopping and isn't offered twice")
    func accepted() async {
        let calls = Calls()
        let s = state(mode: .installVentoy, phase: .downloading, calls: calls)
        await s.cancelRunInProgress()
        #expect(calls.n == 1)
        #expect(s.cancelRequested)
        #expect(!s.canCancelRun)
        await s.cancelRunInProgress()
        #expect(calls.n == 1)
    }

    @Test("a refused cancel says it's too late, and the run carries on")
    func refused() async {
        let s = state(mode: .installVentoy, phase: .extracting, accepted: false)
        await s.cancelRunInProgress()
        #expect(!s.cancelRequested)
        #expect(s.cancelRefusedNote?.contains("Too late to cancel") == true)
        if case .running = s.status {} else { Issue.record("status should stay running") }
    }

    @Test("a refused cancel isn't offered again, even if the run reports .preparing later")
    func refusedNotReoffered() async {
        let s = state(mode: .updateVentoy, phase: .extracting, accepted: false)
        await s.cancelRunInProgress()
        s.noteRunUpdate(.init(phase: .preparing, message: "Preserving disk UUID…"))
        #expect(!s.canCancelRun)
    }

    @Test("once an Update starts writing, a later .preparing update doesn't bring Cancel back")
    func updateWritingClosesCancel() {
        let s = state(mode: .updateVentoy, phase: .extracting)
        #expect(s.canCancelRun)
        s.noteRunUpdate(.init(phase: .writing, message: "Opening /dev/rdisk7..."))
        s.noteRunUpdate(.init(phase: .preparing, message: "Preserving disk UUID…"))
        #expect(!s.canCancelRun)
    }

    @Test("a flash keeps Cancel through writing and checking")
    func flashKeepsCancel() {
        let s = state(mode: .flashImage, phase: .preparing)
        s.noteRunUpdate(.init(phase: .writing, message: "Writing..."))
        s.noteRunUpdate(.init(phase: .verifying, message: "Checking..."))
        #expect(s.canCancelRun)
    }

    @Test("an unreachable helper is reported as that, not as too late")
    func cancellerThrows() async {
        let s = state(mode: .installVentoy, phase: .downloading)
        s.helperRunCanceller = { throw HelperInvoker.HelperError.xpcUnreachable("gone") }
        await s.cancelRunInProgress()
        #expect(!s.cancelRequested)
        #expect(s.cancelRefusedNote?.contains("couldn't reach its helper") == true)
        #expect(s.cancelRefusedNote?.contains("Too late") == false)
    }

    @Test("a cancelled run ends as cancelled, with no Retry")
    func cancelledHasNoRetry() async {
        let s = state(mode: .installVentoy, phase: .downloading)
        await s.cancelRunInProgress()
        s.status = .failed("Cancelled. Nothing was written to the drive.")
        s.settleCancelledRun()
        if case .cancelled(let m) = s.status { #expect(m.hasPrefix("Cancelled")) } else { Issue.record("expected .cancelled") }
        #expect(!s.canRetryRun)
        #expect(s.canClearDownloads)
    }

    @Test("a real failure without a cancel stays a failure")
    func failureStaysFailure() {
        let s = state(mode: .installVentoy, phase: .downloading)
        s.status = .failed("Disk I/O error")
        s.settleCancelledRun()
        if case .failed = s.status {} else { Issue.record("expected .failed") }
    }

    @Test("run() clears the cancel state when it ends")
    func runResetsState() async {
        let s = state(mode: .flashImage, phase: .writing)
        s.cancelClosed = true
        s.status = .idle
        s.helperStatusSource = { .notRegistered }
        await s.run(confirmedTarget: disk, confirmedMode: .flashImage, confirmedSecureBoot: true, confirmedPartitionStyle: .mbr)
        #expect(s.runningMode == nil)
        #expect(!s.cancelClosed)
        #expect(!s.cancelRequested)
    }
}

