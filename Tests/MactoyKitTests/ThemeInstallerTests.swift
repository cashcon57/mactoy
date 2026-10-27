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
        #expect(!exists(v, "ventoy/ventoy.json.mactoy-backup"), "nothing to back up")
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

    @Test("the backup stays the user's first file through later changes")
    func backupKeepsFirst() throws {
        let original = #"{ "control": [ {"VTOY_DEFAULT_SEARCH_ROOT":"/iso"} ] }"#
        let v = try volume(json: original)
        let backup = "ventoy/ventoy.json.mactoy-backup"
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "alpha", name: "A", settings: settings, to: v, isReadOnly: { _ in false })
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "bravo", name: "B", settings: settings, to: v, isReadOnly: { _ in false })
        #expect(try text(v, backup) == original)
        try ThemeInstaller.removeTheme(from: v, isReadOnly: { _ in false })
        #expect(try text(v, backup) == original)
        #expect(try json(v)["theme"] == nil)
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

    @Test("a failed reapply leaves the installed theme in place", arguments: [false, true])
    func failedReapply(failAside: Bool) throws {
        let v = try volume()
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "sample", name: "Old", settings: settings, to: v, isReadOnly: { _ in false })
        let config = try text(v, "ventoy/ventoy.json")
        let second = try themeFolder()
        try Data([9]).write(to: second.appendingPathComponent("bg.png"))
        // Fails either the move that sets the old folder aside or the one that puts the new folder in.
        #expect(throws: InjectedFailure.self) {
            try ThemeInstaller.install(themeDirectory: second, id: "sample", name: "New", settings: settings, to: v,
                                       isReadOnly: { _ in false }, move: { from, to in
                let name = from.lastPathComponent
                if failAside ? name == "mactoy-sample" : name.hasPrefix(".mactoy-staging-") { throw InjectedFailure() }
                try FileManager.default.moveItem(at: from, to: to)
            })
        }
        #expect(try text(v, "ventoy/ventoy.json") == config)
        #expect(try Data(contentsOf: v.appendingPathComponent("ventoy/themes/mactoy-sample/bg.png")) == Data([1]))
        #expect(exists(v, "ventoy/themes/mactoy-sample/theme.txt"))
        #expect(try ThemeInstaller.current(on: v) == .managed(id: "sample", name: "Old"))
        #expect(listing(v, "ventoy/themes") == ["mactoy-sample"], "no staging or old copy left behind")
    }

    @Test("only theme file types reach the drive")
    func onlyAllowedFiles() throws {
        let v = try volume()
        let source = try themeFolder()
        for name in ["ventoy_grub.cfg", "run.sh", "NOTES", "logo.svg", "icons/x.cfg"] {
            try Data("x".utf8).write(to: source.appendingPathComponent(name))
        }
        try Data([7]).write(to: source.appendingPathComponent("Extra.PNG"))
        try ThemeInstaller.apply(themeDirectory: source, id: "sample", name: "Sample", settings: settings, to: v, isReadOnly: { _ in false })
        let base = v.appendingPathComponent("ventoy/themes/mactoy-sample")
        let found = (FileManager.default.enumerator(atPath: base.path)?.allObjects as? [String] ?? [])
            .filter { !$0.hasSuffix("icons") }.sorted()
        #expect(found == [".mactoy-theme.json", "Extra.PNG", "bg.png", "font.pf2", "icons/a.png", "theme.txt"])
    }

    @Test("a theme over the file or size limit is refused before anything is written")
    func caps() throws {
        let v = try volume()
        let many = try themeFolder()
        defer { try? FileManager.default.removeItem(at: many) }
        for i in 0..<ThemeAssembler.maxFiles { try Data([0]).write(to: many.appendingPathComponent("n\(i).png")) }
        #expect(throws: ThemeError.tooManyFiles(ThemeAssembler.maxFiles + 4)) {
            try ThemeInstaller.apply(themeDirectory: many, id: "sample", name: "S", settings: settings, to: v, isReadOnly: { _ in false })
        }
        let big = try themeFolder()
        defer { try? FileManager.default.removeItem(at: big) }
        try Data(count: ThemeAssembler.maxThemeBytes + 1).write(to: big.appendingPathComponent("big.png"))
        #expect { try ThemeInstaller.apply(themeDirectory: big, id: "sample", name: "S", settings: settings, to: v, isReadOnly: { _ in false }) }
            throws: { if case ThemeError.themeTooLarge = $0 { return true } else { return false } }
        #expect(!exists(v, "ventoy"))
    }

    @Test("files that are dropped don't count toward the limits")
    func droppedFilesDontCount() throws {
        let v = try volume()
        let source = try themeFolder()
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(count: ThemeAssembler.maxThemeBytes + 1).write(to: source.appendingPathComponent("payload.cfg"))
        try ThemeInstaller.apply(themeDirectory: source, id: "sample", name: "S", settings: settings, to: v, isReadOnly: { _ in false })
        #expect(!exists(v, "ventoy/themes/mactoy-sample/payload.cfg"))
        #expect(exists(v, "ventoy/themes/mactoy-sample/theme.txt"))
    }

    @Test("leftover staging and old folders are cleaned up, other hidden folders are not")
    func leftovers() throws {
        let v = try volume()
        let themes = v.appendingPathComponent("ventoy/themes")
        let stale = [".mactoy-staging-\(UUID().uuidString)", ".mactoy-old-\(UUID().uuidString)"]
        let keep = [".mactoy-staging-mine", ".mactoy-old-"]
        for name in stale + keep {
            try FileManager.default.createDirectory(at: themes.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "sample", name: "S", settings: settings, to: v, isReadOnly: { _ in false })
        #expect(listing(v, "ventoy/themes") == (keep + ["mactoy-sample"]).sorted())
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

    @Test("a theme setting that names no theme file is the user's, not the default",
          arguments: [#"{"theme":{"gfxmode":"1280x720"}}"#, #"{"theme":{"display_mode":"CLI"}}"#, #"{"theme":{}}"#,
                      #"{"theme":null}"#, #"{"theme":"x"}"#, #"{"theme":{"file":5}}"#])
    func themeWithoutFileIsOther(json: String) throws {
        #expect(try ThemeInstaller.current(on: volume(json: json)) == .other(file: ""))
    }

    @Test("settings with no theme member are still the default")
    func noThemeMemberIsDefault() throws {
        #expect(try ThemeInstaller.current(on: volume(json: #"{"control":[{"theme":{"file":"/inner"}}],"menu_alias":[]}"#)) == .ventoyDefault)
        #expect(try ThemeInstaller.current(on: volume(json: "{}")) == .ventoyDefault)
    }

    @Test("a theme setting with no file is replaced by apply and deleted by remove, like any other")
    func fileLessThemeCanBeChanged() throws {
        let v = try volume(json: #"{"control":[],"theme":{"gfxmode":"1280x720"}}"#)
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "sample", name: "Sample", settings: settings, to: v, isReadOnly: { _ in false })
        #expect(try ThemeInstaller.current(on: v) == .managed(id: "sample", name: "Sample"))
        try ThemeInstaller.removeTheme(from: v, isReadOnly: { _ in false })
        #expect(try ThemeInstaller.current(on: v) == .ventoyDefault)
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

    /// Where on a drive a link could send Mactoy's writes.
    enum Link: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case ventoy, themes, config, backup, temp, destination
        var testDescription: String { rawValue }
        var path: String {
            switch self {
            case .ventoy: return "ventoy"
            case .themes: return "ventoy/themes"
            case .config: return "ventoy/ventoy.json"
            case .backup: return "ventoy/ventoy.json.mactoy-backup"
            case .temp: return "ventoy/.ventoy.json.mactoy-tmp"
            case .destination: return "ventoy/themes/mactoy-sample"
            }
        }
    }

    /// A volume where `kind` is a symlink to a folder (or file) outside it.
    private func linkedVolume(_ kind: Link) throws -> (volume: URL, elsewhere: URL) {
        let fm = FileManager.default
        let v = try volume()
        let elsewhere = fm.temporaryDirectory.appendingPathComponent("mactoy-away-\(UUID().uuidString)")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data(#"{"control":[]}"#.utf8).write(to: elsewhere.appendingPathComponent("keep.json"))
        try Data(#"{"id":"sample","name":"Theirs"}"#.utf8).write(to: elsewhere.appendingPathComponent(".mactoy-theme.json"))
        let ventoy = v.appendingPathComponent("ventoy")
        let config = Data(#"{"control":[]}"#.utf8)
        func symlink(_ path: String, to target: URL) throws {
            try fm.createSymbolicLink(at: v.appendingPathComponent(path), withDestinationURL: target)
        }
        switch kind {
        case .ventoy:
            try symlink("ventoy", to: elsewhere)
        case .themes:
            try fm.createDirectory(at: ventoy, withIntermediateDirectories: true)
            try config.write(to: ventoy.appendingPathComponent("ventoy.json"))
            try symlink("ventoy/themes", to: elsewhere)
        case .config:
            try fm.createDirectory(at: ventoy, withIntermediateDirectories: true)
            try symlink("ventoy/ventoy.json", to: elsewhere.appendingPathComponent("keep.json"))
        case .backup, .temp:
            try fm.createDirectory(at: ventoy, withIntermediateDirectories: true)
            try config.write(to: ventoy.appendingPathComponent("ventoy.json"))
            try symlink(kind == .backup ? "ventoy/ventoy.json.mactoy-backup" : "ventoy/.ventoy.json.mactoy-tmp",
                        to: elsewhere.appendingPathComponent("keep.json"))
        case .destination:
            try fm.createDirectory(at: ventoy.appendingPathComponent("themes"), withIntermediateDirectories: true)
            try config.write(to: ventoy.appendingPathComponent("ventoy.json"))
            try symlink("ventoy/themes/mactoy-sample", to: elsewhere)
        }
        return (v, elsewhere)
    }

    /// Every file under `dir` with its bytes, plus the folders, to compare before and after.
    private func snapshot(_ dir: URL) throws -> [String: Data?] {
        var out: [String: Data?] = [:]
        for case let path as String in FileManager.default.enumerator(atPath: dir.path)! {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path, isDirectory: &isDir)
            out[path] = isDir.boolValue ? nil : try Data(contentsOf: dir.appendingPathComponent(path))
        }
        return out
    }

    @Test("a link to somewhere else is never written through", arguments: Link.allCases)
    func applyRefusesLinks(link: Link) throws {
        let (v, away) = try linkedVolume(link)
        let before = try snapshot(away)
        #expect(throws: ThemeError.unsafeVolumeLayout(link.path)) {
            try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "sample", name: "S", settings: settings, to: v, isReadOnly: { _ in false })
        }
        #expect(try snapshot(away) == before)
    }

    @Test("remove doesn't follow a link either", arguments: Link.allCases.filter { $0 != .destination })
    func removeRefusesLinks(link: Link) throws {
        let (v, away) = try linkedVolume(link)
        let before = try snapshot(away)
        #expect(throws: ThemeError.unsafeVolumeLayout(link.path)) {
            try ThemeInstaller.removeTheme(from: v, isReadOnly: { _ in false })
        }
        #expect(try snapshot(away) == before)
    }

    @Test("a linked mactoy- folder is left alone by remove and switching")
    func linkedFolderSurvives() throws {
        let (v, away) = try linkedVolume(.destination)
        let before = try snapshot(away)
        let link = v.appendingPathComponent(Link.destination.path).path
        try ThemeInstaller.removeTheme(from: v, isReadOnly: { _ in false })
        #expect(try snapshot(away) == before)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) != nil, "the link itself stays")
        // Applying another theme sweeps old managed folders; the link is skipped too.
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "bravo", name: "B", settings: settings, to: v, isReadOnly: { _ in false })
        #expect(try snapshot(away) == before)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) != nil, "the link itself stays")
        #expect(exists(v, "ventoy/themes/mactoy-bravo/theme.txt"))
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

    // MARK: driveTheme

    /// A volume whose ventoy.json is `json`, with each of `files` present (one byte each).
    private func volume(json: String?, files: [String]) throws -> URL {
        let v = try volume(json: json)
        for path in files {
            let url = v.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: url)
        }
        return v
    }

    private func samePath(_ a: URL, _ b: URL) -> Bool { a.standardizedFileURL.path == b.standardizedFileURL.path }

    @Test("a theme the user set up is found, with the fonts inside its folder and nothing else")
    func driveHandTheme() throws {
        let v = try volume(json: #"""
            {"control":[],"theme":{"file":"/ventoy/mytheme/theme.txt",
             "fonts":["/ventoy/mytheme/fonts/f.pf2","/ventoy/other/o.pf2","/ventoy/mytheme/../o2.pf2","/ventoy/MYTHEME/g.pf2"],
             "gfxmode":"1280x720","ventoy_left":"5%","ventoy_top":"10%","ventoy_color":"#112233","display_mode":"CLI"}}
            """#, files: ["ventoy/mytheme/theme.txt"])
        let theme = try #require(try ThemeInstaller.driveTheme(on: v))
        #expect(samePath(theme.folder, v.appendingPathComponent("ventoy/mytheme")))
        #expect(theme.name == "mytheme")
        #expect(theme.managedID == nil)
        // FAT paths ignore case, so MYTHEME is the same folder; ".." and other folders are not inside it.
        #expect(theme.settings == .init(file: "theme.txt", fonts: ["fonts/f.pf2", "g.pf2"], gfxmode: "1280x720",
                                        ventoyLeft: "5%", ventoyTop: "10%", ventoyColor: "#112233"))
    }

    @Test("fonts given as a single string, and values that aren't strings, are handled")
    func driveOddValues() throws {
        let v = try volume(json: ##"{"theme":{"file":"/ventoy/t/theme.txt","fonts":"/ventoy/t/f.pf2","gfxmode":5,"ventoy_color":["#111111"]}}"##,
                           files: ["ventoy/t/theme.txt"])
        let theme = try #require(try ThemeInstaller.driveTheme(on: v))
        #expect(theme.settings == .init(file: "theme.txt", fonts: ["f.pf2"]))
    }

    @Test("a theme straight under ventoy/ is named after the drive")
    func driveThemeInVentoyFolder() throws {
        let v = try volume(json: #"{"theme":{"file":"/ventoy/theme.txt"}}"#, files: ["ventoy/theme.txt"])
        let theme = try #require(try ThemeInstaller.driveTheme(on: v))
        #expect(samePath(theme.folder, v.appendingPathComponent("ventoy")))
        #expect(theme.name == "Theme from \(v.lastPathComponent)")
        #expect(theme.settings.file == "theme.txt")
    }

    @Test("a folder Mactoy installed reports its marker's id and name")
    func driveManagedTheme() throws {
        let v = try volume()
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "custom-night-1a2b3c4d", name: "Night", settings: settings, to: v, isReadOnly: { _ in false })
        let theme = try #require(try ThemeInstaller.driveTheme(on: v))
        #expect(theme.managedID == "custom-night-1a2b3c4d")
        #expect(theme.name == "Night")
        #expect(samePath(theme.folder, v.appendingPathComponent("ventoy/themes/mactoy-custom-night-1a2b3c4d")))
        #expect(theme.settings == .init(file: "theme.txt", fonts: ["font.pf2"], gfxmode: "1920x1080,auto"))
    }

    @Test("a theme file in a subfolder of a managed folder keeps the whole managed folder")
    func driveManagedNested() throws {
        let v = try volume()
        let source = try themeFolder()
        try FileManager.default.createDirectory(at: source.appendingPathComponent("dark"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: source.appendingPathComponent("dark/theme.txt"))
        try ThemeInstaller.apply(themeDirectory: source, id: "nested", name: "Nested", settings: .init(file: "dark/theme.txt", fonts: ["font.pf2"]),
                                 to: v, isReadOnly: { _ in false })
        let theme = try #require(try ThemeInstaller.driveTheme(on: v))
        #expect(theme.managedID == "nested")
        #expect(samePath(theme.folder, v.appendingPathComponent("ventoy/themes/mactoy-nested")))
        #expect(theme.settings.file == "dark/theme.txt")
        #expect(theme.settings.fonts == ["font.pf2"])
    }

    @Test("a mactoy- folder whose marker can't be trusted is just a folder")
    func driveUntrustedMarker() throws {
        let v = try volume(json: #"{"theme":{"file":"/ventoy/themes/mactoy-x/theme.txt"}}"#, files: ["ventoy/themes/mactoy-x/theme.txt"])
        try Data(#"{"id":"../x","name":"Evil"}"#.utf8).write(to: v.appendingPathComponent("ventoy/themes/mactoy-x/.mactoy-theme.json"))
        let theme = try #require(try ThemeInstaller.driveTheme(on: v))
        #expect(theme.managedID == nil)
        #expect(theme.name == "mactoy-x")
    }

    @Test("a name from a drive is cut down to something a person can read")
    func driveNameIsCleaned() throws {
        let long = String(repeating: "n", count: 200)
        let v = try volume(json: #"{"theme":{"file":"/ventoy/\#(long)/theme.txt"}}"#, files: ["ventoy/\(long)/theme.txt"])
        let theme = try #require(try ThemeInstaller.driveTheme(on: v))
        #expect(theme.name.count == 60)
    }

    @Test("there is nothing to save when the drive has no theme, or only settings, or no theme file on it")
    func driveNothingToSave() throws {
        #expect(try ThemeInstaller.driveTheme(on: volume()) == nil)
        #expect(try ThemeInstaller.driveTheme(on: volume(json: #"{"control":[]}"#)) == nil)
        #expect(try ThemeInstaller.driveTheme(on: volume(json: #"{"theme":{"gfxmode":"1280x720"}}"#)) == nil)
        #expect(try ThemeInstaller.driveTheme(on: volume(json: #"{"theme":null}"#)) == nil)
        // Named but not there, or not a file.
        #expect(try ThemeInstaller.driveTheme(on: volume(json: #"{"theme":{"file":"/ventoy/gone/theme.txt"}}"#)) == nil)
        #expect(try ThemeInstaller.driveTheme(on: volume(json: #"{"theme":{"file":"/ventoy/dir/theme.txt"}}"#, files: ["ventoy/dir/theme.txt/inner.txt"])) == nil)
    }

    @Test("a theme file at the volume root is not saved, so the whole drive is never copied")
    func driveThemeAtRoot() throws {
        let v = try volume(json: #"{"theme":{"file":"/theme.txt"}}"#, files: ["theme.txt", "iso/big.png"])
        #expect(try ThemeInstaller.driveTheme(on: v) == nil)
    }

    @Test("a theme file that reaches outside the volume is not saved", arguments: [
        "/ventoy/../../etc/hosts", "/../theme.txt", "/ventoy/./mytheme/theme.txt", "/ventoy/mytheme/../mytheme/theme.txt", "/ventoy/my\\theme/theme.txt"])
    func driveThemeOutside(file: String) throws {
        // The backslash case is escaped the way a JSON file would hold it.
        let escaped = file.replacingOccurrences(of: "\\", with: "\\\\")
        let v = try volume(json: #"{"theme":{"file":"\#(escaped)"}}"#, files: ["ventoy/mytheme/theme.txt"])
        // A backslash in ventoy.json is refused outright; the others are refused by the path check.
        if file.contains("\\") {
            #expect(throws: VentoyConfigEditor.Refusal.containsBackslash) { _ = try ThemeInstaller.driveTheme(on: v) }
        } else {
            #expect(try ThemeInstaller.driveTheme(on: v) == nil)
        }
    }

    @Test("a theme folder, or any folder above it, that is a link is not saved", arguments: ["folder", "parent", "file"])
    func driveThemeThroughLinks(link: String) throws {
        let fm = FileManager.default
        let away = fm.temporaryDirectory.appendingPathComponent("mactoy-away-\(UUID().uuidString)")
        try fm.createDirectory(at: away.appendingPathComponent("mytheme"), withIntermediateDirectories: true)
        try Data([1]).write(to: away.appendingPathComponent("mytheme/theme.txt"))
        let v = try volume(json: #"{"theme":{"file":"/ventoy/mytheme/theme.txt"}}"#)
        let ventoy = v.appendingPathComponent("ventoy")
        switch link {
        case "folder":
            try fm.createSymbolicLink(at: ventoy.appendingPathComponent("mytheme"), withDestinationURL: away.appendingPathComponent("mytheme"))
        case "file":
            try fm.createDirectory(at: ventoy.appendingPathComponent("mytheme"), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: ventoy.appendingPathComponent("mytheme/theme.txt"),
                                      withDestinationURL: away.appendingPathComponent("mytheme/theme.txt"))
        default:
            // ventoy.json has to stay readable, so the link is made one level up from the config.
            let config = try Data(contentsOf: ventoy.appendingPathComponent("ventoy.json"))
            try fm.removeItem(at: ventoy)
            let real = fm.temporaryDirectory.appendingPathComponent("mactoy-real-\(UUID().uuidString)")
            try fm.createDirectory(at: real, withIntermediateDirectories: true)
            try config.write(to: real.appendingPathComponent("ventoy.json"))
            try fm.copyItem(at: away.appendingPathComponent("mytheme"), to: real.appendingPathComponent("mytheme"))
            try fm.createSymbolicLink(at: ventoy, withDestinationURL: real)
        }
        #expect(try ThemeInstaller.driveTheme(on: v) == nil)
    }

    @Test("a ventoy.json that can't be read is an error, not 'no theme'")
    func driveDamagedConfig() throws {
        let v = try volume(json: #"{"theme": "#)
        #expect(throws: VentoyConfigEditor.Refusal.self) { _ = try ThemeInstaller.driveTheme(on: v) }
    }

    // MARK: current() decides "managed" strictly

    private let managedFile = "/ventoy/themes/mactoy-xx/theme.txt"

    /// A volume with a Mactoy-style folder `mactoy-xx` (marker included) and a ventoy.json holding `theme`.
    private func volumeWithManagedFolder(theme: String, marker: String? = #"{"id":"xx","name":"X"}"#) throws -> URL {
        let v = try volume(json: #"{"control":[],"theme":\#(theme)}"#, files: ["ventoy/themes/mactoy-xx/theme.txt", "ventoy/themes/mactoy-xx/f.pf2"])
        if let marker {
            try Data(marker.utf8).write(to: v.appendingPathComponent("ventoy/themes/mactoy-xx/\(ThemeInstaller.markerName)"))
        }
        return v
    }

    @Test("the exact theme Mactoy writes, with every key it writes, is managed")
    func currentManagedExactShape() throws {
        let all = try volumeWithManagedFolder(theme: #"""
            {"file":"/ventoy/themes/mactoy-xx/theme.txt","fonts":["/ventoy/themes/mactoy-xx/f.pf2"],"gfxmode":"1920x1080,auto",
             "ventoy_left":"5%","ventoy_top":"10%","ventoy_color":"#112233"}
            """#)
        #expect(try ThemeInstaller.current(on: all) == .managed(id: "xx", name: "X"))
        let bare = try volumeWithManagedFolder(theme: #"{"file":"/ventoy/themes/mactoy-xx/theme.txt"}"#)
        #expect(try ThemeInstaller.current(on: bare) == .managed(id: "xx", name: "X"))
    }

    @Test("a path with . or .. or an empty part is the user's, even inside a folder that has our marker",
          arguments: [
            "/ventoy/themes/mactoy-xx/../mactoy-xx/theme.txt",
            "/ventoy/themes/mactoy-xx/../../../elsewhere/theme.txt",
            "/ventoy/themes/mactoy-xx/./theme.txt",
            "/ventoy/themes//mactoy-xx/theme.txt",
            "/ventoy/themes/mactoy-xx//theme.txt",
            "ventoy/themes/mactoy-xx/theme.txt",
          ])
    func currentOddPathsAreOther(file: String) throws {
        let v = try volumeWithManagedFolder(theme: #"{"file":"\#(file)"}"#)
        #expect(try ThemeInstaller.current(on: v) == .other(file: file))
    }

    @Test("a managed folder with a key Mactoy doesn't write is the user's, so replacing it asks first",
          arguments: ["\"display_mode\":\"CLI\"", "\"resolution_fit\":\"1\"", "\"default_file\":\"/ventoy/themes/mactoy-xx/b.txt\"",
                      "\"some_future_key\":1", "\"theme_uefi\":{}"])
    func currentExtraKeyIsOther(extra: String) throws {
        let v = try volumeWithManagedFolder(theme: "{\"file\":\"/ventoy/themes/mactoy-xx/theme.txt\",\(extra)}")
        #expect(try ThemeInstaller.current(on: v) == .other(file: managedFile))
    }

    @Test("a file list is the user's, even when it includes the managed file")
    func currentFileArrayIsOther() throws {
        let first = try volumeWithManagedFolder(theme: #"{"file":["/ventoy/themes/mactoy-xx/theme.txt","/ventoy/mine/theme.txt"]}"#)
        #expect(try ThemeInstaller.current(on: first) == .other(file: managedFile))
        let second = try volumeWithManagedFolder(theme: #"{"file":["/ventoy/mine/theme.txt","/ventoy/themes/mactoy-xx/theme.txt"]}"#)
        #expect(try ThemeInstaller.current(on: second) == .other(file: "/ventoy/mine/theme.txt"))
        let single = try volumeWithManagedFolder(theme: #"{"file":["/ventoy/themes/mactoy-xx/theme.txt"]}"#)
        #expect(try ThemeInstaller.current(on: single) == .other(file: managedFile))
    }

    @Test("fonts that aren't all inside the managed folder make it the user's")
    func currentFontsOutsideAreOther() throws {
        for fonts in [#"["/ventoy/themes/mactoy-xx/f.pf2","/ventoy/mine/g.pf2"]"#, #""/ventoy/themes/mactoy-xx/f.pf2""#,
                      #"["/ventoy/themes/mactoy-xx/../f.pf2"]"#, #"[5]"#, #"["/ventoy/themes/mactoy-xx"]"#] {
            let v = try volumeWithManagedFolder(theme: #"{"file":"/ventoy/themes/mactoy-xx/theme.txt","fonts":\#(fonts)}"#)
            #expect(try ThemeInstaller.current(on: v) == .other(file: managedFile), "\(fonts)")
        }
    }

    @Test("a marker that isn't a plain file with a usable id, or names another id, doesn't make a folder ours",
          arguments: [#"{"id":"../x","name":"X"}"#, #"{"id":"","name":"X"}"#, #"{"id":"XX","name":"X"}"#, #"{"id":"yy","name":"X"}"#,
                      "not json", #"{"name":"X"}"#])
    func currentUntrustedMarkerIsOther(marker: String) throws {
        let v = try volumeWithManagedFolder(theme: #"{"file":"/ventoy/themes/mactoy-xx/theme.txt"}"#, marker: marker)
        #expect(try ThemeInstaller.current(on: v) == .other(file: managedFile))
    }

    @Test("a marker that is a link is not read")
    func currentLinkedMarkerIsOther() throws {
        let v = try volumeWithManagedFolder(theme: #"{"file":"/ventoy/themes/mactoy-xx/theme.txt"}"#, marker: nil)
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-marker-\(UUID().uuidString).json")
        try Data(#"{"id":"xx","name":"X"}"#.utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: v.appendingPathComponent("ventoy/themes/mactoy-xx/\(ThemeInstaller.markerName)"),
                                                   withDestinationURL: elsewhere)
        #expect(try ThemeInstaller.current(on: v) == .other(file: managedFile))
    }

    @Test("a folder that is reached through a link is not trusted for its marker", arguments: ["ventoy", "themes", "mactoy-xx"])
    func currentLinkedFolderIsOther(linked: String) throws {
        let fm = FileManager.default
        let v = try volumeWithManagedFolder(theme: #"{"file":"/ventoy/themes/mactoy-xx/theme.txt"}"#)
        let path = ["ventoy": "ventoy", "themes": "ventoy/themes", "mactoy-xx": "ventoy/themes/mactoy-xx"][linked]!
        // Move the real folder away and leave a link to it where it was.
        let real = fm.temporaryDirectory.appendingPathComponent("mactoy-real-\(UUID().uuidString)")
        try fm.moveItem(at: v.appendingPathComponent(path), to: real)
        try fm.createSymbolicLink(at: v.appendingPathComponent(path), withDestinationURL: real)
        #expect(try ThemeInstaller.current(on: v) == .other(file: "/ventoy/themes/mactoy-xx/theme.txt"))
    }

    @Test("a name read off the drive loses control and bidi characters, and is cut to the library's length")
    func currentNameIsCleaned() throws {
        let marker = #"{"id":"xx","name":"Ev\u202Eil\u0007 \u200Bna\u2066me"}"#
        let v = try volumeWithManagedFolder(theme: #"{"file":"/ventoy/themes/mactoy-xx/theme.txt"}"#, marker: marker)
        #expect(try ThemeInstaller.current(on: v) == .managed(id: "xx", name: "Evil name"))

        let long = String(repeating: "n", count: 200)
        let big = try volumeWithManagedFolder(theme: #"{"file":"/ventoy/themes/mactoy-xx/theme.txt"}"#, marker: #"{"id":"xx","name":"\#(long)"}"#)
        #expect(try ThemeInstaller.current(on: big) == .managed(id: "xx", name: String(repeating: "n", count: 60)))

        // Nothing readable left: the id stands in for the name.
        let blank = try volumeWithManagedFolder(theme: #"{"file":"/ventoy/themes/mactoy-xx/theme.txt"}"#, marker: #"{"id":"xx","name":"\u202E\u200B"}"#)
        #expect(try ThemeInstaller.current(on: blank) == .managed(id: "xx", name: "xx"))
    }

    @Test("a damaged ventoy.json still throws from current, as before")
    func currentDamagedConfig() throws {
        let v = try volume(json: #"{"theme": "#)
        #expect(throws: VentoyConfigEditor.Refusal.self) { _ = try ThemeInstaller.current(on: v) }
    }

    // MARK: AppleDouble clutter (exFAT keeps extended attributes in `._` files)

    /// What macOS writes for a file whose only attribute is `com.apple.provenance`: the AppleDouble magic,
    /// version 2, the "Mac OS X" filler, then entries. Only the start matters to Mactoy; the rest is padding.
    private func appleDoubleBytes(size: Int = 82) -> Data {
        var bytes: [UInt8] = [0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00]
        bytes += Array("Mac OS X        ".utf8)
        bytes += [UInt8](repeating: 0, count: max(0, size - bytes.count))
        return Data(bytes)
    }

    /// Plants `._<name>` (or any file) the way exFAT would have, since APFS temp folders never get one.
    private func plant(_ url: URL, _ data: Data? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data ?? appleDoubleBytes()).write(to: url)
    }

    private func fileExists(_ v: URL, _ p: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: v.appendingPathComponent(p).path)) != nil
    }

    @Test("apply removes the AppleDouble files of what it wrote, and no other `._` file")
    func applyTidiesItsOwnClutter() throws {
        let fm = FileManager.default
        let v = try volume(json: #"{"control":[]}"#)
        // Already on the drive and not Mactoy's: the user's folder, a file of theirs, and their companions.
        try plant(v.appendingPathComponent("ventoy/themes/mine/theme.txt"), Data("x".utf8))
        try plant(v.appendingPathComponent("ventoy/themes/._mine"))
        try plant(v.appendingPathComponent("ventoy/notes.txt"), Data("n".utf8))
        try plant(v.appendingPathComponent("ventoy/._notes.txt"))
        // Beside what Mactoy writes or replaces: the settings file, the folder it creates (`themes` already exists here),
        // and the backup it makes. They were there before, so they have to go too.
        try plant(v.appendingPathComponent("ventoy/._ventoy.json"))
        try plant(v.appendingPathComponent("ventoy/._ventoy.json.mactoy-backup"))

        let source = try themeFolder()
        try ThemeInstaller.install(themeDirectory: source, id: "sample", name: "Sample", settings: settings, to: v,
                                   isReadOnly: { _ in false }, move: { from, to in
            if from.lastPathComponent.hasPrefix(".mactoy-staging-") {
                // The new folder, as exFAT would have left it: a companion for every file and folder, the marker included.
                for file in ["theme.txt", "bg.png", "font.pf2", "icons/a.png", ".mactoy-theme.json", "icons"] {
                    try self.plant(from.appendingPathComponent((file as NSString).deletingLastPathComponent)
                        .appendingPathComponent("._" + (file as NSString).lastPathComponent))
                }
                // Look-alikes that are not Mactoy's to touch.
                try self.plant(from.appendingPathComponent("icons/._notes.txt"), Data("not appledouble".utf8))   // no magic
                try self.plant(from.appendingPathComponent("icons/notes.txt"), Data("n".utf8))
                try self.plant(from.appendingPathComponent("._orphan.png"))                                      // nothing beside it
                try self.plant(from.appendingPathComponent("._big.png"), self.appleDoubleBytes(size: 64 * 1024 + 1))
                try self.plant(from.appendingPathComponent("big.png"), Data([1]))
                try self.plant(from.appendingPathComponent("._small.png"), Data([0x00, 0x05, 0x16]))              // shorter than the magic
                try self.plant(from.appendingPathComponent("small.png"), Data([1]))
            }
            try fm.moveItem(at: from, to: to)
            if to.lastPathComponent == "mactoy-sample" {
                try self.plant(to.deletingLastPathComponent().appendingPathComponent("._mactoy-sample"))
            }
        })

        for gone in ["ventoy/._ventoy.json", "ventoy/._ventoy.json.mactoy-backup", "ventoy/themes/._mactoy-sample",
                     "ventoy/themes/mactoy-sample/._theme.txt", "ventoy/themes/mactoy-sample/._bg.png",
                     "ventoy/themes/mactoy-sample/._font.pf2", "ventoy/themes/mactoy-sample/icons/._a.png",
                     "ventoy/themes/mactoy-sample/._.mactoy-theme.json", "ventoy/themes/mactoy-sample/._icons"] {
            #expect(!fileExists(v, gone), "\(gone) should have been removed")
        }
        for kept in ["ventoy/themes/._mine", "ventoy/._notes.txt", "ventoy/themes/mactoy-sample/icons/._notes.txt",
                     "ventoy/themes/mactoy-sample/._orphan.png", "ventoy/themes/mactoy-sample/._big.png",
                     "ventoy/themes/mactoy-sample/._small.png"] {
            #expect(fileExists(v, kept), "\(kept) is not Mactoy's and should still be there")
        }
        // What it installed is untouched.
        #expect(exists(v, "ventoy/themes/mactoy-sample/theme.txt"))
        #expect(exists(v, "ventoy/themes/mactoy-sample/icons/a.png"))
        #expect(try ThemeInstaller.current(on: v) == .managed(id: "sample", name: "Sample"))
    }

    @Test("on a brand new drive the companions of the folders Mactoy made go too, but not other root files'")
    func applyTidiesFreshDrive() throws {
        let v = try volume()
        try plant(v.appendingPathComponent("._ventoy"))        // Mactoy creates `ventoy`, so this is its companion
        try plant(v.appendingPathComponent("._themes"))        // not Mactoy's
        try plant(v.appendingPathComponent("themes"), Data([1]))
        try ThemeInstaller.install(themeDirectory: themeFolder(), id: "sample", name: "Sample", settings: settings, to: v,
                                   isReadOnly: { _ in false }, move: { from, to in
            try FileManager.default.moveItem(at: from, to: to)
            // macOS makes these when it creates `ventoy` and `themes`.
            try self.plant(v.appendingPathComponent("ventoy/._themes"))
        })
        #expect(!fileExists(v, "._ventoy"))
        #expect(!fileExists(v, "ventoy/._themes"))
        #expect(fileExists(v, "._themes"))
        #expect(try ThemeInstaller.current(on: v) == .managed(id: "sample", name: "Sample"))
    }

    @Test("an existing ventoy folder's own companion is not Mactoy's")
    func applyLeavesAnOlderVentoyFoldersCompanion() throws {
        let v = try volume(json: #"{"control":[]}"#)
        try plant(v.appendingPathComponent("._ventoy"))
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "sample", name: "Sample", settings: settings, to: v, isReadOnly: { _ in false })
        #expect(fileExists(v, "._ventoy"))
    }

    @Test("a companion that is a link, a folder or empty is never removed", arguments: ["link", "folder", "empty"])
    func applyKeepsOddCompanions(kind: String) throws {
        let fm = FileManager.default
        let v = try volume(json: #"{"control":[]}"#)
        let companion = v.appendingPathComponent("ventoy/._ventoy.json")
        switch kind {
        case "link":
            let real = fm.temporaryDirectory.appendingPathComponent("mactoy-ad-\(UUID().uuidString)")
            try appleDoubleBytes().write(to: real)
            try fm.createSymbolicLink(at: companion, withDestinationURL: real)
        case "folder":
            try fm.createDirectory(at: companion, withIntermediateDirectories: true)
        default:
            try Data().write(to: companion)
        }
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "sample", name: "Sample", settings: settings, to: v, isReadOnly: { _ in false })
        #expect(fileExists(v, "ventoy/._ventoy.json"))
    }

    @Test("a companion of exactly 64 KiB is removed; one byte more is kept")
    func appleDoubleSizeLimit() throws {
        let v = try volume(json: #"{"control":[]}"#)
        try plant(v.appendingPathComponent("ventoy/._ventoy.json"), appleDoubleBytes(size: 64 * 1024))
        try plant(v.appendingPathComponent("ventoy/._ventoy.json.mactoy-backup"), appleDoubleBytes(size: 64 * 1024 + 1))
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "sample", name: "Sample", settings: settings, to: v, isReadOnly: { _ in false })
        #expect(!fileExists(v, "ventoy/._ventoy.json"))
        #expect(fileExists(v, "ventoy/._ventoy.json.mactoy-backup"))
    }

    @Test("a failed change tidies nothing")
    func failedChangeLeavesCompanions() throws {
        let v = try volume(json: #"{"control":[]}"#)
        try plant(v.appendingPathComponent("ventoy/._ventoy.json"))
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try ThemeInstaller.install(themeDirectory: themeFolder(), id: "sample", name: "S", settings: settings, to: v,
                                       isReadOnly: { _ in false }, move: { _, _ in throw Boom() })
        }
        #expect(fileExists(v, "ventoy/._ventoy.json"))
    }

    @Test("removeTheme removes the companions of the folders it removed and of the settings it rewrote, and no others")
    func removeTidiesItsOwnClutter() throws {
        let v = try volume(json: #"{"control":[]}"#)
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "sample", name: "Sample", settings: settings, to: v, isReadOnly: { _ in false })
        try plant(v.appendingPathComponent("ventoy/themes/mine/theme.txt"), Data("x".utf8))
        try plant(v.appendingPathComponent("ventoy/themes/._mine"))
        try plant(v.appendingPathComponent("ventoy/themes/._mactoy-sample"))
        try plant(v.appendingPathComponent("ventoy/._ventoy.json"))
        try plant(v.appendingPathComponent("ventoy/._ventoy.json.mactoy-backup"))
        try plant(v.appendingPathComponent("ventoy/._themes"))
        try ThemeInstaller.removeTheme(from: v, isReadOnly: { _ in false })
        #expect(!exists(v, "ventoy/themes/mactoy-sample"))
        #expect(!fileExists(v, "ventoy/themes/._mactoy-sample"))
        #expect(!fileExists(v, "ventoy/._ventoy.json"))
        #expect(!fileExists(v, "ventoy/._ventoy.json.mactoy-backup"))
        // Beside `themes`, which it emptied of its own folder (`._themes` is Mactoy's to tidy either way).
        #expect(!fileExists(v, "ventoy/._themes"))
        // `mine` is still in `themes`, so the folder stays, and so does the user's companion.
        #expect(exists(v, "ventoy/themes/mine/theme.txt"))
        #expect(fileExists(v, "ventoy/themes/._mine"))
    }

    // MARK: Empty themes folder

    @Test("removeTheme removes the themes folder when nothing is left in it, and its companion with it")
    func removeDropsEmptyThemesFolder() throws {
        let v = try volume(json: #"{"control":[]}"#)
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "sample", name: "Sample", settings: settings, to: v, isReadOnly: { _ in false })
        // Companions of what is about to be removed don't keep the folder alive.
        try plant(v.appendingPathComponent("ventoy/themes/._mactoy-sample"))
        try plant(v.appendingPathComponent("ventoy/._themes"))
        try ThemeInstaller.removeTheme(from: v, isReadOnly: { _ in false })
        #expect(!fileExists(v, "ventoy/themes"))
        #expect(!fileExists(v, "ventoy/._themes"))
        #expect(listing(v, "ventoy") == ["ventoy.json", "ventoy.json.mactoy-backup"])
        #expect(try json(v)["theme"] == nil)
        #expect(try json(v)["control"] != nil)
    }

    @Test("removeTheme keeps a themes folder that holds anything else", arguments: ["folder", "file", "hidden", "notAppleDouble", "orphanAppleDouble"])
    func removeKeepsThemesFolderWithOtherThings(other: String) throws {
        let v = try volume()
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "sample", name: "Sample", settings: settings, to: v, isReadOnly: { _ in false })
        let themes = v.appendingPathComponent("ventoy/themes")
        switch other {
        case "folder": try FileManager.default.createDirectory(at: themes.appendingPathComponent("mine"), withIntermediateDirectories: true)
        case "file": try Data([1]).write(to: themes.appendingPathComponent("readme.txt"))
        case "hidden": try Data([1]).write(to: themes.appendingPathComponent(".DS_Store"))
        case "notAppleDouble": try plant(themes.appendingPathComponent("._mactoy-sample"), Data("hello there".utf8))
        default: try plant(themes.appendingPathComponent("._stranger"))      // an AppleDouble file, but of nothing Mactoy removed
        }
        try ThemeInstaller.removeTheme(from: v, isReadOnly: { _ in false })
        #expect(exists(v, "ventoy/themes"))
        #expect(!exists(v, "ventoy/themes/mactoy-sample"))
    }

    @Test("removeTheme on a drive whose themes folder is already empty removes it, and leaves the rest of ventoy alone")
    func removeDropsAlreadyEmptyThemesFolder() throws {
        let v = try volume(json: #"{"control":[]}"#)
        try FileManager.default.createDirectory(at: v.appendingPathComponent("ventoy/themes"), withIntermediateDirectories: true)
        try ThemeInstaller.removeTheme(from: v, isReadOnly: { _ in false })
        #expect(!exists(v, "ventoy/themes"))
        #expect(exists(v, "ventoy/ventoy.json"))
    }

    @Test("apply never removes the themes folder")
    func applyKeepsThemesFolder() throws {
        let v = try volume()
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "alpha", name: "A", settings: settings, to: v, isReadOnly: { _ in false })
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "bravo", name: "B", settings: settings, to: v, isReadOnly: { _ in false })
        #expect(listing(v, "ventoy/themes") == ["mactoy-bravo"])
    }

    @Test("the one-time backup is written atomically")
    func backupIsAtomic() throws {
        // A cut-short write can't be seen from a test; this reads the call so it can't be dropped unnoticed.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MactoyKit/ThemeInstaller.swift"), encoding: .utf8)
        #expect(source.contains("try original.write(to: backup, options: .atomic)"))
        // And it still writes the backup.
        let v = try volume(json: #"{"control":[]}"#)
        try ThemeInstaller.apply(themeDirectory: themeFolder(), id: "sample", name: "S", settings: settings, to: v, isReadOnly: { _ in false })
        #expect(try text(v, "ventoy/ventoy.json.mactoy-backup") == #"{"control":[]}"#)
        #expect(listing(v, "ventoy") == ["themes", "ventoy.json", "ventoy.json.mactoy-backup"], "no temp file from the atomic write is left")
    }

    // MARK: Looks freshly installed

    @Test("a volume that was just formatted looks fresh, with or without an empty ventoy or themes folder")
    func freshLooksFresh() throws {
        let v = try volume()
        #expect(ThemeInstaller.looksFreshlyInstalled(v), "no ventoy folder at all")
        let fm = FileManager.default
        try fm.createDirectory(at: v.appendingPathComponent("ventoy"), withIntermediateDirectories: true)
        #expect(ThemeInstaller.looksFreshlyInstalled(v), "an empty ventoy folder")
        try fm.createDirectory(at: v.appendingPathComponent("ventoy/themes"), withIntermediateDirectories: true)
        #expect(ThemeInstaller.looksFreshlyInstalled(v), "an empty themes folder")
        // Files elsewhere on the drive (an ISO, say) say nothing about the settings.
        try Data([1]).write(to: v.appendingPathComponent("some.iso"))
        #expect(ThemeInstaller.looksFreshlyInstalled(v))
    }

    @Test("a drive with a ventoy.json is not fresh, whatever is in it")
    func existingConfigIsNotFresh() throws {
        for json in [#"{"control":[]}"#, "", "{ not json", #"{"theme":null}"#] {
            let v = try volume(json: json)
            #expect(!ThemeInstaller.looksFreshlyInstalled(v), "\(json)")
        }
    }

    @Test("a themes folder with anything in it is not fresh, hidden entries included")
    func filledThemesIsNotFresh() throws {
        let fm = FileManager.default
        for entry in ["mactoy-x", "mine", ".DS_Store", "._junk"] {
            let v = try volume()
            let themes = v.appendingPathComponent("ventoy/themes")
            try fm.createDirectory(at: themes, withIntermediateDirectories: true)
            try fm.createDirectory(at: themes.appendingPathComponent(entry), withIntermediateDirectories: true)
            #expect(!ThemeInstaller.looksFreshlyInstalled(v), "\(entry)")
        }
    }

    @Test("links and files in the place of the settings folder, config or themes folder are not fresh")
    func linksAreNotFresh() throws {
        let fm = FileManager.default
        let away = fm.temporaryDirectory.appendingPathComponent("mactoy-away-\(UUID().uuidString)")
        try fm.createDirectory(at: away, withIntermediateDirectories: true)

        // ventoy -> an empty folder elsewhere
        var v = try volume()
        try fm.createSymbolicLink(at: v.appendingPathComponent("ventoy"), withDestinationURL: away)
        #expect(!ThemeInstaller.looksFreshlyInstalled(v), "ventoy is a link")

        // ventoy is a plain file
        v = try volume()
        try Data([1]).write(to: v.appendingPathComponent("ventoy"))
        #expect(!ThemeInstaller.looksFreshlyInstalled(v), "ventoy is a file")

        // ventoy.json is a link that leads nowhere
        v = try volume()
        try fm.createDirectory(at: v.appendingPathComponent("ventoy"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: v.appendingPathComponent("ventoy/ventoy.json"), withDestinationURL: away.appendingPathComponent("gone.json"))
        #expect(!ThemeInstaller.looksFreshlyInstalled(v), "a dangling ventoy.json link still counts as there")

        // themes -> an empty folder elsewhere, and themes as a file
        v = try volume()
        try fm.createDirectory(at: v.appendingPathComponent("ventoy"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: v.appendingPathComponent("ventoy/themes"), withDestinationURL: away)
        #expect(!ThemeInstaller.looksFreshlyInstalled(v), "themes is a link")
        v = try volume()
        try fm.createDirectory(at: v.appendingPathComponent("ventoy"), withIntermediateDirectories: true)
        try Data([1]).write(to: v.appendingPathComponent("ventoy/themes"))
        #expect(!ThemeInstaller.looksFreshlyInstalled(v), "themes is a file")
    }

    @Test("looking changes nothing on the drive")
    func lookingIsReadOnly() throws {
        let v = try volume(json: #"{"control":[]}"#)
        let before = try Data(contentsOf: v.appendingPathComponent("ventoy/ventoy.json"))
        _ = ThemeInstaller.looksFreshlyInstalled(v)
        #expect(try Data(contentsOf: v.appendingPathComponent("ventoy/ventoy.json")) == before)
        #expect(listing(v, "ventoy") == ["ventoy.json"])
        let empty = try volume()
        _ = ThemeInstaller.looksFreshlyInstalled(empty)
        #expect(!exists(empty, "ventoy"), "it doesn't create the folders it looks for")
    }

}

private struct InjectedFailure: Error {}
