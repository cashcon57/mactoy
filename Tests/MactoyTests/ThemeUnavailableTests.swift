import Foundation
import Testing
@testable import Mactoy
import MactoyKit

/// A catalog theme whose download is gone or changed: how it is recognised, reported, worded and gated.
@Suite("Unavailable themes")
struct ThemeUnavailableTests {

    private func entry(id: String = "tela", name: String = "Tela") -> ThemeEntry {
        ThemeEntry(id: id, name: name, author: "Vinceliuice", homepage: URL(string: "https://github.com/vinceliuice/grub2-themes")!,
                   license: "GPL-3.0", showsVentoyHotkeys: false, notes: nil,
                   download: .init(url: URL(string: "https://github.com/vinceliuice/grub2-themes/releases/download/v1/tela.zip")!,
                                   sha256: String(repeating: "a", count: 64), root: "tela"),
                   files: nil, settings: .init(file: "theme.txt"))
    }

    private func gone(_ status: Int = 404, for entry: ThemeEntry) -> ThemeUnavailable {
        ThemeUnavailable(reason: .gone(status: status), downloadURL: entry.download.url, sha256: entry.download.sha256)
    }

    private func changed(for entry: ThemeEntry) -> ThemeUnavailable {
        ThemeUnavailable(reason: .changed, downloadURL: entry.download.url, sha256: entry.download.sha256)
    }

    // MARK: Recognising it

    @Test("a download that is gone or changed is recorded with its address; nothing else is")
    func recognised() {
        let tela = entry()
        #expect(ThemeUnavailable(error: ThemeError.downloadGone(host: "github.com", status: 404), entry: tela) == gone(404, for: tela))
        #expect(ThemeUnavailable(error: ThemeError.downloadGone(host: "github.com", status: 410), entry: tela) == gone(410, for: tela))
        #expect(ThemeUnavailable(error: ThemeError.checksumMismatch(expected: "a", actual: "b"), entry: tela) == changed(for: tela))
        let others: [any Error] = [ThemeError.serverUnreachable(host: "github.com"), ThemeError.unknownTheme("tela"), ThemeError.missingFile("x"),
                                   DriverError.network("offline"), URLError(.notConnectedToInternet), CancellationError()]
        for error in others { #expect(ThemeUnavailable(error: error, entry: tela) == nil, "\(error)") }
    }

    @Test("a record is about one download: a new address or checksum is another one")
    func describes() {
        let tela = entry()
        let problem = gone(for: tela)
        #expect(problem.describes(tela))
        var moved = tela
        moved.download.url = URL(string: "https://github.com/vinceliuice/grub2-themes/releases/download/v2/tela.zip")!
        var rebuilt = tela
        rebuilt.download.sha256 = String(repeating: "c", count: 64)
        #expect(!problem.describes(moved))
        #expect(!problem.describes(rebuilt))
        // Everything else about the entry is not the download.
        var renamed = tela
        renamed.name = "Tela Again"
        #expect(problem.describes(renamed))
    }

    // MARK: The issue link

    private let appVersion = "0.7.0"
    private let macOS = "macOS 26.0"

    private func query(_ url: URL) throws -> [String: String] {
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test("the link opens a new issue in Mactoy's repository, with a title and a body")
    func issueLink() throws {
        let tela = entry()
        let url = ThemeIssueReport.url(for: tela, problem: gone(for: tela), appVersion: appVersion, macOSVersion: macOS)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "github.com")
        #expect(components.path == "/cashcon57/mactoy/issues/new")
        #expect(components.queryItems?.map(\.name) == ["title", "body"])
        let fields = try query(url)
        #expect(fields["title"] == "Theme unavailable: Tela (tela)")
        #expect(fields["body"] == """
            - **Theme:** Tela (`tela`)
            - **Homepage:** https://github.com/vinceliuice/grub2-themes
            - **Download:** https://github.com/vinceliuice/grub2-themes/releases/download/v1/tela.zip
            - **What happened:** the download returned 404
            - **Mactoy:** 0.7.0
            - **macOS:** macOS 26.0

            Found by Mactoy's theme picker.
            """)
    }

    @Test("what happened says the status for a download that is gone, and the checksum for one that changed")
    func issueWhatHappened() throws {
        let tela = entry()
        let body410 = try query(ThemeIssueReport.url(for: tela, problem: gone(410, for: tela), appVersion: appVersion, macOSVersion: macOS))["body"] ?? ""
        let bodyChanged = try query(ThemeIssueReport.url(for: tela, problem: changed(for: tela), appVersion: appVersion, macOSVersion: macOS))["body"] ?? ""
        #expect(body410.contains("**What happened:** the download returned 410\n"))
        #expect(bodyChanged.contains("**What happened:** the download no longer matches its checksum\n"))
    }

    @Test("nothing about this Mac or its user is in the link")
    func issueLinkIsAnonymous() throws {
        let tela = entry()
        for problem in [gone(for: tela), changed(for: tela)] {
            let url = ThemeIssueReport.url(for: tela, problem: problem)
            let text = url.absoluteString.removingPercentEncoding ?? ""
            #expect(!url.absoluteString.contains("/Users/"))
            #expect(!text.contains("/Users/"))
            #expect(!text.contains(NSHomeDirectory()))
            #expect(!text.contains("/Volumes/"))
        }
    }

    @Test("a name with & # + ; = ? quotes and spaces comes through whole")
    func issueLinkSurvivesAwkwardNames() throws {
        let name = "Rock & Roll #1 C++ ; a=b? “Quoted” é"
        let awkward = entry(id: "rock-roll", name: name)
        let url = ThemeIssueReport.url(for: awkward, problem: gone(for: awkward), appVersion: appVersion, macOSVersion: macOS)
        let fields = try query(url)
        #expect(fields["title"] == "Theme unavailable: \(name) (rock-roll)")
        #expect(fields["body"]?.contains("- **Theme:** \(name) (`rock-roll`)\n") == true)
        // Only the two fields are in the query: nothing in a name ended one early.
        #expect(try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)).queryItems?.count == 2)
        // GitHub reads a "+" as a space and may read ";" as the end of a value, so neither is sent as it is.
        let sent = try #require(url.query)
        #expect(!sent.contains("+"))
        #expect(!sent.contains(";"))
        #expect(!sent.contains("#"))
        #expect(!sent.contains(" "))
        #expect(url.fragment == nil)
    }

    @Test("the link for the running app names a version and a macOS release")
    func issueLinkForThisApp() throws {
        let tela = entry()
        let body = try query(ThemeIssueReport.url(for: tela, problem: gone(for: tela)))["body"] ?? ""
        #expect(body.contains("- **Mactoy:** \(ThemeIssueReport.currentAppVersion)\n"))
        #expect(body.contains("- **macOS:** macOS "))
        #expect(!ThemeIssueReport.currentAppVersion.isEmpty)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #expect(ThemeIssueReport.currentMacOSVersion.hasPrefix("macOS \(v.majorVersion).\(v.minorVersion)"))
    }

    // MARK: Wording

    @Test("the alert says what happened and what to do")
    func alertWording() {
        let tela = entry()
        #expect(ThemeUnavailableCopy.title(name: "Tela") == "“Tela” isn't where it used to be")
        #expect(ThemeUnavailableCopy.message(for: gone(for: tela))
            == "Mactoy couldn't find this theme's download where its theme list says it should be. The author may have moved or changed it. Please report it so we can fix the list. In the meantime, you can find the theme yourself and add it with Add Theme from File.")
        #expect(ThemeUnavailableCopy.message(for: changed(for: tela))
            == "This theme's download has changed since it was added to Mactoy's theme list. The author may have moved or changed it. Please report it so we can fix the list. In the meantime, you can find the theme yourself and add it with Add Theme from File.")
        // A gone download with another status reads the same: the number is for the issue, not the user.
        #expect(ThemeUnavailableCopy.message(for: gone(410, for: tela)) == ThemeUnavailableCopy.message(for: gone(404, for: tela)))
    }

    @Test("the buttons are named as the brief says")
    func buttons() {
        #expect(ThemeUnavailableCopy.reportButton == "Report Problem")
        #expect(ThemeUnavailableCopy.pageButton == "Open Theme's Page")
        #expect(ThemeUnavailableCopy.fileButton == "Add Theme from File…")
        #expect(ThemeUnavailableCopy.okButton == "OK")
        #expect(ThemeUnavailableCopy.chip == "Unavailable")
    }

    @Test("the picker's note is the short version, with the ways forward")
    func pickerNote() {
        let tela = entry()
        #expect(ThemeUnavailableCopy.pickerNote(for: gone(for: tela))
            == "Mactoy couldn't find this theme's download where its theme list says it should be. You can report it, or find the theme yourself and add it from a file.")
        #expect(ThemeUnavailableCopy.pickerNote(for: changed(for: tela))
            == "This theme's download has changed since it was added to Mactoy's theme list. You can report it, or find the theme yourself and add it from a file.")
    }

    @Test("a theme that left the list is named, not its id, and is not reported")
    func unknownTheme() {
        let tela = ThemeChoice.catalog(id: "tela")
        #expect(ThemeUnavailableCopy.unknownTheme(name: "Tela") == "“Tela” is no longer in Mactoy's theme list. Choose another theme.")
        #expect(ThemeUnavailableCopy.message(for: ThemeError.unknownTheme("tela"), choice: tela, themeName: "Tela")
            == "“Tela” is no longer in Mactoy's theme list. Choose another theme.")
        // Any other failure is told as it is.
        #expect(ThemeUnavailableCopy.message(for: ThemeError.serverUnreachable(host: "github.com"), choice: tela, themeName: "Tela")
            == "Couldn't reach github.com. Check your internet connection and try again.")
        #expect(ThemeUnavailableCopy.message(for: DriverError.network("offline"), choice: tela, themeName: "Tela") == DriverError.network("offline").localizedDescription)
    }

    @Test("a removed My Themes theme is not blamed on Mactoy's theme list and shows no internal id")
    func savedThemeRemoved() {
        let id = "custom-night-sky-1a2b3c4d"
        let removed = ThemeError.unknownTheme(id)
        // What the store calls a theme it no longer has is its id: that must not reach the user.
        let told = ThemeUnavailableCopy.message(for: removed, choice: .custom(id: id), themeName: id)
        #expect(told == "That theme is no longer in My Themes. Choose another theme.")
        #expect(!told.contains("Mactoy's theme list"))
        #expect(!told.contains(id))
        #expect(!told.contains("custom-"))
        // After an install the tail already says to pick another theme.
        let afterInstall = ThemeUnavailableCopy.postInstallResult(for: removed, choice: .custom(id: id), name: id)
        #expect(afterInstall == .themeUnavailable(problem: "That theme is no longer in My Themes."))
        // A catalog theme keeps its own wording, and any other failure of a saved theme is told as it is.
        #expect(ThemeUnavailableCopy.message(for: removed, choice: .catalog(id: id), themeName: "Night Sky")
            == "“Night Sky” is no longer in Mactoy's theme list. Choose another theme.")
        let busy = ThemeStoreError.busy
        #expect(ThemeUnavailableCopy.message(for: busy, choice: .custom(id: id), themeName: "Night Sky") == busy.localizedDescription)
        #expect(ThemeUnavailableCopy.postInstallResult(for: busy, choice: .custom(id: id), name: "Night Sky") == .notApplied(problem: busy.localizedDescription))
    }

    @Test("after an install, a theme that can't be used is named, and any other failure is told as it is")
    func postInstall() {
        let tela = ThemeChoice.catalog(id: "tela")
        #expect(ThemeUnavailableCopy.postInstallResult(for: ThemeError.downloadGone(host: "github.com", status: 404), choice: tela, name: "Tela")
            == .themeUnavailable(problem: "Mactoy couldn't find “Tela” where its theme list says it should be."))
        #expect(ThemeUnavailableCopy.postInstallResult(for: ThemeError.checksumMismatch(expected: "a", actual: "b"), choice: tela, name: "Tela")
            == .themeUnavailable(problem: "“Tela” has changed since it was added to Mactoy's theme list, so Mactoy didn't use it."))
        #expect(ThemeUnavailableCopy.postInstallResult(for: ThemeError.unknownTheme("tela"), choice: tela, name: "Tela")
            == .themeUnavailable(problem: "“Tela” is no longer in Mactoy's theme list."))
        let unreachable = ThemeError.serverUnreachable(host: "github.com")
        #expect(ThemeUnavailableCopy.postInstallResult(for: unreachable, choice: tela, name: "Tela") == .notApplied(problem: unreachable.localizedDescription))
        #expect(ThemeUnavailableCopy.postInstallResult(for: DriverError.network("offline"), choice: tela, name: "Tela")
            == .notApplied(problem: DriverError.network("offline").localizedDescription))
        #expect(ThemeUnavailableCopy.postInstallResult(for: ThemeStoreError.busy, choice: tela, name: "Tela") == .notApplied(problem: ThemeStoreError.busy.localizedDescription))
    }

    @Test("no wording uses an em-dash")
    func noEmDashes() {
        let tela = entry()
        let problems = [gone(404, for: tela), gone(410, for: tela), changed(for: tela)]
        var all = [ThemeUnavailableCopy.reportButton, ThemeUnavailableCopy.pageButton, ThemeUnavailableCopy.fileButton, ThemeUnavailableCopy.okButton,
                   ThemeUnavailableCopy.chip, ThemeUnavailableCopy.title(name: "X"), ThemeUnavailableCopy.unknownTheme(name: "X"),
                   ThemeUnavailableCopy.postInstallUnknownTheme(name: "X"), ThemeUnavailableCopy.savedThemeRemoved,
                   ThemeUnavailableCopy.postInstallSavedThemeRemoved,
                   ThemeUnavailableCopy.installNote(for: .catalog(id: "tela"), unavailable: ["tela": gone(for: tela)]) ?? "",
                   ThemeError.serverRefused(host: "github.com").errorDescription ?? "",
                   ThemeError.looseThemeFile(folder: "Downloads").errorDescription ?? ""]
        for problem in problems {
            all += [ThemeUnavailableCopy.message(for: problem), ThemeUnavailableCopy.pickerNote(for: problem),
                    ThemeUnavailableCopy.postInstallProblem(for: problem.reason, name: "X")]
            all.append(ThemeIssueReport.url(for: tela, problem: problem, appVersion: "1", macOSVersion: "macOS 26.0").absoluteString.removingPercentEncoding ?? "")
        }
        for text in all { #expect(!text.contains("\u{2014}"), "\(text)") }
    }

    // MARK: The Install tab's note

    @Test("the Install tab says so, in one plain line, when the chosen catalog theme's download is unavailable")
    func installNote() {
        let tela = entry()
        let unavailable = ["tela": gone(for: tela)]
        #expect(ThemeUnavailableCopy.installNote(for: .catalog(id: "tela"), unavailable: unavailable)
            == "This theme's download isn't available right now. Choose another, or add it from a file.")
        // Whatever the reason, the line is the same.
        #expect(ThemeUnavailableCopy.installNote(for: .catalog(id: "tela"), unavailable: ["tela": changed(for: tela)])
            == ThemeUnavailableCopy.installNote(for: .catalog(id: "tela"), unavailable: unavailable))
        // Nothing for any other theme, or when nothing is known to be wrong.
        #expect(ThemeUnavailableCopy.installNote(for: .catalog(id: "other"), unavailable: unavailable) == nil)
        #expect(ThemeUnavailableCopy.installNote(for: .catalog(id: "tela"), unavailable: [:]) == nil)
        #expect(ThemeUnavailableCopy.installNote(for: .ventoyDefault, unavailable: unavailable) == nil)
        #expect(ThemeUnavailableCopy.installNote(for: .custom(id: "tela"), unavailable: unavailable) == nil)
    }

    // MARK: A change that failed

    @Test("whenever the dialog is to be shown there is a plain note as well, with the short error text")
    func failureAlwaysHasNote() {
        let tela = entry()
        let live = [tela]
        let errors: [any Error] = [ThemeError.downloadGone(host: "github.com", status: 404), ThemeError.downloadGone(host: "github.com", status: 410),
                                   ThemeError.checksumMismatch(expected: "a", actual: "b"), ThemeError.serverUnreachable(host: "github.com"),
                                   ThemeError.serverRefused(host: "github.com"), ThemeError.unknownTheme("tela"), ThemeStoreError.busy,
                                   DriverError.network("offline")]
        for error in errors {
            for saved in [nil, "Mine"] as [String?] {
                for noted in [[:], ["tela": gone(for: tela)]] as [[String: ThemeUnavailable]] {
                    let failure = ThemeChangeFailure(error: error, choice: .catalog(id: "tela"), savedName: saved, themeName: "Tela",
                                                     catalog: live, unavailable: noted)
                    #expect(!failure.message.isEmpty, "\(error)")
                    #expect(failure.isError)
                    // The note ends with what the error says, so it is the reason even if the dialog never shows.
                    let reason = ThemeUnavailableCopy.message(for: error, choice: .catalog(id: "tela"), themeName: "Tela")
                    #expect(failure.message.hasSuffix(reason), "\(error)")
                    if let saved { #expect(failure.message.hasPrefix("Saved “\(saved)” to My Themes. The drive's theme wasn't changed: ")) }
                    else { #expect(failure.message == reason) }
                    // The dialog is only for a download that is gone or changed.
                    #expect((failure.alert != nil) == ((error as? ThemeError)?.meansThemeIsUnavailable == true), "\(error)")
                }
            }
        }
        let gone = ThemeChangeFailure(error: ThemeError.downloadGone(host: "github.com", status: 404), choice: .catalog(id: "tela"), savedName: nil,
                                      themeName: "Tela", catalog: live, unavailable: [:])
        #expect(gone.message == "The theme's download isn't where Mactoy's theme list says it should be.")
        #expect(gone.alert != nil)
    }

    @Test("a theme of the user's own, or one the list no longer has, never gets the dialog")
    func failureDialogOnlyForListedCatalogTheme() {
        let tela = entry()
        let error = ThemeError.downloadGone(host: "github.com", status: 404)
        #expect(ThemeChangeFailure.alert(for: error, choice: .custom(id: "tela"), catalog: [tela], unavailable: ["tela": gone(for: tela)]) == nil)
        #expect(ThemeChangeFailure.alert(for: error, choice: .ventoyDefault, catalog: [tela], unavailable: [:]) == nil)
        #expect(ThemeChangeFailure.alert(for: error, choice: .catalog(id: "tela"), catalog: [], unavailable: [:]) == nil)
    }

    @Test("the dialog is built from what the store recorded, and from the list's entry only without it")
    func failureDialogSource() throws {
        let tela = entry()
        let error = ThemeError.downloadGone(host: "github.com", status: 404)
        // The store recorded a 410; the error in hand says 404. The record is about the download that failed, so it wins.
        let recorded = gone(410, for: tela)
        let fromRecord = try #require(ThemeChangeFailure.alert(for: error, choice: .catalog(id: "tela"), catalog: [tela], unavailable: ["tela": recorded]))
        #expect(fromRecord.problem == recorded)
        #expect(fromRecord.entry.id == "tela")
        // Nothing recorded (the list moved on, say): the live entry stands in.
        let fromEntry = try #require(ThemeChangeFailure.alert(for: error, choice: .catalog(id: "tela"), catalog: [tela], unavailable: [:]))
        #expect(fromEntry.problem == gone(404, for: tela))
        // A record about another download of the id is not this one.
        var moved = tela
        moved.download.sha256 = String(repeating: "c", count: 64)
        let stale = gone(410, for: tela)
        let other = try #require(ThemeChangeFailure.alert(for: error, choice: .catalog(id: "tela"), catalog: [moved], unavailable: ["tela": stale]))
        #expect(other.problem == gone(404, for: moved))
        // A connection problem is not made into "gone" by an older record.
        #expect(ThemeChangeFailure.alert(for: ThemeError.serverUnreachable(host: "github.com"), choice: .catalog(id: "tela"),
                                         catalog: [tela], unavailable: ["tela": recorded]) == nil)
    }

    // MARK: Sheets after adding a theme from a file

    private func pendingChoice() throws -> PendingThemeChoice {
        let pack = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-flow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: pack) }
        for flavour in ["latte", "mocha"] {
            let dir = pack.appendingPathComponent(flavour, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("title-text: \"x\"\n".utf8).write(to: dir.appendingPathComponent("theme.txt"))
        }
        return PendingThemeChoice(opened: try CustomThemeImporter.open(pack))
    }

    @Test("after choosing, the picker opens only once the choice sheet has gone, and the choice is acted on once")
    func pickerWaitsForChoiceSheet() throws {
        let pending = try pendingChoice()
        let mocha = try #require(pending.choices.first { $0.name == "Mocha" })
        var flow = ThemeImportFlow()
        flow.started(.needsChoice(pending))
        #expect(flow.pendingChoice?.id == pending.id, "the sheet is up")
        #expect(!flow.showPicker)

        flow.choose(mocha, from: pending)
        // The sheet is closing: it is no longer asked for, and the picker is not asked for yet.
        #expect(flow.pendingChoice == nil)
        #expect(!flow.showPicker, "not while the choice sheet is still closing")
        #expect(flow.pickerStart == nil)

        // The sheet has gone: now the chosen theme is added.
        let answered = flow.choiceSheetDismissed()
        let answer = try #require(answered)
        #expect(answer.choice == mocha)
        #expect(answer.pending.id == pending.id)
        #expect(!flow.showPicker, "still not: the theme isn't in My Themes yet")
        let again = flow.choiceSheetDismissed()
        #expect(again == nil, "the answer is used once")

        // It is in My Themes: the picker opens on it.
        flow.openPicker(on: .custom(id: "custom-mocha-1a2b3c4d"))
        #expect(flow.showPicker)
        #expect(flow.pickerStart == .custom(id: "custom-mocha-1a2b3c4d"))
    }

    @Test("cancelling the choice sheet leaves nothing pending and opens nothing")
    func cancelLeavesNothing() throws {
        let pending = try pendingChoice()
        var flow = ThemeImportFlow()
        flow.started(.needsChoice(pending))
        flow.cancel()
        #expect(flow.pendingChoice == nil)
        let afterCancel = flow.choiceSheetDismissed()
        #expect(afterCancel == nil)
        #expect(!flow.showPicker)
        #expect(flow.pickerStart == nil)
        // A sheet that goes some other way (its window closed) with no answer is the same.
        flow.started(.needsChoice(pending))
        flow.pendingChoice = nil
        let afterClose = flow.choiceSheetDismissed()
        #expect(afterClose == nil)
        #expect(!flow.showPicker)
    }

    @Test("a cancelled choice is not carried over to the next file")
    func cancelForgetsAnswer() throws {
        let pending = try pendingChoice()
        let latte = try #require(pending.choices.first)
        var flow = ThemeImportFlow()
        flow.started(.needsChoice(pending))
        flow.choose(latte, from: pending)
        flow.cancel()
        let left = flow.choiceSheetDismissed()
        #expect(left == nil)
    }

    @Test("a file with one theme opens the picker on it at once; there is no sheet to wait for")
    func oneThemeOpensPicker() {
        var flow = ThemeImportFlow()
        flow.started(.imported(.custom(id: "custom-x-12345678")))
        #expect(flow.showPicker)
        #expect(flow.pickerStart == .custom(id: "custom-x-12345678"))
        #expect(flow.pendingChoice == nil)
        // The Change Theme button opens it on the drive's theme.
        var plain = ThemeImportFlow()
        plain.openPicker()
        #expect(plain.showPicker)
        #expect(plain.pickerStart == nil)
    }

    // MARK: The picker

    @Test("a theme known to be unavailable can't be confirmed; everything else can")
    func pickerGate() {
        let tela = entry()
        let unavailable = ["tela": gone(for: tela)]
        #expect(!ThemePickerRules.canConfirm(.catalog(id: "tela"), unavailable: unavailable))
        #expect(ThemePickerRules.canConfirm(.catalog(id: "other"), unavailable: unavailable))
        #expect(ThemePickerRules.canConfirm(.ventoyDefault, unavailable: unavailable))
        // A saved theme can't share an id with a catalog one, but even then it is a different theme.
        #expect(ThemePickerRules.canConfirm(.custom(id: "tela"), unavailable: unavailable))
        #expect(ThemePickerRules.canConfirm(.catalog(id: "tela"), unavailable: [:]))
    }
}
