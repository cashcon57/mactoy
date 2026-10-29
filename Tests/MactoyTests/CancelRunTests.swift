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
        for phase: ProgressUpdate.Phase in [.preparing, .verifying, .writing, .formatting] {
            #expect(state(mode: .flashImage, phase: phase).canCancelRun, "\(phase)")
        }
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
}
