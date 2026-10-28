import Foundation
import Testing
@testable import MactoyKit

/// How a failed theme download is told apart: gone, changed, or just not reachable.
@Suite("Theme download errors")
struct ThemeDownloadErrorTests {

    @Test("404 and 410 say the download is gone", arguments: [404, 410])
    func gone(status: Int) {
        #expect(URLSessionThemeTransport.themeError(forStatus: status, host: "github.com") == .downloadGone(host: "github.com", status: status))
    }

    @Test("200 is the only answer that carries a file")
    func ok() {
        #expect(URLSessionThemeTransport.themeError(forStatus: 200, host: "github.com") == nil)
    }

    @Test("403 and 429 say the server turned the download away for now, not that the connection is down", arguments: [403, 429])
    func refused(status: Int) {
        #expect(URLSessionThemeTransport.themeError(forStatus: status, host: "github.com") == .serverRefused(host: "github.com"))
        #expect(URLSessionThemeTransport.themeError(forStatus: status, host: "example.org") == .serverRefused(host: "example.org"))
    }

    @Test("any other answer is a server that can't be used right now", arguments: [500, 502, 503, 504, 401, 301, 304, 204, 400, 0])
    func unreachable(status: Int) {
        #expect(URLSessionThemeTransport.themeError(forStatus: status, host: "github.com") == .serverUnreachable(host: "github.com"))
    }

    @Test("every status maps to exactly one outcome: a file, gone, refused or unreachable")
    func statusTable() {
        let table: [(Int, ThemeError?)] = [
            (200, nil),
            (404, .downloadGone(host: "h", status: 404)), (410, .downloadGone(host: "h", status: 410)),
            (403, .serverRefused(host: "h")), (429, .serverRefused(host: "h")),
            (500, .serverUnreachable(host: "h")), (503, .serverUnreachable(host: "h")),
        ]
        for (status, expected) in table { #expect(URLSessionThemeTransport.themeError(forStatus: status, host: "h") == expected, "\(status)") }
    }

    @Test("a URLError for no connection or no answer is unreachable", arguments: [
        URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
        .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
    ])
    func noAnswer(code: URLError.Code) {
        #expect(URLSessionThemeTransport.themeError(for: URLError(code), host: "github.com") == .serverUnreachable(host: "github.com"))
    }

    @Test("other URLErrors stay as they are, so a cancelled download still looks cancelled", arguments: [
        URLError.Code.cancelled, .badURL, .secureConnectionFailed, .serverCertificateUntrusted, .cannotDecodeContentData, .unsupportedURL,
    ])
    func other(code: URLError.Code) {
        #expect(URLSessionThemeTransport.themeError(for: URLError(code), host: "github.com") == nil)
    }

    @Test("the host in a message is the one that was asked")
    func host() throws {
        #expect(URLSessionThemeTransport.hostName(of: try #require(URL(string: "https://github.com/a/b/x.zip"))) == "github.com")
        #expect(URLSessionThemeTransport.hostName(of: URL(fileURLWithPath: "/tmp/x.zip")) == "the server")
    }

    @Test("only a download that is gone or changed means the theme is unavailable")
    func meansThemeIsUnavailable() {
        let unavailable: [ThemeError] = [.downloadGone(host: "github.com", status: 404), .downloadGone(host: "github.com", status: 410),
                                         .checksumMismatch(expected: "a", actual: "b")]
        let available: [ThemeError] = [
            .serverUnreachable(host: "github.com"), .serverRefused(host: "github.com"), .looseThemeFile(folder: "Downloads"), .downloadTooLarge(1), .fileTooLarge(1), .unreadableArchive("x"), .rootNotFound("x"),
            .missingFile("x"), .themeTooLarge(1), .tooManyFiles(1), .noThemeFile, .ambiguousThemes(["x"]), .tooManyThemes(21),
            .unsupportedSource, .readOnlyVolume, .writeFailed("x"), .unknownTheme("x"), .destinationExists("x"), .unsafeVolumeLayout("x"),
        ]
        for error in unavailable { #expect(error.meansThemeIsUnavailable, "\(error)") }
        for error in available { #expect(!error.meansThemeIsUnavailable, "\(error)") }
    }

    @Test("the short messages say what is wrong and what to do, in plain words")
    func messages() {
        #expect(ThemeError.downloadGone(host: "github.com", status: 404).errorDescription
            == "The theme's download isn't where Mactoy's theme list says it should be.")
        #expect(ThemeError.checksumMismatch(expected: "a", actual: "b").errorDescription
            == "The theme's download has changed since it was added to Mactoy's theme list, so it wasn't used.")
        #expect(ThemeError.serverUnreachable(host: "github.com").errorDescription
            == "Couldn't reach github.com. Check your internet connection and try again.")
        #expect(ThemeError.serverRefused(host: "github.com").errorDescription
            == "github.com turned the download away for now. Try again in a while.")
        #expect(ThemeError.looseThemeFile(folder: "Downloads").errorDescription
            == "That theme.txt is loose in Downloads. Put the theme's files in their own folder, then choose that folder.")
        #expect(ThemeError.unknownTheme("tela").errorDescription == "“tela” is no longer in Mactoy's theme list. Choose another theme.")
        let all: [ThemeError] = [.downloadGone(host: "h", status: 410), .checksumMismatch(expected: "a", actual: "b"),
                                 .serverUnreachable(host: "h"), .serverRefused(host: "h"), .looseThemeFile(folder: "Desktop"),
                                 .unknownTheme("x"), .tooManyThemes(21), .unsupportedSource,
                                 .ambiguousThemes(["a/theme.txt", "b/theme.txt"])]
        for error in all {
            let text = error.errorDescription ?? ""
            #expect(!text.contains("\u{2014}"), "no em-dash in \(text)")
            #expect(!text.contains("Network error"), "\(text)")
        }
    }

    @Test("the network error other code throws is unchanged")
    func driverErrorStays() {
        #expect(DriverError.network("github.com returned 404").description == "Network error: github.com returned 404")
    }
}
