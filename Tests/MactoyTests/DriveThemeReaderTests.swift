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

    @Test("the theme on the drive comes with the snapshot, ready to be kept")
    func driveThemeInSnapshot() throws {
        let v = try volume(json: #"{ "theme": { "file": "/ventoy/mytheme/theme.txt", "gfxmode": "1280x720" } }"#)
        try FileManager.default.createDirectory(at: v.appendingPathComponent("ventoy/mytheme"), withIntermediateDirectories: true)
        try Data([1]).write(to: v.appendingPathComponent("ventoy/mytheme/theme.txt"))
        let snapshot = DriveThemeReader.read(v)
        #expect(snapshot.current == .other(file: "/ventoy/mytheme/theme.txt"))
        #expect(snapshot.driveTheme?.name == "mytheme")
        #expect(snapshot.driveTheme?.settings == .init(file: "theme.txt", gfxmode: "1280x720"))
    }

    @Test("there is no theme to keep on a default drive, for settings only, or when the theme file is missing")
    func noDriveTheme() throws {
        #expect(DriveThemeReader.read(try volume()).driveTheme == nil)
        #expect(DriveThemeReader.read(try volume(json: #"{ "theme": { "gfxmode": "1280x720" } }"#)).driveTheme == nil)
        let missing = DriveThemeReader.read(try volume(json: #"{ "theme": { "file": "/ventoy/gone/theme.txt" } }"#))
        #expect(missing.current == .other(file: "/ventoy/gone/theme.txt"))
        #expect(missing.driveTheme == nil)
        #expect(DriveThemeReader.read(try volume(json: #"{ "theme": "#)).driveTheme == nil)
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

    @Test("a hand-edited setting that points into a folder Mactoy added says that folder will be removed")
    func mactoyFolderIsRemoved() {
        let file = "/ventoy/themes/mactoy-night/theme.txt"
        #expect(DriveThemeCopy.replaceMessage(file: file, toDefault: false)
            == "This drive uses a theme you set up yourself (\(file)). Mactoy will point the drive at the new theme instead. The theme folder Mactoy added (mactoy-night) will be removed. You can download or pick it again later.")
        #expect(DriveThemeCopy.replaceMessage(file: file, toDefault: true)
            == "This drive uses a theme you set up yourself (\(file)). Mactoy will switch the drive back to Ventoy's own theme. The theme folder Mactoy added (mactoy-night) will be removed. You can download or pick it again later.")
        // A theme file deeper in the folder, a folder named in other case, and the folder itself.
        for deeper in ["/ventoy/themes/mactoy-night/sub/theme.txt", "/Ventoy/Themes/mactoy-night/theme.txt", "/ventoy/themes/mactoy-night"] {
            let message = DriveThemeCopy.replaceMessage(file: deeper, toDefault: false)
            #expect(message.contains("The theme folder Mactoy added (mactoy-night) will be removed."), "\(deeper)")
            #expect(!message.contains("stay on the drive"), "\(deeper)")
        }
        #expect(DriveThemeCopy.mactoyFolder(of: file) == "mactoy-night")
    }

    @Test("a theme of the user's anywhere else keeps the 'files stay' wording")
    func otherFoldersKeepFilesStay() {
        for file in ["/ventoy/mine/theme.txt", "/ventoy/themes/mine/theme.txt", "/ventoy/mactoy-night/theme.txt",
                     "/ventoy/themes/xmactoy-night/theme.txt", "/ventoy/themes/mactoynight/theme.txt", "/mactoy-night/theme.txt",
                     "/ventoy/themes", "/ventoy/themes/", "/themes/mactoy-night/theme.txt", "mactoy-night"] {
            #expect(DriveThemeCopy.mactoyFolder(of: file) == nil, "\(file)")
            for toDefault in [true, false] {
                #expect(DriveThemeCopy.replaceMessage(file: file, toDefault: toDefault).hasSuffix("Your theme's files stay on the drive."), "\(file)")
            }
        }
        #expect(DriveThemeCopy.mactoyFolder(of: "") == nil)
    }

    @Test("settings with no theme file are described without a path")
    func noFile() {
        #expect(DriveThemeCopy.replaceMessage(file: "", toDefault: false)
            == "This drive has theme settings you set up yourself. Mactoy will replace them with the new theme.")
        #expect(DriveThemeCopy.replaceMessage(file: "", toDefault: true)
            == "This drive has theme settings you set up yourself. Mactoy will remove them and switch the drive back to Ventoy's own theme.")
        #expect(DriveThemeCopy.ownTheme(file: "") == "Your own theme settings")
        #expect(DriveThemeCopy.ownTheme(file: "/a/theme.txt") == "Your own theme (/a/theme.txt)")
    }

    @Test("the offer to keep a copy names the theme and says where it goes")
    func keepCopy() {
        #expect(DriveThemeCopy.keepCopyTitle == "Keep a copy of this drive's theme?")
        #expect(DriveThemeCopy.keepCopyMessage(name: "Mine")
            == "This drive uses “Mine”, which isn't in Mactoy's theme list. Save it to My Themes first so you can put it back later.")
        #expect(DriveThemeCopy.saveButton == "Save to My Themes")
        #expect(DriveThemeCopy.saved(name: "Mine") == "Saved “Mine” to My Themes.")
    }

    @Test("a failed save says the drive was left alone; a failed change says the copy is safe")
    func failures() {
        #expect(DriveThemeCopy.saveFailed("No space.") == "Couldn't save this drive's theme to My Themes, so the drive was left as it was. No space.")
        #expect(DriveThemeCopy.changeFailed(savedName: "Mine", reason: "Read-only.") == "Saved “Mine” to My Themes. The drive's theme wasn't changed: Read-only.")
        #expect(DriveThemeCopy.changeFailed(savedName: nil, reason: "Read-only.") == "Read-only.")
    }

    @Test("no wording uses an em-dash")
    func noEmDashes() {
        let all = [DriveThemeCopy.replaceTitle, DriveThemeCopy.keepCopyTitle, DriveThemeCopy.keepCopyMessage(name: "X"),
                   DriveThemeCopy.saveButton, DriveThemeCopy.saveHint, DriveThemeCopy.saved(name: "X"), DriveThemeCopy.saveFailed("x"),
                   DriveThemeCopy.changeFailed(savedName: "X", reason: "x"), DriveThemeCopy.success(removed: true), DriveThemeCopy.success(removed: false),
                   DriveThemeCopy.ownTheme(file: ""), DriveThemeCopy.ownTheme(file: "/a"), ThemeStoreError.nothingToSave.errorDescription ?? "",
                   ThemeStoreError.busy.errorDescription ?? ""]
            + [true, false].flatMap { [DriveThemeCopy.replaceMessage(file: "", toDefault: $0), DriveThemeCopy.replaceMessage(file: "/a", toDefault: $0),
                                       DriveThemeCopy.replaceMessage(file: "/ventoy/themes/mactoy-x/theme.txt", toDefault: $0)] }
        #expect(all.allSatisfy { !$0.contains("\u{2014}") })
    }

    @Test("removing says so, and nothing promises a backup")
    func success() {
        #expect(DriveThemeCopy.success(removed: true) == "Theme removed. The drive will show Ventoy's own menu next time you boot from it.")
        #expect(DriveThemeCopy.success(removed: false) == "Theme updated. It will show the next time you boot from this drive.")
        #expect(!DriveThemeCopy.replaceMessage(file: "/a", toDefault: false).contains("backup"))
    }
}
