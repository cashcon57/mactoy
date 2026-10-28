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
        #expect(throws: ThemeError.fileTooLarge(CustomThemeImporter.maxZipBytes + 1)) {
            _ = try CustomThemeImporter.importTheme(from: big, cacheRoot: tempDir())
        }
    }

    @Test("the refusal of a big file the user picked doesn't talk about a download")
    func oversizedZipWording() {
        let message = ThemeError.fileTooLarge(CustomThemeImporter.maxZipBytes + 1).errorDescription
        #expect(message == "That file is too large to be a theme (65 MB).")
        #expect(ThemeError.fileTooLarge(200 * 1_048_576).errorDescription == "That file is too large to be a theme (200 MB).")
        #expect(message?.localizedCaseInsensitiveContains("download") == false)
        // A real download still says what it is.
        #expect(ThemeError.downloadTooLarge(70 * 1_048_576).errorDescription == "The theme download is too large (70 MB).")
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
            #expect(reason == "it doesn't look like a ZIP file")
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
        #expect(reason(-1, "timeout after 60.0s") == "it took too long to read")
        #expect(reason(1, "ditto: Couldn't read PKZip archive\nditto: Unknown compression type\n") == "Couldn't read PKZip archive")
        #expect(reason(1, "ditto: /private/var/T/mactoy-unzip-1/unpacked/pack/dir/x.png: Not a directory") == "pack/dir/x.png: Not a directory")
        #expect(reason(1, "") == "unpacking failed with status 1")
        #expect(reason(1, String(repeating: "x", count: 500)).count == 120)
        #expect(CustomThemeImporter.shortReason(CocoaError(.fileNoSuchFile), hiding: []).isEmpty == false)
    }

    // MARK: the file list that is checked before anything is unpacked

    /// Real `zipinfo -l` output, trimmed: a Unix archive, then a Windows one (7-character modes).
    private let unixListing = """
        Archive:  /tmp/real.zip
        Zip file size: 1706 bytes, number of entries: 4
        drwxr-xr-x  3.0 unx        0 bx        0 stor 26-Oct-26 19:17 pack/
        -rw-r--r--  3.0 unx       15 tx       15 stor 26-Oct-26 19:17 pack/theme.txt
        lrwxr-xr-x  3.0 unx       10 bx       10 stor 26-Oct-26 19:17 pack/my link.png
        -rw-r--r--  3.0 unx 209715200 bx   203529 defN 26-Oct-26 19:30 pack/big file.png
        4 files, 209715225 bytes uncompressed, 203554 bytes compressed:  99.9%

        """
    private let windowsListing = """
        Archive:  fat.zip
        Zip file size: 613 bytes, number of entries: 2
        -rw-a--     2.0 fat        3 b-        3 stor 80-Jan-01 00:00 fat/theme.txt
        drwx---     2.0 fat        0 b-        0 stor 80-Jan-01 00:00 fat/dir/
        2 files, 3 bytes uncompressed, 3 bytes compressed:  0.0%
        """

    private func listed(_ sizes: [Int], names: [String]? = nil) -> [CustomThemeImporter.ListedEntry] {
        sizes.enumerated().map { .init(name: names?[$0.offset] ?? "t/\($0.offset).png", size: $0.element) }
    }

    @Test("zipinfo output is read into names and sizes")
    func parseListing() throws {
        let entries = try CustomThemeImporter.parseListing(unixListing)
        #expect(entries.map(\.name) == ["pack/", "pack/theme.txt", "pack/my link.png", "pack/big file.png"])
        #expect(entries.map(\.size) == [0, 15, 10, 209_715_200])
        let windows = try CustomThemeImporter.parseListing(windowsListing)
        #expect(windows == [.init(name: "fat/theme.txt", size: 3), .init(name: "fat/dir/", size: 0)])
        // No entries, with or without zipinfo's "Empty zipfile." line.
        #expect(try CustomThemeImporter.parseListing("Archive:  e.zip\nZip file size: 22 bytes, number of entries: 0\nEmpty zipfile.\n").isEmpty)
        // Sizes too big for an Int are read as the biggest Int, so they still trip the limit.
        let huge = "Zip file size: 9 bytes, number of entries: 1\n-rw-r--r--  4.5 unx 18446744073709551615 bx 5 defN 26-Oct-26 19:30 x.png\n"
        #expect(try CustomThemeImporter.parseListing(huge).first?.size == Int.max)
    }

    @Test("a listing that can't be read is refused")
    func unparsableListing() {
        let lines = unixListing.split(separator: "\n", omittingEmptySubsequences: false)
        let cases = [
            "",                                                                   // nothing
            "Archive:  x.zip\n",                                                   // no header
            "Zip file size: 9 bytes, number of entries: many\n",                   // count isn't a number
            lines.filter { !$0.contains("pack/theme.txt") }.joined(separator: "\n"),          // fewer lines than it declares
            lines.joined(separator: "\n").replacingOccurrences(of: "number of entries: 4", with: "number of entries: 3"),
            lines.joined(separator: "\n").replacingOccurrences(of: "tx       15 stor", with: "tx   fifteen stor"),   // a size that isn't a number
            unixListing.replacingOccurrences(of: "4 files,", with: "extra line that is not an entry\n4 files,"),
            "Zip file size: 9 bytes, number of entries: 1\nnot an entry at all\n",
        ]
        for text in cases {
            #expect(throws: ThemeError.self, "\(text)") { _ = try CustomThemeImporter.parseListing(text) }
        }
    }

    @Test("a listing over the file-count or size limits is refused")
    func listingLimits() throws {
        let cap = ThemeAssembler.maxFiles * 2
        try CustomThemeImporter.checkListing(listed(Array(repeating: 1, count: cap)))
        #expect(throws: ThemeError.tooManyFiles(cap + 1)) { try CustomThemeImporter.checkListing(listed(Array(repeating: 1, count: cap + 1))) }

        let limit = ThemeAssembler.maxUnpackedBytes
        try CustomThemeImporter.checkListing(listed([limit - 10, 10]))
        #expect(throws: ThemeError.themeTooLarge(limit + 1)) { try CustomThemeImporter.checkListing(listed([limit - 10, 11])) }
        // The bomb shape: one small archive that declares 200 MiB.
        #expect(throws: ThemeError.themeTooLarge(209_715_200)) { try CustomThemeImporter.checkListing(listed([209_715_200])) }
        // Declared sizes that would wrap a sum.
        #expect(throws: ThemeError.themeTooLarge(Int.max)) { try CustomThemeImporter.checkListing(listed([Int.max, Int.max])) }
        #expect(throws: ThemeError.themeTooLarge(Int.max)) { try CustomThemeImporter.checkListing(listed([Int.max])) }
    }

    @Test("absolute names and .. components are refused; dots inside a name are fine")
    func listingNames() throws {
        for name in ["../x.png", "pack/../../x.png", "pack/..", "..", "/x.png", "/", "a/b/../c.png", "../"] {
            #expect(throws: ThemeError.unreadableArchive("it has unsafe file names"), "\(name)") {
                try CustomThemeImporter.checkListing(listed([1, 1], names: ["pack/theme.txt", name]))
            }
        }
        try CustomThemeImporter.checkListing(listed([1, 1, 1, 1, 1, 1, 1], names: ["pack/", "pack/theme.txt", "a..b.png", "...", "..hidden.png", "pack/x..", "./pack/a.png"]))
        try CustomThemeImporter.checkListing([])
    }

    @Test("a bomb-shaped zip is refused from its file list, before anything is unpacked")
    func bombZip() throws {
        let work = tempDir()
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        // 200 MiB of zeros (sparse, so it costs no disk) packs to about 200 KB.
        let zeros = work.appendingPathComponent("zeros.png")
        FileManager.default.createFile(atPath: zeros.path, contents: nil)
        let handle = try FileHandle(forWritingTo: zeros)
        try handle.truncate(atOffset: 200 * 1024 * 1024)
        try handle.close()
        let zip = try zipUp("zeros.png", in: work, as: "bomb.zip")
        let packed = (try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? .max
        #expect(packed < CustomThemeImporter.maxZipBytes)
        let scratch = work.appendingPathComponent("scratch")
        #expect(throws: ThemeError.themeTooLarge(200 * 1024 * 1024)) {
            _ = try CustomThemeImporter.importTheme(from: zip, cacheRoot: work.appendingPathComponent("cache"), workRoot: scratch)
        }
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
    }

    @Test("declared sizes are checked before ditto runs, links included")
    func declaredBeforeUnpacking() throws {
        // A link whose entry claims 300 MiB. ditto would fail on this archive; the size error can only come from the list.
        let work = tempDir()
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("claims.zip")
        try ThemeAssemblerTests.zip([
            .init(name: "pack/theme.txt", data: Data("t".utf8)),
            .init(name: "pack/l.png", data: Data("/etc/hosts".utf8), declaredSize: 300 * 1024 * 1024, mode: 0o120777),
        ]).write(to: zip)
        #expect(throws: ThemeError.themeTooLarge(300 * 1024 * 1024 + 1)) {
            _ = try CustomThemeImporter.importTheme(from: zip, cacheRoot: tempDir(), workRoot: tempDir())
        }
    }

    @Test("an archive with no entries has no theme")
    func emptyZip() throws {
        let work = tempDir()
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("empty.zip")
        try ThemeAssemblerTests.zip([]).write(to: zip)
        #expect(throws: ThemeError.noThemeFile) { _ = try CustomThemeImporter.importTheme(from: zip, cacheRoot: tempDir()) }
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

    @Test("entry names that climb out of the unpack folder are refused before anything is unpacked")
    func hostileNames() throws {
        let tag = UUID().uuidString
        let root = tempDir()
        let zipDir = root.appendingPathComponent("a/b/zips")
        let scratch = root.appendingPathComponent("scratch")           // the importer's temp area
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: zipDir, withIntermediateDirectories: true)
        let bad = ["../escape-\(tag).png", "pack/../../escape2-\(tag).png", "../../../../../../../../tmp/escape3-\(tag).png",
                   "/escape4-\(tag).png", "pack/..", "pack/../escape-\(tag).png"]
        for (i, name) in bad.enumerated() {
            let zip = zipDir.appendingPathComponent("hostile\(i).zip")
            try ThemeAssemblerTests.zip([
                .init(name: "pack/theme.txt", data: Data("title-text: \"\"\n".utf8)),
                .init(name: "pack/a.png", data: Data([1])),
                .init(name: name, data: Data([9])),
            ]).write(to: zip)
            do {
                _ = try CustomThemeImporter.importTheme(from: zip, cacheRoot: cache, workRoot: scratch)
                Issue.record("\(name) should have been refused")
            } catch ThemeError.unreadableArchive(let reason) {
                #expect(reason == "it has unsafe file names", "\(name)")
            } catch {
                Issue.record("wrong error for \(name): \(error)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: scratch.path), "nothing was unpacked")
        #expect(!FileManager.default.fileExists(atPath: cache.path))
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

    // MARK: any shape of download

    private let themeText = "title-text: \"\"\n"

    /// Writes `files` (text, by relative path) under `dir`.
    private func put(_ files: [(String, String)], in dir: URL) throws {
        for (path, text) in files { try write(text, to: dir.appendingPathComponent(path)) }
    }

    /// A ZIP with exactly these entries, in this order.
    private func zipFile(_ entries: [(String, String)], named name: String = "pack.zip", in work: URL) throws -> URL {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent(name)
        try ThemeAssemblerTests.zip(entries.map { .init(name: $0.0, data: Data($0.1.utf8)) }).write(to: zip)
        return zip
    }

    /// The kind of `ventoy.json` Diego Duarte's releases carry.
    private func duarteJSON(_ folder: String) -> String {
        """
        {
            "theme":{
                "file":[
                    "/ventoy/\(folder)/theme.txt",
                    "/ventoy/\(folder)/theme_legacy.txt"
                ],
                "default_file": 1,
                "resolution_fit": 1,
                "gfxmode": "1920x1080"
            }
        }
        """
    }

    @Test("1. a folder whose top level is the theme")
    func shapeFolderAtTop() throws {
        let src = tempDir().appendingPathComponent("Plain Theme")
        try put([("theme.txt", themeText), ("bg.png", "x"), ("icons/a.png", "y")], in: src)
        let imported = try CustomThemeImporter.importTheme(from: src, cacheRoot: tempDir())
        #expect(imported.name == "Plain Theme")
        #expect(imported.id == "custom-plain-theme")
        #expect(listing(imported.directory) == ["bg.png", "icons/a.png", "theme.txt"])
        #expect(imported.skippedFiles.isEmpty)
    }

    @Test("2. a folder with the theme nested below it, at any depth")
    func shapeFolderNested() throws {
        // What Diego Duarte's release looks like once unzipped, and the folder picked is its top.
        let src = tempDir().appendingPathComponent("ventoy-pop")
        try put([("ventoy/ventoy.json", duarteJSON("ventoy-pop")), ("ventoy/ventoy-pop/theme.txt", themeText),
                 ("ventoy/ventoy-pop/background.png", "x")], in: src)
        let imported = try CustomThemeImporter.importTheme(from: src, cacheRoot: tempDir())
        #expect(imported.name == "ventoy-pop")
        #expect(listing(imported.directory) == ["background.png", "theme.txt"])
        #expect(imported.skippedFiles.isEmpty)
        // Deeper still, with the picked folder's own name not mattering.
        let deep = tempDir().appendingPathComponent("Downloads")
        try put([("a/b/c/d/Deep Theme/theme.txt", themeText), ("a/b/c/d/Deep Theme/bg.png", "x"), ("a/readme.md", "hi")], in: deep)
        let found = try CustomThemeImporter.importTheme(from: deep, cacheRoot: tempDir())
        #expect(found.name == "Deep Theme")
        #expect(listing(found.directory) == ["bg.png", "theme.txt"])
    }

    @Test("3. a zip with theme.txt at the archive root")
    func shapeZipAtRoot() throws {
        let zip = try zipFile([("theme.txt", themeText), ("bg.png", "x"), ("icons/a.png", "y")], named: "Flat Pack.zip", in: tempDir())
        let imported = try CustomThemeImporter.importTheme(from: zip, cacheRoot: tempDir())
        #expect(imported.name == "Flat Pack")
        #expect(listing(imported.directory) == ["bg.png", "icons/a.png", "theme.txt"])
        #expect(imported.skippedFiles.isEmpty)
    }

    @Test("4. a zip with one top folder that holds the theme at its root")
    func shapeZipOneFolder() throws {
        let zip = try zipFile([("Folder Theme/theme.txt", themeText), ("Folder Theme/bg.png", "x"), ("Folder Theme/icons/a.png", "y")], in: tempDir())
        let imported = try CustomThemeImporter.importTheme(from: zip, cacheRoot: tempDir())
        #expect(imported.name == "Folder Theme")
        #expect(listing(imported.directory) == ["bg.png", "icons/a.png", "theme.txt"])
    }

    @Test("5. a zip with the theme nested deeper, as Diego Duarte's releases are")
    func shapeZipNested() throws {
        let zip = try zipFile([("ventoy/ventoy.json", duarteJSON("ventoy-blueprint")),
                               ("ventoy/ventoy-blueprint/theme.txt", "desktop-image: \"background.png\"\n"),
                               ("ventoy/ventoy-blueprint/theme_legacy.txt", themeText),
                               ("ventoy/ventoy-blueprint/background.png", "x")], named: "ventoy_blueprint.zip", in: tempDir())
        let imported = try CustomThemeImporter.importTheme(from: zip, cacheRoot: tempDir())
        #expect(imported.name == "ventoy-blueprint")
        #expect(imported.id == "custom-ventoy-blueprint")
        #expect(listing(imported.directory) == ["background.png", "theme.txt", "theme_legacy.txt"])
        #expect(imported.previewImage?.lastPathComponent == "background.png")
        #expect(imported.skippedFiles.isEmpty)
    }

    @Test("6. Finder's __MACOSX copy and ._ files are never a theme, never copied and never reported")
    func shapeFinderZip() throws {
        let junk: [(String, String)] = [("__MACOSX/Pack/._theme.txt", "a"), ("__MACOSX/Pack/._bg.png", "b"), ("Pack/.DS_Store", "c"),
                                        ("__MACOSX/._Pack", "d"), ("__MACOSX/theme.txt", themeText)]
        let clean = try CustomThemeImporter.importTheme(
            from: try zipFile([("Pack/theme.txt", themeText), ("Pack/bg.png", "x")], named: "clean.zip", in: tempDir()), cacheRoot: tempDir())
        let finder = try CustomThemeImporter.importTheme(
            from: try zipFile([("Pack/theme.txt", themeText), ("Pack/bg.png", "x")] + junk, named: "finder.zip", in: tempDir()), cacheRoot: tempDir())
        // The look-alike theme.txt under __MACOSX isn't a second theme.
        #expect(finder.name == "Pack")
        #expect(listing(finder.directory) == ["bg.png", "theme.txt"])
        #expect(finder.skippedFiles.isEmpty)
        // Same name, same digest: the junk changed nothing.
        #expect(finder.directory.lastPathComponent == clean.directory.lastPathComponent)

        // Files compressed together put the theme at the root of the archive, where the junk sits beside it.
        let flatJunk: [(String, String)] = [("__MACOSX/._theme.txt", "a"), ("__MACOSX/._bg.png", "b"), (".DS_Store", "c"), ("._bg.png", "d")]
        let flat = try CustomThemeImporter.importTheme(
            from: try zipFile([("theme.txt", themeText), ("bg.png", "x")] + flatJunk, named: "Flat.zip", in: tempDir()), cacheRoot: tempDir())
        let flatClean = try CustomThemeImporter.importTheme(
            from: try zipFile([("theme.txt", themeText), ("bg.png", "x")], named: "Flat.zip", in: tempDir()), cacheRoot: tempDir())
        #expect(flat.name == "Flat")
        #expect(listing(flat.directory) == ["bg.png", "theme.txt"])
        #expect(flat.skippedFiles.isEmpty)
        #expect(flat.directory.lastPathComponent == flatClean.directory.lastPathComponent)

        // Nothing but junk is no theme.
        let onlyJunk = try zipFile([("__MACOSX/Pack/theme.txt", themeText), ("__MACOSX/Pack/._theme.txt", "a")], named: "junk.zip", in: tempDir())
        #expect(throws: ThemeError.noThemeFile) { _ = try CustomThemeImporter.importTheme(from: onlyJunk, cacheRoot: tempDir()) }
    }

    @Test("6. a ZIP that Finder's own tool makes, with real extended attributes")
    func shapeRealFinderZip() throws {
        let work = tempDir()
        let pack = work.appendingPathComponent("Pack")
        try put([("theme.txt", themeText), ("bg.png", "x")], in: pack)
        // An extended attribute is what makes the archiver write a __MACOSX/._ copy.
        for name in ["theme.txt", "bg.png"] {
            let status = pack.appendingPathComponent(name).path.withCString { path in
                "mactoy-test".withCString { value in setxattr(path, "com.mactoy.test", value, 11, 0, 0) }
            }
            try #require(status == 0)
        }
        try Data("junk".utf8).write(to: pack.appendingPathComponent(".DS_Store"))
        let zip = work.appendingPathComponent("Pack.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", pack.path, zip.path]
        try p.run(); p.waitUntilExit()
        let entries = try CustomThemeImporter.parseListing(try Subprocess.run("/usr/bin/zipinfo", ["-l", zip.path]).stdout).map(\.name)
        #expect(entries.contains { $0.hasPrefix("__MACOSX/") }, "the archive should hold a __MACOSX copy: \(entries)")

        let imported = try CustomThemeImporter.importTheme(from: zip, cacheRoot: tempDir())
        #expect(imported.name == "Pack")
        #expect(listing(imported.directory) == ["bg.png", "theme.txt"])
        #expect(imported.skippedFiles.isEmpty)
    }

    @Test("6. a picked folder's .DS_Store, ._ files and __MACOSX are left out and not reported")
    func shapeFolderJunk() throws {
        let src = tempDir().appendingPathComponent("Pack")
        try put([("theme.txt", themeText), ("bg.png", "x"), (".DS_Store", "c"), ("._bg.png", "d"), ("icons/.DS_Store", "e"),
                 ("__MACOSX/._theme.txt", "f")], in: src)
        let imported = try CustomThemeImporter.importTheme(from: src, cacheRoot: tempDir())
        #expect(listing(imported.directory) == ["bg.png", "theme.txt"])
        #expect(imported.skippedFiles.isEmpty)
    }

    @Test("a cloned repository's .git folder is not read")
    func shapeClonedRepository() throws {
        let src = tempDir().appendingPathComponent("grub-theme")
        try put([("theme.txt", themeText), ("bg.png", "x"), (".git/HEAD", "ref"), (".git/objects/ab/cdef", "blob")], in: src)
        let imported = try CustomThemeImporter.importTheme(from: src, cacheRoot: tempDir())
        #expect(listing(imported.directory) == ["bg.png", "theme.txt"])
        #expect(imported.skippedFiles.isEmpty)
        #expect(try ThemeAssembler.files(fromFolder: src).map(\.path).sorted() == ["bg.png", "theme.txt"])
    }

    @Test("7. picking the theme.txt file itself imports its folder")
    func shapePickThemeFile() throws {
        let src = tempDir().appendingPathComponent("Picked Theme")
        try put([("theme.txt", "desktop-image: \"bg.png\"\n"), ("bg.png", "x"), ("b.pf2", "f"), ("sub/a.png", "y")], in: src)
        let viaFile = try CustomThemeImporter.importTheme(from: src.appendingPathComponent("theme.txt"), cacheRoot: tempDir())
        let viaFolder = try CustomThemeImporter.importTheme(from: src, cacheRoot: tempDir())
        #expect(viaFile.name == "Picked Theme")
        #expect(viaFile.id == "custom-picked-theme")
        #expect(listing(viaFile.directory) == ["b.pf2", "bg.png", "sub/a.png", "theme.txt"])
        #expect(viaFile.settings.fonts == ["b.pf2"])
        #expect(viaFile.previewImage?.lastPathComponent == "bg.png")
        #expect(viaFile.directory.lastPathComponent == viaFolder.directory.lastPathComponent)
        // Other themes below it don't make it ambiguous: this one was named.
        try put([("more/theme.txt", themeText)], in: src)
        #expect(try CustomThemeImporter.importTheme(from: src.appendingPathComponent("theme.txt"), cacheRoot: tempDir()).name == "Picked Theme")
        // A link to the file reads the folder the file is really in.
        let link = tempDir().appendingPathComponent("theme.txt")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: src.appendingPathComponent("theme.txt"))
        #expect(try CustomThemeImporter.importTheme(from: link, cacheRoot: tempDir()).name == "Picked Theme")
    }

    @Test("7. any other .txt file is refused with a clear message")
    func shapeOtherTextFile() throws {
        let src = tempDir().appendingPathComponent("Pack")
        try put([("theme.txt", themeText)], in: src)
        for name in ["notes.txt", "README.TXT", "theme_legacy.txt", "README.md", "theme.7z"] {
            let file = src.appendingPathComponent(name)
            try write("x", to: file)
            #expect(throws: ThemeError.unsupportedSource, "\(name)") { _ = try CustomThemeImporter.importTheme(from: file, cacheRoot: tempDir()) }
        }
        #expect(ThemeError.unsupportedSource.errorDescription == "Choose the theme's folder, its .zip file, or its theme.txt.")
        // A ZIP is a ZIP whatever it is called; a file that is missing is still reported as an unreadable archive.
        let zip = try zipFile([("theme.txt", themeText)], named: "download", in: tempDir())
        #expect(try CustomThemeImporter.importTheme(from: zip, cacheRoot: tempDir()).name == "download")
        #expect(throws: ThemeError.unreadableArchive("it doesn't look like a ZIP file")) {
            _ = try CustomThemeImporter.importTheme(from: src.appendingPathComponent("missing"), cacheRoot: tempDir())
        }
    }

    @Test("8. a download with several themes lists them, and the chosen folder imports from a zip")
    func shapeSeveralThemesZip() throws {
        let top = "grub-0a37ab"
        let zip = try zipFile(catppuccinLike(top: top), named: "grub-0a37ab.zip", in: tempDir())
        // The one-shot call still refuses, naming every theme.txt (shallowest first).
        let expected = ["\(top)/src/catppuccin-latte-grub-theme/theme.txt", "\(top)/src/catppuccin-mocha-grub-theme/theme.txt",
                        "\(top)/ventoy/src/latte/catppuccin-latte/theme.txt", "\(top)/ventoy/src/mocha/catppuccin-mocha/theme.txt"]
        #expect(throws: ThemeError.ambiguousThemes(expected)) { _ = try CustomThemeImporter.importTheme(from: zip, cacheRoot: tempDir()) }

        let opened = try CustomThemeImporter.open(zip)
        #expect(opened.needsChoice)
        #expect(opened.choices.map(\.folder) == expected.map { ThemeAssembler.parent($0) })
        #expect(opened.choices.map(\.name) == ["Catppuccin Latte Grub Theme", "Catppuccin Mocha Grub Theme", "Catppuccin Latte", "Catppuccin Mocha"])
        #expect(opened.choices.map(\.location) == ["src/catppuccin-latte-grub-theme", "src/catppuccin-mocha-grub-theme",
                                                   "latte/catppuccin-latte", "mocha/catppuccin-mocha"])

        // The folder under the Ventoy tree, which isn't one of the shallowest, works too.
        let mocha = try CustomThemeImporter.importTheme(from: zip, themeRoot: "\(top)/ventoy/src/mocha/catppuccin-mocha", cacheRoot: tempDir())
        #expect(mocha.name == "catppuccin-mocha")
        #expect(mocha.id == "custom-catppuccin-mocha")
        #expect(listing(mocha.directory) == ["terminus-14.pf2", "theme.txt"])
        #expect(mocha.settings == .init(file: "theme.txt", fonts: ["terminus-14.pf2"], ventoyColor: "#89b4fa"))
        // And a plain GRUB flavour, with nothing from the other themes in it.
        let plain = try CustomThemeImporter.importTheme(from: zip, themeRoot: "\(top)/src/catppuccin-latte-grub-theme", cacheRoot: tempDir())
        #expect(plain.name == "catppuccin-latte-grub-theme")
        #expect(listing(plain.directory) == ["font.pf2", "theme.txt"])
        #expect(plain.settings == .init(file: "theme.txt", fonts: ["font.pf2"]))
    }

    /// A repository like Catppuccin's: plain GRUB themes under `src` and the Ventoy ones deeper, each with its own ventoy.json.
    private func catppuccinLike(top: String) -> [(String, String)] {
        var entries: [(String, String)] = [("\(top)/README.md", "hi"), ("\(top)/assets/preview.png", "p")]
        for flavour in ["latte", "mocha"] {
            entries += [("\(top)/src/catppuccin-\(flavour)-grub-theme/theme.txt", themeText),
                        ("\(top)/src/catppuccin-\(flavour)-grub-theme/font.pf2", "f"),
                        ("\(top)/ventoy/src/\(flavour)/catppuccin-\(flavour)/theme.txt", themeText),
                        ("\(top)/ventoy/src/\(flavour)/catppuccin-\(flavour)/terminus-14.pf2", "t"),
                        ("\(top)/ventoy/src/\(flavour)/ventoy.json", """
                         {
                             "theme":{
                                 "file": "/ventoy/catppuccin-\(flavour)/theme.txt",
                                 "ventoy_color": "\(flavour == "mocha" ? "#89b4fa" : "#1e66f5")",
                                 "fonts":[ "/ventoy/catppuccin-\(flavour)/terminus-14.pf2" ]
                             }
                         }
                         """)]
        }
        return entries
    }

    @Test("8. several themes in a folder: the chosen one imports, and an extracted top folder works the same")
    func shapeSeveralThemesFolder() throws {
        let src = tempDir().appendingPathComponent("grub-extracted")
        try put(catppuccinLike(top: "inner"), in: src)
        #expect(throws: ThemeError.self) { _ = try CustomThemeImporter.importTheme(from: src, cacheRoot: tempDir()) }
        let imported = try CustomThemeImporter.importTheme(from: src, themeRoot: "inner/ventoy/src/latte/catppuccin-latte", cacheRoot: tempDir())
        #expect(imported.name == "catppuccin-latte")
        #expect(imported.settings.ventoyColor == "#1e66f5")
        #expect(listing(imported.directory) == ["terminus-14.pf2", "theme.txt"])

        // Picking the extracted top folder itself: paths start below it.
        let top = tempDir().appendingPathComponent("grub-top")
        try put(catppuccinLike(top: "x").map { (String($0.0.dropFirst(2)), $0.1) }, in: top)
        let opened = try CustomThemeImporter.open(top)
        #expect(opened.choices.map(\.folder).last == "ventoy/src/mocha/catppuccin-mocha")
        let mocha = try CustomThemeImporter.importTheme(opened, themeRoot: "ventoy/src/mocha/catppuccin-mocha", cacheRoot: tempDir())
        #expect(mocha.settings.ventoyColor == "#89b4fa")
    }

    @Test("8. choosing from an opened source doesn't read the source again")
    func shapeChoiceReadsOnce() throws {
        let work = tempDir()
        let zip = try zipFile(catppuccinLike(top: "repo"), in: work)
        let scratch = tempDir()
        let opened = try CustomThemeImporter.open(zip, workRoot: scratch)
        #expect(names(in: scratch).isEmpty, "the unpack area is gone as soon as the source is read")
        try FileManager.default.removeItem(at: zip)
        // With the zip gone, every choice still imports.
        for choice in opened.choices {
            let imported = try CustomThemeImporter.importTheme(opened, themeRoot: choice.folder, cacheRoot: tempDir())
            #expect(imported.name == ThemeAssembler.last(choice.folder))
        }
        #expect(throws: ThemeError.self) { _ = try CustomThemeImporter.importTheme(opened, cacheRoot: tempDir()) }
        // What is held is the themes and their ventoy.json files, not the rest of the download.
        let held = Set(opened.files.map(\.path))
        #expect(!held.contains("repo/README.md"))
        #expect(!held.contains("repo/assets/preview.png"))
        #expect(held.contains("repo/ventoy/src/mocha/ventoy.json"))
        #expect(held.contains("repo/src/catppuccin-mocha-grub-theme/font.pf2"))
    }

    @Test("8. a folder that isn't a theme can't be chosen")
    func shapeBadChoice() throws {
        let zip = try zipFile(catppuccinLike(top: "repo") + [("repo/docs/guide.txt", "g")], in: tempDir())
        let cache = tempDir()
        #expect(throws: ThemeError.rootNotFound("repo/nowhere")) { _ = try CustomThemeImporter.importTheme(from: zip, themeRoot: "repo/nowhere", cacheRoot: cache) }
        // The folder is there but holds no theme.txt.
        #expect(throws: ThemeError.noThemeFile) { _ = try CustomThemeImporter.importTheme(from: zip, themeRoot: "repo/ventoy/src", cacheRoot: cache) }
        #expect(throws: ThemeError.noThemeFile) { _ = try CustomThemeImporter.importTheme(from: zip, themeRoot: "repo/docs", cacheRoot: cache) }
        // Names that climb out or are hidden are never looked up.
        for bad in ["../repo/src/catppuccin-mocha-grub-theme", "/repo/src/catppuccin-mocha-grub-theme/../..", "repo/.git", "repo/src/*"] {
            #expect(throws: ThemeError.rootNotFound(bad), "\(bad)") { _ = try CustomThemeImporter.importTheme(from: zip, themeRoot: bad, cacheRoot: cache) }
        }
        // A trailing slash is the same folder.
        #expect(try CustomThemeImporter.importTheme(from: zip, themeRoot: "repo/src/catppuccin-mocha-grub-theme/", cacheRoot: cache).name == "catppuccin-mocha-grub-theme")
        #expect(names(in: cache).count == 1)
    }

    @Test("8. at most 20 themes are listed; more asks for the theme's own folder")
    func shapeChoiceCap() throws {
        func pack(_ count: Int) throws -> URL {
            let dir = tempDir().appendingPathComponent("pack\(count)")
            for i in 0..<count { try write(themeText, to: dir.appendingPathComponent("themes/theme-\(String(format: "%02d", i))/theme.txt")) }
            return dir
        }
        let atCap = try CustomThemeImporter.open(try pack(20))
        #expect(atCap.choices.count == 20)
        #expect(atCap.choices.first?.name == "Theme 00")
        let over = try pack(21)
        #expect(throws: ThemeError.tooManyThemes(21)) { _ = try CustomThemeImporter.open(over) }
        #expect(throws: ThemeError.tooManyThemes(21)) { _ = try CustomThemeImporter.importTheme(from: over, cacheRoot: tempDir()) }
        // Naming the folder needs no list, so the cap doesn't apply.
        #expect(try CustomThemeImporter.importTheme(from: over, themeRoot: "themes/theme-03", cacheRoot: tempDir()).name == "theme-03")
        let message = try #require(ThemeError.tooManyThemes(21).errorDescription)
        #expect(message == "This contains 21 themes, which is too many to choose from here. Choose the folder of the one you want instead.")
        #expect(!message.contains("\u{2014}"))
        // The theme's own folder is the way out.
        #expect(try CustomThemeImporter.importTheme(from: over.appendingPathComponent("themes/theme-03"), cacheRoot: tempDir()).name == "theme-03")
    }

    @Test("8. choice names read well and can't carry hidden characters")
    func shapeChoiceNames() {
        #expect(CustomThemeImporter.readableName("catppuccin-mocha") == "Catppuccin Mocha")
        #expect(CustomThemeImporter.readableName("ventoy_pop") == "Ventoy Pop")
        #expect(CustomThemeImporter.readableName("MapleMono-CN") == "MapleMono CN")
        #expect(CustomThemeImporter.readableName("a--b") == "A B")
        let choices = CustomThemeImporter.choices(for: ["one", "a/b/c/theme-x", "x/\u{202E}evil\u{200B}-name"])
        #expect(choices.map(\.name) == ["One", "Theme X", "Evil Name"])
        #expect(choices.map(\.location) == ["one", "c/theme-x", "x/evil-name"])
        #expect(choices.map(\.id) == ["one", "a/b/c/theme-x", "x/\u{202E}evil\u{200B}-name"])
    }

    @Test("a shallower theme still wins over deeper ones, and a tie lists every theme")
    func shapeDepthRule() throws {
        #expect(try CustomThemeImporter.themeRoot(in: ["pack/theme.txt", "pack/old/theme.txt", "pack/old/deeper/theme.txt"]) == "pack")
        #expect(try CustomThemeImporter.themeRoot(in: ["theme.txt", "a/theme.txt", "b/theme.txt"]) == "")
        #expect(throws: ThemeError.ambiguousThemes(["a/theme.txt", "b/theme.txt", "a/old/theme.txt"])) {
            _ = try CustomThemeImporter.themeRoot(in: ["a/old/theme.txt", "b/theme.txt", "a/theme.txt"])
        }
        #expect(throws: ThemeError.noThemeFile) { _ = try CustomThemeImporter.themeRoot(in: ["a/Theme.txt", "a/.hidden/theme.txt", "a/theme.txt.bak"]) }
    }

    // MARK: ventoy.json next to the theme

    @Test("9. a pack's ventoy.json gives the fonts and settings, as paths inside the theme folder")
    func packSettingsApply() throws {
        let zip = try zipFile([
            ("ventoy/ventoy.json", """
             {
                 "control": [ { "VTOY_DEFAULT_MENU_MODE": "1" } ],
                 "theme": {
                     "file": [ "/ventoy/ventoy-pop/theme.txt", "/ventoy/ventoy-pop/theme_legacy.txt" ],
                     "default_file": 1,
                     "resolution_fit": 1,
                     "display_mode": "GUI",
                     "serial_param": "--unit=0",
                     "gfxmode": "1280x720,auto",
                     "ventoy_left": "5%",
                     "ventoy_top": "100%-19",
                     "ventoy_color": "#2b2b2b",
                     "fonts": [ "/ventoy/ventoy-pop/fonts/b.pf2", "/ventoy/ventoy-pop/a.pf2" ]
                 },
                 "menu_alias": [ { "dir": "/isos", "alias": "ISOs" } ]
             }
             """),
            ("ventoy/ventoy-pop/theme.txt", themeText), ("ventoy/ventoy-pop/theme_legacy.txt", themeText),
            ("ventoy/ventoy-pop/a.pf2", "a"), ("ventoy/ventoy-pop/fonts/b.pf2", "b"), ("ventoy/ventoy-pop/c.pf2", "c"),
        ], in: tempDir())
        let imported = try CustomThemeImporter.importTheme(from: zip, cacheRoot: tempDir())
        // Only the fonts it names (c.pf2 is not one of them), in its order; every other key is left alone.
        #expect(imported.settings == .init(file: "theme.txt", fonts: ["fonts/b.pf2", "a.pf2"], gfxmode: "1280x720,auto",
                                           ventoyLeft: "5%", ventoyTop: "100%-19", ventoyColor: "#2b2b2b"))
        // ventoy.json itself is never copied.
        #expect(listing(imported.directory) == ["a.pf2", "c.pf2", "fonts/b.pf2", "theme.txt", "theme_legacy.txt"])
        #expect(imported.skippedFiles.isEmpty)
    }

    @Test("9. the same pack picked as a folder, or by its theme.txt, gives the same settings")
    func packSettingsFromFolder() throws {
        let src = tempDir().appendingPathComponent("pack")
        try put([("ventoy/ventoy.json", duarteJSON("ventoy-blueprint")), ("ventoy/ventoy-blueprint/theme.txt", themeText)], in: src)
        let fromFolder = try CustomThemeImporter.importTheme(from: src, cacheRoot: tempDir())
        #expect(fromFolder.settings == .init(file: "theme.txt", gfxmode: "1920x1080"))
        // The theme.txt alone has the ventoy.json out of reach: today's settings.
        let fromFile = try CustomThemeImporter.importTheme(from: src.appendingPathComponent("ventoy/ventoy-blueprint/theme.txt"), cacheRoot: tempDir())
        #expect(fromFile.settings == .init(file: "theme.txt"))
    }

    @Test("9. a top-level ventoy.json whose paths start at the drive's root")
    func packSettingsTopLevel() throws {
        let zip = try zipFile([
            ("ventoy.json", #"{"theme":{"file":"/ventoy/themes/x/theme.txt","fonts":"/ventoy/themes/x/f.pf2","gfxmode":"max","ventoy_top":"90%"}}"#),
            ("ventoy/themes/x/theme.txt", themeText), ("ventoy/themes/x/f.pf2", "f"), ("ventoy/themes/x/g.pf2", "g"),
        ], in: tempDir())
        let imported = try CustomThemeImporter.importTheme(from: zip, cacheRoot: tempDir())
        #expect(imported.name == "x")
        #expect(imported.settings == .init(file: "theme.txt", fonts: ["f.pf2"], gfxmode: "max", ventoyTop: "90%"))
        #expect(listing(imported.directory) == ["f.pf2", "g.pf2", "theme.txt"])

        // The same, with the folder holding ventoy.json standing for the drive's root.
        let root = try zipFile([
            ("ventoy.json", #"{"theme":{"file":"/themes/y/theme.txt","fonts":["/themes/y/f.pf2"],"ventoy_left":"5%"}}"#),
            ("themes/y/theme.txt", themeText), ("themes/y/f.pf2", "f"),
        ], named: "root.zip", in: tempDir())
        #expect(try CustomThemeImporter.importTheme(from: root, cacheRoot: tempDir()).settings == .init(file: "theme.txt", fonts: ["f.pf2"], ventoyLeft: "5%"))
    }

    @Test("9. a ventoy.json that is about another theme, or none, leaves today's behaviour")
    func packSettingsNotForThisTheme() throws {
        let src = tempDir().appendingPathComponent("pack")
        try put([
            ("ventoy/ventoy.json", ##"{"theme":{"file":"/ventoy/b/theme.txt","gfxmode":"1024x768","ventoy_color":"#112233","fonts":["/ventoy/b/b.pf2"]}}"##),
            ("ventoy/a/theme.txt", themeText), ("ventoy/a/a.pf2", "a"),
            ("ventoy/b/theme.txt", themeText), ("ventoy/b/b.pf2", "b"), ("ventoy/b/extra.pf2", "e"),
        ], in: src)
        let cache = tempDir()
        // Theme a: its top-level .pf2 files, the default gfxmode (nil here, filled in when written to a drive).
        let a = try CustomThemeImporter.importTheme(from: src, themeRoot: "ventoy/a", cacheRoot: cache)
        #expect(a.settings == .init(file: "theme.txt", fonts: ["a.pf2"]))
        let b = try CustomThemeImporter.importTheme(from: src, themeRoot: "ventoy/b", cacheRoot: cache)
        #expect(b.settings == .init(file: "theme.txt", fonts: ["b.pf2"], gfxmode: "1024x768", ventoyColor: "#112233"))
        // No ventoy.json at all.
        let plain = tempDir().appendingPathComponent("plain")
        try put([("theme.txt", themeText), ("z.pf2", "z"), ("a.pf2", "a")], in: plain)
        #expect(try CustomThemeImporter.importTheme(from: plain, cacheRoot: cache).settings == .init(file: "theme.txt", fonts: ["a.pf2", "z.pf2"]))
    }

    @Test("9. values that fail the catalog's rules are dropped, and fonts that aren't there")
    func packSettingsValidated() throws {
        let json = """
            {"theme":{"file":"/ventoy/x/theme.txt","gfxmode":"fast","ventoy_left":"left","ventoy_top":"1%+","ventoy_color":"red",
             "fonts":["/ventoy/x/ok.pf2","/ventoy/x/missing.pf2","/ventoy/x/../../etc/evil.pf2","/ventoy/x/image.png","/etc/passwd","/ventoy/x/ok.pf2"]}}
            """
        let src = tempDir().appendingPathComponent("pack")
        try put([("ventoy/ventoy.json", json), ("ventoy/x/theme.txt", themeText), ("ventoy/x/ok.pf2", "o"), ("ventoy/x/image.png", "i"),
                 ("ventoy/x/other.pf2", "t")], in: src)
        let imported = try CustomThemeImporter.importTheme(from: src, cacheRoot: tempDir())
        #expect(imported.settings == .init(file: "theme.txt", fonts: ["ok.pf2"]))
        // A pack whose fonts all fail falls back to the .pf2 files beside theme.txt.
        let none = tempDir().appendingPathComponent("pack")
        try put([("ventoy/ventoy.json", #"{"theme":{"file":"/ventoy/x/theme.txt","fonts":["/ventoy/x/gone.pf2"],"gfxmode":"800x600"}}"#),
                 ("ventoy/x/theme.txt", themeText), ("ventoy/x/b.pf2", "b")], in: none)
        #expect(try CustomThemeImporter.importTheme(from: none, cacheRoot: tempDir()).settings == .init(file: "theme.txt", fonts: ["b.pf2"], gfxmode: "800x600"))
    }

    @Test("9. a ventoy.json that can't be used is ignored, not an error")
    func packSettingsUnusable() throws {
        let bad: [String] = ["", "not json", "[1,2]", #"{"theme":"/ventoy/x/theme.txt"}"#, #"{"theme":{"file":5}}"#, #"{"theme":{"gfxmode":"max"}}"#,
                             #"{"theme":{"file":"/ventoy/x/theme.txt"#, String(repeating: " ", count: CustomThemeImporter.maxVentoyJSONBytes)
                             + #"{"theme":{"file":"/ventoy/x/theme.txt","gfxmode":"max"}}"#]
        for text in bad {
            let src = tempDir().appendingPathComponent("pack")
            try put([("ventoy/ventoy.json", text), ("ventoy/x/theme.txt", themeText)], in: src)
            let imported = try CustomThemeImporter.importTheme(from: src, cacheRoot: tempDir())
            #expect(imported.settings == .init(file: "theme.txt"), "\(text.prefix(40))")
        }
        // A byte order mark, as editors on Windows write one, doesn't hide a good file.
        let src = tempDir().appendingPathComponent("pack")
        try put([("ventoy/x/theme.txt", themeText)], in: src)
        try (Data([0xEF, 0xBB, 0xBF]) + Data(#"{"theme":{"file":"/ventoy/x/theme.txt","gfxmode":"max"}}"#.utf8)).write(to: src.appendingPathComponent("ventoy/ventoy.json"))
        #expect(try CustomThemeImporter.importTheme(from: src, cacheRoot: tempDir()).settings == .init(file: "theme.txt", gfxmode: "max"))
    }

    @Test("9. names are matched without regard to case, as on the drive, and the closest ventoy.json wins")
    func packSettingsCaseAndNearest() throws {
        let src = tempDir().appendingPathComponent("pack")
        try put([
            ("ventoy/ventoy.json", #"{"theme":{"file":"/ventoy/Pop/Theme.TXT","gfxmode":"640x480"}}"#),
            ("ventoy/pop/ventoy.json", #"{"theme":{"file":"/ventoy/theme.txt","fonts":["/VENTOY/F.PF2"],"gfxmode":"800x600"}}"#),
            ("ventoy/pop/theme.txt", themeText), ("ventoy/pop/f.pf2", "f"),
        ], in: src)
        let imported = try CustomThemeImporter.importTheme(from: src, cacheRoot: tempDir())
        #expect(imported.settings == .init(file: "theme.txt", fonts: ["f.pf2"], gfxmode: "800x600"))
    }

    @Test("9. a ventoy.json inside the theme folder is read, not copied, and not reported")
    func packSettingsInsideFolder() throws {
        let src = tempDir().appendingPathComponent("pack")
        try put([("ventoy.json", #"{"theme":{"file":"/ventoy/theme.txt","gfxmode":"max"}}"#), ("theme.txt", themeText), ("notes.md", "n")], in: src)
        let imported = try CustomThemeImporter.importTheme(from: src, cacheRoot: tempDir())
        #expect(imported.settings.gfxmode == "max")
        #expect(listing(imported.directory) == ["theme.txt"])
        #expect(imported.skippedFiles == ["notes.md"])
    }

    @Test("9. a pack's settings survive being saved to My Themes")
    func packSettingsSaved() throws {
        let zip = try zipFile(catppuccinLike(top: "repo"), in: tempDir())
        let imported = try CustomThemeImporter.importTheme(from: zip, themeRoot: "repo/ventoy/src/mocha/catppuccin-mocha", cacheRoot: tempDir())
        let library = ThemeLibrary(root: tempDir().appendingPathComponent("My Themes"))
        let saved = try library.save(folder: imported.directory, name: imported.name, settings: imported.settings, origin: "Added from a file")
        #expect(saved.settings == .init(file: "theme.txt", fonts: ["terminus-14.pf2"], ventoyColor: "#89b4fa"))
        #expect(library.list() == [saved])
    }
}
