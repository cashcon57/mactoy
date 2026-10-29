import Foundation
import Testing
@testable import MactoyKit

/// Issue #22: Mactoy leaves fewer files behind.
@Suite("Leftover files")
struct LeftoverFilesTests {
    private let fm = FileManager.default

    /// A temp folder laid out like `/Library/Application Support/Mactoy/Cache`.
    private func mactoyFolder() throws -> (base: URL, mactoy: URL, cache: URL) {
        let base = fm.temporaryDirectory.appendingPathComponent("mactoy-leftovers-\(UUID().uuidString)", isDirectory: true)
        let mactoy = base.appendingPathComponent("Mactoy", isDirectory: true)
        let cache = try VentoyDownloader.prepareCacheDirectory(at: mactoy.appendingPathComponent("Cache", isDirectory: true))
        return (base, mactoy, cache)
    }

    @Test("clearing the cache deletes it and the empty Mactoy folder, and reports the space")
    func clearsCache() throws {
        let (base, mactoy, cache) = try mactoyFolder()
        defer { try? fm.removeItem(at: base) }
        try Data(repeating: 7, count: 100_000).write(to: cache.appendingPathComponent("ventoy-1.1.10-linux.tar.gz"))
        let run = try VentoyDownloader.makeRunDirectory(in: cache)
        try Data(repeating: 1, count: 5_000).write(to: run.appendingPathComponent("boot.img"))

        let freed = try VentoyDownloader.clearCache(at: cache)

        #expect(freed >= 105_000)
        #expect(!fm.fileExists(atPath: cache.path))
        #expect(!fm.fileExists(atPath: mactoy.path))
        #expect(fm.fileExists(atPath: base.path))
    }

    @Test("the Mactoy folder stays when something else is in it")
    func keepsNonEmptyParent() throws {
        let (base, mactoy, cache) = try mactoyFolder()
        defer { try? fm.removeItem(at: base) }
        try Data("keep".utf8).write(to: mactoy.appendingPathComponent("other"))

        try VentoyDownloader.clearCache(at: cache)

        #expect(!fm.fileExists(atPath: cache.path))
        #expect(fm.fileExists(atPath: mactoy.appendingPathComponent("other").path))
    }

    @Test("a parent that isn't Mactoy's own folder is never removed, even when empty")
    func onlyRemovesMactoyParent() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("mactoy-leftovers-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let parent = base.appendingPathComponent("Somebody Else", isDirectory: true)
        let cache = try VentoyDownloader.prepareCacheDirectory(at: parent.appendingPathComponent("Cache"))

        try VentoyDownloader.clearCache(at: cache)

        #expect(fm.fileExists(atPath: parent.path))
    }

    @Test("no cache is not an error, and an empty Mactoy folder is still tidied up")
    func missingCache() throws {
        let (base, mactoy, cache) = try mactoyFolder()
        defer { try? fm.removeItem(at: base) }
        try fm.removeItem(at: cache)

        #expect(try VentoyDownloader.clearCache(at: cache) == 0)
        #expect(!fm.fileExists(atPath: mactoy.path))
    }

    @Test("a linked or world-writable cache is refused and nothing behind it is deleted")
    func untrustedCacheNotCleared() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("mactoy-leftovers-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let target = base.appendingPathComponent("precious", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let file = target.appendingPathComponent("file")
        try Data("keep".utf8).write(to: file)
        let mactoy = base.appendingPathComponent("Mactoy", isDirectory: true)
        try fm.createDirectory(at: mactoy, withIntermediateDirectories: true)
        let link = mactoy.appendingPathComponent("Cache")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: DriverError.self) { try VentoyDownloader.clearCache(at: link) }
        #expect(fm.fileExists(atPath: file.path))

        try fm.removeItem(at: link)
        try fm.createDirectory(at: link, withIntermediateDirectories: false)
        try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: link.path)
        #expect(throws: DriverError.self) { try VentoyDownloader.clearCache(at: link) }
        #expect(fm.fileExists(atPath: link.path))
    }

    @Test("a link inside the cache is removed without following it")
    func linkInsideCacheNotFollowed() throws {
        let (base, _, cache) = try mactoyFolder()
        defer { try? fm.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("file"))
        try fm.createSymbolicLink(at: cache.appendingPathComponent("escape"), withDestinationURL: outside)

        try VentoyDownloader.clearCache(at: cache)

        #expect(fm.fileExists(atPath: outside.appendingPathComponent("file").path))
    }

    @Test("Mactoy's network session keeps nothing on disk")
    func sessionIsEphemeral() {
        let config = MactoyHTTP.session.configuration
        #expect(config.urlCache == nil)
        #expect(config.httpCookieStorage == nil)
        #expect(config.urlCredentialStorage == nil)
        #expect(!config.httpShouldSetCookies)
        #expect(MactoyHTTP.configuration().urlCache == nil)
    }

    @Test("the shared session's old files are deleted, and nothing else in Library is touched")
    func staleSessionFilesRemoved() throws {
        let library = fm.temporaryDirectory.appendingPathComponent("mactoy-library-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: library) }
        let caches = library.appendingPathComponent("Caches/com.mactoy.Mactoy", isDirectory: true)
        try fm.createDirectory(at: caches.appendingPathComponent("fsCachedData"), withIntermediateDirectories: true)
        try fm.createDirectory(at: caches.appendingPathComponent("Themes"), withIntermediateDirectories: true)
        try fm.createDirectory(at: caches.appendingPathComponent("Ventoy"), withIntermediateDirectories: true)
        for name in ["Cache.db", "Cache.db-shm", "Cache.db-wal"] {
            try Data("x".utf8).write(to: caches.appendingPathComponent(name))
        }
        let storages = library.appendingPathComponent("HTTPStorages/com.mactoy.Mactoy", isDirectory: true)
        try fm.createDirectory(at: storages, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: library.appendingPathComponent("HTTPStorages/com.mactoy.Mactoy.binarycookies"))
        let otherApp = library.appendingPathComponent("HTTPStorages/com.example.Other", isDirectory: true)
        try fm.createDirectory(at: otherApp, withIntermediateDirectories: true)

        MactoyHTTP.removeStaleSharedSessionFiles(library: library)

        for gone in ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"] {
            #expect(!fm.fileExists(atPath: caches.appendingPathComponent(gone).path))
        }
        #expect(!fm.fileExists(atPath: storages.path))
        #expect(!fm.fileExists(atPath: library.appendingPathComponent("HTTPStorages/com.mactoy.Mactoy.binarycookies").path))
        #expect(fm.fileExists(atPath: caches.appendingPathComponent("Themes").path))
        #expect(fm.fileExists(atPath: caches.appendingPathComponent("Ventoy").path))
        #expect(fm.fileExists(atPath: otherApp.path))
    }

    @Test("the helper's old cache under root's Library goes, and its emptied folder with it")
    func helperStaleFilesRemoved() throws {
        let library = fm.temporaryDirectory.appendingPathComponent("mactoy-root-library-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: library) }
        let caches = library.appendingPathComponent("Caches/mactoyd", isDirectory: true)
        try fm.createDirectory(at: caches.appendingPathComponent("fsCachedData"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: caches.appendingPathComponent("Cache.db"))
        let appCaches = library.appendingPathComponent("Caches/com.mactoy.Mactoy", isDirectory: true)
        try fm.createDirectory(at: appCaches, withIntermediateDirectories: true)

        MactoyHTTP.removeStaleSharedSessionFiles(library: library, removeEmptyCacheFolders: true)

        #expect(!fm.fileExists(atPath: caches.path))
        #expect(!fm.fileExists(atPath: appCaches.path))
    }

    @Test("without removeEmptyCacheFolders the app's cache folder stays, even when empty")
    func appKeepsCacheFolder() throws {
        let library = fm.temporaryDirectory.appendingPathComponent("mactoy-library-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: library) }
        let appCaches = library.appendingPathComponent("Caches/com.mactoy.Mactoy", isDirectory: true)
        try fm.createDirectory(at: appCaches, withIntermediateDirectories: true)

        MactoyHTTP.removeStaleSharedSessionFiles(library: library)

        #expect(fm.fileExists(atPath: appCaches.path))
    }

    @Test("a download whose file can't be moved reports its failure once, not twice")
    func downloadFailureReportedOnce() {
        final class Count: @unchecked Sendable { var n = 0; var lastFailed = false }
        let count = Count()
        let delegate = DownloadProgressDelegate(displayName: "x", progress: CallbackProgressSink { _ in }) { result in
            count.n += 1
            if case .failure = result { count.lastFailed = true }
        }
        let session = URLSession(configuration: MactoyHTTP.configuration())
        let task = session.downloadTask(with: URL(string: "https://example.invalid/x")!)
        let missing = fm.temporaryDirectory.appendingPathComponent("mactoy-missing-\(UUID().uuidString)")

        delegate.urlSession(session, downloadTask: task, didFinishDownloadingTo: missing)
        delegate.urlSession(session, task: task, didCompleteWithError: nil)

        #expect(count.n == 1)
        #expect(count.lastFailed)
    }
}
