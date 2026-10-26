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

    final class FakeTransport: ThemeTransport, @unchecked Sendable {
        let payload: Data
        private(set) var calls = 0
        init(_ payload: Data) { self.payload = payload }
        func data(from url: URL, maxBytes: Int) async throws -> Data { calls += 1; return payload }
    }

    private func entry(sha: String, settingsFile: String = "theme.txt") -> ThemeEntry {
        ThemeEntry(id: "sample", name: "Sample", author: "A", homepage: URL(string: "https://github.com/a/b")!,
                   license: "MIT", showsVentoyHotkeys: true, notes: nil,
                   download: .init(url: URL(string: "https://github.com/a/b/releases/download/v1/t.zip")!, sha256: sha, root: "pack/mytheme"),
                   files: nil, settings: .init(file: settingsFile, fonts: ["font.pf2"]))
    }

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
        #expect(listing(dir1).contains(".complete"))
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

    @Test("a bundled copy is used without downloading, only for the current checksum")
    func bundled() async throws {
        let zip = try Self.fixture()
        let sha = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        let bundledRoot = tempDir()
        let folder = bundledRoot.appendingPathComponent("sample-\(sha.prefix(16))")
        try ThemeAssembler.assemble(try ThemeAssembler.files(fromZip: zip), root: "pack/mytheme", mappings: nil, into: folder)
        try Data().write(to: folder.appendingPathComponent(".complete"))
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
}
