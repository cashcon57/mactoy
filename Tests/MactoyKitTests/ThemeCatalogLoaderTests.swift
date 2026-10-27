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

        let junk: [Data] = [
            Data("not json".utf8),
            Data("[]".utf8),                                                   // not an object
            Data(#"{"schema":1}"#.utf8),                                       // no themes
            Data(#"{"schema":1,"themes":"nope"}"#.utf8),                       // themes isn't an array
            Data(#"{"themes":[]}"#.utf8),                                      // no schema
            Data(#"{"schema":"1","themes":[]}"#.utf8),                         // schema isn't a number
            try rawCatalog(schema: 2, themes: [["id": 5, "future": true]]),    // unsupported schema, new shape
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

    @Test("previews: fetched once per catalog checksum, else cached, else bundled")
    func previews() async throws {
        let dir = tempDir()
        let previews = dir.appendingPathComponent("bundled-previews")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        try Data("bundled-art".utf8).write(to: previews.appendingPathComponent("pretty.jpg"))
        let t = Transport()
        let loader = makeLoader(t, in: dir, previews: previews)
        let v1 = entry("pretty", sha: "a")
        let url = ThemeCatalogLoader.remotePreviewURL(for: "pretty")

        // Offline with nothing cached: the bundled picture.
        #expect(await loader.previewData(for: v1) == Data("bundled-art".utf8))
        // No picture anywhere.
        #expect(await loader.previewData(for: entry("unknown")) == nil)

        // Online: the remote picture, which is then kept.
        t.responses[url] = Data("remote-art".utf8)
        #expect(await loader.previewData(for: v1) == Data("remote-art".utf8))
        t.responses = [:]
        t.requested = []
        #expect(await loader.previewData(for: v1) == Data("remote-art".utf8))
        #expect(t.requested.isEmpty)

        // The theme was updated (new checksum): fetch again; offline falls
        // back to the bundled one rather than the stale cached picture.
        let v2 = entry("pretty", sha: "d")
        t.responses[url] = Data("remote-art-2".utf8)
        #expect(await loader.previewData(for: v2) == Data("remote-art-2".utf8))
        let v3 = entry("pretty", sha: "e")
        t.responses = [:]
        #expect(await loader.previewData(for: v3) == Data("bundled-art".utf8))
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
        let found = await VentoyVolumeLocator.waitForVolume(onDisk: "disk7", timeout: 10, pollInterval: 0.05,
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
        #expect(elapsed >= 0.4 && elapsed < 5)
    }
}
