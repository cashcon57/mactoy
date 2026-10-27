import Testing
import Foundation
@testable import Mactoy
import MactoyKit

/// What the Manage Disk theme section learns from a drive.
@Suite("Drive theme reader")
struct DriveThemeReaderTests {

    private func volume(json: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ventoy"), withIntermediateDirectories: true)
        if let json { try Data(json.utf8).write(to: root.appendingPathComponent("ventoy/ventoy.json")) }
        return root
    }

    @Test("no ventoy.json means the Ventoy default")
    func noConfig() throws {
        let snapshot = DriveThemeReader.read(try volume())
        #expect(snapshot.current == .ventoyDefault)
        #expect(snapshot.error == nil)
        #expect(!snapshot.readOnly)
    }

    @Test("a theme the user set up is reported as theirs, with its path")
    func ownTheme() throws {
        let snapshot = DriveThemeReader.read(try volume(json: #"{ "theme": { "file": "/ventoy/themes/mine/theme.txt" } }"#))
        #expect(snapshot.current == .other(file: "/ventoy/themes/mine/theme.txt"))
    }

    @Test("a theme setting with no file is the user's, not the Ventoy default")
    func settingsWithoutFile() throws {
        let snapshot = DriveThemeReader.read(try volume(json: #"{ "theme": { "gfxmode": "1280x720" } }"#))
        #expect(snapshot.current == .other(file: ""))
        #expect(snapshot.error == nil)
    }

    @Test("a damaged ventoy.json is an error, not the Ventoy default")
    func damagedConfig() throws {
        let snapshot = DriveThemeReader.read(try volume(json: #"{ "theme": "#))
        #expect(snapshot.current == nil)
        #expect(snapshot.error != nil)
    }
}

/// The section's wording.
@Suite("Drive theme copy")
struct DriveThemeCopyTests {

    @Test("the confirmation names the user's theme file, and what happens to it")
    func replaceMessages() {
        #expect(DriveThemeCopy.replaceMessage(file: "/ventoy/mine/theme.txt", toDefault: false)
            == "This drive uses a theme you set up yourself (/ventoy/mine/theme.txt). Mactoy will point the drive at the new theme instead. Your theme's files stay on the drive.")
        #expect(DriveThemeCopy.replaceMessage(file: "/ventoy/mine/theme.txt", toDefault: true)
            == "This drive uses a theme you set up yourself (/ventoy/mine/theme.txt). Mactoy will switch the drive back to Ventoy's own theme. Your theme's files stay on the drive.")
    }

    @Test("settings with no theme file are described without a path")
    func noFile() {
        #expect(DriveThemeCopy.replaceMessage(file: "", toDefault: false).hasPrefix("This drive has theme settings you set up yourself. Mactoy will point"))
        #expect(DriveThemeCopy.replaceMessage(file: "", toDefault: true).hasPrefix("This drive has theme settings you set up yourself. Mactoy will switch"))
        #expect(DriveThemeCopy.ownTheme(file: "") == "Your own theme settings")
        #expect(DriveThemeCopy.ownTheme(file: "/a/theme.txt") == "Your own theme (/a/theme.txt)")
    }

    @Test("removing says so, and nothing promises a backup")
    func success() {
        #expect(DriveThemeCopy.success(removed: true) == "Theme removed. The drive will show Ventoy's own menu next time you boot from it.")
        #expect(DriveThemeCopy.success(removed: false) == "Theme updated. It will show the next time you boot from this drive.")
        #expect(!DriveThemeCopy.replaceMessage(file: "/a", toDefault: false).contains("backup"))
    }
}
