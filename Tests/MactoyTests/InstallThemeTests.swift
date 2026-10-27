import Foundation
import Testing
@testable import Mactoy
import MactoyKit

// Every test here uses a fictitious disk (`disk97`): a run that gets as far
// as its live re-probe (Layer 4) stops there, so nothing reaches a helper or
// a real disk. Each AppState gets its own UserDefaults suite, so no test
// reads or writes the real saved theme choice.

fileprivate final class Counter: @unchecked Sendable { var n = 0 }

fileprivate final class Events: @unchecked Sendable { var list: [String] = [] }

fileprivate struct SaveFailure: LocalizedError {
    let errorDescription: String?
}

@MainActor
fileprivate final class TempDefaults {
    let name = "mactoy-test-\(UUID().uuidString)"
    let defaults: UserDefaults
    init() { defaults = UserDefaults(suiteName: name)! }
    func remove() { defaults.removePersistentDomain(forName: name) }
}

@MainActor
fileprivate enum Fixture {
    static func disk(_ bsd: String = "disk97") -> DiskTarget {
        DiskTarget(bsdName: bsd, sizeInBytes: 32_000_000_000, isExternal: true, isRemovable: true, mediaName: "Stick", volumes: [])
    }

    static func state(_ d: TempDefaults, bsd: String = "disk97") -> AppState {
        let s = AppState(defaults: d.defaults)
        s.timeMachineLookup = { [] }
        s.ventoyProber = { .unknownDisk(bsdName: $0, reason: "stub") }
        s.usedBytesEstimator = { _ in nil }
        s.disks = [disk(bsd)]
        s.selectedDiskBSD = bsd
        return s
    }

    static func probe(_ bsd: String) -> VentoyProbeResult {
        VentoyProbeResult(bsdName: bsd, isVentoyDisk: true, detectedVersion: "1.1.17", secureBootEnabled: true,
                          partitionStyle: .gpt, partition2StartSector: 1000, layoutIssues: [], looksLikeBrokenVentoy: false)
    }

    /// Polls until `condition` holds, for up to about 3 seconds.
    static func wait(until condition: () -> Bool) async {
        var waited = 0
        while !condition() && waited < 300 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
    }
}

@MainActor
@Suite("Install-time boot theme")
struct InstallThemeTests {

    private func disk() -> DiskTarget { Fixture.disk() }

    @Test("Catppuccin Mocha is the default, and an opt-out is remembered")
    func defaultAndOptOut() {
        let d = TempDefaults(); defer { d.remove() }
        let first = AppState(defaults: d.defaults)
        #expect(first.installTheme == .catalog(id: "catppuccin-mocha"))
        #expect(AppState.defaultInstallTheme == .catalog(id: "catppuccin-mocha"))
        first.installTheme = .ventoyDefault
        #expect(AppState(defaults: d.defaults).installTheme == .ventoyDefault)
        first.installTheme = .catalog(id: "tela")
        #expect(AppState(defaults: d.defaults).installTheme == .catalog(id: "tela"))
        first.installTheme = .custom(id: "custom-x")
        #expect(AppState(defaults: d.defaults).installTheme == .catalog(id: "tela"), "custom themes aren't saved")
    }

    @Test("the saved values are the documented strings under the documented key")
    func savedFormat() {
        let d = TempDefaults(); defer { d.remove() }
        let s = AppState(defaults: d.defaults)
        #expect(d.defaults.string(forKey: "installTheme") == nil, "reading the default writes nothing")
        s.installTheme = .ventoyDefault
        #expect(d.defaults.string(forKey: "installTheme") == "ventoy-default")
        s.installTheme = .catalog(id: "tela")
        #expect(d.defaults.string(forKey: "installTheme") == "catalog:tela")
        // A stored value nobody wrote falls back to Mactoy's pick rather than to nothing.
        d.defaults.set("something-else", forKey: "installTheme")
        #expect(AppState(defaults: d.defaults).installTheme == AppState.defaultInstallTheme)
        // Reading a saved choice doesn't rewrite it.
        d.defaults.set("catalog:vimix", forKey: "installTheme")
        #expect(AppState(defaults: d.defaults).installTheme == .catalog(id: "vimix"))
        #expect(d.defaults.string(forKey: "installTheme") == "catalog:vimix")
    }

    @Test("theme is captured at confirmation")
    func captured() {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        s.mode = .installVentoy
        s.installTheme = .catalog(id: "tela")
        s.requestRun()
        s.installTheme = .catalog(id: "dracula")
        #expect(s.pendingEraseConfirmation?.theme == .catalog(id: "tela"))
    }

    @Test("update and flash never carry a theme")
    func otherModes() {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        s.installTheme = .catalog(id: "tela")

        s.mode = .updateVentoy
        s.applyProbeResult(Fixture.probe("disk97"))
        s.requestRun()
        #expect(s.pendingEraseConfirmation != nil, "setup: the update sheet should be open")
        #expect(s.pendingEraseConfirmation?.theme == .ventoyDefault)
        s.cancelRun()

        s.mode = .flashImage
        s.selectedImagePath = "/tmp/x.iso"
        s.requestRun()
        #expect(s.pendingEraseConfirmation != nil, "setup: the flash sheet should be open")
        #expect(s.pendingEraseConfirmation?.theme == .ventoyDefault)
    }

    @Test("success with the theme")
    func applied() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        let calls = Counter()
        s.installThemeApplier = { _, _ in calls.n += 1; return nil }
        s.status = .success("Install complete")
        await s.addThemeAfterInstall(.catalog(id: "tela"), mode: .installVentoy, to: disk())
        #expect(calls.n == 1)
        guard case .success(let m) = s.status else { Issue.record("not success"); return }
        #expect(m == "Install complete, with your boot theme")
    }

    @Test("the applier gets the chosen theme and the installed disk, and the status says so while it works")
    func appliedArguments() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        let seen = Events()
        s.installThemeApplier = { [s] choice, target in
            seen.list.append("\(choice) \(target.bsdName)")
            if case .preparing(let m) = s.status { seen.list.append(m) }
            return nil
        }
        s.status = .success("Install complete")
        await s.addThemeAfterInstall(.custom(id: "mine"), mode: .installVentoy, to: disk())
        #expect(seen.list == ["custom(id: \"mine\") disk97", "Adding the boot theme…"])
    }

    @Test("a theme problem keeps the install a success")
    func problem() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        s.installThemeApplier = { _, _ in "the download failed." }
        s.status = .success("Install complete")
        await s.addThemeAfterInstall(.catalog(id: "tela"), mode: .installVentoy, to: disk())
        guard case .success(let m) = s.status else { Issue.record("not success"); return }
        #expect(m == "Install complete. The boot theme wasn't added: the download failed. You can add it from Manage Disk.")
        #expect(!s.canRetryRun, "a Retry here would erase the drive again")
    }

    @Test("default theme, update and flash skip the applier")
    func skipped() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        let calls = Counter()
        s.installThemeApplier = { _, _ in calls.n += 1; return nil }
        s.status = .success("Install complete")
        await s.addThemeAfterInstall(.ventoyDefault, mode: .installVentoy, to: disk())
        await s.addThemeAfterInstall(.catalog(id: "tela"), mode: .updateVentoy, to: disk())
        await s.addThemeAfterInstall(.catalog(id: "tela"), mode: .flashImage, to: disk())
        #expect(calls.n == 0)
        guard case .success(let m) = s.status else { Issue.record("not success"); return }
        #expect(m == "Install complete")
    }

    @Test("the confirmed theme reaches run(), and Retry and the approval resume pass it on, whatever the card says later")
    func reachesRunRetryAndResume() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        s.mode = .installVentoy
        s.installTheme = .catalog(id: "tela")
        s.requestRun()
        s.installTheme = .catalog(id: "dracula")      // changed while the sheet is open
        s.confirmRun()
        await Fixture.wait { s.canRetryRun }
        #expect(s.canRetryRun)
        #expect(s.runRequestCount == 1)
        #expect(s.lastRunRequest?.theme == .catalog(id: "tela"))

        s.installTheme = .ventoyDefault               // and again after the failure
        await s.retryRun()
        #expect(s.runRequestCount == 2)
        #expect(s.lastRunRequest?.theme == .catalog(id: "tela"))

        s.installTheme = .catalog(id: "vimix")
        s.helperApprovalCompleted(resumesRun: true)
        await Fixture.wait { s.runRequestCount == 3 }
        #expect(s.runRequestCount == 3)
        #expect(s.lastRunRequest?.theme == .catalog(id: "tela"))
    }

    @Test("a run that wasn't given a theme has none")
    func runDefaultsToNoTheme() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        s.installTheme = .catalog(id: "tela")
        await s.run(confirmedTarget: disk(), confirmedMode: .installVentoy, confirmedSecureBoot: true, confirmedPartitionStyle: .mbr)
        #expect(s.lastRunRequest?.theme == .ventoyDefault, "run() never reads the live choice")
        #expect(s.lastRunRequest?.saveThemeFrom == nil)
    }

    @Test("the confirmation sentence names the theme, and says when it is Mactoy's own pick")
    func sentence() {
        let sentence = EraseConfirmationSheet.themeSentence(for:name:)
        #expect(sentence(.ventoyDefault, "Ventoy default") == "")
        #expect(sentence(.catalog(id: "catppuccin-mocha"), "Catppuccin Mocha")
                == "Boot theme: Catppuccin Mocha (Mactoy's default; change it on the Install tab).")
        #expect(sentence(.catalog(id: "tela"), "Tela") == "Boot theme: Tela.")
        #expect(sentence(.custom(id: "custom-x"), "My Theme") == "Boot theme: My Theme.")
    }
}

@MainActor
@Suite("Install saves the drive's theme first")
struct InstallThemeSaveFirstTests {

    private let volume = URL(fileURLWithPath: "/Volumes/Ventoy")
    private func disk() -> DiskTarget { Fixture.disk() }

    /// An Install sheet that has found a theme on the drive.
    private func sheetWithTheme(_ s: AppState, volume: URL? = nil) async {
        let found = volume ?? self.volume
        s.driveThemeProbe = { _ in (name: "Sunset", volume: found) }
        s.mode = .installVentoy
        s.requestRun()
        await Fixture.wait { s.pendingEraseConfirmation?.driveThemeName != nil }
    }

    // MARK: Detection

    @Test("the theme on the drive is looked for after the sheet opens, and lands on that sheet")
    func probeFillsTheSheet() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        let url = volume
        s.driveThemeProbe = { _ in
            try? await Task.sleep(nanoseconds: 200_000_000)     // a slow drive
            return (name: "Sunset", volume: url)
        }
        s.mode = .installVentoy
        s.requestRun()
        #expect(s.pendingEraseConfirmation != nil, "the sheet must not wait on the drive")
        #expect(s.pendingEraseConfirmation?.driveThemeName == nil)

        await Fixture.wait { s.pendingEraseConfirmation?.driveThemeName != nil }
        #expect(s.pendingEraseConfirmation?.driveThemeName == "Sunset")
        #expect(s.pendingEraseConfirmation?.driveThemeVolume == url)
        #expect(s.pendingEraseConfirmation?.saveDriveThemeFirst == true, "ticked unless the user clears it")
    }

    @Test("the probe is given the confirmed disk")
    func probeGetsTheDisk() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        let seen = Events()
        s.driveThemeProbe = { target in seen.list.append(target.bsdName); return nil }
        s.mode = .installVentoy
        s.requestRun()
        await Fixture.wait { !seen.list.isEmpty }
        #expect(seen.list == ["disk97"])
        #expect(s.pendingEraseConfirmation?.driveThemeName == nil, "nothing found, nothing offered")
        #expect(s.pendingEraseConfirmation?.driveThemeVolume == nil)
    }

    @Test("a late result never lands on a newer confirmation")
    func lateProbeIgnored() async throws {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        let url = volume
        s.driveThemeProbe = { _ in
            try? await Task.sleep(nanoseconds: 200_000_000)
            return (name: "Old", volume: url)
        }
        s.mode = .installVentoy
        s.requestRun()
        let firstID = try #require(s.pendingEraseConfirmation?.id)
        s.cancelRun()

        s.driveThemeProbe = { _ in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return (name: "New", volume: url)
        }
        s.requestRun()
        let second = try #require(s.pendingEraseConfirmation)
        #expect(second.id != firstID)

        try await Task.sleep(nanoseconds: 400_000_000)           // the first probe has returned
        #expect(s.pendingEraseConfirmation?.driveThemeName == nil, "\"Old\" belongs to the cancelled sheet")
        #expect(s.pendingEraseConfirmation?.driveThemeVolume == nil)
    }

    @Test("a result after the sheet is closed lands nowhere")
    func probeAfterCancel() async throws {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        let url = volume
        s.driveThemeProbe = { _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return (name: "Sunset", volume: url)
        }
        s.mode = .installVentoy
        s.requestRun()
        s.cancelRun()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(s.pendingEraseConfirmation == nil)
    }

    @Test("only an Install looks: Update and Flash Image don't erase the theme")
    func probeOnlyForInstall() async throws {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        let probes = Counter()
        let url = volume
        s.driveThemeProbe = { _ in probes.n += 1; return (name: "Sunset", volume: url) }

        s.mode = .updateVentoy
        s.applyProbeResult(Fixture.probe("disk97"))
        s.requestRun()
        #expect(s.pendingEraseConfirmation != nil)
        s.cancelRun()

        s.mode = .flashImage
        s.selectedImagePath = "/tmp/x.iso"
        s.requestRun()
        #expect(s.pendingEraseConfirmation != nil)
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(probes.n == 0)
        #expect(s.pendingEraseConfirmation?.driveThemeName == nil)
        s.cancelRun()

        s.mode = .installVentoy
        s.requestRun()
        await Fixture.wait { probes.n == 1 }
        #expect(probes.n == 1)
    }

    // MARK: Capture at confirmation

    @Test("the box as it stood at confirmation is what run() is given, and Retry keeps it until a save has happened")
    func tickCaptured() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        let url = volume
        let saves = Counter()
        s.driveThemeSaver = { _ in saves.n += 1 }

        // Ticked (the default).
        await sheetWithTheme(s)
        s.confirmRun()
        await Fixture.wait { s.canRetryRun }
        #expect(s.runRequestCount == 1)
        #expect(s.lastRunRequest?.saveThemeFrom == url)
        await s.retryRun()
        #expect(s.lastRunRequest?.saveThemeFrom == url, "nothing was saved yet, so Retry still has it to do")
        s.reset()

        // Cleared by the user.
        await sheetWithTheme(s)
        s.pendingEraseConfirmation?.saveDriveThemeFirst = false
        s.confirmRun()
        await Fixture.wait { s.runRequestCount == 3 }
        #expect(s.lastRunRequest?.saveThemeFrom == nil)
        await Fixture.wait { s.canRetryRun }
        await s.retryRun()
        #expect(s.lastRunRequest?.saveThemeFrom == nil)
        s.reset()

        // No theme found on the drive.
        s.driveThemeProbe = { _ in nil }
        s.mode = .installVentoy
        s.requestRun()
        s.confirmRun()
        await Fixture.wait { s.runRequestCount == 5 }
        #expect(s.lastRunRequest?.saveThemeFrom == nil)
        await Fixture.wait { s.canRetryRun }

        #expect(saves.n == 0, "every one of these runs stopped at the live re-probe")
    }

    @Test("a box on an Update or Flash confirmation is ignored")
    func tickIgnoredOutsideInstall() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        for mode in [AppMode.updateVentoy, .flashImage] {
            s.reset()
            let before = s.runRequestCount
            s.mode = mode
            s.pendingEraseConfirmation = EraseConfirmation(
                mode: mode, disk: disk(), usedBytes: nil, totalBytes: 32_000_000_000, partitionStyle: .mbr,
                driveThemeName: "Sunset", driveThemeVolume: volume, saveDriveThemeFirst: true
            )
            s.confirmRun()
            await Fixture.wait { s.runRequestCount == before + 1 }
            #expect(s.lastRunRequest?.mode == mode)
            #expect(s.lastRunRequest?.saveThemeFrom == nil, "\(mode) doesn't erase the theme")
            await Fixture.wait { s.canRetryRun }
        }
    }

    @Test("a ticked box with no volume saves nothing")
    func tickWithoutVolume() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        s.pendingEraseConfirmation = EraseConfirmation(
            mode: .installVentoy, disk: disk(), usedBytes: nil, totalBytes: 32_000_000_000, partitionStyle: .mbr,
            driveThemeName: "Sunset", driveThemeVolume: nil, saveDriveThemeFirst: true
        )
        s.confirmRun()
        await Fixture.wait { s.runRequestCount == 1 }
        #expect(s.lastRunRequest?.saveThemeFrom == nil)
    }

    @Test("the approval resume carries the capture too")
    func resumeCarriesCapture() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        let url = volume
        await sheetWithTheme(s)
        s.confirmRun()
        await Fixture.wait { s.canRetryRun }
        s.helperApprovalCompleted(resumesRun: true)
        await Fixture.wait { s.runRequestCount == 2 }
        #expect(s.runRequestCount == 2)
        #expect(s.lastRunRequest?.saveThemeFrom == url)
    }

    @Test("cancelling clears the capture")
    func cancelClears() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        await sheetWithTheme(s)
        s.confirmRun()
        await Fixture.wait { s.canRetryRun }
        s.cancelRun()                                  // as a cancelled approval does
        s.helperApprovalCompleted(resumesRun: true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(s.runRequestCount == 1, "nothing is left to resume")
    }

    // MARK: The save itself

    @Test("the theme is saved first, with the status saying so, and the volume is checked against the confirmed disk")
    func savesFirst() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        let url = volume
        let events = Events()
        s.driveVolumeIdentifier = { v in events.list.append("check \(v.lastPathComponent)"); return "disk97s2" }
        s.driveThemeSaver = { [s] v in
            events.list.append("save \(v.lastPathComponent)")
            if case .preparing(let m) = s.status { events.list.append(m) }
        }
        let ok = await s.saveDriveThemeBeforeErase(from: url, on: disk())
        #expect(ok)
        #expect(events.list == ["check Ventoy", "save Ventoy", "Saving the drive's boot theme…"])
    }

    @Test("a failed save stops the run with the stated message, and nothing is erased")
    func failedSaveStops() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        s.driveVolumeIdentifier = { _ in "disk97s2" }
        let expected = "Couldn't save the drive's boot theme: the library is read-only. Nothing was erased. To erase without saving, untick the option and try again."
        for reason in ["the library is read-only", "the library is read-only."] {
            s.driveThemeSaver = { _ in throw SaveFailure(errorDescription: reason) }
            s.status = .idle
            let ok = await s.saveDriveThemeBeforeErase(from: volume, on: disk())
            #expect(!ok)
            guard case .failed(let m) = s.status else { Issue.record("not failed: \(s.status)"); return }
            #expect(m == expected)
        }
    }

    @Test("a volume that isn't on the confirmed disk any more is not saved from")
    func volumeMoved() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        let saves = Counter()
        s.driveThemeSaver = { _ in saves.n += 1 }
        // Another disk, a disk whose name merely starts the same, and a volume that's gone.
        for id in ["disk9s2", "disk970s1", nil] as [String?] {
            s.driveVolumeIdentifier = { _ in id }
            s.status = .idle
            let ok = await s.saveDriveThemeBeforeErase(from: volume, on: disk())
            #expect(!ok, "\(String(describing: id))")
            guard case .failed(let m) = s.status else { Issue.record("not failed: \(s.status)"); return }
            #expect(m.hasPrefix("Couldn't save the drive's boot theme: the drive's Ventoy volume is no longer mounted from /dev/disk97."))
            #expect(m.hasSuffix("Nothing was erased. To erase without saving, untick the option and try again."))
        }
        #expect(saves.n == 0)
    }

    // MARK: Order, and the wrong-disk layers

    @Test("the wrong-disk layers run first: a refused run never saves anything")
    func layersRunFirst() async {
        let d = TempDefaults(); defer { d.remove() }
        let saves = Counter()
        let url = volume

        // Layer 4: the fictitious disk fails the live re-probe.
        var s = Fixture.state(d)
        s.driveThemeSaver = { _ in saves.n += 1 }
        s.driveVolumeIdentifier = { _ in "disk97s2" }
        await s.run(confirmedTarget: disk(), confirmedMode: .installVentoy, confirmedSecureBoot: true,
                    confirmedPartitionStyle: .mbr, confirmedSaveThemeFrom: url)
        guard case .failed(let m4) = s.status else { Issue.record("not failed"); return }
        #expect(m4.contains("could not re-verify"))

        // Layer 6: the selection drifted.
        s = Fixture.state(d)
        s.driveThemeSaver = { _ in saves.n += 1 }
        s.driveVolumeIdentifier = { _ in "disk97s2" }
        s.disks = [disk(), Fixture.disk("disk98")]
        s.selectedDiskBSD = "disk98"
        await s.run(confirmedTarget: disk(), confirmedMode: .installVentoy, confirmedSecureBoot: true,
                    confirmedPartitionStyle: .mbr, confirmedSaveThemeFrom: url)
        guard case .failed(let m6) = s.status else { Issue.record("not failed"); return }
        #expect(m6.contains("selected disk changed"))

        // Time Machine: a failed lookup, and a drive found to be a backup.
        s = Fixture.state(d)
        s.driveThemeSaver = { _ in saves.n += 1 }
        s.driveVolumeIdentifier = { _ in "disk97s2" }
        s.timeMachineLookup = { throw DriverError.diskIO("diskutil hung") }
        await s.run(confirmedTarget: disk(), confirmedMode: .installVentoy, confirmedSecureBoot: true,
                    confirmedPartitionStyle: .mbr, confirmedSaveThemeFrom: url)
        guard case .failed(let mLookup) = s.status else { Issue.record("not failed"); return }
        #expect(mLookup.contains("Nothing was written"))

        s = Fixture.state(d)
        s.driveThemeSaver = { _ in saves.n += 1 }
        s.driveVolumeIdentifier = { _ in "disk97s2" }
        s.timeMachineLookup = { ["disk97"] }
        await s.run(confirmedTarget: disk(), confirmedMode: .installVentoy, confirmedSecureBoot: true,
                    confirmedPartitionStyle: .mbr, confirmedSaveThemeFrom: url)
        guard case .failed(let mBackup) = s.status else { Issue.record("not failed"); return }
        #expect(mBackup.contains("Time Machine"))

        #expect(saves.n == 0)
    }

    @Test("Retry after a save doesn't save again; Retry after a failed save tries again")
    func retryDoesNotSaveAgain() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        let url = volume
        let saves = Counter()
        s.driveVolumeIdentifier = { _ in "disk97s2" }
        s.driveThemeSaver = { _ in saves.n += 1 }

        await sheetWithTheme(s)
        s.confirmRun()
        await Fixture.wait { s.canRetryRun }
        #expect(s.lastRunRequest?.saveThemeFrom == url)

        // A save that fails keeps the capture: the drive hasn't been touched.
        s.driveThemeSaver = { _ in throw SaveFailure(errorDescription: "no space") }
        #expect(await s.saveDriveThemeBeforeErase(from: url, on: disk()) == false)
        await s.retryRun()
        #expect(s.lastRunRequest?.saveThemeFrom == url, "still to do")

        // A save that works clears it: from here on the drive may be partly erased.
        s.driveThemeSaver = { _ in saves.n += 1 }
        #expect(await s.saveDriveThemeBeforeErase(from: url, on: disk()))
        #expect(saves.n == 1)
        s.status = .failed("the erase failed")
        await s.retryRun()
        #expect(s.lastRunRequest?.saveThemeFrom == nil, "Retry must not save from a drive that may be half erased")

        s.helperApprovalCompleted(resumesRun: true)
        await Fixture.wait { s.runRequestCount == 4 }
        #expect(s.lastRunRequest?.saveThemeFrom == nil, "nor the approval resume")
        #expect(saves.n == 1)
    }
}

// MARK: Call sites in run()

/// `run()` can't be driven past its live re-probe (Layer 4) without a real
/// disk, so nothing else would notice the theme steps being dropped from it,
/// or the save moving ahead of the wrong-disk layers. These read the source:
/// crude, but the alternative is a silent change that erases a theme the user
/// asked to keep, or one that adds no theme to a successful install.
@MainActor
@Suite("run() call sites for the theme steps (source order)")
struct InstallThemeRunSourceTests {

    private func runBody() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Mactoy/AppState.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "    func run(\n"))
        let end = try #require(source.range(of: "    /// The plan `run(...)` hands to the helper", range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    @Test("the save comes after the wrong-disk layers and the Time Machine check, and before the helper is called")
    func saveOrder() throws {
        let body = try runBody()
        func index(_ needle: String) throws -> String.Index {
            try #require(body.range(of: needle)?.lowerBound, "missing in run(): \(needle)")
        }
        let steps = [
            "Layer 6 (BSD-name guard)",
            "try await timeMachineLookup()",
            "isLockedBackup(target)",
            "DiskInfo.probe(bsdName: target.bsdName)",
            "fingerprintMismatch(against: live)",
            "guard await saveDriveThemeBeforeErase(from: themeVolume, on: target) else { return }",
            "try await HelperInvoker.run(",
        ]
        let positions = try steps.map(index)
        #expect(positions == positions.sorted(), "the order of the checks, the save and the helper call changed")
        // Only for an Install, and only when the box was ticked.
        #expect(body.contains("if confirmedMode == .installVentoy, let themeVolume = confirmedSaveThemeFrom {"))
    }

    @Test("both success sites add the confirmed theme")
    func successSites() throws {
        let body = try runBody()
        let successes = body.components(separatedBy: "status = .success(\"Install complete\")").count - 1
        let withTheme = body.components(separatedBy: "status = .success(\"Install complete\")\n").dropFirst().filter {
            $0.drop(while: { $0 == " " }).hasPrefix("await addThemeAfterInstall(confirmedTheme, mode: confirmedMode, to: target)")
        }.count
        #expect(successes == 2)
        #expect(withTheme == 2, "a successful install must go on to add the confirmed theme")
    }
}

// MARK: What the app wires in

@MainActor
@Suite("Finding a theme worth keeping on a drive")
struct InstallThemeDriveProbeTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func store() throws -> ThemeStore {
        ThemeStore(library: ThemeLibrary(root: try tempDir().appendingPathComponent("My Themes")))
    }

    /// `/Volumes` with a Ventoy volume in it whose ventoy.json is `json`.
    private func volumes(volumeName: String = "Ventoy", config json: String?) throws -> URL {
        let root = try tempDir()
        let v = root.appendingPathComponent(volumeName)
        let ventoy = v.appendingPathComponent("ventoy")
        let theme = ventoy.appendingPathComponent("mytheme")
        try FileManager.default.createDirectory(at: theme, withIntermediateDirectories: true)
        try Data("desktop-image: \"bg.png\"\n".utf8).write(to: theme.appendingPathComponent("theme.txt"))
        try Data([1]).write(to: theme.appendingPathComponent("bg.png"))
        if let json { try Data(json.utf8).write(to: ventoy.appendingPathComponent("ventoy.json")) }
        return root
    }

    private let handTheme = #"{"control":[],"theme":{"file":"/ventoy/mytheme/theme.txt"}}"#

    @Test("a hand-made theme on a Ventoy volume of that disk is found, with its volume")
    func found() async throws {
        let root = try volumes(config: handTheme)
        let found = try await store().savableDriveTheme(onDisk: "disk97", volumesDirectory: root, deviceIdentifier: { _ in "disk97s2" })
        #expect(found?.name == "mytheme")
        #expect(found?.volume == root.appendingPathComponent("Ventoy"))
    }

    @Test("a volume on another disk, with no theme, or not a Ventoy volume offers nothing")
    func notFound() async throws {
        let s = try store()
        let withTheme = try volumes(config: handTheme)
        // Another disk, and one whose name merely starts the same.
        #expect(await s.savableDriveTheme(onDisk: "disk97", volumesDirectory: withTheme, deviceIdentifier: { _ in "disk9s2" }) == nil)
        #expect(await s.savableDriveTheme(onDisk: "disk9", volumesDirectory: withTheme, deviceIdentifier: { _ in "disk97s2" }) == nil)
        // Not named like a Ventoy volume.
        let other = try volumes(volumeName: "Photos", config: handTheme)
        #expect(await s.savableDriveTheme(onDisk: "disk97", volumesDirectory: other, deviceIdentifier: { _ in "disk97s2" }) == nil)
        // The default theme, no config, and a config that can't be read.
        for config in [#"{"control":[]}"#, nil, "{ not json"] as [String?] {
            let root = try volumes(config: config)
            #expect(await s.savableDriveTheme(onDisk: "disk97", volumesDirectory: root, deviceIdentifier: { _ in "disk97s2" }) == nil,
                    "\(String(describing: config))")
        }
        // Nothing mounted at all.
        #expect(await s.savableDriveTheme(onDisk: "disk97", volumesDirectory: try tempDir(), deviceIdentifier: { _ in "disk97s2" }) == nil)
    }

    @Test("it reads the drive and changes nothing on it")
    func readOnly() async throws {
        let root = try volumes(config: handTheme)
        let config = root.appendingPathComponent("Ventoy/ventoy/ventoy.json")
        let before = try Data(contentsOf: config)
        _ = try await store().savableDriveTheme(onDisk: "disk97", volumesDirectory: root, deviceIdentifier: { _ in "disk97s2" })
        #expect(try Data(contentsOf: config) == before)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Ventoy/ventoy/themes").path))
    }
}
