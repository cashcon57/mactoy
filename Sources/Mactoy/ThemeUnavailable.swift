import Foundation
import MactoyKit

/// A catalog theme whose download isn't what Mactoy's theme list says it is,
/// found this session. Not saved: the list may be fixed by the next launch.
struct ThemeUnavailable: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// The server said the file isn't there (404 or 410).
        case gone(status: Int)
        /// The file is there but is no longer the one the list was written for.
        case changed
    }

    let reason: Reason
    let downloadURL: URL
    /// The list's checksum for the download when this was found. With the URL,
    /// it says which download this is about: a fixed list names another.
    let sha256: String

    init(reason: Reason, downloadURL: URL, sha256: String) {
        self.reason = reason
        self.downloadURL = downloadURL
        self.sha256 = sha256
    }

    /// Nil unless `error` says a download is gone or changed (`ThemeError.meansThemeIsUnavailable`).
    static func reason(of error: any Error) -> Reason? {
        switch error as? ThemeError {
        case .downloadGone(_, let status): return .gone(status: status)
        case .checksumMismatch: return .changed
        default: return nil
        }
    }

    /// Nil unless `error` says the download of `entry` is gone or changed.
    init?(error: any Error, entry: ThemeEntry) {
        guard let reason = Self.reason(of: error) else { return nil }
        self.init(reason: reason, downloadURL: entry.download.url, sha256: entry.download.sha256)
    }

    /// Whether this is about the download `entry` has now.
    func describes(_ entry: ThemeEntry) -> Bool {
        entry.download.url == downloadURL && entry.download.sha256 == sha256
    }
}

/// The prefilled GitHub issue for a theme that can't be downloaded.
enum ThemeIssueReport {
    static let newIssueURL = "https://github.com/cashcon57/mactoy/issues/new"

    /// Says only what the theme list already says, plus the two versions.
    /// No paths, drive names or user names: nothing about this Mac or its user goes in.
    static func url(for entry: ThemeEntry, problem: ThemeUnavailable, appVersion: String, macOSVersion: String) -> URL {
        let happened: String
        switch problem.reason {
        case .gone(let status): happened = "the download returned \(status)"
        case .changed: happened = "the download no longer matches its checksum"
        }
        let body = """
            - **Theme:** \(entry.name) (`\(entry.id)`)
            - **Homepage:** \(entry.homepage.absoluteString)
            - **Download:** \(problem.downloadURL.absoluteString)
            - **What happened:** \(happened)
            - **Mactoy:** \(appVersion)
            - **macOS:** \(macOSVersion)

            Found by Mactoy's theme picker.
            """
        var components = URLComponents(string: newIssueURL)!
        // URLComponents leaves "+" and ";" as they are in a query, and GitHub reads
        // the first as a space and may read the second as the end of a value. Only
        // letters, digits and "-._~" stay as they are, so a name can't break the link.
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "title", value: encode("Theme unavailable: \(entry.name) (\(entry.id))")),
            URLQueryItem(name: "body", value: encode(body)),
        ]
        return components.url!
    }

    /// The report for the running app.
    static func url(for entry: ThemeEntry, problem: ThemeUnavailable) -> URL {
        url(for: entry, problem: problem, appVersion: currentAppVersion, macOSVersion: currentMacOSVersion)
    }

    static var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    static var currentMacOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion == 0 ? "" : ".\(v.patchVersion)")
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

/// What the picker lets the user confirm.
enum ThemePickerRules {
    /// A catalog theme known to be unavailable can't be confirmed: it would fail
    /// the same way, and after the drive had been erased, for an install.
    static func canConfirm(_ selection: ThemeChoice, unavailable: [String: ThemeUnavailable]) -> Bool {
        guard case .catalog(let id) = selection else { return true }
        return unavailable[id] == nil
    }
}

/// The wording for themes that can't be used, kept out of the views so tests can read it.
enum ThemeUnavailableCopy {
    static let reportButton = "Report Problem"
    static let pageButton = "Open Theme's Page"
    static let fileButton = "Add Theme from File…"
    static let okButton = "OK"
    static let chip = "Unavailable"

    static func title(name: String) -> String { "“\(name)” isn't where it used to be" }

    /// The first sentence of the alert and the picker's note: what is wrong with the download.
    private static func headline(_ problem: ThemeUnavailable) -> String {
        switch problem.reason {
        case .gone: return "Mactoy couldn't find this theme's download where its theme list says it should be."
        case .changed: return "This theme's download has changed since it was added to Mactoy's theme list."
        }
    }

    /// The alert's message, for the Manage Disk change that failed.
    static func message(for problem: ThemeUnavailable) -> String {
        "\(headline(problem)) The author may have moved or changed it. Please report it so we can fix the list. In the meantime, you can find the theme yourself and add it with Add Theme from File."
    }

    /// The picker's note under an unavailable theme, above the same three actions.
    static func pickerNote(for problem: ThemeUnavailable) -> String {
        "\(headline(problem)) You can report it, or find the theme yourself and add it from a file."
    }

    /// Manage Disk, when the theme isn't in the list any more. Removing one is deliberate, so there is nothing to report.
    static func unknownTheme(name: String) -> String {
        "“\(name)” is no longer in Mactoy's theme list. Choose another theme."
    }

    /// A theme in My Themes that was removed while it was still the pick. Its id is an internal one, and it was never in
    /// Mactoy's theme list, so neither is said.
    static let savedThemeRemoved = "That theme is no longer in My Themes. Choose another theme."

    /// Under the Install tab's theme name, when the chosen catalog theme's download is known to be unavailable. Nil otherwise.
    static func installNote(for choice: ThemeChoice, unavailable: [String: ThemeUnavailable]) -> String? {
        guard case .catalog(let id) = choice, unavailable[id] != nil else { return nil }
        return "This theme's download isn't available right now. Choose another, or add it from a file."
    }

    /// For the end of "The boot theme wasn't added: ...", where the theme's own name is the subject.
    static func postInstallProblem(for reason: ThemeUnavailable.Reason, name: String) -> String {
        switch reason {
        case .gone: return "Mactoy couldn't find “\(name)” where its theme list says it should be."
        case .changed: return "“\(name)” has changed since it was added to Mactoy's theme list, so Mactoy didn't use it."
        }
    }

    static func postInstallUnknownTheme(name: String) -> String {
        "“\(name)” is no longer in Mactoy's theme list."
    }

    static let postInstallSavedThemeRemoved = "That theme is no longer in My Themes."

    /// What to tell the user about a failed change to `choice`. Only the theme's id is known to the
    /// error, so the theme's name is put in its place, and a theme of the user's own is told without
    /// either: it was never in Mactoy's theme list, and its id is not for people.
    static func message(for error: any Error, choice: ThemeChoice, themeName: String) -> String {
        if case ThemeError.unknownTheme = error {
            if case .custom = choice { return savedThemeRemoved }
            return unknownTheme(name: themeName)
        }
        return error.localizedDescription
    }

    /// How a fresh install's theme step ended when it threw `error` for `choice`, the theme called `name`.
    /// A theme that can't be used says so with its name, and the install message then points to
    /// another theme instead of trying again; any other failure is told as it is.
    static func postInstallResult(for error: any Error, choice: ThemeChoice, name: String) -> PostInstallThemeResult {
        if let reason = ThemeUnavailable.reason(of: error) {
            return .themeUnavailable(problem: postInstallProblem(for: reason, name: name))
        }
        if case ThemeError.unknownTheme = error {
            if case .custom = choice { return .themeUnavailable(problem: postInstallSavedThemeRemoved) }
            return .themeUnavailable(problem: postInstallUnknownTheme(name: name))
        }
        return .notApplied(problem: error.localizedDescription)
    }
}

/// The dialog for a catalog theme that can't be downloaded: which theme, and what is wrong with its download.
struct UnavailableAlert {
    let entry: ThemeEntry
    let problem: ThemeUnavailable
}

/// How a change to a drive's theme that threw is told in Manage Disk.
struct ThemeChangeFailure {
    /// The note under the section. Always there, whatever else is shown: a dialog asked for while another is
    /// still closing can be dropped, and then this is all the user would see.
    let message: String
    let isError: Bool
    /// The dialog that explains a download that is gone or changed, with the ways forward. Nil for any other failure.
    let alert: UnavailableAlert?

    /// `savedName` is the drive's old theme, when a copy of it was kept before the change failed. `catalog`
    /// and `unavailable` are the store's (`ThemeStore.catalog` and `unavailableThemes`), and `themeName` is what
    /// the store calls `choice`.
    init(error: any Error, choice: ThemeChoice, savedName: String?, themeName: String,
         catalog: [ThemeEntry], unavailable: [String: ThemeUnavailable]) {
        message = DriveThemeCopy.changeFailed(
            savedName: savedName, reason: ThemeUnavailableCopy.message(for: error, choice: choice, themeName: themeName))
        isError = true
        alert = Self.alert(for: error, choice: choice, catalog: catalog, unavailable: unavailable)
    }

    /// The dialog for `error`, when it says the download of the catalog theme in `choice` is gone or changed.
    /// What the store recorded for that download is used when it is there: it is about the download that failed,
    /// and the store drops it as soon as the list names another. Only without it is the entry the list has now asked.
    static func alert(for error: any Error, choice: ThemeChoice, catalog: [ThemeEntry],
                      unavailable: [String: ThemeUnavailable]) -> UnavailableAlert? {
        guard case .catalog(let id) = choice, ThemeUnavailable.reason(of: error) != nil,
              let entry = catalog.first(where: { $0.id == id }) else { return nil }
        if let recorded = unavailable[id], recorded.describes(entry) { return UnavailableAlert(entry: entry, problem: recorded) }
        return ThemeUnavailable(error: error, entry: entry).map { UnavailableAlert(entry: entry, problem: $0) }
    }
}
