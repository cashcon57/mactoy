import Foundation
import Testing
@testable import Mactoy
import MactoyKit

/// Issue #22: Clear Ventoy Downloads, and the helper's downloads go when the helper does.
@MainActor
@Suite("Clear Ventoy downloads")
struct ClearDownloadsTests {
    final class Calls: @unchecked Sendable {
        var events: [String] = []
    }

    private func state(helper: HelperStatus, calls: Calls,
                       helperFreed: UInt64 = 20_000_000, localFreed: UInt64 = 0,
                       helperError: Error? = nil, helperCacheThere: Bool = true) -> AppState {
        let s = AppState()
        s.timeMachineLookup = { [] }
        s.helperStatusSource = { helper }
        s.helperDownloadClearer = {
            calls.events.append("clear-helper")
            if let helperError { throw helperError }
            return helperFreed
        }
        s.localDownloadClearer = {
            calls.events.append("clear-local")
            return localFreed
        }
        s.helperDownloadsExist = { helperCacheThere }
        s.helperRemover = { calls.events.append("unregister") }
        return s
    }

    @Test("with the helper set up, both caches are cleared and the total is reported")
    func clearsBoth() async {
        let calls = Calls()
        let s = state(helper: .enabled, calls: calls, helperFreed: 20_000_000, localFreed: 1_000_000)
        await s.clearVentoyDownloads()
        #expect(calls.events == ["clear-local", "clear-helper"])
        let report = s.clearDownloadsReport ?? ""
        #expect(report.hasPrefix("Cleared 21"))
        #expect(!report.contains("helper"))
    }

    @Test("without the helper, its leftover downloads are explained, not touched")
    func helperNotSetUp() async {
        let calls = Calls()
        let s = state(helper: .notRegistered, calls: calls, localFreed: 0, helperCacheThere: true)
        await s.clearVentoyDownloads()
        #expect(calls.events == ["clear-local"])
        #expect(s.clearDownloadsReport?.contains("isn't set up right now") == true)
        #expect(s.clearDownloadsReport?.contains("There were no") == false)
    }

    @Test("nothing anywhere: says so")
    func nothingToClear() async {
        let calls = Calls()
        let s = state(helper: .notRegistered, calls: calls, localFreed: 0, helperCacheThere: false)
        await s.clearVentoyDownloads()
        #expect(s.clearDownloadsReport == "There were no Ventoy downloads to clear.")
    }

    @Test("a helper from another Mactoy version is explained")
    func versionMismatch() async {
        let calls = Calls()
        let s = state(helper: .enabled, calls: calls,
                      helperError: HelperInvoker.HelperError.versionMismatch(helper: "0.5.0"))
        await s.clearVentoyDownloads()
        #expect(s.clearDownloadsReport?.contains("another version of Mactoy") == true)
    }

    @Test("a refusal from the helper is passed on")
    func helperRefuses() async {
        let calls = Calls()
        let s = state(helper: .enabled, calls: calls,
                      helperError: HelperInvoker.HelperError.executionFailed("Mactoy is writing a drive. Try again when it's finished."))
        await s.clearVentoyDownloads()
        #expect(s.clearDownloadsReport?.contains("writing a drive") == true)
    }

    @Test("not while a drive is being written")
    func notWhileRunning() async {
        let calls = Calls()
        let s = state(helper: .enabled, calls: calls)
        s.status = .running(.init(phase: .writing, message: "Writing..."))
        #expect(!s.canClearDownloads)
        await s.clearVentoyDownloads()
        #expect(calls.events.isEmpty)
        #expect(s.clearDownloadsReport == nil)
        s.status = .preparing("…")
        #expect(!s.canClearDownloads)
        s.status = .success("done")
        #expect(s.canClearDownloads)
    }

    @Test("removing the helper clears its downloads first")
    func removalClearsFirst() async {
        let calls = Calls()
        await AppState.removeHelper(clearDownloads: { calls.events.append("clear"); return 1 },
                                    unregister: { calls.events.append("unregister") })
        #expect(calls.events == ["clear", "unregister"])
    }

    @Test("the helper is still removed when clearing fails")
    func removalSurvivesClearFailure() async {
        let calls = Calls()
        await AppState.removeHelper(clearDownloads: {
            calls.events.append("clear")
            throw HelperInvoker.HelperError.xpcUnreachable("gone")
        }, unregister: { calls.events.append("unregister") })
        #expect(calls.events == ["clear", "unregister"])
    }
}
