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
        #expect(ThemeUnavailableCopy.unknownTheme(name: "Tela") == "“Tela” is no longer in Mactoy's theme list. Choose another theme.")
        #expect(ThemeUnavailableCopy.message(for: ThemeError.unknownTheme("tela"), themeName: "Tela")
            == "“Tela” is no longer in Mactoy's theme list. Choose another theme.")
        // Any other failure is told as it is.
        #expect(ThemeUnavailableCopy.message(for: ThemeError.serverUnreachable(host: "github.com"), themeName: "Tela")
            == "Couldn't reach github.com. Check your internet connection and try again.")
        #expect(ThemeUnavailableCopy.message(for: DriverError.network("offline"), themeName: "Tela") == DriverError.network("offline").localizedDescription)
    }

    @Test("after an install, a theme that can't be used is named, and any other failure is told as it is")
    func postInstall() {
        #expect(ThemeUnavailableCopy.postInstallResult(for: ThemeError.downloadGone(host: "github.com", status: 404), name: "Tela")
            == .themeUnavailable(problem: "Mactoy couldn't find “Tela” where its theme list says it should be."))
        #expect(ThemeUnavailableCopy.postInstallResult(for: ThemeError.checksumMismatch(expected: "a", actual: "b"), name: "Tela")
            == .themeUnavailable(problem: "“Tela” has changed since it was added to Mactoy's theme list, so Mactoy didn't use it."))
        #expect(ThemeUnavailableCopy.postInstallResult(for: ThemeError.unknownTheme("tela"), name: "Tela")
            == .themeUnavailable(problem: "“Tela” is no longer in Mactoy's theme list."))
        let unreachable = ThemeError.serverUnreachable(host: "github.com")
        #expect(ThemeUnavailableCopy.postInstallResult(for: unreachable, name: "Tela") == .notApplied(problem: unreachable.localizedDescription))
        #expect(ThemeUnavailableCopy.postInstallResult(for: DriverError.network("offline"), name: "Tela")
            == .notApplied(problem: DriverError.network("offline").localizedDescription))
        #expect(ThemeUnavailableCopy.postInstallResult(for: ThemeStoreError.busy, name: "Tela") == .notApplied(problem: ThemeStoreError.busy.localizedDescription))
    }

    @Test("no wording uses an em-dash")
    func noEmDashes() {
        let tela = entry()
        let problems = [gone(404, for: tela), gone(410, for: tela), changed(for: tela)]
        var all = [ThemeUnavailableCopy.reportButton, ThemeUnavailableCopy.pageButton, ThemeUnavailableCopy.fileButton, ThemeUnavailableCopy.okButton,
                   ThemeUnavailableCopy.chip, ThemeUnavailableCopy.title(name: "X"), ThemeUnavailableCopy.unknownTheme(name: "X"),
                   ThemeUnavailableCopy.postInstallUnknownTheme(name: "X"), DriveThemeCopy.savedButUnchanged(name: "X")]
        for problem in problems {
            all += [ThemeUnavailableCopy.message(for: problem), ThemeUnavailableCopy.pickerNote(for: problem),
                    ThemeUnavailableCopy.postInstallProblem(for: problem.reason, name: "X")]
            all.append(ThemeIssueReport.url(for: tela, problem: problem, appVersion: "1", macOSVersion: "macOS 26.0").absoluteString.removingPercentEncoding ?? "")
        }
        for text in all { #expect(!text.contains("\u{2014}"), "\(text)") }
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
