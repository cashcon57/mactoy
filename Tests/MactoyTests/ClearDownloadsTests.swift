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

    @Test("not while a sheet is open, since the result alert can't show over it")
    func notWhileSheetOpen() {
        let s = state(helper: .enabled, calls: Calls())
        #expect(s.canClearDownloads)
        s.showHelperExplainer = true
        #expect(!s.canClearDownloads)
        s.showHelperExplainer = false
        s.isAwaitingHelperApproval = true
        #expect(!s.canClearDownloads)
        s.isAwaitingHelperApproval = false
        s.showFullDiskAccessSheet = true
        #expect(!s.canClearDownloads)
    }

    @Test("a failure in the Caches folder is reported in readable words")
    func localFailureReadable() async {
        let calls = Calls()
        let s = state(helper: .notRegistered, calls: calls, helperCacheThere: false)
        s.localDownloadClearer = { throw DriverError.validation("cache: /x has unexpected ownership or permissions; not clearing it") }
        await s.clearVentoyDownloads()
        let report = s.clearDownloadsReport ?? ""
        #expect(report.contains("unexpected ownership"))
        #expect(!report.contains("error 0"))
    }

    @Test("an unreachable helper is explained in plain words")
    func helperUnreachable() async {
        let calls = Calls()
        let s = state(helper: .enabled, calls: calls,
                      helperError: HelperInvoker.HelperError.xpcUnreachable("Error Domain=NSCocoaErrorDomain Code=4099"))
        await s.clearVentoyDownloads()
        let report = s.clearDownloadsReport ?? ""
        #expect(report.contains("couldn't reach its helper"))
        #expect(!report.contains("4099"))
    }

    @Test("clearing doesn't reset the 'remove helper after this run' choice")
    func keepsUninstallChoice() async {
        let s = state(helper: .enabled, calls: Calls())
        s.helperStatus = .requiresApproval      // a run waiting on approval
        s.uninstallHelperAfterRun = true
        await s.clearVentoyDownloads()
        #expect(s.uninstallHelperAfterRun)
        #expect(s.helperStatus == .requiresApproval)
    }

    @Test("while the helper is being removed, clearing waits and a new run waits for the removal")
    func removalBlocksClearAndRun() async {
        final class Gate: @unchecked Sendable { var open: CheckedContinuation<Void, Never>? }
        let gate = Gate()
        let calls = Calls()
        let s = state(helper: .enabled, calls: calls)
        s.uninstallHelperAfterRun = true
        s.helperRemover = {
            calls.events.append("unregister-start")
            await withCheckedContinuation { gate.open = $0 }
            calls.events.append("unregister-end")
        }
        let removal = Task { await s.removeHelperIfAsked() }
        while gate.open == nil { await Task.yield() }
        #expect(!s.canClearDownloads)

        let disk = DiskTarget(bsdName: "disk9", sizeInBytes: 8_000_000_000, isExternal: true, isRemovable: true)
        s.helperStatusSource = { .notRegistered }
        let run = Task {
            await s.run(confirmedTarget: disk, confirmedMode: .flashImage,
                        confirmedSecureBoot: true, confirmedPartitionStyle: .mbr)
            calls.events.append("run-returned")
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(!calls.events.contains("run-returned"))

        gate.open?.resume()
        await removal.value
        await run.value
        #expect(calls.events.firstIndex(of: "unregister-end")! < calls.events.firstIndex(of: "run-returned")!)
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
