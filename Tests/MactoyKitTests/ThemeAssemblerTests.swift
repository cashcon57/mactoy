import CryptoKit
import Foundation
import Testing
@testable import MactoyKit

@Suite("Theme assembly and download")
struct ThemeAssemblerTests {

    static func fixture() throws -> Data {
        try Data(contentsOf: try #require(Bundle.module.url(forResource: "Fixtures/theme-sample", withExtension: "zip")))
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-theme-\(UUID().uuidString)")
    }

    private func listing(_ dir: URL) -> [String] {
        let base = dir.standardizedFileURL.path + "/"
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])!
        return e.compactMap { ($0 as? URL).flatMap { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true ? String($0.standardizedFileURL.path.dropFirst(base.count)) : nil } }.sorted()
    }

    @Test("zip listing has regular files only")
    func zipFiles() throws {
        let files = try ThemeAssembler.files(fromZip: Self.fixture())
        #expect(files.map(\.path).sorted() == [
            "pack/mytheme/._background.png", "pack/mytheme/background.png", "pack/mytheme/font.pf2",
            "pack/mytheme/icons/linux.png", "pack/mytheme/logo.svg", "pack/mytheme/select_c.png",
            "pack/mytheme/theme.txt", "pack/mytheme/ventoy_grub.cfg", "pack/other/theme.txt",
        ])
        #expect(files.first { $0.path == "pack/mytheme/font.pf2" }?.data == Data("PF2".utf8))
        #expect(throws: ThemeError.self) { try ThemeAssembler.files(fromZip: Data("not a zip".utf8)) }
    }

    @Test("zip symlink entries are left out")
    func zipSymlinks() throws {
        // Fixture holds pack/link.png -> /etc/passwd and pack/up -> ../.. beside two real files.
        let zip = try Data(contentsOf: try #require(Bundle.module.url(forResource: "Fixtures/theme-symlink", withExtension: "zip")))
        #expect(try ThemeAssembler.files(fromZip: zip).map(\.path).sorted() == ["pack/a.png", "pack/theme.txt"])
    }

    @Test("copies allowed files under root and reports the rest")
    func wholeRoot() throws {
        let files = try ThemeAssembler.files(fromZip: Self.fixture())
        let out = tempDir()
        let skipped = try ThemeAssembler.assemble(files, root: "pack/mytheme", mappings: nil, into: out)
        #expect(listing(out) == ["background.png", "font.pf2", "icons/linux.png", "select_c.png", "theme.txt"])
        #expect(skipped == ["._background.png", "logo.svg", "ventoy_grub.cfg"])
    }

    @Test("explicit mappings, globs and dot destination")
    func mappings() throws {
        let files = try ThemeAssembler.files(fromZip: Self.fixture())
        let out = tempDir()
        try ThemeAssembler.assemble(files, root: "pack", mappings: [
            .init(from: "mytheme/theme.txt", to: "theme.txt"),
            .init(from: "mytheme/*.png", to: "."),
            .init(from: "mytheme/icons/*.png", to: "icons"),
        ], into: out)
        #expect(listing(out) == ["background.png", "icons/linux.png", "select_c.png", "theme.txt"])
    }

    @Test("a mapping can't land on an unsafe or disallowed destination")
    func mappingDestinations() throws {
        let files = try ThemeAssembler.files(fromZip: Self.fixture())
        let box = tempDir()
        let out = box.appendingPathComponent("a/theme")
        let skipped = try ThemeAssembler.assemble(files, root: "pack/mytheme", mappings: [
            .init(from: "theme.txt", to: "theme.txt"),
            .init(from: "theme.txt", to: "../escape.txt"),
            .init(from: "theme.txt", to: "ventoy_grub.cfg"),
            .init(from: "font.pf2", to: ".hidden.pf2"),
            .init(from: "*.png", to: ".."),
        ], into: out)
        #expect(listing(box) == ["a/theme/theme.txt"])
        // The glob matches `._background.png`, which is hidden at its destination too.
        #expect(skipped == [".hidden.pf2", "../._background.png", "../background.png", "../escape.txt", "../select_c.png", "ventoy_grub.cfg"].sorted())
    }

    @Test("an archive entry that climbs out of the root is skipped, never written")
    func traversal() throws {
        let png = Data([1])
        let files = [
            ThemeSourceFile(path: "pack/mytheme/theme.txt", data: png),
            ThemeSourceFile(path: "pack/mytheme/../../evil.png", data: png),
            ThemeSourceFile(path: "pack/mytheme/icons/../../../evil2.png", data: png),
            ThemeSourceFile(path: "pack/mytheme//double.png", data: png),
            ThemeSourceFile(path: "pack/mytheme/..\\evil3.png", data: png),
        ]
        let box = tempDir()
        let out = box.appendingPathComponent("a/b/theme")
        let skipped = try ThemeAssembler.assemble(files, root: "pack/mytheme", mappings: nil, into: out)
        #expect(listing(box) == ["a/b/theme/theme.txt"])
        #expect(skipped == ["../../evil.png", "..\\evil3.png", "/double.png", "icons/../../../evil2.png"].sorted())
        // An absolute entry name with no root can't pick a path outside the destination.
        let abs = try ThemeAssembler.assemble([ThemeSourceFile(path: "/tmp/evil4.png", data: png)], root: "", mappings: nil, into: box.appendingPathComponent("abs"))
        #expect(abs == ["/tmp/evil4.png"])
    }

    @Test("missing sources and roots throw")
    func missing() throws {
        let files = try ThemeAssembler.files(fromZip: Self.fixture())
        #expect(throws: ThemeError.missingFile("mytheme/nope.png")) {
            try ThemeAssembler.assemble(files, root: "pack", mappings: [.init(from: "mytheme/nope.png", to: "x.png")], into: tempDir())
        }
        #expect(throws: ThemeError.missingFile("mytheme/*.jpg")) {
            try ThemeAssembler.assemble(files, root: "pack", mappings: [.init(from: "mytheme/*.jpg", to: ".")], into: tempDir())
        }
        #expect(throws: ThemeError.rootNotFound("pack/nothing")) {
            try ThemeAssembler.assemble(files, root: "pack/nothing", mappings: nil, into: tempDir())
        }
    }

    @Test("limits are enforced")
    func limits() throws {
        let big = [ThemeSourceFile(path: "t/a.png", data: Data(count: ThemeAssembler.maxThemeBytes + 1))]
        #expect(throws: ThemeError.themeTooLarge(ThemeAssembler.maxThemeBytes + 1)) {
            try ThemeAssembler.assemble(big, root: "t", mappings: nil, into: tempDir())
        }
        let many = (0...ThemeAssembler.maxFiles).map { ThemeSourceFile(path: "t/\($0).png", data: Data([1])) }
        #expect(throws: ThemeError.tooManyFiles(ThemeAssembler.maxFiles + 1)) {
            try ThemeAssembler.assemble(many, root: "t", mappings: nil, into: tempDir())
        }
    }

    @Test("settings must point at files that exist")
    func checkSettings() throws {
        let out = tempDir()
        try ThemeAssembler.assemble(try ThemeAssembler.files(fromZip: Self.fixture()), root: "pack/mytheme", mappings: nil, into: out)
        try ThemeAssembler.checkSettings(.init(file: "theme.txt", fonts: ["font.pf2"]), in: out)
        #expect(throws: ThemeError.missingFile("missing.pf2")) {
            try ThemeAssembler.checkSettings(.init(file: "theme.txt", fonts: ["missing.pf2"]), in: out)
        }
        #expect(throws: ThemeError.missingFile("other.txt")) {
            try ThemeAssembler.checkSettings(.init(file: "other.txt"), in: out)
        }
    }

    @Test("a folder is read as regular files only, symlinks left out")
    func folder() throws {
        let src = tempDir()
        let fm = FileManager.default
        try fm.createDirectory(at: src.appendingPathComponent("icons"), withIntermediateDirectories: true)
        try Data("t".utf8).write(to: src.appendingPathComponent("theme.txt"))
        try Data("p".utf8).write(to: src.appendingPathComponent("icons/linux.png"))
        try Data("h".utf8).write(to: src.appendingPathComponent(".DS_Store"))
        let outside = tempDir()
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.png"))
        try fm.createSymbolicLink(at: src.appendingPathComponent("link.png"), withDestinationURL: outside.appendingPathComponent("secret.png"))
        try fm.createSymbolicLink(at: src.appendingPathComponent("linked"), withDestinationURL: outside)

        let files = try ThemeAssembler.files(fromFolder: src)
        #expect(files.map(\.path).sorted() == [".DS_Store", "icons/linux.png", "theme.txt"])
        #expect(files.first { $0.path == "theme.txt" }?.data == Data("t".utf8))

        let out = tempDir()
        let skipped = try ThemeAssembler.assemble(files, root: "", mappings: nil, into: out)
        #expect(listing(out) == ["icons/linux.png", "theme.txt"])
        #expect(skipped == [".DS_Store"])
    }

    // MARK: hand-built archives (SWCompression can only read ZIPs, and zip(1) can't write these shapes)

    struct ZipPart {
        var name: String
        var data: Data = Data()
        /// What the headers claim; defaults to the real size.
        var declaredSize: Int? = nil
        var mode: UInt32 = 0o100644
    }

    /// A stored (uncompressed) ZIP with unix attributes, so entry types come from `mode`.
    static func zip(_ parts: [ZipPart]) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
        var out = Data()
        var central = Data()
        for p in parts {
            let name = Array(p.name.utf8)
            let crc = CRC32.checksum(p.data)
            let declared = UInt32(p.declaredSize ?? p.data.count)
            let offset = UInt32(out.count)
            out += le32(0x04034b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0x21)
            out += le32(crc) + le32(UInt32(p.data.count)) + le32(declared) + le16(name.count) + le16(0) + name
            out += p.data
            central += le32(0x02014b50) + le16(0x031E) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0x21)
            central += le32(crc) + le32(UInt32(p.data.count)) + le32(declared) + le16(name.count) + le16(0) + le16(0)
            central += le16(0) + le16(0) + le32(p.mode << 16) + le32(offset) + name
        }
        let cdOffset = UInt32(out.count)
        out += central
        out += le32(0x06054b50) + le16(0) + le16(0) + le16(parts.count) + le16(parts.count)
        out += le32(UInt32(central.count)) + le32(cdOffset) + le16(0)
        return out
    }

    @Test("the hand-built archive reads like a real one, and ./ prefixes come off")
    func zipBuilder() throws {
        let zip = Self.zip([
            .init(name: "pack/", mode: 0o040755),
            .init(name: "./pack/theme.txt", data: Data("t".utf8)),
            .init(name: "././pack/a.png", data: Data("p".utf8)),
            .init(name: "pack/link.png", data: Data("/etc/passwd".utf8), mode: 0o120777),
        ])
        let files = try ThemeAssembler.files(fromZip: zip)
        #expect(files.map(\.path).sorted() == ["pack/a.png", "pack/theme.txt"])
        #expect(files.first { $0.path == "pack/theme.txt" }?.data == Data("t".utf8))
    }

    @Test("an archive with too many entries is refused before anything is unpacked")
    func zipEntryCap() throws {
        let cap = ThemeAssembler.maxFiles * 2
        let atCap = Self.zip((0..<cap).map { .init(name: "t/\($0).png", data: Data([1])) })
        #expect(try ThemeAssembler.files(fromZip: atCap).count == cap)
        let over = Self.zip((0...cap).map { .init(name: "t/\($0).png", data: Data([1])) })
        #expect(throws: ThemeError.tooManyFiles(cap + 1)) { try ThemeAssembler.files(fromZip: over) }
    }

    @Test("declared sizes are checked before the archive is inflated")
    func zipDeclaredSize() throws {
        // The data is 3 bytes; a size check after `open` would see a different error (wrong size).
        let lying = Self.zip([.init(name: "t/a.png", data: Data([1, 2, 3]), declaredSize: ThemeAssembler.maxUnpackedBytes + 1)])
        #expect(throws: ThemeError.themeTooLarge(ThemeAssembler.maxUnpackedBytes + 1)) { try ThemeAssembler.files(fromZip: lying) }
        // A symlink entry is inflated too, so its size counts.
        let link = Self.zip([.init(name: "t/l.png", data: Data([1]), declaredSize: ThemeAssembler.maxUnpackedBytes + 1, mode: 0o120777)])
        #expect(throws: ThemeError.themeTooLarge(ThemeAssembler.maxUnpackedBytes + 1)) { try ThemeAssembler.files(fromZip: link) }
    }

    @Test("a stored entry that claims more bytes than the archive holds is an error, not a crash")
    func zipOverrun() throws {
        // Under the size limit, so only the overrun check stands between this and a trap inside SWCompression.
        let lying = Self.zip([.init(name: "t/a.png", data: Data([1, 2, 3]), declaredSize: 1000)])
        #expect(throws: ThemeError.unreadableArchive("an entry is larger than the archive")) { try ThemeAssembler.files(fromZip: lying) }
    }

    @Test("declared sizes: missing, negative, over the limit and wrapping ones are rejected")
    func declaredSizes() throws {
        let limit = ThemeAssembler.maxUnpackedBytes
        try ThemeAssembler.checkDeclaredSizes([])
        try ThemeAssembler.checkDeclaredSizes([0, 5, limit - 5])
        let invalid = ThemeError.unreadableArchive("an entry doesn't declare a valid size")
        #expect(throws: invalid) { try ThemeAssembler.checkDeclaredSizes([1, nil]) }
        #expect(throws: invalid) { try ThemeAssembler.checkDeclaredSizes([-1]) }
        #expect(throws: invalid) { try ThemeAssembler.checkDeclaredSizes([limit, nil]) }
        #expect(throws: ThemeError.themeTooLarge(limit + 1)) { try ThemeAssembler.checkDeclaredSizes([limit, 1]) }
        #expect(throws: ThemeError.themeTooLarge(Int.max)) { try ThemeAssembler.checkDeclaredSizes([Int.max]) }
        // 5 + Int.max would wrap negative and slip under the limit.
        #expect(throws: ThemeError.themeTooLarge(Int.max)) { try ThemeAssembler.checkDeclaredSizes([5, Int.max]) }
    }

    @Test("assemble only writes into a destination that doesn't exist yet")
    func destinationMustNotExist() throws {
        let files = [ThemeSourceFile(path: "t/theme.txt", data: Data([1]))]
        let fm = FileManager.default

        let existing = tempDir()
        try fm.createDirectory(at: existing, withIntermediateDirectories: true)
        #expect(throws: ThemeError.destinationExists(existing.path)) {
            try ThemeAssembler.assemble(files, root: "t", mappings: nil, into: existing)
        }
        #expect(listing(existing) == [])

        // A link to a folder somewhere else is never written through.
        let outside = tempDir()
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = tempDir()
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: ThemeError.destinationExists(link.path)) {
            try ThemeAssembler.assemble(files, root: "t", mappings: nil, into: link)
        }
        #expect(listing(outside) == [])

        // Nor is a dangling one, which `fileExists` would call absent.
        let target = tempDir()
        let dangling = tempDir()
        try fm.createSymbolicLink(at: dangling, withDestinationURL: target)
        #expect(throws: ThemeError.destinationExists(dangling.path)) {
            try ThemeAssembler.assemble(files, root: "t", mappings: nil, into: dangling)
        }
        #expect(!fm.fileExists(atPath: target.path))
    }

    final class FakeTransport: ThemeTransport, @unchecked Sendable {
        let payload: Data
        private(set) var calls = 0
        init(_ payload: Data) { self.payload = payload }
        func data(from url: URL, maxBytes: Int) async throws -> Data { calls += 1; return payload }
    }

    private func entry(sha: String, root: String = "pack/mytheme", files: [ThemeEntry.FileMapping]? = nil,
                       settingsFile: String = "theme.txt", fonts: [String]? = ["font.pf2"]) -> ThemeEntry {
        ThemeEntry(id: "sample", name: "Sample", author: "A", homepage: URL(string: "https://github.com/a/b")!,
                   license: "MIT", showsVentoyHotkeys: true, notes: nil,
                   download: .init(url: URL(string: "https://github.com/a/b/releases/download/v1/t.zip")!, sha256: sha, root: root),
                   files: files, settings: .init(file: settingsFile, fonts: fonts))
    }

    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @Test("fetcher verifies the checksum and caches once")
    func fetcher() async throws {
        let zip = try Self.fixture()
        let sha = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        let transport = FakeTransport(zip)
        let cache = tempDir()
        let fetcher = ThemeFetcher(transport: transport, cacheRoot: cache, bundledRoot: nil)
        let dir1 = try await fetcher.themeDirectory(for: entry(sha: sha))
        let dir2 = try await fetcher.themeDirectory(for: entry(sha: sha))
        #expect(dir1 == dir2)
        #expect(transport.calls == 1)
        #expect(listing(dir1).contains("theme.txt"))
        #expect(try Data(contentsOf: dir1.appendingPathComponent(".complete")) == Data(ThemeFetcher.fingerprint(for: entry(sha: sha)).utf8))
        #expect(dir1.lastPathComponent == "sample-\(sha.prefix(16))")
        #expect(dir1.deletingLastPathComponent().standardizedFileURL == cache.standardizedFileURL)

        let badCache = tempDir()
        let bad = ThemeFetcher(transport: FakeTransport(zip), cacheRoot: badCache, bundledRoot: nil)
        await #expect(throws: ThemeError.checksumMismatch(expected: String(repeating: "0", count: 64), actual: sha)) {
            _ = try await bad.themeDirectory(for: entry(sha: String(repeating: "0", count: 64)))
        }
        #expect(!FileManager.default.fileExists(atPath: badCache.path))
    }

    @Test("a theme whose settings name a missing file isn't cached")
    func badSettingsNotCached() async throws {
        let zip = try Self.fixture()
        let sha = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        let cache = tempDir()
        let fetcher = ThemeFetcher(transport: FakeTransport(zip), cacheRoot: cache, bundledRoot: nil)
        await #expect(throws: ThemeError.missingFile("nope.txt")) {
            _ = try await fetcher.themeDirectory(for: entry(sha: sha, settingsFile: "nope.txt"))
        }
        // No finished folder and no staging leftovers.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) == [])
    }

    /// A finished bundled folder for `entry`, the way the app's build would ship one.
    private func makeBundled(in root: URL, zip: Data, entry: ThemeEntry, marker: String? = nil) throws -> URL {
        let folder = root.appendingPathComponent(ThemeFetcher.folderName(for: entry))
        try ThemeAssembler.assemble(try ThemeAssembler.files(fromZip: zip), root: "pack/mytheme", mappings: nil, into: folder)
        try Data((marker ?? ThemeFetcher.fingerprint(for: entry)).utf8).write(to: folder.appendingPathComponent(".complete"))
        return folder
    }

    @Test("a bundled copy is used without downloading, only for the current checksum")
    func bundled() async throws {
        let zip = try Self.fixture()
        let sha = sha256(zip)
        let bundledRoot = tempDir()
        let folder = try makeBundled(in: bundledRoot, zip: zip, entry: entry(sha: sha))
        let transport = FakeTransport(zip)
        let fetcher = ThemeFetcher(transport: transport, cacheRoot: tempDir(), bundledRoot: bundledRoot)
        // `folder` was built before it existed, so it has no trailing slash; the returned URL does.
        #expect(try await fetcher.themeDirectory(for: entry(sha: sha)).standardizedFileURL == folder.standardizedFileURL)
        #expect(transport.calls == 0)

        let stale = bundledRoot.appendingPathComponent("sample-0000000000000000")
        try FileManager.default.moveItem(at: folder, to: stale)
        _ = try await fetcher.themeDirectory(for: entry(sha: sha))
        #expect(transport.calls == 1)
    }

    @Test("a bundled copy made for a different recipe, or missing a settings file, is skipped")
    func bundledStale() async throws {
        let zip = try Self.fixture()
        let sha = sha256(zip)
        let fm = FileManager.default

        // Same ZIP, but the catalog has since changed what to take from it.
        let oldRecipe = entry(sha: sha, files: [.init(from: "theme.txt", to: "theme.txt"), .init(from: "font.pf2", to: "font.pf2")])
        let rootA = tempDir()
        let folderA = try makeBundled(in: rootA, zip: zip, entry: entry(sha: sha), marker: ThemeFetcher.fingerprint(for: oldRecipe))
        let transportA = FakeTransport(zip)
        let cacheA = tempDir()
        let dirA = try await ThemeFetcher(transport: transportA, cacheRoot: cacheA, bundledRoot: rootA).themeDirectory(for: entry(sha: sha))
        #expect(transportA.calls == 1)
        #expect(dirA.standardizedFileURL != folderA.standardizedFileURL)
        #expect(dirA.deletingLastPathComponent().standardizedFileURL == cacheA.standardizedFileURL)
        // The bundled folder itself is left as it was.
        #expect(fm.fileExists(atPath: folderA.appendingPathComponent("font.pf2").path))

        // Right recipe, but a file the settings name isn't there.
        let rootB = tempDir()
        let folderB = try makeBundled(in: rootB, zip: zip, entry: entry(sha: sha))
        try fm.removeItem(at: folderB.appendingPathComponent("font.pf2"))
        let transportB = FakeTransport(zip)
        let dirB = try await ThemeFetcher(transport: transportB, cacheRoot: tempDir(), bundledRoot: rootB).themeDirectory(for: entry(sha: sha))
        #expect(transportB.calls == 1)
        #expect(fm.fileExists(atPath: dirB.appendingPathComponent("font.pf2").path))
    }

    @Test("the fingerprint follows root, files and settings, not the rest of the entry")
    func fingerprint() {
        let sha = String(repeating: "a", count: 64)
        let base = entry(sha: sha)
        let picked: [ThemeEntry.FileMapping] = [.init(from: "theme.txt", to: "theme.txt")]
        let variants = [
            base,
            entry(sha: sha, root: "pack/other"),
            entry(sha: sha, files: picked),
            entry(sha: sha, files: picked + [.init(from: "font.pf2", to: "font.pf2")]),
            entry(sha: sha, files: [.init(from: "theme.txt", to: "other.txt")]),
            entry(sha: sha, settingsFile: "other.txt"),
            entry(sha: sha, fonts: nil),
            entry(sha: sha, fonts: ["other.pf2"]),
        ]
        #expect(Set(variants.map(ThemeFetcher.fingerprint)).count == variants.count)
        var cosmetic = base
        cosmetic.name = "Renamed"
        cosmetic.notes = "Looks different"
        cosmetic.settings.gfxmode = "1024x768"
        cosmetic.download.sha256 = String(repeating: "b", count: 64)
        #expect(ThemeFetcher.fingerprint(for: cosmetic) == ThemeFetcher.fingerprint(for: base))
        #expect(ThemeFetcher.fingerprint(for: base).count == 64)
    }

    @Test("a cached folder is rebuilt when the catalog changes how to assemble it, or when it is damaged")
    func cacheRebuilds() async throws {
        let zip = try Self.fixture()
        let sha = sha256(zip)
        let transport = FakeTransport(zip)
        let fetcher = ThemeFetcher(transport: transport, cacheRoot: tempDir(), bundledRoot: nil)

        let whole = entry(sha: sha)
        let dir = try await fetcher.themeDirectory(for: whole)
        #expect(listing(dir) == [".complete", "background.png", "font.pf2", "icons/linux.png", "select_c.png", "theme.txt"])
        #expect(transport.calls == 1)

        // Same ZIP, different files picked.
        let picked = entry(sha: sha, files: [.init(from: "theme.txt", to: "theme.txt"), .init(from: "font.pf2", to: "font.pf2")])
        let dir2 = try await fetcher.themeDirectory(for: picked)
        #expect(dir2.standardizedFileURL == dir.standardizedFileURL)
        #expect(transport.calls == 2)
        #expect(listing(dir2) == [".complete", "font.pf2", "theme.txt"])
        _ = try await fetcher.themeDirectory(for: picked)
        #expect(transport.calls == 2)

        // Different root.
        let other = entry(sha: sha, root: "pack/other", fonts: nil)
        let dir3 = try await fetcher.themeDirectory(for: other)
        #expect(transport.calls == 3)
        #expect(listing(dir3) == [".complete", "theme.txt"])

        // Different settings only.
        let noFonts = entry(sha: sha, fonts: nil)
        _ = try await fetcher.themeDirectory(for: noFonts)
        #expect(transport.calls == 4)

        // Damage: a file the settings name is gone.
        let dir5 = try await fetcher.themeDirectory(for: whole)
        #expect(transport.calls == 5)
        try FileManager.default.removeItem(at: dir5.appendingPathComponent("font.pf2"))
        let dir6 = try await fetcher.themeDirectory(for: whole)
        #expect(transport.calls == 6)
        #expect(FileManager.default.fileExists(atPath: dir6.appendingPathComponent("font.pf2").path))
        _ = try await fetcher.themeDirectory(for: whole)
        #expect(transport.calls == 6)
    }
}
