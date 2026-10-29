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

/// Lets a test decide when a stubbed probe answers, instead of racing two timers.
fileprivate actor Gate {
    private var isOpen = false
    func open() { isOpen = true }
    func wait() async {
        while !isOpen { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
}

fileprivate struct SaveFailure: LocalizedError {
    let errorDescription: String?
}

/// A preferences domain of its own for one test, kept in the temporary folder: a suite
/// name that is a path puts the plist there, not in ~/Library/Preferences, where
/// cfprefsd can write it again after the test has removed it.
@MainActor
final class TempDefaults {
    let name = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-test-\(UUID().uuidString)").path
    let defaults: UserDefaults
    init() { defaults = UserDefaults(suiteName: name)! }
    func remove() {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(atPath: name + ".plist")
    }
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

    /// Polls until `condition` holds, for up to about 10 seconds (longer on
    /// a busy machine, since each poll's sleep can run late).
    static func wait(until condition: () -> Bool) async {
        var waited = 0
        while !condition() && waited < 1000 {
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
        s.installThemeApplier = { _, _ in calls.n += 1; return .applied(warnings: []) }
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
            return .applied(warnings: [])
        }
        s.status = .success("Install complete")
        await s.addThemeAfterInstall(.custom(id: "mine"), mode: .installVentoy, to: disk())
        #expect(seen.list == ["custom(id: \"mine\") disk97", "Adding the boot theme…"])
    }

    @Test("a theme problem keeps the install a success")
    func problem() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        s.installThemeApplier = { _, _ in .notApplied(problem: "the download failed.") }
        s.status = .success("Install complete")
        await s.addThemeAfterInstall(.catalog(id: "tela"), mode: .installVentoy, to: disk())
        guard case .success(let m) = s.status else { Issue.record("not success"); return }
        #expect(m == "Install complete. The boot theme wasn't added: the download failed. You can add it from Manage Disk.")
        #expect(!s.canRetryRun, "a Retry here would erase the drive again")
    }

    /// The message the install ends on when the applier answers `result`.
    private func message(after result: PostInstallThemeResult) async -> String? {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        s.installThemeApplier = { _, _ in result }
        s.status = .success("Install complete")
        await s.addThemeAfterInstall(.catalog(id: "tela"), mode: .installVentoy, to: disk())
        guard case .success(let m) = s.status else { Issue.record("not success: \(s.status)"); return nil }
        #expect(!s.canRetryRun, "a Retry here would erase the drive again")
        return m
    }

    @Test("a problem is finished with a period when it has none, and never gets a second one")
    func problemPunctuation() async {
        let tail = " You can add it from Manage Disk."
        let head = "Install complete. The boot theme wasn't added: "
        #expect(await message(after: .notApplied(problem: "the download failed")) == head + "the download failed." + tail)
        #expect(await message(after: .notApplied(problem: "the download failed.")) == head + "the download failed." + tail)
        #expect(await message(after: .notApplied(problem: "the download failed. \n")) == head + "the download failed." + tail, "trailing whitespace goes")
        #expect(await message(after: .notApplied(problem: "no space left  ")) == head + "no space left." + tail)
        #expect(await message(after: .notApplied(problem: "did it fail?")) == head + "did it fail?" + tail)
        #expect(await message(after: .notApplied(problem: "it failed!")) == head + "it failed!" + tail)
    }

    @Test("a theme that can't be used is named, and the message points to another theme instead of trying again")
    func themeUnavailable() async {
        let head = "Install complete. The boot theme wasn't added: "
        let tail = " You can pick another theme from Manage Disk."
        // The exact text for a download that is gone.
        let gone = ThemeUnavailableCopy.postInstallResult(for: ThemeError.downloadGone(host: "github.com", status: 404), choice: .catalog(id: "tela"), name: "Tela")
        #expect(await message(after: gone) == "Install complete. The boot theme wasn't added: Mactoy couldn't find “Tela” where its theme list says it should be. You can pick another theme from Manage Disk.")
        let changed = ThemeUnavailableCopy.postInstallResult(for: ThemeError.checksumMismatch(expected: "a", actual: "b"), choice: .catalog(id: "tela"), name: "Tela")
        #expect(await message(after: changed) == head + "“Tela” has changed since it was added to Mactoy's theme list, so Mactoy didn't use it." + tail)
        let removed = ThemeUnavailableCopy.postInstallResult(for: ThemeError.unknownTheme("tela"), choice: .catalog(id: "tela"), name: "Tela")
        #expect(await message(after: removed) == head + "“Tela” is no longer in Mactoy's theme list." + tail)
        // A theme of the user's own was removed from My Themes: no list, and no internal id.
        let savedGone = ThemeUnavailableCopy.postInstallResult(for: ThemeError.unknownTheme("custom-night-sky-1a2b3c4d"),
                                                               choice: .custom(id: "custom-night-sky-1a2b3c4d"), name: "custom-night-sky-1a2b3c4d")
        #expect(await message(after: savedGone) == head + "That theme is no longer in My Themes." + tail)
        // The same punctuation rules as any other problem.
        #expect(await message(after: .themeUnavailable(problem: "it is gone")) == head + "it is gone." + tail)
        #expect(await message(after: .themeUnavailable(problem: "it is gone. \n")) == head + "it is gone." + tail)
    }

    @Test("warnings after the theme was written are a note on the success, not a failure")
    func appliedWithWarnings() async {
        let uefi = "This drive also sets a separate theme for UEFI boot (\"theme_uefi\" in ventoy.json). Ventoy uses that one instead when it boots in that mode."
        let folder = "The drive's settings folder is named \"Ventoy\". Ventoy only reads a folder named \"ventoy\" in lowercase, so rename it or the theme won't load."
        #expect(await message(after: .applied(warnings: [uefi])) == "Install complete, with your boot theme. Note: " + uefi)
        #expect(await message(after: .applied(warnings: [uefi, folder])) == "Install complete, with your boot theme. Note: " + uefi + " " + folder)
        // Each warning is a sentence of its own, so a run of them reads as sentences.
        #expect(await message(after: .applied(warnings: ["one thing", " another thing \n"])) == "Install complete, with your boot theme. Note: one thing. another thing.")
        // Nothing to say is the plain success; so is a list of nothing.
        #expect(await message(after: .applied(warnings: [])) == "Install complete, with your boot theme")
        #expect(await message(after: .applied(warnings: ["", "  "])) == "Install complete, with your boot theme")
    }

    @Test("asSentence trims, adds a period only when none of . ! ? ends the text, and leaves nothing alone")
    func asSentence() {
        #expect(AppState.asSentence("failed") == "failed.")
        #expect(AppState.asSentence("failed.") == "failed.")
        #expect(AppState.asSentence("failed!") == "failed!")
        #expect(AppState.asSentence("failed?") == "failed?")
        #expect(AppState.asSentence("  failed \n\t") == "failed.")
        #expect(AppState.asSentence("failed.  ") == "failed.")
        #expect(AppState.asSentence("failed...") == "failed...")
        #expect(AppState.asSentence("") == "")
        #expect(AppState.asSentence(" \n ") == "")
    }

    @Test("with no applier wired in, the success message says so instead of claiming a theme")
    func unwiredApplier() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        s.status = .success("Install complete")
        await s.addThemeAfterInstall(.catalog(id: "tela"), mode: .installVentoy, to: disk())
        guard case .success(let m) = s.status else { Issue.record("not success"); return }
        #expect(m == "Install complete. The boot theme wasn't added: theme support isn't set up. You can add it from Manage Disk.")
        // Ventoy's own theme needs no applier, so nothing is reported.
        s.status = .success("Install complete")
        await s.addThemeAfterInstall(.ventoyDefault, mode: .installVentoy, to: disk())
        guard case .success(let m2) = s.status else { Issue.record("not success"); return }
        #expect(m2 == "Install complete")
    }

    @Test("default theme, update and flash skip the applier")
    func skipped() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        let calls = Counter()
        s.installThemeApplier = { _, _ in calls.n += 1; return .applied(warnings: []) }
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

    // MARK: Erase waits for the probe

    @Test("Erase is held until the probe answers, whether it finds a theme or not")
    func eraseHeldUntilProbeAnswers() async {
        let d = TempDefaults(); defer { d.remove() }
        let url = volume
        for found in [true, false] {
            let s = Fixture.state(d)
            s.driveThemeProbeCap = 600_000_000_000     // only the answer may release it here, not the cap
            s.driveThemeProbe = { _ in
                try? await Task.sleep(nanoseconds: 150_000_000)
                return found ? (name: "Sunset", volume: url) : nil
            }
            s.mode = .installVentoy
            s.requestRun()
            #expect(s.pendingEraseConfirmation?.driveThemeProbePending == true, "held from the moment the sheet opens")
            await Fixture.wait { s.pendingEraseConfirmation?.driveThemeProbePending == false }
            #expect(s.pendingEraseConfirmation?.driveThemeProbePending == false)
            #expect((s.pendingEraseConfirmation?.driveThemeName != nil) == found)
        }
    }

    @Test("a drive that never answers holds Erase only for the cap; a later answer still adds the box")
    func eraseHeldOnlyForTheCap() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        let url = volume
        let gate = Gate()
        s.driveThemeProbeCap = 100_000_000
        s.driveThemeProbe = { _ in
            // Answers only once the test has seen the cap release Erase.
            await gate.wait()
            return (name: "Sunset", volume: url)
        }
        s.mode = .installVentoy
        s.requestRun()
        #expect(s.pendingEraseConfirmation?.driveThemeProbePending == true)
        await Fixture.wait { s.pendingEraseConfirmation?.driveThemeProbePending == false }
        #expect(s.pendingEraseConfirmation?.driveThemeProbePending == false, "the cap released it")
        #expect(s.pendingEraseConfirmation?.driveThemeName == nil, "the probe hasn't answered; no box yet")
        await gate.open()
        await Fixture.wait { s.pendingEraseConfirmation?.driveThemeName != nil }
        #expect(s.pendingEraseConfirmation?.driveThemeName == "Sunset")
        #expect(s.pendingEraseConfirmation?.driveThemeProbePending == false)
    }

    @Test("the default cap is 3 seconds")
    func defaultCap() {
        let d = TempDefaults(); defer { d.remove() }
        #expect(Fixture.state(d).driveThemeProbeCap == 3_000_000_000)
    }

    @Test("only an Install's sheet is held, and an old probe or cap never releases a newer one")
    func heldPerConfirmation() async throws {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        let url = volume

        s.mode = .updateVentoy
        s.applyProbeResult(Fixture.probe("disk97"))
        s.requestRun()
        #expect(s.pendingEraseConfirmation?.driveThemeProbePending == false, "Update has nothing to wait for")
        s.cancelRun()
        s.mode = .flashImage
        s.selectedImagePath = "/tmp/x.iso"
        s.requestRun()
        #expect(s.pendingEraseConfirmation?.driveThemeProbePending == false, "nor does Flash Image")
        s.cancelRun()

        // The first confirmation's probe and cap both run out while the second is open.
        s.mode = .installVentoy
        s.driveThemeProbeCap = 150_000_000
        s.driveThemeProbe = { _ in
            try? await Task.sleep(nanoseconds: 150_000_000)
            return (name: "Old", volume: url)
        }
        s.requestRun()
        s.cancelRun()
        s.driveThemeProbeCap = 5_000_000_000
        s.driveThemeProbe = { _ in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return (name: "New", volume: url)
        }
        s.requestRun()
        try await Task.sleep(nanoseconds: 450_000_000)
        #expect(s.pendingEraseConfirmation?.driveThemeProbePending == true, "the first sheet's answer and cap don't release this one")
        #expect(s.pendingEraseConfirmation?.driveThemeName == nil)
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
        let expected = "Couldn't save the drive's boot theme: the library is read-only. Nothing was erased. Choose Retry to try saving again, or choose Done and start the install again with the option unticked to erase without saving."
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
            #expect(m.hasSuffix("Nothing was erased. Choose Retry to try saving again, or choose Done and start the install again with the option unticked to erase without saving."))
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

    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Mactoy/AppState.swift"), encoding: .utf8)
    }

    private func runBody() throws -> String {
        let source = try source()
        let start = try #require(source.range(of: "    func run(\n"))
        let end = try #require(source.range(of: "    /// Layer 6 (BSD-name guard): even if", range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    @Test("Layer 6, Time Machine and Layer 4 come first, then the helper gate, then the save, then Layer 6 and Layer 4 again, then the helper")
    func saveOrder() throws {
        let body = try runBody()
        let steps = [
            "guard passesBSDNameGuard(target) else { return }",
            "try await timeMachineLookup()",
            "isLockedBackup(target)",
            "guard passesLiveFingerprintCheck(target) else { return }",
            "if helperStatus != .enabled {",
            "guard await saveDriveThemeBeforeErase(from: themeVolume, on: target) else {",
            "guard passesBSDNameGuard(target), passesLiveFingerprintCheck(target) else {",
            "try await HelperInvoker.run(",
        ]
        var positions: [String.Index] = []
        for step in steps {
            let range = try #require(body.range(of: step), "missing in run(): \(step)")
            positions.append(range.lowerBound)
        }
        #expect(positions == positions.sorted(), "the order of the checks, the save and the helper call changed")
        // The second pair of checks, and the save, are for a run that saves, and only then.
        #expect(body.contains("if confirmedMode == .installVentoy, let themeVolume = confirmedSaveThemeFrom {"))
        // Each guard appears once at the top and once after the save, and nowhere else in run().
        #expect(body.components(separatedBy: "passesBSDNameGuard(target)").count - 1 == 2)
        #expect(body.components(separatedBy: "passesLiveFingerprintCheck(target)").count - 1 == 2)
    }

    /// The text of the `else { ... }` that follows `guard`, up to its closing brace (no nested braces in these).
    private func elseBlock(after guardLine: String, in body: String) throws -> String {
        let start = try #require(body.range(of: guardLine), "missing in run(): \(guardLine)")
        let rest = body[start.upperBound...]
        let end = try #require(rest.firstIndex(of: "}"))
        return String(rest[rest.startIndex..<end])
    }

    @Test("a run that stops after the helper gate, on a failed save or a failed re-check, still honours 'remove helper after this run'")
    func earlyExitsRemoveTheHelper() throws {
        let body = try runBody()
        let save = try elseBlock(after: "guard await saveDriveThemeBeforeErase(from: themeVolume, on: target) else {", in: body)
        #expect(save.contains("await removeHelperIfAsked()") && save.contains("return"))
        #expect(try #require(save.range(of: "await removeHelperIfAsked()")).lowerBound < (try #require(save.range(of: "return")).lowerBound),
                "the helper is dealt with before the run returns")
        let recheck = try elseBlock(after: "guard passesBSDNameGuard(target), passesLiveFingerprintCheck(target) else {", in: body)
        #expect(recheck.contains("await removeHelperIfAsked()") && recheck.contains("return"))
        #expect(try #require(recheck.range(of: "await removeHelperIfAsked()")).lowerBound < (try #require(recheck.range(of: "return")).lowerBound))

        // Exits before the gate have no helper to remove and are not changed.
        let gate = try #require(body.range(of: "if helperStatus != .enabled {"))
        for before in ["guard passesBSDNameGuard(target) else { return }", "guard passesLiveFingerprintCheck(target) else { return }"] {
            #expect(try #require(body.range(of: before)).lowerBound < gate.lowerBound)
        }
        // The call is used in exactly three places: those two exits and the end of the run.
        #expect(body.components(separatedBy: "removeHelperIfAsked()").count - 1 == 3)
        // The choice itself is read in one place, the shared helper, not in run().
        #expect(!body.contains("if uninstallHelperAfterRun"))
        // The one remaining direct unregister is the re-register path of a version mismatch.
        #expect(body.components(separatedBy: "HelperLifecycle.unregister()").count - 1 == 1)
        let reregister = try #require(body.range(of: "try? await HelperLifecycle.unregister()"))
        #expect(body[reregister.upperBound...].prefix(80).contains("HelperLifecycle.register()"))
        // The end of the run calls it before it clears or keeps the captured target.
        let end = try #require(body.range(of: "        await removeHelperIfAsked()\n\n        // Clear the captured target/mode now"))
        #expect(end.lowerBound > (try #require(body.range(of: "Self.log.error(\"run() failed: ")).lowerBound))
    }

    @Test("removeHelperIfAsked takes the helper off only when the user left the box ticked")
    func removeHelperIfAsked() async {
        let d = TempDefaults(); defer { d.remove() }
        let s = Fixture.state(d)
        let removals = Counter()
        s.helperRemover = { removals.n += 1 }
        #expect(s.uninstallHelperAfterRun, "ticked by default")
        await s.removeHelperIfAsked()
        #expect(removals.n == 1)
        s.uninstallHelperAfterRun = false
        s.helperStatus = .enabled
        await s.removeHelperIfAsked()
        #expect(removals.n == 1, "unticked: the helper stays")
        #expect(s.helperStatus == .enabled, "and nothing about it is changed")
    }

    @Test("the status goes back to the plain text once the save and the re-check are done")
    func statusAfterTheSave() throws {
        let body = try runBody()
        let neutral = "status = .preparing(\"Preparing install plan...\")"
        // Once at the top, as before, and once after the save.
        #expect(body.components(separatedBy: neutral).count - 1 == 2)
        let recheck = try #require(body.range(of: "guard passesBSDNameGuard(target), passesLiveFingerprintCheck(target) else {"))
        let helper = try #require(body.range(of: "try await HelperInvoker.run("))
        let again = try #require(body.range(of: neutral, range: recheck.upperBound..<body.endIndex))
        #expect(again.lowerBound < helper.lowerBound, "the status is reset before the helper starts erasing")
        // It ends the save block, so it only happens in a run that saved.
        let after = body[again.upperBound...].drop(while: { $0 == " " || $0 == "\n" })
        #expect(after.hasPrefix("}"))
        // And it is the same text the run used before the save.
        let first = try #require(body.range(of: neutral))
        #expect(first.lowerBound < recheck.lowerBound)
        // The "Saving…" text is set in the save step, not in run().
        #expect(!body.contains("status = .preparing(\"Saving"))
    }

    @Test("the doc comments of the theme seams sit on the property they describe, and the re-check comment says what is in between")
    func comments() throws {
        let source = try source()
        func docComment(above declaration: String) throws -> String {
            let at = try #require(source.range(of: declaration), "missing: \(declaration)")
            let lines = source[..<at.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            return lines.reversed().prefix(while: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("///") })
                .reversed().joined(separator: "\n")
        }
        let cap = try docComment(above: "var driveThemeProbeCap: UInt64")
        #expect(cap.contains("How long the erase sheet waits for `driveThemeProbe`"))
        #expect(!cap.contains("Which disk"))
        let identifier = try docComment(above: "var driveVolumeIdentifier:")
        #expect(identifier.contains("Which disk a mounted volume is on"))
        #expect(!identifier.contains("How long"))
        #expect(try runBody().contains("without one has only the plan, version lookup and helper gate in\n            // between, as before."))
    }

    @Test("the two layers keep their code and messages when run again after a save")
    func layersKeepTheirCode() throws {
        let source = try source()
        func body(of function: String, until next: String) throws -> String {
            let start = try #require(source.range(of: function))
            let end = try #require(source.range(of: next, range: start.upperBound..<source.endIndex))
            return String(source[start.lowerBound..<end.lowerBound])
        }
        let layer6 = try body(of: "private func passesBSDNameGuard", until: "    /// Layer 4 (app-side re-verification)")
        #expect(layer6.contains("if let liveSelection = selectedDiskBSD, liveSelection != target.bsdName {"))
        #expect(layer6.contains("Refusing to run: the selected disk changed between confirmation and execution. "))
        #expect(layer6.contains("status = .failed("))
        #expect(layer6.contains("return false"))
        let layer4 = try body(of: "private func passesLiveFingerprintCheck", until: "    /// The plan `run(...)` hands to the helper")
        #expect(layer4.contains("let live = try DiskInfo.probe(bsdName: target.bsdName)"))
        #expect(layer4.contains("if let mismatch = target.fingerprintMismatch(against: live) {"))
        #expect(layer4.contains("Refusing to run: the disk at /dev/"))
        #expect(layer4.contains("Refusing to run: could not re-verify /dev/"))
        #expect(layer4.components(separatedBy: "status = .failed(").count - 1 == 2)
        #expect(layer4.components(separatedBy: "return false").count - 1 == 2)
    }

    @Test("both success sites add the confirmed theme")
    func successSites() throws {
        let body = try runBody()
        let successes = body.components(separatedBy: "status = .success(Self.successMessage(for: plan))").count - 1
        let withTheme = body.components(separatedBy: "status = .success(Self.successMessage(for: plan))\n").dropFirst().filter {
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
        ThemeStore(library: ThemeLibrary(root: try tempDir().appendingPathComponent("My Themes"), discard: .delete))
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

    @Test("a drive using a theme that is in My Themes offers nothing, checked on disk without listing My Themes")
    func savedThemeOnDrive() async throws {
        let libraryRoot = try tempDir().appendingPathComponent("My Themes")
        let root = try volumes(config: handTheme)
        let volume = root.appendingPathComponent("Ventoy")
        let prefs = TempDefaults()
        defer { prefs.remove() }
        let first = ThemeStore(library: ThemeLibrary(root: libraryRoot, discard: .delete), defaults: prefs.defaults)
        let saved = try #require(try await first.saveDriveTheme(on: volume))
        _ = try await first.apply(.custom(id: saved.id), to: volume)
        let probe = { (store: ThemeStore) in
            await store.savableDriveTheme(onDisk: "disk97", volumesDirectory: root, deviceIdentifier: { _ in "disk97s2" })
        }

        // The app starts again and nothing has listed My Themes yet.
        let later = ThemeStore(library: ThemeLibrary(root: libraryRoot, discard: .delete), defaults: prefs.defaults)
        #expect(await probe(later) == nil)
        #expect(!later.hasListedLibrary)

        // Deleted in Finder after it was listed: the list is out of date, the offer isn't.
        await later.loadSavedThemes()
        #expect(later.savedThemes.map(\.id) == [saved.id])
        try FileManager.default.removeItem(at: libraryRoot.appendingPathComponent(saved.id))
        #expect(await probe(later)?.name == saved.name)
    }

    @Test("on a Mac that hasn't used My Themes, a drive's saved theme is offered and My Themes isn't read")
    func savedThemeOnDriveLibraryNotInUse() async throws {
        let libraryRoot = try tempDir().appendingPathComponent("My Themes")
        let root = try volumes(config: handTheme)
        let volume = root.appendingPathComponent("Ventoy")
        let first = ThemeStore(library: ThemeLibrary(root: libraryRoot, discard: .delete))
        let saved = try #require(try await first.saveDriveTheme(on: volume))
        _ = try await first.apply(.custom(id: saved.id), to: volume)
        // No record that My Themes is in use (another Mac's drive, or preferences removed).
        let later = ThemeStore(library: ThemeLibrary(root: libraryRoot, discard: .delete))
        #expect(await later.savableDriveTheme(onDisk: "disk97", volumesDirectory: root, deviceIdentifier: { _ in "disk97s2" })?.name == saved.name)
        #expect(!later.hasListedLibrary)
        // Saving it again is harmless: the entry it came from, no second copy.
        #expect(try await later.saveDriveTheme(on: volume) == saved)
        #expect(later.savedThemes == [saved])

        // Changed on the drive, it's a different theme: offered, and saving keeps the drive's version.
        let onDrive = volume.appendingPathComponent("ventoy/themes/mactoy-\(saved.id)/bg.png")
        try Data([9, 9]).write(to: onDrive)
        let prefs = TempDefaults()
        defer { prefs.remove() }
        prefs.defaults.set(true, forKey: ThemeStore.libraryInUseKey)
        let inUse = ThemeStore(library: ThemeLibrary(root: libraryRoot, discard: .delete), defaults: prefs.defaults)
        #expect(await inUse.savableDriveTheme(onDisk: "disk97", volumesDirectory: root, deviceIdentifier: { _ in "disk97s2" })?.name == saved.name)
        let edited = try #require(try await later.saveDriveTheme(on: volume))
        #expect(edited.id != saved.id)
        #expect(try Data(contentsOf: libraryRoot.appendingPathComponent(edited.id).appendingPathComponent("bg.png")) == Data([9, 9]))
        #expect(Set(later.savedThemes.map(\.id)) == [saved.id, edited.id])
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

// MARK: A pick that is gone

@MainActor
@Suite("A theme that no longer exists is not the pick for the next install")
struct InstallThemeGoneTests {

    private func available(saved: [String] = [], catalog: [String] = [], source: ThemeCatalogLoader.Source = .remote) -> ThemeAvailability {
        ThemeAvailability(savedIDs: Set(saved), catalogIDs: Set(catalog), catalogSource: source)
    }

    private let fallback = AppState.defaultInstallTheme

    @Test("a saved theme that left My Themes goes back to the default; one that is still there stays")
    func removedSavedTheme() {
        let pick = ThemeChoice.custom(id: "custom-night-12345678")
        #expect(available(saved: ["custom-night-12345678"]).validated(pick, fallback: fallback) == pick)
        #expect(available(saved: ["custom-other-87654321"]).validated(pick, fallback: fallback) == fallback)
        #expect(available().validated(pick, fallback: fallback) == fallback)
        // Whatever the catalog is doing, a saved theme depends on My Themes only.
        for source: ThemeCatalogLoader.Source in [.none, .bundled, .cached, .remote] {
            #expect(available(source: source).validated(pick, fallback: fallback) == fallback)
        }
    }

    @Test("a catalog theme that isn't in the online catalog goes back to the default; one that is stays")
    func missingCatalogTheme() {
        let pick = ThemeChoice.catalog(id: "tela")
        #expect(available(catalog: ["tela", "dracula"], source: .remote).validated(pick, fallback: fallback) == pick)
        #expect(available(catalog: ["dracula"], source: .remote).validated(pick, fallback: fallback) == fallback)
        #expect(available(catalog: [], source: .remote).validated(pick, fallback: fallback) == fallback)
    }

    @Test("the bundled and cached catalogs can lag the online one, so a pick missing from them is kept")
    func laggingCatalogsKeepThePick() {
        let pick = ThemeChoice.catalog(id: "tela")
        for source: ThemeCatalogLoader.Source in [.bundled, .cached] {
            #expect(available(catalog: ["tela", "dracula"], source: source).validated(pick, fallback: fallback) == pick, "\(source)")
            #expect(available(catalog: ["dracula"], source: source).validated(pick, fallback: fallback) == pick, "\(source)")
            #expect(available(catalog: [], source: source).validated(pick, fallback: fallback) == pick, "\(source)")
        }
    }

    @Test("before any catalog has loaded the catalog pick is left alone")
    func catalogNotLoadedYet() {
        let pick = ThemeChoice.catalog(id: "tela")
        #expect(available(source: .none).validated(pick, fallback: fallback) == pick)
        // A saved pick can't be a custom theme here: only a loaded My Themes can name one.
        #expect(available(saved: ["custom-x-12345678"], source: .none).validated(pick, fallback: fallback) == pick)
    }

    @Test("Ventoy's own theme is always there, and the default stays the default")
    func alwaysThere() {
        for source: ThemeCatalogLoader.Source in [.none, .bundled, .remote] {
            #expect(available(source: source).validated(.ventoyDefault, fallback: fallback) == .ventoyDefault)
        }
        #expect(available(catalog: [], source: .remote).validated(fallback, fallback: fallback) == fallback)
    }

    @Test("the app state resets a gone pick, saves the reset, and leaves a good pick unwritten")
    func appStateResets() {
        let d = TempDefaults(); defer { d.remove() }
        let s = AppState(defaults: d.defaults)

        s.installTheme = .custom(id: "custom-night-12345678")
        s.resetInstallThemeIfUnavailable(available(saved: ["custom-night-12345678"]))
        #expect(s.installTheme == .custom(id: "custom-night-12345678"))
        s.resetInstallThemeIfUnavailable(available(saved: []))
        #expect(s.installTheme == AppState.defaultInstallTheme)

        s.installTheme = .catalog(id: "tela")
        s.resetInstallThemeIfUnavailable(available(catalog: ["tela"], source: .bundled))
        #expect(s.installTheme == .catalog(id: "tela"))
        s.resetInstallThemeIfUnavailable(available(catalog: [], source: .none))
        #expect(s.installTheme == .catalog(id: "tela"), "no catalog yet")
        s.resetInstallThemeIfUnavailable(available(catalog: ["dracula"], source: .bundled))
        #expect(s.installTheme == .catalog(id: "tela"), "a bundled copy can lag the online catalog")
        s.resetInstallThemeIfUnavailable(available(catalog: ["dracula"], source: .cached))
        #expect(s.installTheme == .catalog(id: "tela"), "so can a cached one")
        s.resetInstallThemeIfUnavailable(available(catalog: ["dracula"], source: .remote))
        #expect(s.installTheme == AppState.defaultInstallTheme)
        // The next launch starts from the reset pick, not from the theme that is gone.
        #expect(AppState(defaults: d.defaults).installTheme == AppState.defaultInstallTheme)

        // The user's opt-out is theirs to keep.
        s.installTheme = .ventoyDefault
        s.resetInstallThemeIfUnavailable(available(catalog: [], source: .remote))
        #expect(s.installTheme == .ventoyDefault)
        #expect(d.defaults.string(forKey: "installTheme") == "ventoy-default")
    }

    // The fallback is what the user last chose and kept, not Mactoy's default.

    @Test("a removed custom pick goes back to a stored opt-out, which stays stored")
    func removedCustomKeepsTheOptOut() {
        let d = TempDefaults(); defer { d.remove() }
        let s = AppState(defaults: d.defaults)
        s.installTheme = .ventoyDefault
        #expect(d.defaults.string(forKey: "installTheme") == "ventoy-default")
        s.installTheme = .custom(id: "custom-night-12345678")     // not stored
        #expect(d.defaults.string(forKey: "installTheme") == "ventoy-default")
        s.resetInstallThemeIfUnavailable(available(saved: []))
        #expect(s.installTheme == .ventoyDefault)
        #expect(d.defaults.string(forKey: "installTheme") == "ventoy-default")
        #expect(AppState(defaults: d.defaults).installTheme == .ventoyDefault)
    }

    @Test("a removed custom pick with nothing stored goes to Mocha, and the default stays unsaved")
    func removedCustomWithNothingStored() {
        let d = TempDefaults(); defer { d.remove() }
        let s = AppState(defaults: d.defaults)
        s.installTheme = .custom(id: "custom-night-12345678")
        s.resetInstallThemeIfUnavailable(available(saved: []))
        #expect(s.installTheme == .catalog(id: "catppuccin-mocha"))
        #expect(d.defaults.string(forKey: "installTheme") == nil)
        #expect(AppState(defaults: d.defaults).installTheme == AppState.defaultInstallTheme)
    }

    @Test("a removed custom pick goes back to a stored catalog theme that is still there, and stores nothing new")
    func removedCustomKeepsTheCatalogPick() {
        let d = TempDefaults(); defer { d.remove() }
        d.defaults.set("catalog:tela", forKey: "installTheme")
        let s = AppState(defaults: d.defaults)
        #expect(s.installTheme == .catalog(id: "tela"))
        s.installTheme = .custom(id: "custom-night-12345678")
        s.resetInstallThemeIfUnavailable(available(saved: [], catalog: ["tela", "dracula"], source: .remote))
        #expect(s.installTheme == .catalog(id: "tela"))
        #expect(d.defaults.string(forKey: "installTheme") == "catalog:tela")

        // Before the online list is in, a stored catalog theme isn't known to be gone, so it is the fallback.
        for source: ThemeCatalogLoader.Source in [.none, .bundled, .cached] {
            s.installTheme = .custom(id: "custom-night-12345678")
            s.resetInstallThemeIfUnavailable(available(saved: [], catalog: [], source: source))
            #expect(s.installTheme == .catalog(id: "tela"), "\(source)")
            #expect(d.defaults.string(forKey: "installTheme") == "catalog:tela", "\(source)")
        }
    }

    @Test("a removed custom pick, with a stored catalog theme that is gone from the online catalog, goes to Mocha and the stale value is dropped")
    func removedCustomWithStaleStoredCatalogTheme() {
        let d = TempDefaults(); defer { d.remove() }
        d.defaults.set("catalog:tela", forKey: "installTheme")
        let s = AppState(defaults: d.defaults)
        s.installTheme = .custom(id: "custom-night-12345678")
        s.resetInstallThemeIfUnavailable(available(saved: [], catalog: ["dracula"], source: .remote))
        #expect(s.installTheme == AppState.defaultInstallTheme)
        #expect(d.defaults.string(forKey: "installTheme") == nil, "nothing new is stored, and the next launch doesn't start from tela")
        #expect(AppState(defaults: d.defaults).installTheme == AppState.defaultInstallTheme)
    }

    @Test("a stored value Mactoy didn't write is not a fallback")
    func removedCustomWithJunkStored() {
        let d = TempDefaults(); defer { d.remove() }
        d.defaults.set("something-else", forKey: "installTheme")
        let s = AppState(defaults: d.defaults)
        s.installTheme = .custom(id: "custom-night-12345678")
        s.resetInstallThemeIfUnavailable(available(saved: []))
        #expect(s.installTheme == AppState.defaultInstallTheme)
        #expect(d.defaults.string(forKey: "installTheme") != "catalog:catppuccin-mocha", "the default is not stored")
    }

    @Test("a pick that is fine is left alone, whatever is stored")
    func goodPickIgnoresWhatIsStored() {
        let d = TempDefaults(); defer { d.remove() }
        d.defaults.set("ventoy-default", forKey: "installTheme")
        let s = AppState(defaults: d.defaults)
        s.installTheme = .custom(id: "custom-night-12345678")
        s.resetInstallThemeIfUnavailable(available(saved: ["custom-night-12345678"]))
        #expect(s.installTheme == .custom(id: "custom-night-12345678"))
        #expect(d.defaults.string(forKey: "installTheme") == "ventoy-default")
    }

    @Test("the theme picker goes back to what it opened on if that is still there, else to Ventoy's own theme")
    func pickerFallback() {
        let night = ThemeChoice.custom(id: "custom-night-12345678")
        // The sheet opened on the catalog pick: removing a saved theme returns to it.
        #expect(available(saved: ["custom-night-12345678"], catalog: ["tela"]).validated(.catalog(id: "tela"), fallback: .ventoyDefault) == .catalog(id: "tela"))
        // It opened on the saved theme that was just removed.
        #expect(available(saved: []).validated(night, fallback: .ventoyDefault) == .ventoyDefault)
        // It opened on another saved theme that is still there.
        #expect(available(saved: ["custom-other-87654321"]).validated(.custom(id: "custom-other-87654321"), fallback: .ventoyDefault) == .custom(id: "custom-other-87654321"))
        #expect(available().validated(.ventoyDefault, fallback: .ventoyDefault) == .ventoyDefault)
    }

    @Test("a good pick is not written again")
    func goodPickNotRewritten() {
        let d = TempDefaults(); defer { d.remove() }
        let s = AppState(defaults: d.defaults)
        #expect(d.defaults.string(forKey: "installTheme") == nil)
        s.resetInstallThemeIfUnavailable(available(catalog: ["catppuccin-mocha"], source: .bundled))
        #expect(d.defaults.string(forKey: "installTheme") == nil, "the untouched default stays unsaved")
        // Even the default itself missing from the catalog changes nothing: it is already the fallback.
        s.resetInstallThemeIfUnavailable(available(catalog: ["tela"], source: .remote))
        #expect(s.installTheme == AppState.defaultInstallTheme)
        #expect(d.defaults.string(forKey: "installTheme") == nil)
    }

    @Test("the store reports what can be chosen, and it follows My Themes and the catalog")
    func storeAvailability() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-avail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let theme = dir.appendingPathComponent("Night")
        try FileManager.default.createDirectory(at: theme, withIntermediateDirectories: true)
        try Data("title-text: \"x\"\n".utf8).write(to: theme.appendingPathComponent("theme.txt"))
        let entry = ThemeEntry(id: "from-catalog", name: "From Catalog", author: "a", homepage: URL(string: "https://github.com/a/b")!,
                               license: "MIT", showsVentoyHotkeys: true, notes: nil,
                               download: .init(url: URL(string: "https://github.com/a/b/releases/download/v1/x.zip")!,
                                               sha256: String(repeating: "b", count: 64), root: ""),
                               files: nil, settings: .init(file: "theme.txt"))
        let bundled = dir.appendingPathComponent("bundled.json")
        try JSONEncoder().encode(ThemeCatalog(schema: ThemeCatalog.supportedSchema, themes: [entry])).write(to: bundled)

        struct Offline: ThemeTransport {
            func data(from url: URL, maxBytes: Int) async throws -> Data { throw URLError(.notConnectedToInternet) }
        }
        let store = ThemeStore(loader: ThemeCatalogLoader(transport: Offline(), cacheDirectory: dir.appendingPathComponent("cache"),
                                                          bundledCatalog: bundled, bundledPreviews: nil),
                               fetcher: ThemeFetcher(transport: Offline(), cacheRoot: dir.appendingPathComponent("themes"), bundledRoot: nil),
                               library: ThemeLibrary(root: dir.appendingPathComponent("My Themes"), discard: .delete))
        #expect(store.availability == available(source: .none))

        let choice = try await store.importCustom(from: theme)
        guard case .custom(let id) = choice else { Issue.record("not a saved theme"); return }
        await store.load()
        #expect(store.availability == available(saved: [id], catalog: ["from-catalog"], source: .bundled))

        // Removing it from My Themes is what makes an app state holding it let go.
        let d = TempDefaults(); defer { d.remove() }
        let s = AppState(defaults: d.defaults)
        s.installTheme = choice
        s.resetInstallThemeIfUnavailable(store.availability)
        #expect(s.installTheme == choice)
        try await store.removeSaved(id: id)
        s.resetInstallThemeIfUnavailable(store.availability)
        #expect(s.installTheme == AppState.defaultInstallTheme)
    }
}
