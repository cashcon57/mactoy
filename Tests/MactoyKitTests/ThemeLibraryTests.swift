import Foundation
import Testing
@testable import MactoyKit

@Suite("Theme library")
struct ThemeLibraryTests {

    private func tempDir(_ label: String = "lib") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A theme folder as found on a drive or in a download: wanted files, and
    /// things that must never be kept (a script, a hidden file, a `.cfg`).
    private func themeFolder(extra: [String: Data] = [:]) throws -> URL {
        let dir = try tempDir("src")
        var files: [String: Data] = [
            "theme.txt": Data("desktop-image: \"bg.png\"\n".utf8),
            "bg.png": Data([1]), "font.pf2": Data([2]), "icons/a.png": Data([3]),
            "grub.cfg": Data("echo hi".utf8), "run.sh": Data("#!/bin/sh".utf8),
            ".DS_Store": Data([4]), "icons/.hidden.png": Data([5]), "._bg.png": Data([6]),
        ]
        files.merge(extra) { _, new in new }
        for (path, data) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return dir
    }

    private func library() throws -> ThemeLibrary { ThemeLibrary(root: try tempDir("root").appendingPathComponent("My Themes"), discard: .delete) }
    private let settings = ThemeEntry.Settings(file: "theme.txt", fonts: ["font.pf2"])

    private func listing(_ url: URL) -> [String] {
        let base = url.resolvingSymlinksInPath().path + "/"
        return (FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.resolvingSymlinksInPath().path.dropFirst(base.count)) }.sorted()
    }

    private func names(_ root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    private func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9][a-z0-9-]{1,59}$"#, options: .regularExpression) == id.startIndex..<id.endIndex && ThemeInstaller.isValidID(id)
    }

    // MARK: save

    @Test("only the theme's own file types are kept, and the folder is described by a hidden file")
    func savesAllowedFilesOnly() throws {
        let lib = try library()
        let saved = try lib.save(folder: themeFolder(), name: "Night Sky", settings: settings, origin: "Added from a file")
        let stored = lib.directory(for: saved)
        #expect(listing(stored) == [".mactoy-library.json", "bg.png", "font.pf2", "icons/a.png", "theme.txt"])
        #expect(saved.name == "Night Sky")
        #expect(saved.origin == "Added from a file")
        #expect(saved.settings == settings)
        #expect(saved.previewFile == "bg.png")
        #expect(isValidID(saved.id) && saved.id.hasPrefix("custom-night-sky-"))
        #expect(lib.list() == [saved])
    }

    @Test("what the installer would copy to a drive never includes the description")
    func descriptionStaysOffDrives() throws {
        let lib = try library()
        let saved = try lib.save(folder: themeFolder(), name: "Night", settings: settings, origin: "x")
        let files = try ThemeInstaller.installableFiles(in: lib.directory(for: saved)).map(\.path).sorted()
        #expect(files == ["bg.png", "font.pf2", "icons/a.png", "theme.txt"])
    }

    @Test("the same theme saved again is the same entry, and nothing is written")
    func dedupes() throws {
        let lib = try library()
        let first = try lib.save(folder: themeFolder(), name: "Night", settings: settings, origin: "Added from a file")
        // A second copy of the same files, from somewhere else.
        let sentinel = lib.directory(for: first).appendingPathComponent("sentinel.txt")
        try Data("still here".utf8).write(to: sentinel)
        let second = try lib.save(folder: themeFolder(), name: "Night", settings: settings, origin: "Saved from the drive “Other”")
        #expect(second == first)
        #expect(second.origin == "Added from a file")
        #expect(names(lib.root) == [first.id])
        #expect(FileManager.default.fileExists(atPath: sentinel.path), "the folder wasn't rewritten")
    }

    @Test("a different name, different files or different settings is a different theme")
    func differentContentDiffersInID() throws {
        let lib = try library()
        let a = try lib.save(folder: themeFolder(), name: "Night", settings: settings, origin: "x")
        let otherName = try lib.save(folder: themeFolder(), name: "Day", settings: settings, origin: "x")
        let otherFile = try lib.save(folder: themeFolder(extra: ["bg.png": Data([9])]), name: "Night", settings: settings, origin: "x")
        let otherSettings = try lib.save(folder: themeFolder(), name: "Night",
                                         settings: .init(file: "theme.txt", fonts: ["font.pf2"], gfxmode: "1024x768"), origin: "x")
        #expect(Set([a.id, otherName.id, otherFile.id, otherSettings.id]).count == 4)
        #expect(lib.list().count == 4)
    }

    @Test("a file that isn't kept doesn't change the id")
    func droppedFilesDontChangeID() throws {
        let lib = try library()
        let a = try lib.save(folder: themeFolder(), name: "Night", settings: settings, origin: "x")
        let b = try lib.save(folder: themeFolder(extra: ["notes.cfg": Data([7]), ".other": Data([8])]), name: "Night", settings: settings, origin: "x")
        #expect(a.id == b.id)
    }

    @Test("a theme saved out of the library's own folder is the same theme")
    func resaveFromLibrary() throws {
        let lib = try library()
        let a = try lib.save(folder: themeFolder(), name: "Night", settings: settings, origin: "x")
        let b = try lib.save(folder: lib.directory(for: a), name: "Night", settings: a.settings, origin: "y")
        #expect(a == b)
    }

    @Test("fonts that aren't in the folder, or aren't safe, are dropped; the theme is still saved")
    func dropsMissingFonts() throws {
        let lib = try library()
        let wanted = ThemeEntry.Settings(file: "theme.txt",
                                         fonts: ["font.pf2", "gone.pf2", "../outside.pf2", "/abs.pf2", "icons/a.png", "font.pf2", "x/../font.pf2"])
        let saved = try lib.save(folder: themeFolder(), name: "Night", settings: wanted, origin: "x")
        #expect(saved.settings.fonts == ["font.pf2"])
        let none = try lib.save(folder: themeFolder(), name: "Plain", settings: .init(file: "theme.txt", fonts: ["gone.pf2"]), origin: "x")
        #expect(none.settings.fonts == nil)
    }

    @Test("a setting that fails the catalog's format check is dropped, the rest are kept")
    func dropsInvalidValues() throws {
        let lib = try library()
        let wanted = ThemeEntry.Settings(file: "theme.txt", fonts: nil, gfxmode: "huge", ventoyLeft: "5%",
                                         ventoyTop: "up\"; evil", ventoyColor: "#12345")
        let saved = try lib.save(folder: themeFolder(), name: "Night", settings: wanted, origin: "x")
        #expect(saved.settings == .init(file: "theme.txt", ventoyLeft: "5%"))
        let good = ThemeEntry.Settings(file: "theme.txt", gfxmode: "1280x720,auto", ventoyLeft: "5%", ventoyTop: "100%-19", ventoyColor: "#89b4fa")
        #expect(try lib.save(folder: themeFolder(), name: "Good", settings: good, origin: "x").settings == good)
    }

    @Test("a theme file that isn't there is refused, and nothing is left behind",
          arguments: ["missing.txt", "grub.cfg", "run.sh", "../theme.txt", "/theme.txt", "theme.txt/", "icons", "bg.png", ".DS_Store", ""])
    func missingSettingsFile(file: String) throws {
        let lib = try library()
        #expect(throws: ThemeError.missingFile(file)) {
            try lib.save(folder: themeFolder(), name: "Night", settings: .init(file: file), origin: "x")
        }
        #expect(names(lib.root).isEmpty, "no staging folder or half-made theme remains")
    }

    @Test("an empty folder is refused as missing the theme file")
    func emptyFolder() throws {
        let lib = try library()
        #expect(throws: ThemeError.missingFile("theme.txt")) {
            try lib.save(folder: tempDir("empty"), name: "Night", settings: settings, origin: "x")
        }
        #expect(names(lib.root).isEmpty)
    }

    @Test("links in the folder are not followed")
    func ignoresLinks() throws {
        let lib = try library()
        let away = try tempDir("away")
        try Data("secret".utf8).write(to: away.appendingPathComponent("secret.txt"))
        let source = try themeFolder()
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("leak.txt"), withDestinationURL: away.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("linked"), withDestinationURL: away)
        let saved = try lib.save(folder: source, name: "Night", settings: settings, origin: "x")
        #expect(listing(lib.directory(for: saved)) == [".mactoy-library.json", "bg.png", "font.pf2", "icons/a.png", "theme.txt"])
    }

    @Test("ids fit the installer's rule whatever the name",
          arguments: ["", "   ", "Ünïcödé Thème", "A/B\\C", String(repeating: "long ", count: 40), "---", "🎨🎨", "Night\u{0}Sky\n", "\u{202E}rtl", "zero\u{200B}width\u{FEFF}", "a\u{202D}b\u{2066}c\u{200F}", "UPPER lower 123"])
    func idsAreValid(name: String) throws {
        let lib = try library()
        let saved = try lib.save(folder: themeFolder(), name: name, settings: settings, origin: "x")
        #expect(isValidID(saved.id), "\(saved.id)")
        #expect(saved.id.count <= 46)
        #expect(saved.name.count <= 60 && !saved.name.isEmpty)
        #expect(!saved.name.unicodeScalars.contains { [.control, .format].contains($0.properties.generalCategory) })
        #expect(!saved.origin.unicodeScalars.contains { [.control, .format].contains($0.properties.generalCategory) })
        #expect(lib.list() == [saved])
    }

    @Test("invisible and direction-changing characters are removed from names and origins")
    func cleansFormatCharacters() throws {
        #expect(ThemeLibrary.cleaned("a\u{202E}b\u{200B}c\u{FEFF}", limit: 60) == "abc")
        #expect(ThemeLibrary.cleaned("\u{202E}\u{200B}", limit: 60, fallback: "Theme") == "Theme")
        let lib = try library()
        let saved = try lib.save(folder: themeFolder(), name: "Night\u{202E}Sky\u{200B}", settings: settings, origin: "Saved from the drive “\u{202E}Ventoy”")
        #expect(saved.name == "NightSky")
        #expect(saved.origin == "Saved from the drive “Ventoy”")
        // An entry written by something else, with such a character in its name, is not listed.
        let url = lib.directory(for: saved).appendingPathComponent(ThemeLibrary.metadataName)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["name"] = "Night\u{202E}Sky"
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(lib.list().isEmpty)
    }

    @Test("the picture comes from the theme file, relative to the theme file's folder")
    func previewFile() throws {
        let lib = try library()
        let nested = try lib.save(folder: themeFolder(extra: ["dark/theme.txt": Data("desktop-image: \"back.jpg\"\n".utf8), "dark/back.jpg": Data([1])]),
                                  name: "Nested", settings: .init(file: "dark/theme.txt"), origin: "x")
        #expect(nested.previewFile == "dark/back.jpg")
        // A picture that isn't there, isn't a picture type, or climbs out of the folder is not a preview.
        for (text, label) in [("desktop-image: \"gone.png\"", "gone"), ("desktop-image: \"font.pf2\"", "font"),
                              ("desktop-image: \"../bg.png\"", "climbs"), ("desktop-image: \"icons\"", "folder"), ("title-text: \"x\"", "none")] {
            let saved = try lib.save(folder: themeFolder(extra: ["theme.txt": Data(text.utf8)]), name: label, settings: settings, origin: "x")
            #expect(saved.previewFile == nil, "\(label)")
        }
    }

    @Test("what save returns is what list reads back")
    func saveMatchesList() throws {
        let lib = try library()
        let saved = try lib.save(folder: themeFolder(), name: "Night", settings: settings, origin: "Saved from the drive “Ventoy”")
        #expect(lib.list() == [saved])
        #expect(saved.savedAt.timeIntervalSince1970 == saved.savedAt.timeIntervalSince1970.rounded(.down))
        #expect(abs(saved.savedAt.timeIntervalSinceNow) < 5)
    }

    @Test("a damaged leftover under the same name is replaced")
    func replacesDamagedLeftover() throws {
        let lib = try library()
        let first = try lib.save(folder: themeFolder(), name: "Night", settings: settings, origin: "x")
        try FileManager.default.removeItem(at: lib.directory(for: first).appendingPathComponent(ThemeLibrary.metadataName))
        #expect(lib.list().isEmpty)
        let again = try lib.save(folder: themeFolder(), name: "Night", settings: settings, origin: "x")
        #expect(again.id == first.id)
        #expect(lib.list() == [again])
    }

    @Test("a link under the theme's name is never written through")
    func refusesLinkAtDestination() throws {
        let lib = try library()
        let first = try lib.save(folder: themeFolder(), name: "Night", settings: settings, origin: "x")
        let away = try tempDir("away")
        try Data("keep".utf8).write(to: away.appendingPathComponent("keep.txt"))
        try FileManager.default.removeItem(at: lib.directory(for: first))
        try FileManager.default.createSymbolicLink(at: lib.directory(for: first), withDestinationURL: away)
        #expect(throws: ThemeError.destinationExists(lib.directory(for: first).path)) {
            try lib.save(folder: themeFolder(), name: "Night", settings: settings, origin: "x")
        }
        #expect(listing(away) == ["keep.txt"])
        #expect(names(lib.root) == [first.id], "no staging folder remains")
    }

    // MARK: list

    /// Writes a library folder by hand, as another version of Mactoy or a user might leave it.
    @discardableResult
    private func plant(_ lib: ThemeLibrary, folder: String, id: String? = nil, name: String = "Planted", settings: ThemeEntry.Settings? = nil,
                       savedAt: Date = Date(), metadata: Data? = nil, files: [String] = ["theme.txt"]) throws -> URL {
        let dir = lib.root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files { try Data([1]).write(to: dir.appendingPathComponent(f)) }
        let theme = SavedTheme(id: id ?? folder, name: name, settings: settings ?? .init(file: "theme.txt"), origin: "x", savedAt: savedAt, previewFile: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try (metadata ?? encoder.encode(theme)).write(to: dir.appendingPathComponent(ThemeLibrary.metadataName))
        return dir
    }

    @Test("list shows newest first and skips whatever can't be a theme")
    func listSkipsBad() throws {
        let lib = try library()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try plant(lib, folder: "custom-old-11111111", name: "Old", savedAt: now.addingTimeInterval(-100))
        try plant(lib, folder: "custom-new-22222222", name: "New", savedAt: now)
        // Damaged metadata, and metadata that isn't a theme.
        try plant(lib, folder: "custom-bad-33333333", metadata: Data("{ not json".utf8))
        try plant(lib, folder: "custom-empty-44444444", metadata: Data())
        try plant(lib, folder: "custom-shape-55555555", metadata: Data(#"{"id":"custom-shape-55555555"}"#.utf8))
        // The theme file or a font its settings name is gone.
        try plant(lib, folder: "custom-nofile-66666666", files: ["other.txt"])
        try plant(lib, folder: "custom-nofont-77777777", settings: .init(file: "theme.txt", fonts: ["gone.pf2"]))
        // The folder name and the id disagree, or the name isn't an id at all.
        try plant(lib, folder: "custom-liar-88888888", id: "custom-other-88888888")
        try plant(lib, folder: "Not An ID")
        try plant(lib, folder: ".staging-\(UUID().uuidString)")
        // Settings that name a path outside the folder (a file really is there, so only the path check can refuse it).
        try Data([1]).write(to: lib.root.appendingPathComponent("theme.txt"))
        try plant(lib, folder: "custom-climb-99999999", settings: .init(file: "../theme.txt"), files: [])
        try plant(lib, folder: "custom-nl-aaaaaaaa", name: "Two\nlines")
        // A plain file, and a link to a folder that would otherwise be a fine theme.
        try Data("x".utf8).write(to: lib.root.appendingPathComponent("custom-file-bbbbbbbb"))
        let away = try tempDir("away")
        try Data([1]).write(to: away.appendingPathComponent("theme.txt"))
        try Data(JSONEncoder().encode(SavedTheme(id: "custom-link-cccccccc", name: "Link", settings: .init(file: "theme.txt"), origin: "x",
                                                  savedAt: .distantPast, previewFile: nil))).write(to: away.appendingPathComponent(ThemeLibrary.metadataName))
        try FileManager.default.createSymbolicLink(at: lib.root.appendingPathComponent("custom-link-cccccccc"), withDestinationURL: away)

        #expect(lib.list().map(\.name) == ["New", "Old"])
    }

    @Test("a picture path that isn't safe is dropped from the entry, the theme stays")
    func listDropsBadPreview() throws {
        let lib = try library()
        try plant(lib, folder: "custom-pic-11111111", name: "Pic")
        let url = lib.root.appendingPathComponent("custom-pic-11111111").appendingPathComponent(ThemeLibrary.metadataName)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["previewFile"] = "../../secret.png"
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let listed = try #require(lib.list().first)
        #expect(listed.previewFile == nil)
    }

    @Test("an empty or missing library lists nothing")
    func listEmpty() throws {
        #expect(try library().list().isEmpty)
        let lib = try library()
        try FileManager.default.createDirectory(at: lib.root, withIntermediateDirectories: true)
        #expect(lib.list().isEmpty)
    }

    // MARK: remove

    @Test("remove deletes the theme's folder and nothing else")
    func removes() throws {
        let lib = try library()
        let keep = try lib.save(folder: themeFolder(), name: "Keep", settings: settings, origin: "x")
        let drop = try lib.save(folder: themeFolder(), name: "Drop", settings: settings, origin: "x")
        try lib.remove(id: drop.id)
        #expect(lib.list() == [keep])
        #expect(names(lib.root) == [keep.id])
        // Already gone is fine.
        try lib.remove(id: drop.id)
    }

    @Test("remove refuses an id that could be a path or isn't an id",
          arguments: ["", "../x", "..", ".", "a/b", "UPPER", "custom-x-1/..", " custom-x", "custom-x\n", "-custom", ".staging-1", "/custom-x-12345678"])
    func removeRefusesBadID(id: String) throws {
        let lib = try library()
        let keep = try lib.save(folder: themeFolder(), name: "Keep", settings: settings, origin: "x")
        // A sibling folder with a description, which a path trick would reach.
        let outside = lib.root.deletingLastPathComponent().appendingPathComponent("x")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([1]).write(to: outside.appendingPathComponent(ThemeLibrary.metadataName))
        #expect(throws: ThemeLibraryError.notInLibrary(id)) { try lib.remove(id: id) }
        #expect(lib.list() == [keep])
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("remove refuses a folder that has no description")
    func removeRefusesUndescribed() throws {
        let lib = try library()
        let dir = lib.root.appendingPathComponent("custom-mine-12345678")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("precious.txt"))
        #expect(throws: ThemeLibraryError.notInLibrary("custom-mine-12345678")) { try lib.remove(id: "custom-mine-12345678") }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("precious.txt").path))
        // A plain file under a valid id is not a theme either.
        try Data([1]).write(to: lib.root.appendingPathComponent("custom-file-12345678"))
        #expect(throws: ThemeLibraryError.notInLibrary("custom-file-12345678")) { try lib.remove(id: "custom-file-12345678") }
    }

    @Test("remove never follows a link")
    func removeRefusesLink() throws {
        let lib = try library()
        let away = try tempDir("away")
        try Data("keep".utf8).write(to: away.appendingPathComponent("keep.txt"))
        try Data("{}".utf8).write(to: away.appendingPathComponent(ThemeLibrary.metadataName))
        try FileManager.default.createDirectory(at: lib.root, withIntermediateDirectories: true)
        let link = lib.root.appendingPathComponent("custom-link-12345678")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: away)
        #expect(throws: ThemeLibraryError.isALink("custom-link-12345678")) { try lib.remove(id: "custom-link-12345678") }
        #expect(listing(away) == [".mactoy-library.json", "keep.txt"])
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil, "the link itself is still there")
    }

    @Test("the default library is in Documents, where it outlives Mactoy; the old one was in Application Support")
    func defaultRoot() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ThemeLibrary.defaultRoot().path == home + "/Documents/Mactoy Themes")
        #expect(ThemeLibrary().root == ThemeLibrary.defaultRoot())
        #expect(ThemeLibrary.legacyRoot().path == home + "/Library/Application Support/Mactoy/My Themes")
    }

    // MARK: moving from the old library

    /// `<temp>/Mactoy/My Themes` with the given themes saved in it, laid out like v0.7.0's.
    private func oldLibrary(themes: [String]) throws -> ThemeLibrary {
        let lib = ThemeLibrary(root: try tempDir("support").appendingPathComponent("Mactoy/My Themes"), discard: .delete)
        for name in themes { try lib.save(folder: themeFolder(), name: name, settings: settings, origin: "Added from a file") }
        if themes.isEmpty { try FileManager.default.createDirectory(at: lib.root, withIntermediateDirectories: true) }
        return lib
    }

    private func exists(_ url: URL) -> Bool { ThemeInstaller.fileType(url) != nil }

    @Test("every theme moves with its files and description, and the emptied old folders go")
    func movesThemes() throws {
        let old = try oldLibrary(themes: ["Night Sky", "Dawn"])
        let before = old.list()
        let files = before.map { listing(old.directory(for: $0)) }
        let new = try library()
        let parent = old.root.deletingLastPathComponent()

        let result = new.moveThemes(from: old.root, thenRemoveIfEmpty: parent)

        #expect(Set(result.moved) == Set(before.map(\.id)))
        #expect(result.leftBehind.isEmpty && result.notMoved.isEmpty)
        #expect(new.list() == before, "same ids, names, settings, origins and dates")
        #expect(new.list().map { listing(new.directory(for: $0)) } == files)
        #expect(!exists(old.root))
        #expect(!exists(parent))
        #expect(names(new.root).allSatisfy { !$0.hasPrefix(".staging-") })
    }

    @Test("anything that isn't a whole theme stays where it was, and so do the folders holding it")
    func leavesTheRest() throws {
        let old = try oldLibrary(themes: ["Night Sky"])
        let fm = FileManager.default
        let parent = old.root.deletingLastPathComponent()
        // A note of the user's, a folder with no description, a theme missing its files, and a link.
        try Data("mine".utf8).write(to: old.root.appendingPathComponent("notes.txt"))
        try fm.createDirectory(at: old.root.appendingPathComponent("custom-bare-12345678"), withIntermediateDirectories: true)
        let broken = try oldLibrary(themes: ["Broken"])
        let brokenTheme = try #require(broken.list().first)
        try fm.removeItem(at: broken.directory(for: brokenTheme).appendingPathComponent("theme.txt"))
        try fm.moveItem(at: broken.directory(for: brokenTheme), to: old.root.appendingPathComponent(brokenTheme.id))
        let away = try tempDir("away")
        try fm.createSymbolicLink(at: old.root.appendingPathComponent("custom-link-12345678"), withDestinationURL: away)
        try Data("other app".utf8).write(to: parent.appendingPathComponent("other.txt"))

        let new = try library()
        let result = new.moveThemes(from: old.root, thenRemoveIfEmpty: parent)

        #expect(result.moved.count == 1)
        #expect(result.notMoved.isEmpty, "a theme missing its files isn't a whole theme")
        #expect(result.leftBehind == [brokenTheme.id, "custom-bare-12345678", "custom-link-12345678", "notes.txt"].sorted())
        #expect(names(old.root) == [brokenTheme.id, "custom-bare-12345678", "custom-link-12345678", "notes.txt"].sorted())
        #expect(listing(old.root.appendingPathComponent(brokenTheme.id)) == [".mactoy-library.json", "bg.png", "font.pf2", "icons/a.png"])
        #expect(exists(parent.appendingPathComponent("other.txt")))
        #expect(new.list().count == 1)
    }

    @Test("a folder that held only the old library stays when something else is in it")
    func keepsParentWithOtherThings() throws {
        let old = try oldLibrary(themes: ["Night Sky"])
        let parent = old.root.deletingLastPathComponent()
        try Data("x".utf8).write(to: parent.appendingPathComponent("other.txt"))
        let result = try library().moveThemes(from: old.root, thenRemoveIfEmpty: parent)
        #expect(result.moved.count == 1)
        #expect(!exists(old.root))
        #expect(names(parent) == ["other.txt"])
    }

    @Test("a theme already in the new library is the same theme, so the old copy goes")
    func sameThemeInBoth() throws {
        let old = try oldLibrary(themes: ["Night Sky"])
        let new = try library()
        let here = try new.save(folder: themeFolder(), name: "Night Sky", settings: settings, origin: "Added from a file")
        #expect(old.list().map(\.id) == [here.id], "same files and settings give the same id")

        let result = new.moveThemes(from: old.root)

        #expect(result.moved == [here.id])
        #expect(!exists(old.root))
        #expect(new.list().map(\.id) == [here.id])
    }

    @Test("something else under the theme's name in the new library is left alone, and so is the theme")
    func destinationTaken() throws {
        let old = try oldLibrary(themes: ["Night Sky"])
        let id = try #require(old.list().first?.id)
        let new = try library()
        let taken = new.root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: taken.appendingPathComponent("keep.txt"))

        let result = new.moveThemes(from: old.root)

        #expect(result.notMoved == [id])
        #expect(result.leftBehind.isEmpty)
        #expect(listing(taken) == ["keep.txt"])
        #expect(old.list().map(\.id) == [id])
    }

    @Test("Mactoy's half-saved leftovers and Finder's .DS_Store go; a link named like a leftover doesn't")
    func removesLeftovers() throws {
        let old = try oldLibrary(themes: [])
        let fm = FileManager.default
        let staging = old.root.appendingPathComponent(".staging-ABC")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data([1]).write(to: staging.appendingPathComponent("bg.png"))
        try Data([1]).write(to: old.root.appendingPathComponent(".DS_Store"))
        let away = try tempDir("away")
        try Data("keep".utf8).write(to: away.appendingPathComponent("keep.txt"))
        try fm.createSymbolicLink(at: old.root.appendingPathComponent(".staging-LINK"), withDestinationURL: away)

        let new = try library()
        let result = new.moveThemes(from: old.root)

        #expect(result == ThemeLibrary.MoveResult())
        #expect(names(old.root) == [".staging-LINK"])
        #expect(listing(away) == ["keep.txt"])
        #expect(!exists(new.root), "no theme to move, so the new folder isn't touched")
    }

    @Test("no old library, or one with no themes, leaves the new folder untouched")
    func nothingToMove() throws {
        let new = try library()
        let missing = try tempDir("support").appendingPathComponent("Mactoy/My Themes")
        #expect(new.moveThemes(from: missing) == ThemeLibrary.MoveResult())
        let empty = try oldLibrary(themes: [])
        let parent = empty.root.deletingLastPathComponent()
        #expect(new.moveThemes(from: empty.root, thenRemoveIfEmpty: parent) == ThemeLibrary.MoveResult())
        #expect(!exists(new.root))
        #expect(!exists(empty.root) && !exists(parent), "an empty old library is still tidied away")
    }

    @Test("a new library that can't be written keeps every theme in the old one")
    func newLibraryUnwritable() throws {
        let old = try oldLibrary(themes: ["Night Sky", "Dawn"])
        let ids = old.list().map(\.id).sorted()
        // Stands in for macOS refusing access to Documents: the new folder can't be made.
        let locked = try tempDir("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        let new = ThemeLibrary(root: locked.appendingPathComponent("Mactoy Themes"), discard: .delete)

        let result = new.moveThemes(from: old.root, thenRemoveIfEmpty: old.root.deletingLastPathComponent())

        #expect(result.notMoved == ids)
        #expect(result.moved.isEmpty)
        #expect(old.list().map(\.id).sorted() == ids)
        #expect(old.list().allSatisfy { listing(old.directory(for: $0)) == [".mactoy-library.json", "bg.png", "font.pf2", "icons/a.png", "theme.txt"] })
    }

    @Test("themes the library lets go of go to the Trash unless told otherwise")
    func discardsToTrashByDefault() {
        #expect(ThemeLibrary().discard == .trash)
        #expect(ThemeLibrary(root: URL(fileURLWithPath: "/nowhere")).discard == .trash)
    }

    @Test("a folder macOS won't let Mactoy read is told apart from an empty or missing one")
    func unreadable() throws {
        let lib = try library()
        #expect(!lib.isUnreadable(), "missing")
        try lib.save(folder: themeFolder(), name: "Night Sky", settings: settings, origin: "Added from a file")
        #expect(!lib.isUnreadable())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lib.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lib.root.path) }
        #expect(lib.list().isEmpty)
        #expect(lib.isUnreadable())
    }

    @Test("the id a save would give is worked out without writing to the library")
    func idIfSaving() throws {
        let lib = try library()
        let folder = try themeFolder()
        let id = try ThemeLibrary.id(ifSaving: folder, name: "Night Sky", settings: settings)
        #expect(!exists(lib.root))
        #expect(try lib.save(folder: folder, name: "Night Sky", settings: settings, origin: "Added from a file").id == id)
        #expect(try ThemeLibrary.id(ifSaving: folder, name: "Night Sky", settings: .init(file: "theme.txt", gfxmode: "1024x768")) != id)
    }

    @Test("an old library that is a link is never read through")
    func oldRootIsALink() throws {
        let real = try oldLibrary(themes: ["Night Sky"])
        let link = try tempDir("support").appendingPathComponent("My Themes")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real.root)
        let new = try library()
        #expect(new.moveThemes(from: link) == ThemeLibrary.MoveResult())
        #expect(real.list().count == 1)
        #expect(!exists(new.root))
    }
}
