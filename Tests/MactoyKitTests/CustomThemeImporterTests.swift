import Foundation
import Testing
@testable import MactoyKit

@Suite("Custom theme import")
struct CustomThemeImporterTests {

    private func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-import-\(UUID().uuidString)") }

    private func listing(_ dir: URL) -> [String] {
        let base = dir.standardizedFileURL.path + "/"
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])!
        return e.compactMap { ($0 as? URL).flatMap { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true ? String($0.standardizedFileURL.path.dropFirst(base.count)) : nil } }.sorted()
    }

    private func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Zips `folder` (relative to `work`) with zip(1); `keepLinks` stores symlinks as links.
    private func zipUp(_ folder: String, in work: URL, as name: String = "theme.zip", keepLinks: Bool = false) throws -> URL {
        let zip = work.appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = work
        p.arguments = [keepLinks ? "-qry" : "-qr", zip.path, folder]
        try p.run(); p.waitUntilExit()
        return zip
    }

    // MARK: folders and ZIPs

    @Test("folder with theme.txt at the top")
    func folder() throws {
        let src = tempDir().appendingPathComponent("My Cool Theme!")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("desktop-image: \"bg.png\"\n".utf8).write(to: src.appendingPathComponent("theme.txt"))
        try Data([1]).write(to: src.appendingPathComponent("bg.png"))
        try Data([2]).write(to: src.appendingPathComponent("b.pf2"))
        try Data([3]).write(to: src.appendingPathComponent("a.pf2"))
        try Data("menuentry".utf8).write(to: src.appendingPathComponent("ventoy_grub.cfg"))
        let cache = tempDir()
        let imported = try CustomThemeImporter.importTheme(from: src, cacheRoot: cache)
        #expect(imported.id == "custom-my-cool-theme")
        #expect(imported.name == "My Cool Theme!")
        #expect(imported.settings.fonts == ["a.pf2", "b.pf2"])
        #expect(imported.previewImage?.lastPathComponent == "bg.png")
        #expect(imported.skippedFiles == ["ventoy_grub.cfg"])
        #expect(listing(imported.directory) == ["a.pf2", "b.pf2", "bg.png", "theme.txt"])
        let again = try CustomThemeImporter.importTheme(from: src, cacheRoot: cache)
        #expect(again.directory == imported.directory)
        #expect(again.skippedFiles == ["ventoy_grub.cfg"])
    }

    @Test("zip with one theme in a subfolder")
    func zipSubfolder() throws {
        let work = tempDir()
        let theme = work.appendingPathComponent("pack/nice-theme")
        try FileManager.default.createDirectory(at: theme, withIntermediateDirectories: true)
        try Data("title-text: \"\"\n".utf8).write(to: theme.appendingPathComponent("theme.txt"))
        let zip = try zipUp("pack", in: work, as: "nice.zip")
        let imported = try CustomThemeImporter.importTheme(from: zip, cacheRoot: tempDir())
        #expect(imported.id == "custom-nice-theme")
        #expect(imported.name == "nice-theme")
        #expect(imported.previewImage == nil)
        #expect(imported.settings.fonts == nil)
        #expect(listing(imported.directory) == ["theme.txt"])
    }

    @Test("a zip with the theme at its top is named after the zip file")
    func zipTop() throws {
        let work = tempDir()
        try write("title-text: \"\"\n", to: work.appendingPathComponent("src/theme.txt"))
        try write("x", to: work.appendingPathComponent("src/bg.png"))
        let zip = work.appendingPathComponent("My Theme.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = work.appendingPathComponent("src")
        p.arguments = ["-qr", zip.path, "theme.txt", "bg.png"]
        try p.run(); p.waitUntilExit()
        let imported = try CustomThemeImporter.importTheme(from: zip, cacheRoot: tempDir())
        #expect(imported.id == "custom-my-theme")
        #expect(imported.name == "My Theme")
        #expect(listing(imported.directory) == ["bg.png", "theme.txt"])
    }

    @Test("ambiguous and empty sources are refused")
    func refusals() throws {
        let fixture = try #require(Bundle.module.url(forResource: "Fixtures/theme-sample", withExtension: "zip"))
        #expect(throws: ThemeError.ambiguousThemes(["pack/mytheme/theme.txt", "pack/other/theme.txt"])) {
            _ = try CustomThemeImporter.importTheme(from: fixture, cacheRoot: tempDir())
        }
        let empty = tempDir()
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: ThemeError.noThemeFile) { _ = try CustomThemeImporter.importTheme(from: empty, cacheRoot: tempDir()) }
    }

    @Test("a zip with no theme.txt is refused")
    func zipWithoutTheme() throws {
        let work = tempDir()
        try write("x", to: work.appendingPathComponent("pack/bg.png"))
        let zip = try zipUp("pack", in: work)
        #expect(throws: ThemeError.noThemeFile) { _ = try CustomThemeImporter.importTheme(from: zip, cacheRoot: tempDir()) }
    }

    @Test("the shallowest theme.txt wins when depths differ")
    func shallowestWins() throws {
        let work = tempDir()
        try write("a", to: work.appendingPathComponent("pack/theme.txt"))
        try write("b", to: work.appendingPathComponent("pack/old/theme.txt"))
        let zip = try zipUp("pack", in: work)
        let imported = try CustomThemeImporter.importTheme(from: zip, cacheRoot: tempDir())
        #expect(imported.id == "custom-pack")
        #expect(listing(imported.directory) == ["old/theme.txt", "theme.txt"])
    }

    // MARK: size and unreadable input

    @Test("a zip over 64 MiB is refused before it is read")
    func oversizedZip() throws {
        let work = tempDir()
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let big = work.appendingPathComponent("big.zip")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(CustomThemeImporter.maxZipBytes + 1))   // sparse: costs no disk
        try handle.close()
        // The contents aren't a ZIP, so reading it first would give a different error.
        #expect(throws: ThemeError.downloadTooLarge(CustomThemeImporter.maxZipBytes + 1)) {
            _ = try CustomThemeImporter.importTheme(from: big, cacheRoot: tempDir())
        }
    }

    @Test("a file that isn't a zip is an error with a reason, and leaves nothing behind")
    func notAZip() throws {
        let work = tempDir()
        let junk = work.appendingPathComponent("junk.zip")
        try write("this is not a zip", to: junk)
        let scratch = tempDir()
        let cache = tempDir()
        do {
            _ = try CustomThemeImporter.importTheme(from: junk, cacheRoot: cache, workRoot: scratch)
            Issue.record("expected the import to fail")
        } catch ThemeError.unreadableArchive(let reason) {
            #expect(!reason.isEmpty)
            #expect(!reason.contains("\n"))
            #expect(!reason.contains(scratch.path))
        } catch {
            Issue.record("wrong error: \(error)")
        }
        #expect(names(in: scratch).isEmpty)
        #expect(names(in: cache).isEmpty)
    }

    @Test("unpack failures read as one short line without our temp paths")
    func reasons() {
        func reason(_ status: Int32, _ stderr: String) -> String {
            CustomThemeImporter.shortReason(DriverError.subprocess("/usr/bin/ditto -x -k a b", status, stderr), hiding: ["/private/var/T/mactoy-unzip-1", "/var/T/mactoy-unzip-1"])
        }
        #expect(reason(-1, "timeout after 60.0s") == "it took too long to unpack")
        #expect(reason(1, "ditto: Couldn't read PKZip archive\nditto: Unknown compression type\n") == "Couldn't read PKZip archive")
        #expect(reason(1, "ditto: /private/var/T/mactoy-unzip-1/unpacked/pack/dir/x.png: Not a directory") == "pack/dir/x.png: Not a directory")
        #expect(reason(1, "") == "unpacking failed with status 1")
        #expect(reason(1, String(repeating: "x", count: 500)).count == 120)
        #expect(CustomThemeImporter.shortReason(CocoaError(.fileNoSuchFile), hiding: []).isEmpty == false)
    }

    @Test("a damaged zip is an error, not a crash")
    func damagedZip() throws {
        // Declares 1000 bytes but holds 3: the shape that traps SWCompression.
        let work = tempDir()
        let lying = ThemeAssemblerTests.zip([.init(name: "t/theme.txt", data: Data([1, 2, 3]), declaredSize: 1000)])
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("lying.zip")
        try lying.write(to: zip)
        #expect(throws: ThemeError.self) { _ = try CustomThemeImporter.importTheme(from: zip, cacheRoot: tempDir()) }
        // A real ZIP cut off in the middle of a file (random bytes, so they can't compress away).
        try write("title-text: \"\"\n", to: work.appendingPathComponent("pack/theme.txt"))
        try Data((0..<20_000).map { _ in UInt8.random(in: 0...255) }).write(to: work.appendingPathComponent("pack/bg.png"))
        let whole = try Data(contentsOf: try zipUp("pack", in: work))
        let cut = work.appendingPathComponent("cut.zip")
        try whole.prefix(whole.count / 2).write(to: cut)
        do {
            _ = try CustomThemeImporter.importTheme(from: cut, cacheRoot: tempDir())
            Issue.record("expected the cut-off zip to be refused")
        } catch ThemeError.unreadableArchive(let reason) {
            #expect(!reason.isEmpty)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    // MARK: hostile archives

    /// Where an escaped file could land, relative to a ZIP at `zipDir`, a cache and a scratch area.
    private func expectNoEscapes(tag: String, root: URL, zipDir: URL, scratch: URL, cache: URL) {
        let escapes = ["escape-\(tag).png", "escape2-\(tag).png", "escape3-\(tag).png", "escape4-\(tag).png", "pwn-\(tag).png"]
        let places = [zipDir, zipDir.deletingLastPathComponent(), root, scratch, cache, cache.deletingLastPathComponent(),
                      URL(fileURLWithPath: "/tmp"), FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/")]
        for place in places {
            for name in escapes {
                #expect(!FileManager.default.fileExists(atPath: place.appendingPathComponent(name).path), "\(name) in \(place.path)")
            }
        }
    }

    @Test("entry names that climb out of the unpack folder are neutralised")
    func hostileNames() throws {
        let tag = UUID().uuidString
        let root = tempDir()
        let zipDir = root.appendingPathComponent("a/b/zips")
        let scratch = root.appendingPathComponent("scratch")           // the importer's temp area
        let cache = root.appendingPathComponent("cache")
        for dir in [zipDir, scratch] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let zip = zipDir.appendingPathComponent("hostile.zip")
        try ThemeAssemblerTests.zip([
            .init(name: "pack/theme.txt", data: Data("title-text: \"\"\n".utf8)),
            .init(name: "pack/a.png", data: Data([1])),
            .init(name: "../escape-\(tag).png", data: Data([9])),
            .init(name: "pack/../../escape2-\(tag).png", data: Data([9])),
            .init(name: "../../../../../../../../tmp/escape3-\(tag).png", data: Data([9])),
            .init(name: "/escape4-\(tag).png", data: Data([9])),
        ]).write(to: zip)

        let imported = try CustomThemeImporter.importTheme(from: zip, cacheRoot: cache, workRoot: scratch)
        #expect(listing(imported.directory) == ["a.png", "theme.txt"])
        #expect(imported.skippedFiles.isEmpty)
        #expect(names(in: scratch).isEmpty, "the unpack area is removed afterwards")
        #expect(names(in: cache) == [imported.directory.lastPathComponent])
        expectNoEscapes(tag: tag, root: root, zipDir: zipDir, scratch: scratch, cache: cache)
    }

    @Test("a link stored in a zip is not followed, by name or by a file written under it")
    func hostileLinks() throws {
        let tag = UUID().uuidString
        let root = tempDir()
        let outside = root.appendingPathComponent("outside")          // where a link points
        let zipDir = root.appendingPathComponent("zips")
        let scratch = root.appendingPathComponent("scratch")
        let cache = root.appendingPathComponent("cache")
        for dir in [outside, zipDir, scratch] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let base: [ThemeAssemblerTests.ZipPart] = [
            .init(name: "pack/theme.txt", data: Data("title-text: \"\"\n".utf8)),
            .init(name: "pack/a.png", data: Data([1])),
            .init(name: "pack/hosts.png", data: Data("/etc/hosts".utf8), mode: 0o120777),
            .init(name: "pack/dir", data: Data(outside.path.utf8), mode: 0o120777),
        ]
        // The links themselves are left out.
        let plain = zipDir.appendingPathComponent("links.zip")
        try ThemeAssemblerTests.zip(base).write(to: plain)
        let imported = try CustomThemeImporter.importTheme(from: plain, cacheRoot: cache, workRoot: scratch)
        #expect(listing(imported.directory) == ["a.png", "theme.txt"])
        #expect(imported.skippedFiles.isEmpty)

        // A file listed after a link to a folder must not be written through it. The
        // unpacker may refuse this archive or import part of it; either is fine.
        let through = zipDir.appendingPathComponent("through.zip")
        try ThemeAssemblerTests.zip(base + [.init(name: "pack/dir/pwn-\(tag).png", data: Data([9]))]).write(to: through)
        _ = try? CustomThemeImporter.importTheme(from: through, cacheRoot: cache, workRoot: scratch)
        #expect(names(in: outside).isEmpty, "nothing was written through the link")
        #expect(names(in: scratch).isEmpty, "the unpack area is removed afterwards")
        expectNoEscapes(tag: tag, root: root, zipDir: zipDir, scratch: scratch, cache: cache)
    }

    @Test("a real symlink stored in a zip does not reach the imported theme")
    func zipSymlink() throws {
        let work = tempDir()
        try write("title-text: \"\"\n", to: work.appendingPathComponent("pack/theme.txt"))
        try write("x", to: work.appendingPathComponent("pack/a.png"))
        try FileManager.default.createSymbolicLink(atPath: work.appendingPathComponent("pack/hosts.png").path, withDestinationPath: "/etc/hosts")
        let zip = try zipUp("pack", in: work, keepLinks: true)
        let imported = try CustomThemeImporter.importTheme(from: zip, cacheRoot: tempDir())
        #expect(listing(imported.directory) == ["a.png", "theme.txt"])
        #expect(imported.skippedFiles.isEmpty)
    }

    @Test("a folder's symlinks are left out too")
    func folderSymlink() throws {
        let src = tempDir().appendingPathComponent("linky")
        try write("title-text: \"\"\n", to: src.appendingPathComponent("theme.txt"))
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("hosts.png").path, withDestinationPath: "/etc/hosts")
        let imported = try CustomThemeImporter.importTheme(from: src, cacheRoot: tempDir())
        #expect(listing(imported.directory) == ["theme.txt"])
    }

    @Test("a link to a theme folder imports the folder it points to")
    func linkedFolder() throws {
        let work = tempDir()
        try write("title-text: \"\"\n", to: work.appendingPathComponent("real/theme.txt"))
        let link = work.appendingPathComponent("Shortcut")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: work.appendingPathComponent("real").path)
        let imported = try CustomThemeImporter.importTheme(from: link, cacheRoot: tempDir())
        #expect(imported.id == "custom-shortcut")
        #expect(listing(imported.directory) == ["theme.txt"])
    }

    @Test("the unpack folder is private")
    func privateWorkFolder() throws {
        let scratch = tempDir()
        let dir = try CustomThemeImporter.makePrivateDirectory(in: scratch)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(dir.deletingLastPathComponent().standardizedFileURL == scratch.standardizedFileURL)
        // A second call makes a different folder.
        #expect(try CustomThemeImporter.makePrivateDirectory(in: scratch) != dir)
    }

    // MARK: cache

    @Test("re-importing identical content gives the same folder, untouched")
    func reimportSame() throws {
        let work = tempDir()
        try write("desktop-image: \"bg.png\"\n", to: work.appendingPathComponent("pack/theme.txt"))
        try write("x", to: work.appendingPathComponent("pack/bg.png"))
        try write("menuentry", to: work.appendingPathComponent("pack/ventoy_grub.cfg"))
        let zip = try zipUp("pack", in: work)
        let cache = tempDir()
        let first = try CustomThemeImporter.importTheme(from: zip, cacheRoot: cache)
        let inode = try FileManager.default.attributesOfItem(atPath: first.directory.path)[.systemFileNumber] as? Int
        let second = try CustomThemeImporter.importTheme(from: zip, cacheRoot: cache)
        #expect(second == first)
        #expect(try FileManager.default.attributesOfItem(atPath: second.directory.path)[.systemFileNumber] as? Int == inode)
        #expect(names(in: cache) == [first.directory.lastPathComponent])
        // The same files as a plain folder land in the same place.
        let asFolder = try CustomThemeImporter.importTheme(from: work.appendingPathComponent("pack"), cacheRoot: cache)
        #expect(asFolder.directory == first.directory)
    }

    @Test("changed content gets its own folder")
    func reimportChanged() throws {
        let src = tempDir().appendingPathComponent("evolving")
        try write("title-text: \"\"\n", to: src.appendingPathComponent("theme.txt"))
        let cache = tempDir()
        let v1 = try CustomThemeImporter.importTheme(from: src, cacheRoot: cache)
        try write("title-text: \"hi\"\n", to: src.appendingPathComponent("theme.txt"))
        let v2 = try CustomThemeImporter.importTheme(from: src, cacheRoot: cache)
        #expect(v1.id == v2.id)
        #expect(v1.directory != v2.directory)
        #expect(try String(contentsOf: v1.directory.appendingPathComponent("theme.txt"), encoding: .utf8) == "title-text: \"\"\n")
    }

    @Test("a damaged cached folder is rebuilt in place")
    func damagedCache() throws {
        let src = tempDir().appendingPathComponent("fragile")
        try write("title-text: \"\"\n", to: src.appendingPathComponent("theme.txt"))
        try write("x", to: src.appendingPathComponent("bg.png"))
        let cache = tempDir()
        let first = try CustomThemeImporter.importTheme(from: src, cacheRoot: cache)
        try FileManager.default.removeItem(at: first.directory.appendingPathComponent("bg.png"))
        try write("not part of the theme", to: first.directory.appendingPathComponent("extra.txt"))
        let again = try CustomThemeImporter.importTheme(from: src, cacheRoot: cache)
        #expect(again.directory == first.directory)
        #expect(listing(again.directory) == ["bg.png", "theme.txt"])
        #expect(names(in: cache) == [first.directory.lastPathComponent])
    }

    @Test("a file's path and bytes can't be shifted across their boundary to land on the same folder")
    func digestFraming() throws {
        let cache = tempDir()
        let a = tempDir().appendingPathComponent("same")
        let b = tempDir().appendingPathComponent("same")
        try write("t", to: a.appendingPathComponent("theme.txt"))
        try write("xb.png", to: a.appendingPathComponent("a.png"))
        try write("t", to: b.appendingPathComponent("theme.txt"))
        try write("", to: b.appendingPathComponent("a.pngxb.png"))   // "a.png"+"xb.png" and "a.pngxb.png"+"" read alike
        let one = try CustomThemeImporter.importTheme(from: a, cacheRoot: cache)
        let two = try CustomThemeImporter.importTheme(from: b, cacheRoot: cache)
        #expect(one.directory != two.directory)
    }

    // MARK: names and preview

    @Test("ids always satisfy the installer's rule")
    func ids() {
        let rule = #"^[a-z0-9][a-z0-9-]{1,59}$"#
        let names = ["My Cool Theme!", "!!!", "", "   ", "日本語", "-", "a", "A__B  C", "ÉCLAT", String(repeating: "x", count: 100),
                     String(repeating: "ab-", count: 30), "../../etc", ".hidden", "emoji 🎨 theme", "tab\tand\nnewline"]
        for name in names {
            let id = "custom-" + CustomThemeImporter.slug(name)
            #expect(ThemePath.matches(id, rule), "\(name.debugDescription) -> \(id)")
            #expect(CustomThemeImporter.slug(name).count <= 30)
        }
        #expect(CustomThemeImporter.slug("My Cool Theme!") == "my-cool-theme")
        #expect(CustomThemeImporter.slug("!!!") == "theme")
        #expect(CustomThemeImporter.slug("A__B  C") == "a-b-c")
        #expect(!CustomThemeImporter.slug(String(repeating: "ab-", count: 30)).hasSuffix("-"))
    }

    @Test("a folder named only with symbols still imports")
    func symbolName() throws {
        let src = tempDir().appendingPathComponent("★★★")
        try write("title-text: \"\"\n", to: src.appendingPathComponent("theme.txt"))
        let imported = try CustomThemeImporter.importTheme(from: src, cacheRoot: tempDir())
        #expect(imported.id == "custom-theme")
        #expect(imported.name == "★★★")
    }

    @Test("the preview comes from desktop-image, and only when the file is really there")
    func preview() throws {
        func theme(_ text: String, extra: [String] = []) throws -> CustomThemeImporter.Imported {
            let src = tempDir().appendingPathComponent("p")
            try write(text, to: src.appendingPathComponent("theme.txt"))
            for name in extra { try write("x", to: src.appendingPathComponent(name)) }
            return try CustomThemeImporter.importTheme(from: src, cacheRoot: tempDir())
        }
        #expect(try theme("desktop-image: \"bg.png\"\n", extra: ["bg.png"]).previewImage?.lastPathComponent == "bg.png")
        #expect(try theme("desktop-image : \"img/bg.jpg\"\n", extra: ["img/bg.jpg"]).previewImage?.lastPathComponent == "bg.jpg")
        // Named but missing, a comment, or no desktop-image at all.
        #expect(try theme("desktop-image: \"gone.png\"\n").previewImage == nil)
        #expect(try theme("# desktop-image: \"bg.png\"\n", extra: ["bg.png"]).previewImage == nil)
        #expect(try theme("title-text: \"\"\n", extra: ["bg.png"]).previewImage == nil)
        // A path that climbs out is never followed.
        #expect(try theme("desktop-image: \"../bg.png\"\n", extra: ["bg.png"]).previewImage == nil)
        #expect(try theme("desktop-image: \"/etc/hosts\"\n").previewImage == nil)
        // A file type the assembler drops can't be the preview.
        #expect(try theme("desktop-image: \"bg.gif\"\n", extra: ["bg.gif"]).previewImage == nil)
    }
}
