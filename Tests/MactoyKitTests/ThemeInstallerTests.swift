import Foundation
import Testing
@testable import MactoyKit

@Suite("Theme installer")
struct ThemeInstallerTests {

    private func volume(json: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-vol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let json {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("ventoy"), withIntermediateDirectories: true)
            try Data(json.utf8).write(to: root.appendingPathComponent("ventoy/ventoy.json"))
        }
        return root
    }

    private func themeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("icons"), withIntermediateDirectories: true)
        try Data("desktop-image: \"bg.png\"\n".utf8).write(to: dir.appendingPathComponent("theme.txt"))
        try Data([1]).write(to: dir.appendingPathComponent("bg.png"))
        try Data([2]).write(to: dir.appendingPathComponent("font.pf2"))
        try Data([3]).write(to: dir.appendingPathComponent("icons/a.png"))
        try Data().write(to: dir.appendingPathComponent(".complete"))
        return dir
    }

    private let settings = ThemeEntry.Settings(file: "theme.txt", fonts: ["font.pf2"])
    private func json(_ v: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: v.appendingPathComponent("ventoy/ventoy.json"))) as! [String: Any]
    }
    private func exists(_ v: URL, _ p: String) -> Bool { FileManager.default.fileExists(atPath: v.appendingPathComponent(p).path) }
    private func listing(_ v: URL, _ p: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: v.appendingPathComponent(p).path)) ?? []).sorted()
    }
    private func text(_ v: URL, _ p: String) throws -> String {
        try String(contentsOf: v.appendingPathComponent(p), encoding: .utf8)
    }

    @Test("fresh volume gets the folder, marker and settings")
    func fresh() throws {
        let v = try volume()
        let outcome = try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "sample", name: "Sample", settings: settings, to: v, isReadOnly: { _ in false })
        #expect(exists(v, "ventoy/themes/mactoy-sample/theme.txt"))
        #expect(exists(v, "ventoy/themes/mactoy-sample/icons/a.png"))
        #expect(exists(v, "ventoy/themes/mactoy-sample/.mactoy-theme.json"))
        #expect(!exists(v, "ventoy/themes/mactoy-sample/.complete"))
        let theme = try json(v)["theme"] as! [String: Any]
        #expect(theme["file"] as? String == "/ventoy/themes/mactoy-sample/theme.txt")
        #expect(theme["fonts"] as? [String] == ["/ventoy/themes/mactoy-sample/font.pf2"])
        #expect(theme["gfxmode"] as? String == "1920x1080,auto")
        #expect(try ThemeInstaller.current(on: v) == .managed(id: "sample", name: "Sample"))
        #expect(outcome.warnings.isEmpty)
    }

    @Test("existing settings are kept byte for byte, with a backup")
    func keepsExisting() throws {
        let original = #"{ "control": [ {"VTOY_DEFAULT_SEARCH_ROOT":"/iso"} ], "menu_alias": [] }"#
        let v = try volume(json: original)
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "sample", name: "Sample", settings: settings, to: v, isReadOnly: { _ in false })
        let text = try String(contentsOf: v.appendingPathComponent("ventoy/ventoy.json"), encoding: .utf8)
        #expect(text.hasPrefix(#"{ "control": [ {"VTOY_DEFAULT_SEARCH_ROOT":"/iso"} ], "menu_alias": []"#))
        #expect(try String(contentsOf: v.appendingPathComponent("ventoy/ventoy.json.mactoy-backup"), encoding: .utf8) == original)
    }

    @Test("nothing but the folder, config and backup is left behind")
    func noLeftovers() throws {
        let v = try volume(json: #"{"control":[]}"#)
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "sample", name: "Sample", settings: settings, to: v, isReadOnly: { _ in false })
        #expect(listing(v, "ventoy") == ["themes", "ventoy.json", "ventoy.json.mactoy-backup"])
        #expect(listing(v, "ventoy/themes") == ["mactoy-sample"])
    }

    @Test("switching removes only Mactoy's previous folder")
    func switching() throws {
        let v = try volume()
        try FileManager.default.createDirectory(at: v.appendingPathComponent("ventoy/themes/mine"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: v.appendingPathComponent("ventoy/themes/mactoy-handmade"), withIntermediateDirectories: true)
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "alpha", name: "A", settings: settings, to: v, isReadOnly: { _ in false })
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "bravo", name: "B", settings: settings, to: v, isReadOnly: { _ in false })
        #expect(!exists(v, "ventoy/themes/mactoy-alpha"))
        #expect(exists(v, "ventoy/themes/mactoy-bravo/theme.txt"))
        #expect(exists(v, "ventoy/themes/mine"))
        #expect(exists(v, "ventoy/themes/mactoy-handmade"), "no marker, so not ours")
    }

    @Test("applying the same theme again replaces its folder")
    func reapply() throws {
        let v = try volume()
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "sample", name: "Old", settings: settings, to: v, isReadOnly: { _ in false })
        let second = try themeFolder()
        try FileManager.default.removeItem(at: second.appendingPathComponent("icons"))
        try Data([9]).write(to: second.appendingPathComponent("new.png"))
        try ThemeInstaller.apply(themeDirectory: second, id: "sample", name: "New", settings: settings, to: v, isReadOnly: { _ in false })
        #expect(exists(v, "ventoy/themes/mactoy-sample/new.png"))
        #expect(!exists(v, "ventoy/themes/mactoy-sample/icons/a.png"))
        #expect(try ThemeInstaller.current(on: v) == .managed(id: "sample", name: "New"))
        #expect(listing(v, "ventoy/themes") == ["mactoy-sample"])
    }

    @Test("a mactoy- folder without a marker is never replaced")
    func unmarkedDestination() throws {
        let original = #"{"control":[]}"#
        let v = try volume(json: original)
        let theirs = v.appendingPathComponent("ventoy/themes/mactoy-sample")
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: theirs.appendingPathComponent("notes.txt"))
        #expect(throws: ThemeError.destinationExists(theirs.path)) {
            try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "sample", name: "Sample", settings: settings, to: v, isReadOnly: { _ in false })
        }
        #expect(try text(v, "ventoy/themes/mactoy-sample/notes.txt") == "keep")
        #expect(try text(v, "ventoy/ventoy.json") == original)
        #expect(!exists(v, "ventoy/ventoy.json.mactoy-backup"))
        #expect(listing(v, "ventoy/themes") == ["mactoy-sample"])
    }

    @Test("remove returns to Ventoy's default")
    func remove() throws {
        let v = try volume(json: #"{"control":[]}"#)
        try FileManager.default.createDirectory(at: v.appendingPathComponent("ventoy/themes/mine"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: v.appendingPathComponent("ventoy/themes/mactoy-handmade"), withIntermediateDirectories: true)
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "alpha", name: "A", settings: settings, to: v, isReadOnly: { _ in false })
        try ThemeInstaller.removeTheme(from: v, isReadOnly: { _ in false })
        #expect(try json(v)["theme"] == nil)
        #expect(try json(v)["control"] != nil)
        #expect(!exists(v, "ventoy/themes/mactoy-alpha"))
        #expect(exists(v, "ventoy/themes/mine"))
        #expect(exists(v, "ventoy/themes/mactoy-handmade"), "no marker, so not ours")
        #expect(try ThemeInstaller.current(on: v) == .ventoyDefault)
    }

    @Test("remove on a drive with no settings does nothing")
    func removeNothing() throws {
        let v = try volume()
        try ThemeInstaller.removeTheme(from: v, isReadOnly: { _ in false })
        #expect(!exists(v, "ventoy"))
    }

    @Test("a refused ventoy.json stops remove before any folder is deleted")
    func refusedRemove() throws {
        let v = try volume()
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "alpha", name: "A", settings: settings, to: v, isReadOnly: { _ in false })
        try Data(#"{"menu_alias":[{"image":"\/a.iso","alias":"x"}]}"#.utf8).write(to: v.appendingPathComponent("ventoy/ventoy.json"))
        #expect(throws: VentoyConfigEditor.Refusal.containsBackslash) {
            try ThemeInstaller.removeTheme(from: v, isReadOnly: { _ in false })
        }
        #expect(exists(v, "ventoy/themes/mactoy-alpha/theme.txt"))
    }

    @Test("current is the default when there is no ventoy.json")
    func currentDefault() throws {
        #expect(try ThemeInstaller.current(on: volume()) == .ventoyDefault)
    }

    @Test("someone else's theme is reported as other")
    func other() throws {
        let v = try volume(json: #"{"theme":{"file":"/ventoy/mytheme/theme.txt"}}"#)
        #expect(try ThemeInstaller.current(on: v) == .other(file: "/ventoy/mytheme/theme.txt"))
    }

    @Test("a mactoy- path without a marker is reported as other")
    func unmarkedIsOther() throws {
        let v = try volume(json: #"{"theme":{"file":"/ventoy/themes/mactoy-x/theme.txt"}}"#)
        try FileManager.default.createDirectory(at: v.appendingPathComponent("ventoy/themes/mactoy-x"), withIntermediateDirectories: true)
        #expect(try ThemeInstaller.current(on: v) == .other(file: "/ventoy/themes/mactoy-x/theme.txt"))
    }

    @Test("a refused ventoy.json changes nothing on the drive")
    func refusedLeavesDriveAlone() throws {
        let v = try volume(json: #"{"menu_alias":[{"image":"\/a.iso","alias":"x"}]}"#)
        #expect(throws: VentoyConfigEditor.Refusal.containsBackslash) {
            try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "alpha", name: "A", settings: settings, to: v, isReadOnly: { _ in false })
        }
        #expect(!exists(v, "ventoy/themes"))
    }

    @Test("settings the editor can't write change nothing on the drive")
    func unwritableSettingsLeaveDriveAlone() throws {
        // No ventoy.json to parse, so only building the new `theme` can refuse this.
        let v = try volume()
        let bad = ThemeEntry.Settings(file: "theme.txt", fonts: ["font.pf2"], gfxmode: "1920x1080\\,auto")
        #expect(throws: VentoyConfigEditor.Refusal.containsBackslash) {
            try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "alpha", name: "A", settings: bad, to: v, isReadOnly: { _ in false })
        }
        #expect(!exists(v, "ventoy"))
    }

    @Test("a failed copy leaves ventoy.json alone")
    func failedCopyLeavesConfig() throws {
        let original = #"{"control":[]}"#
        let v = try volume(json: original)
        let themes = v.appendingPathComponent("ventoy/themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        // Not writable, so the copy can't start; the settings must not have moved ahead of it.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: themes.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: themes.path) }
        #expect(throws: (any Error).self) {
            try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "alpha", name: "A", settings: settings, to: v, isReadOnly: { _ in false })
        }
        #expect(try text(v, "ventoy/ventoy.json") == original)
        #expect(!exists(v, "ventoy/ventoy.json.mactoy-backup"))
    }

    @Test("a theme missing its files is refused before anything is written")
    func missingThemeFile() throws {
        let v = try volume()
        let source = try themeFolder()
        try FileManager.default.removeItem(at: source.appendingPathComponent("font.pf2"))
        #expect(throws: ThemeError.missingFile("font.pf2")) {
            try ThemeInstaller.apply(themeDirectory: source, id: "alpha", name: "A", settings: settings, to: v, isReadOnly: { _ in false })
        }
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-src-\(UUID().uuidString)")
        #expect(throws: ThemeError.missingFile("theme.txt")) {
            try ThemeInstaller.apply(themeDirectory: gone, id: "alpha", name: "A", settings: settings, to: v, isReadOnly: { _ in false })
        }
        #expect(!exists(v, "ventoy"))
    }

    @Test("read-only volumes are refused")
    func readOnly() throws {
        let v = try volume()
        #expect(throws: ThemeError.readOnlyVolume) {
            try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "alpha", name: "A", settings: settings, to: v, isReadOnly: { _ in true })
        }
        #expect(throws: ThemeError.readOnlyVolume) {
            try ThemeInstaller.removeTheme(from: v, isReadOnly: { _ in true })
        }
        #expect(!exists(v, "ventoy"))
    }

    @Test("ids that could leave the themes folder are refused before anything is written",
          arguments: ["", "a", "../evil", "ab/cd", "ab/../cd", "Ab", "-ab", "ab cd", "ab\n", "ab\r\n", "ab.c",
                      "ab\\cd", "\u{E9}a", "a\u{301}b", "ab\u{200D}", String(repeating: "a", count: 61)])
    func badIDs(id: String) throws {
        let v = try volume()
        #expect(throws: ThemeError.unknownTheme(id)) {
            try ThemeInstaller.apply(themeDirectory: themeFolder(), id: id, name: "X", settings: settings, to: v, isReadOnly: { _ in false })
        }
        #expect(!exists(v, "ventoy"))
    }

    @Test("catalog and custom ids are accepted")
    func goodIDs() {
        for id in ["ab", "0a", "catppuccin-mocha", "custom-my-theme-2", String(repeating: "a", count: 60)] {
            #expect(ThemeInstaller.isValidID(id), "\(id)")
        }
    }

    @Test("hidden files and extended attributes are not copied")
    func copiesBytesOnly() throws {
        let v = try volume()
        let source = try themeFolder()
        try Data([4]).write(to: source.appendingPathComponent("icons/.DS_Store"))
        try Data([5]).write(to: source.appendingPathComponent("._bg.png"))
        let bg = source.appendingPathComponent("bg.png")
        try #require(setxattr(bg.path, "com.mactoy.test", "x", 1, 0, 0) == 0, "couldn't set the test attribute")
        try ThemeInstaller.apply(themeDirectory: source, id: "sample", name: "Sample", settings: settings, to: v, isReadOnly: { _ in false })
        #expect(listing(v, "ventoy/themes/mactoy-sample").contains(".complete") == false)
        #expect(!exists(v, "ventoy/themes/mactoy-sample/icons/.DS_Store"))
        #expect(!exists(v, "ventoy/themes/mactoy-sample/._bg.png"))
        let copied = v.appendingPathComponent("ventoy/themes/mactoy-sample/bg.png").path
        #expect(try Data(contentsOf: URL(fileURLWithPath: copied)) == Data([1]))
        #expect(getxattr(copied, "com.mactoy.test", nil, 0, 0, 0) == -1)
    }

    @Test("the marker keeps the name as given")
    func markerName() throws {
        let v = try volume()
        let name = "Cat \u{201C}Mocha\u{201D} / v2"
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "sample", name: name, settings: settings, to: v, isReadOnly: { _ in false })
        #expect(try ThemeInstaller.current(on: v) == .managed(id: "sample", name: name))
    }

    @Test("settings value carries every field, and only those set")
    func settingsValue() {
        let full = ThemeEntry.Settings(file: "theme.txt", fonts: ["a.pf2", "sub/b.pf2"], gfxmode: "1024x768",
                                       ventoyLeft: "5%", ventoyTop: "100%-19", ventoyColor: "#89b4fa")
        let value = ThemeInstaller.settingsValue(full, folder: "mactoy-x")
        #expect(value["file"] as? String == "/ventoy/themes/mactoy-x/theme.txt")
        #expect(value["fonts"] as? [String] == ["/ventoy/themes/mactoy-x/a.pf2", "/ventoy/themes/mactoy-x/sub/b.pf2"])
        #expect(value["gfxmode"] as? String == "1024x768")
        #expect(value["ventoy_left"] as? String == "5%")
        #expect(value["ventoy_top"] as? String == "100%-19")
        #expect(value["ventoy_color"] as? String == "#89b4fa")
        let bare = ThemeInstaller.settingsValue(.init(file: "theme.txt", fonts: []), folder: "mactoy-x")
        #expect(Set(bare.keys) == ["file", "gfxmode"])
    }

    @Test("warns about per-mode themes")
    func warnings() throws {
        let v = try volume(json: #"{"theme_uefi":{"file":"/ventoy/u/theme.txt"}}"#)
        let outcome = try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "alpha", name: "A", settings: settings, to: v, isReadOnly: { _ in false })
        #expect(outcome.warnings.count == 1)
        #expect(outcome.warnings[0].contains("UEFI"))
    }

    @Test("names every per-mode key, on apply and on remove")
    func manyWarnings() throws {
        let v = try volume(json: #"{"theme_legacy":{},"theme_uefi":{},"theme_mips":{}}"#)
        let applied = try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "alpha", name: "A", settings: settings, to: v, isReadOnly: { _ in false })
        #expect(applied.warnings.count == 3)
        #expect(applied.warnings.contains { $0.contains("theme_legacy") && $0.contains("Legacy BIOS") })
        #expect(applied.warnings.contains { $0.contains("theme_mips") })
        let removed = try ThemeInstaller.removeTheme(from: v, isReadOnly: { _ in false })
        #expect(removed.warnings.count == 3)
    }

    @Test("warns when the settings folder isn't lowercase")
    func caseWarning() throws {
        let v = try volume()
        try FileManager.default.createDirectory(at: v.appendingPathComponent("Ventoy"), withIntermediateDirectories: true)
        let outcome = try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "alpha", name: "A", settings: settings, to: v, isReadOnly: { _ in false })
        #expect(outcome.warnings.count == 1)
        #expect(outcome.warnings[0].contains("\"Ventoy\""))
    }
}
