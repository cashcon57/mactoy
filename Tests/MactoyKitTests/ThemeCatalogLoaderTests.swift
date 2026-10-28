import Foundation
import Testing
@testable import MactoyKit

@Suite("Theme catalog loading and volume lookup")
struct ThemeCatalogLoaderTests {

    final class Transport: ThemeTransport, @unchecked Sendable {
        var responses: [URL: Data] = [:]
        var requested: [URL] = []
        func data(from url: URL, maxBytes: Int) async throws -> Data {
            requested.append(url)
            guard let d = responses[url] else { throw DriverError.network("offline") }
            return d
        }
    }

    private func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-loader-\(UUID().uuidString)") }

    private func entry(_ id: String, sha: Character = "b") -> ThemeEntry {
        ThemeEntry(id: id, name: id, author: "a", homepage: URL(string: "https://github.com/a/b")!,
                   license: "MIT", showsVentoyHotkeys: true, notes: nil,
                   download: .init(url: URL(string: "https://github.com/a/b/releases/download/v1/x.zip")!, sha256: String(repeating: sha, count: 64), root: ""),
                   files: nil, settings: .init(file: "theme.txt"))
    }

    private func catalogData(ids: [String], schema: Int = 1, badSecond: Bool = false) throws -> Data {
        let themes = ids.enumerated().map { i, id -> ThemeEntry in
            var e = entry(id)
            if badSecond && i == 1 { e.id = "BAD ID" }
            return e
        }
        return try JSONEncoder().encode(ThemeCatalog(schema: schema, themes: themes))
    }

    /// A catalog whose `themes` array holds arbitrary JSON, for shapes the
    /// typed encoder can't produce.
    private func rawCatalog(schema: Int = 1, themes: [Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema": schema, "themes": themes])
    }

    private func json(of entry: ThemeEntry) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
    }

    private func makeLoader(_ t: Transport, in dir: URL, bundled: URL? = nil, previews: URL? = nil) -> ThemeCatalogLoader {
        ThemeCatalogLoader(transport: t, cacheDirectory: dir.appendingPathComponent("cache"), bundledCatalog: bundled, bundledPreviews: previews)
    }

    @Test("remote, then cache, then bundle")
    func order() async throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundled = dir.appendingPathComponent("bundled.json")
        try catalogData(ids: ["from-bundle"]).write(to: bundled)
        let t = Transport()
        let loader = ThemeCatalogLoader(transport: t, cacheDirectory: dir.appendingPathComponent("cache"), bundledCatalog: bundled, bundledPreviews: nil)

        var (catalog, source) = await loader.load()
        #expect(source == .bundled && catalog.themes.map(\.id) == ["from-bundle"])

        t.responses[ThemeCatalogLoader.remoteCatalogURL] = try catalogData(ids: ["from-remote", "second"], badSecond: true)
        (catalog, source) = await loader.load()
        #expect(source == .remote && catalog.usableThemes.map(\.id) == ["from-remote"])

        t.responses = [:]
        (catalog, source) = await loader.load()
        #expect(source == .cached && catalog.usableThemes.map(\.id) == ["from-remote"])

        t.responses[ThemeCatalogLoader.remoteCatalogURL] = try catalogData(ids: ["future"], schema: 2)
        (_, source) = await loader.load()
        #expect(source == .cached)
    }

    @Test("loadLocal: cache, else bundle, else nothing, and never the network")
    func localOnly() async throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t = Transport()
        t.responses[ThemeCatalogLoader.remoteCatalogURL] = try catalogData(ids: ["from-remote"])

        // Nothing on disk yet, even though the network would answer.
        var (catalog, source) = makeLoader(t, in: dir).loadLocal()
        #expect(source == .none && catalog.themes.isEmpty)

        let bundled = dir.appendingPathComponent("bundled.json")
        try catalogData(ids: ["from-bundle"]).write(to: bundled)
        let loader = makeLoader(t, in: dir, bundled: bundled)
        (catalog, source) = loader.loadLocal()
        #expect(source == .bundled && catalog.themes.map(\.id) == ["from-bundle"])

        // A successful load() leaves a cached copy, which now wins over the bundle.
        _ = await loader.load()
        t.requested = []
        (catalog, source) = loader.loadLocal()
        #expect(source == .cached && catalog.themes.map(\.id) == ["from-remote"])

        // A damaged cache falls through to the bundle.
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("cache/catalog.json"))
        (catalog, source) = loader.loadLocal()
        #expect(source == .bundled && catalog.themes.map(\.id) == ["from-bundle"])
        #expect(t.requested.isEmpty)
    }

    @Test("nothing anywhere gives an empty catalog")
    func nothing() async throws {
        let loader = makeLoader(Transport(), in: tempDir())
        let (catalog, source) = await loader.load()
        #expect(source == .none && catalog.themes.isEmpty && catalog.schema == ThemeCatalog.supportedSchema)
    }

    @Test("a remote that isn't a usable catalog falls back and leaves the cache alone")
    func unusableRemote() async throws {
        let dir = tempDir()
        let t = Transport()
        let loader = makeLoader(t, in: dir)
        let good = try catalogData(ids: ["kept"])
        t.responses[ThemeCatalogLoader.remoteCatalogURL] = good
        _ = await loader.load()
        let cacheFile = dir.appendingPathComponent("cache/catalog.json")
        #expect(try Data(contentsOf: cacheFile) == good)

        var insecure = try json(of: entry("insecure"))
        insecure["homepage"] = "http://example.com"
        let junk: [Data] = [
            Data("not json".utf8),
            Data("[]".utf8),                                                   // not an object
            Data(#"{"schema":1}"#.utf8),                                       // no themes
            Data(#"{"schema":1,"themes":"nope"}"#.utf8),                       // themes isn't an array
            Data(#"{"themes":[]}"#.utf8),                                      // no schema
            Data(#"{"schema":"1","themes":[]}"#.utf8),                         // schema isn't a number
            try rawCatalog(schema: 2, themes: [["id": 5, "future": true]]),    // unsupported schema, new shape
            Data(#"{"schema":1,"themes":[]}"#.utf8),                           // supported but empty: must not replace a good cache
            try rawCatalog(themes: [NSNull(), 7, ["id": 5, "future": true]]),  // every entry malformed
            try rawCatalog(themes: [insecure]),                                // well-formed, but nothing passes validation
        ]
        for body in junk {
            t.responses[ThemeCatalogLoader.remoteCatalogURL] = body
            let (catalog, source) = await loader.load()
            #expect(source == .cached && catalog.usableThemes.map(\.id) == ["kept"])
            #expect(try Data(contentsOf: cacheFile) == good)
        }
    }

    @Test("an entry with an unknown settings key drops only itself")
    func unknownSettingsKey() async throws {
        var strange = try json(of: entry("strange"))
        var settings = try #require(strange["settings"] as? [String: Any])
        settings["menu_password"] = "x"
        strange["settings"] = settings
        let t = Transport()
        t.responses[ThemeCatalogLoader.remoteCatalogURL] = try rawCatalog(themes: [strange, json(of: entry("good-one"))])
        let (catalog, source) = await makeLoader(t, in: tempDir()).load()
        #expect(source == .remote)
        #expect(catalog.themes.map(\.id) == ["good-one"])
    }

    @Test("entries of the wrong shape are dropped one by one, not the whole catalog")
    func lossyEntries() async throws {
        var missingField = try json(of: entry("no-author"))
        missingField["author"] = nil
        var badURL = try json(of: entry("bad-url"))
        badURL["homepage"] = 42
        let junkEntries: [Any] = [NSNull(), 7, "text", [Any](), [String: Any](), missingField, badURL]
        let t = Transport()
        t.responses[ThemeCatalogLoader.remoteCatalogURL] = try rawCatalog(
            themes: [try json(of: entry("first"))] + junkEntries + [try json(of: entry("last"))])
        let (catalog, source) = await makeLoader(t, in: tempDir()).load()
        #expect(source == .remote)
        #expect(catalog.themes.map(\.id) == ["first", "last"])
    }

    @Test("entries that fail validation or repeat an id are dropped, first one wins")
    func invalidAndDuplicates() async throws {
        var insecure = try json(of: entry("insecure"))
        insecure["homepage"] = "http://example.com"
        var second = try json(of: entry("twice", sha: "c"))
        second["name"] = "second"
        let t = Transport()
        t.responses[ThemeCatalogLoader.remoteCatalogURL] = try rawCatalog(
            themes: [try json(of: entry("twice")), insecure, second, try json(of: entry("other"))])
        let (catalog, source) = await makeLoader(t, in: tempDir()).load()
        #expect(source == .remote)
        #expect(catalog.themes.map(\.id) == ["twice", "other"])
        #expect(catalog.themes.first?.download.sha256 == String(repeating: "b", count: 64))
        #expect(catalog.problems().isEmpty)
    }

    @Test("an unusable cache falls through to the bundle")
    func corruptCache() async throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("cache"), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("cache/catalog.json"))
        let bundled = dir.appendingPathComponent("bundled.json")
        try catalogData(ids: ["from-bundle"]).write(to: bundled)
        let (catalog, source) = await makeLoader(Transport(), in: dir, bundled: bundled).load()
        #expect(source == .bundled && catalog.themes.map(\.id) == ["from-bundle"])
    }

    @Test("a cache with no usable entries falls through to the bundle")
    func poisonedCache() async throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("cache"), withIntermediateDirectories: true)
        try Data(#"{"schema":1,"themes":[]}"#.utf8).write(to: dir.appendingPathComponent("cache/catalog.json"))
        let bundled = dir.appendingPathComponent("bundled.json")
        try catalogData(ids: ["from-bundle"]).write(to: bundled)
        let (catalog, source) = await makeLoader(Transport(), in: dir, bundled: bundled).load()
        #expect(source == .bundled && catalog.themes.map(\.id) == ["from-bundle"])
    }

    /// Starts like a JPEG (FF D8 FF), then says what it is for the assertions.
    private func jpeg(_ label: String) -> Data { Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(label.utf8) }

    private func previewSetup(bundled: Bool = true) throws -> (loader: ThemeCatalogLoader, transport: Transport, dir: URL) {
        let dir = tempDir()
        let previews = dir.appendingPathComponent("bundled-previews")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        if bundled { try jpeg("bundled-art").write(to: previews.appendingPathComponent("pretty.jpg")) }
        let t = Transport()
        return (makeLoader(t, in: dir, previews: previews), t, dir)
    }

    private func cachedPreview(_ dir: URL, _ entry: ThemeEntry) -> URL {
        dir.appendingPathComponent("cache/previews/\(entry.id)-\(entry.download.sha256.prefix(16)).jpg")
    }

    @Test("previews: fetched once per catalog checksum, else cached, else bundled")
    func previews() async throws {
        let (loader, t, _) = try previewSetup()
        let v1 = entry("pretty", sha: "a")
        let url = ThemeCatalogLoader.remotePreviewURL(for: "pretty")

        // Offline with nothing cached: the bundled picture.
        #expect(await loader.previewData(for: v1) == jpeg("bundled-art"))
        // No picture anywhere.
        #expect(await loader.previewData(for: entry("unknown")) == nil)

        // Online: the remote picture, which is then kept.
        t.responses[url] = jpeg("remote-art")
        #expect(await loader.previewData(for: v1) == jpeg("remote-art"))
        t.responses = [:]
        t.requested = []
        #expect(await loader.previewData(for: v1) == jpeg("remote-art"))
        #expect(t.requested.isEmpty)

        // The theme was updated (new checksum): fetch again; offline falls
        // back to the bundled one rather than the stale cached picture.
        let v2 = entry("pretty", sha: "d")
        t.responses[url] = jpeg("remote-art-2")
        #expect(await loader.previewData(for: v2) == jpeg("remote-art-2"))
        let v3 = entry("pretty", sha: "e")
        t.responses = [:]
        #expect(await loader.previewData(for: v3) == jpeg("bundled-art"))
    }

    @Test("a reply that isn't a JPEG is neither shown nor cached; the bundled picture is used",
          arguments: ["<!DOCTYPE html><html>404: Not Found</html>", "404: Not Found", "", "\u{89}PNG\r\n"])
    func nonImageIsNotCached(body: String) async throws {
        let (loader, t, dir) = try previewSetup()
        let v1 = entry("pretty", sha: "a")
        t.responses[ThemeCatalogLoader.remotePreviewURL(for: "pretty")] = Data(body.utf8)
        #expect(await loader.previewData(for: v1) == jpeg("bundled-art"))
        #expect(!FileManager.default.fileExists(atPath: cachedPreview(dir, v1).path), "nothing written to the cache")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("cache/previews").path)
                || ((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("cache/previews").path)) ?? []).isEmpty)
        // And it asks again next time, since there is nothing kept.
        t.requested = []
        #expect(await loader.previewData(for: v1) == jpeg("bundled-art"))
        #expect(t.requested == [ThemeCatalogLoader.remotePreviewURL(for: "pretty")])
    }

    @Test("with no bundled picture either, a non-image reply gives nothing")
    func nonImageWithoutBundle() async throws {
        let (loader, t, dir) = try previewSetup(bundled: false)
        let v1 = entry("pretty", sha: "a")
        t.responses[ThemeCatalogLoader.remotePreviewURL(for: "pretty")] = Data("<html></html>".utf8)
        #expect(await loader.previewData(for: v1) == nil)
        #expect(!FileManager.default.fileExists(atPath: cachedPreview(dir, v1).path))
    }

    @Test("the JPEG check is the three magic bytes, so a shorter or different start fails")
    func jpegMagic() {
        #expect(ThemeCatalogLoader.isJPEG(Data([0xFF, 0xD8, 0xFF])))
        #expect(ThemeCatalogLoader.isJPEG(Data([0xFF, 0xD8, 0xFF, 0xDB, 0x00])))
        #expect(!ThemeCatalogLoader.isJPEG(Data()))
        #expect(!ThemeCatalogLoader.isJPEG(Data([0xFF, 0xD8])))
        #expect(!ThemeCatalogLoader.isJPEG(Data([0xFF, 0xD8, 0x00])))
        #expect(!ThemeCatalogLoader.isJPEG(Data([0x00, 0xFF, 0xD8, 0xFF])))
    }

    @Test("a cached file that isn't a JPEG is ignored and replaced by the next good download")
    func badCacheIsIgnored() async throws {
        let (loader, t, dir) = try previewSetup()
        let v1 = entry("pretty", sha: "a")
        let cached = cachedPreview(dir, v1)
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        for junk in [Data("<html>cached error page</html>".utf8), Data()] {
            try junk.write(to: cached)
            // Offline: not the junk, the bundled picture.
            #expect(await loader.previewData(for: v1) == jpeg("bundled-art"))
        }
        // Online: the good picture replaces the junk and is served from the cache after.
        t.responses[ThemeCatalogLoader.remotePreviewURL(for: "pretty")] = jpeg("remote-art")
        #expect(await loader.previewData(for: v1) == jpeg("remote-art"))
        #expect(try Data(contentsOf: cached) == jpeg("remote-art"))
        t.responses = [:]
        #expect(await loader.previewData(for: v1) == jpeg("remote-art"))
    }

    @Test("a good cached picture is still served without a request")
    func goodCacheIsServed() async throws {
        let (loader, t, dir) = try previewSetup()
        let v1 = entry("pretty", sha: "a")
        let cached = cachedPreview(dir, v1)
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg("cached-art").write(to: cached)
        #expect(await loader.previewData(for: v1) == jpeg("cached-art"))
        #expect(t.requested.isEmpty)
    }

    @Test("the picture of Ventoy's own menu comes from the bundle, with no request")
    func ventoyDefaultPreview() throws {
        let (loader, t, dir) = try previewSetup()
        // Nothing bundled under that name yet.
        #expect(loader.ventoyDefaultPreviewData() == nil)
        try jpeg("stock-menu").write(to: dir.appendingPathComponent("bundled-previews/ventoy-default.jpg"))
        #expect(loader.ventoyDefaultPreviewData() == jpeg("stock-menu"))
        #expect(t.requested.isEmpty, "it is never fetched")
        #expect(ThemeCatalogLoader.ventoyDefaultPreviewID == "ventoy-default")
    }

    @Test("a bundled Ventoy default picture that isn't a JPEG, or no bundle at all, gives nothing")
    func ventoyDefaultPreviewNotUsable() throws {
        let (loader, _, dir) = try previewSetup()
        let file = dir.appendingPathComponent("bundled-previews/ventoy-default.jpg")
        for junk in [Data("<html></html>".utf8), Data()] {
            try junk.write(to: file)
            #expect(loader.ventoyDefaultPreviewData() == nil)
        }
        let t = Transport()
        #expect(makeLoader(t, in: dir).ventoyDefaultPreviewData() == nil, "no bundled previews folder")
    }

    @Test("an entry can't ask for the Ventoy default picture's file, so a catalog can't replace it")
    func ventoyDefaultIsNotACatalogPreview() async throws {
        let (loader, t, dir) = try previewSetup()
        try jpeg("stock-menu").write(to: dir.appendingPathComponent("bundled-previews/ventoy-default.jpg"))
        t.responses[ThemeCatalogLoader.remotePreviewURL(for: "ventoy-default")] = jpeg("evil")
        #expect(await loader.previewData(for: entry("ventoy-default")) == nil)
        #expect(t.requested.isEmpty)
        #expect(loader.ventoyDefaultPreviewData() == jpeg("stock-menu"))
    }

    @Test("a preview for an entry with an unsafe id touches nothing")
    func unsafePreviewID() async throws {
        let dir = tempDir()
        let t = Transport()
        let loader = makeLoader(t, in: dir)
        t.responses = [ThemeCatalogLoader.remotePreviewURL(for: "../x"): Data("x".utf8)]
        #expect(await loader.previewData(for: entry("../x")) == nil)
        #expect(t.requested.isEmpty)
    }

    @Test("volume lookup matches the disk's own slices only")
    func locator() throws {
        let vols = tempDir()
        for name in ["Ventoy", "Ventoy 1", "Other"] {
            try FileManager.default.createDirectory(at: vols.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let ids = ["Ventoy": "disk10s1", "Ventoy 1": "disk1s1", "Other": "disk1s2"]
        let found = VentoyVolumeLocator.find(onDisk: "disk1", volumesDirectory: vols) { ids[$0.lastPathComponent] }
        #expect(found?.lastPathComponent == "Ventoy 1")
        #expect(VentoyVolumeLocator.find(onDisk: "disk2", volumesDirectory: vols) { ids[$0.lastPathComponent] } == nil)
    }

    @Test("waitForVolume returns once the volume mounts")
    func waitFinds() async throws {
        let vols = tempDir()
        try FileManager.default.createDirectory(at: vols, withIntermediateDirectories: true)
        let mount = vols.appendingPathComponent("Ventoy")
        Task.detached {
            try? await Task.sleep(nanoseconds: 300_000_000)
            try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        }
        // A generous timeout: on a small CI machine other tests can hold the
        // worker threads for several seconds.
        let found = await VentoyVolumeLocator.waitForVolume(onDisk: "disk7", timeout: 60, pollInterval: 0.05,
                                                            volumesDirectory: vols) { _ in "disk7s1" }
        #expect(found?.lastPathComponent == "Ventoy")
    }

    @Test("waitForVolume gives up after the timeout")
    func waitTimesOut() async throws {
        let vols = tempDir()
        try FileManager.default.createDirectory(at: vols, withIntermediateDirectories: true)
        let start = Date()
        let found = await VentoyVolumeLocator.waitForVolume(onDisk: "disk7", timeout: 0.4, pollInterval: 0.05,
                                                            volumesDirectory: vols) { _ in "disk7s1" }
        let elapsed = Date().timeIntervalSince(start)
        #expect(found == nil)
        // Only the lower bound is exact; the upper one just catches a wait
        // that never gives up, with room for a busy CI machine.
        #expect(elapsed >= 0.4 && elapsed < 60)
    }
}
