import Testing
import Foundation
@testable import MactoyKit

@Suite("VentoyDownloader.isValidVersion")
struct VentoyDownloaderTests {

    @Test("accepts well-formed versions")
    func acceptsGoodVersions() {
        for v in ["1.1.11", "1.2.0", "2.0.0.1", "1.0", "10.20.30"] {
            #expect(VentoyDownloader.isValidVersion(v), "should accept \(v)")
        }
    }

    @Test("rejects path traversal + injection")
    func rejectsBadVersions() {
        let bad = [
            "",
            "1",                             // single component
            "1.1.11/../../../etc/passwd",    // traversal
            "1.1.11\n",                      // newline
            "1.1.11 && rm -rf /",            // shell injection
            "../1.1.11",
            "1..11",                         // empty component
            ".1.1",
            "1.1.",
            "1a.2.3",                        // non-numeric
            "1.2.3.4.5",                     // too many components
            String(repeating: "1.", count: 20),
        ]
        for v in bad {
            #expect(!VentoyDownloader.isValidVersion(v), "should reject \(v)")
        }
    }
}

@Suite("VentoyDownloader cache + run directories (issue #8)")
struct VentoyDownloaderCacheTests {

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactoy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("cache directory is created once and is stable across calls")
    func cacheIsStable() throws {
        let root = try scratch().appendingPathComponent("Cache")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let a = try VentoyDownloader.prepareCacheDirectory(at: root)
        let b = try VentoyDownloader.prepareCacheDirectory(at: root)
        #expect(a == b)
        #expect(a == root)
    }

    @Test("a symlinked or world-writable cache directory is refused")
    func untrustedCacheRefused() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        let real = base.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: DriverError.self) { try VentoyDownloader.prepareCacheDirectory(at: link) }

        let open = base.appendingPathComponent("open")
        try fm.createDirectory(at: open, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: open.path)
        #expect(throws: DriverError.self) { try VentoyDownloader.prepareCacheDirectory(at: open) }
    }

    @Test("run directories are unique, private, and live inside the cache root")
    func runDirectories() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try VentoyDownloader.makeRunDirectory(in: root)
        let b = try VentoyDownloader.makeRunDirectory(in: root)
        #expect(a != b)
        #expect(a.deletingLastPathComponent().path == root.path)
        let perms = try FileManager.default.attributesOfItem(atPath: a.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
    }

    @Test("stale run directories are swept, fresh ones are left alone")
    func staleRunDirectoriesSwept() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let stale = try VentoyDownloader.makeRunDirectory(in: root)
        let fresh = try VentoyDownloader.makeRunDirectory(in: root)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: stale.path)

        _ = try VentoyDownloader.makeRunDirectory(in: root)
        #expect(!fm.fileExists(atPath: stale.path))
        #expect(fm.fileExists(atPath: fresh.path))
    }

    @Test("pruning keeps the current tarball and anything that isn't a Ventoy tarball")
    func prune() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for name in ["ventoy-1.1.16-linux.tar.gz", "ventoy-1.1.17-linux.tar.gz", "ventoy-1.0.99-linux.tar.gz", "notes.txt"] {
            fm.createFile(atPath: root.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        VentoyDownloader.pruneTarballs(in: root, keeping: root.appendingPathComponent("ventoy-1.1.17-linux.tar.gz"))
        let left = try fm.contentsOfDirectory(atPath: root.path).sorted()
        #expect(left == ["notes.txt", "ventoy-1.1.17-linux.tar.gz"])
    }

    /// Opt-in (hits GitHub): MACTOY_NETWORK_TESTS=1 swift test --filter secondDownload
    @Test("second download of the same version is served from the cache",
          .enabled(if: ProcessInfo.processInfo.environment["MACTOY_NETWORK_TESTS"] != nil))
    func secondDownloadIsCached() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        final class Recorder: ProgressSink, @unchecked Sendable {
            var messages: [String] = []
            func report(_ update: ProgressUpdate) { messages.append(update.message) }
        }
        let first = Recorder(), second = Recorder()
        let a = try await VentoyDownloader().downloadTarball(version: "1.1.17", workDir: root, progress: first)
        let b = try await VentoyDownloader().downloadTarball(version: "1.1.17", workDir: root, progress: second)
        #expect(a == b)
        #expect(first.messages.contains { $0.hasPrefix("Downloading") })
        #expect(!second.messages.contains { $0.hasPrefix("Downloading") })
        #expect(second.messages.contains { $0.contains("Using cached") })
    }
}
