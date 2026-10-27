import Foundation

/// Where the theme list comes from: `main` on GitHub (so an approved
/// theme PR shows up without an app release), else the last copy that
/// loaded, else the copy bundled in the app.
public struct ThemeCatalogLoader: Sendable {
    public static let remoteCatalogURL = URL(string: "https://raw.githubusercontent.com/cashcon57/mactoy/main/themes/catalog.json")!
    public static func remotePreviewURL(for id: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/cashcon57/mactoy/main/themes/previews/\(id).jpg")!
    }
    static let maxCatalogBytes = 1024 * 1024
    static let maxPreviewBytes = 2 * 1024 * 1024

    public enum Source: Equatable, Sendable { case remote, cached, bundled, none }

    let transport: any ThemeTransport
    let cacheDirectory: URL
    let bundledCatalog: URL?
    let bundledPreviews: URL?

    public init(transport: any ThemeTransport = URLSessionThemeTransport(),
                cacheDirectory: URL = ThemeFetcher.defaultCacheRoot(),
                bundledCatalog: URL? = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "Themes"),
                bundledPreviews: URL? = Bundle.main.resourceURL?.appendingPathComponent("Themes/previews", isDirectory: true)) {
        self.transport = transport
        self.cacheDirectory = cacheDirectory
        self.bundledCatalog = bundledCatalog
        self.bundledPreviews = bundledPreviews
    }

    var cachedCatalogURL: URL { cacheDirectory.appendingPathComponent("catalog.json") }

    public func load() async -> (catalog: ThemeCatalog, source: Source) {
        if let data = try? await transport.data(from: Self.remoteCatalogURL, maxBytes: Self.maxCatalogBytes),
           let catalog = Self.decode(data) {
            Self.writeAtomically(data, to: cachedCatalogURL)
            return (catalog, .remote)
        }
        return loadLocal()
    }

    /// The copies already on this Mac, with no network: the one the last
    /// good `load()` cached, else the one bundled in the app, else nothing.
    /// Lets the app show themes right away while `load()` waits on a slow
    /// connection.
    public func loadLocal() -> (catalog: ThemeCatalog, source: Source) {
        if let data = try? Data(contentsOf: cachedCatalogURL), let catalog = Self.decode(data) { return (catalog, .cached) }
        if let url = bundledCatalog, let data = try? Data(contentsOf: url), let catalog = Self.decode(data) { return (catalog, .bundled) }
        return (ThemeCatalog(schema: ThemeCatalog.supportedSchema, themes: []), .none)
    }

    /// A supported catalog, with only its usable entries. Unusable means
    /// not a JSON object with an `Int` `schema` we support and a `themes`
    /// array, or no entry left after filtering; the next source is tried
    /// then. Entries are decoded one at a
    /// time so a single malformed or future-shaped one (say, a settings key
    /// this app doesn't know) drops only itself, not the whole list.
    static func decode(_ data: Data) -> ThemeCatalog? {
        struct Header: Decodable { let schema: Int }
        struct Body: Decodable { let themes: [LossyEntry] }
        struct LossyEntry: Decodable {
            let entry: ThemeEntry?
            // Never throws, so the array decoder moves on to the next element.
            init(from decoder: any Decoder) { entry = try? ThemeEntry(from: decoder) }
        }

        let decoder = JSONDecoder()
        // Checked first: a newer schema may reshape the entries too.
        guard let header = try? decoder.decode(Header.self, from: data),
              header.schema == ThemeCatalog.supportedSchema,
              let body = try? decoder.decode(Body.self, from: data) else { return nil }
        let usable = ThemeCatalog(schema: header.schema, themes: body.themes.compactMap(\.entry)).usableThemes
        // A catalog with nothing usable is no better than none: if it won it
        // would replace a good cache, and the empty cache would then mask
        // the bundled copy on the next offline launch.
        return usable.isEmpty ? nil : ThemeCatalog(schema: header.schema, themes: usable)
    }

    /// Preview bytes for a catalog theme. Remote copies are cached per
    /// download checksum, so a theme update fetches a new screenshot.
    ///
    /// Previews are JPEGs, so anything else a server sends (an HTML error page
    /// behind a 200, an empty body) is neither shown nor kept: a cached copy
    /// would be served on every launch afterwards. The bundled picture is used instead.
    public func previewData(for entry: ThemeEntry) async -> Data? {
        // The id and checksum end up in a URL and a file name.
        guard entry.problems().isEmpty else { return nil }
        let cached = cacheDirectory.appendingPathComponent("previews/\(entry.id)-\(entry.download.sha256.prefix(16)).jpg")
        // A file an older version cached before this check is ignored too, and replaced below.
        if let data = try? Data(contentsOf: cached), Self.isJPEG(data) { return data }
        if let data = try? await transport.data(from: Self.remotePreviewURL(for: entry.id), maxBytes: Self.maxPreviewBytes),
           Self.isJPEG(data) {
            Self.writeAtomically(data, to: cached)
            return data
        }
        return bundledPreview(named: entry.id)
    }

    /// A JPEG starts with FF D8 FF. An empty body has no start, so it fails too.
    static func isJPEG(_ data: Data) -> Bool { data.starts(with: [0xFF, 0xD8, 0xFF]) }

    private func bundledPreview(named name: String) -> Data? {
        bundledPreviews.flatMap { try? Data(contentsOf: $0.appendingPathComponent("\(name).jpg")) }
    }

    /// Atomic so a crash or a second window mid-write can't leave a
    /// half-written file that the next launch would read as the cache.
    private static func writeAtomically(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
