import CryptoKit
import Foundation

public protocol ThemeTransport: Sendable {
    func data(from url: URL, maxBytes: Int) async throws -> Data
}

public struct URLSessionThemeTransport: ThemeTransport {
    public init() {}
    public func data(from url: URL, maxBytes: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("Mactoy", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DriverError.network("\(url.host ?? "server") returned \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard data.count <= maxBytes else { throw ThemeError.downloadTooLarge(data.count) }
        return data
    }
}

/// Downloads a catalog theme, checks it against the catalog's SHA-256,
/// and keeps the assembled folder in the user's caches.
public struct ThemeFetcher: Sendable {
    public static let maxDownloadBytes = 64 * 1024 * 1024
    static let completeMarker = ".complete"

    let transport: any ThemeTransport
    let cacheRoot: URL
    /// Themes shipped inside the app (`Contents/Resources/Themes/bundled`),
    /// one folder per `<id>-<sha256 prefix 16>`, so the default theme
    /// needs no download. Only used when the folder name matches the
    /// catalog's current checksum.
    let bundledRoot: URL?

    public init(transport: any ThemeTransport = URLSessionThemeTransport(),
                cacheRoot: URL = ThemeFetcher.defaultCacheRoot(),
                bundledRoot: URL? = Bundle.main.resourceURL?.appendingPathComponent("Themes/bundled", isDirectory: true)) {
        self.transport = transport
        self.cacheRoot = cacheRoot
        self.bundledRoot = bundledRoot
    }

    static func folderName(for entry: ThemeEntry) -> String { "\(entry.id)-\(entry.download.sha256.prefix(16))" }

    public static func defaultCacheRoot() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("com.mactoy.Mactoy/Themes", isDirectory: true)
    }

    public func themeDirectory(for entry: ThemeEntry) async throws -> URL {
        // The id and checksum become a folder name (and that folder may be
        // deleted below), so an entry that fails catalog validation never
        // gets as far as the file system.
        guard entry.problems().isEmpty else { throw ThemeError.unknownTheme(entry.id) }
        let fm = FileManager.default
        let dir = cacheRoot.appendingPathComponent(Self.folderName(for: entry), isDirectory: true)
        if fm.fileExists(atPath: dir.appendingPathComponent(Self.completeMarker).path) { return dir }
        if let bundled = bundledRoot?.appendingPathComponent(Self.folderName(for: entry), isDirectory: true),
           fm.fileExists(atPath: bundled.appendingPathComponent(Self.completeMarker).path) {
            return bundled
        }

        let data = try await transport.data(from: entry.download.url, maxBytes: Self.maxDownloadBytes)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == entry.download.sha256 else {
            throw ThemeError.checksumMismatch(expected: entry.download.sha256, actual: actual)
        }
        let files = try ThemeAssembler.files(fromZip: data)
        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let staging = cacheRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try ThemeAssembler.assemble(files, root: entry.download.root, mappings: entry.files, into: staging)
        try ThemeAssembler.checkSettings(entry.settings, in: staging)
        // The marker goes in before the move, so the folder is complete from
        // the moment it appears under its final name.
        try Data().write(to: staging.appendingPathComponent(Self.completeMarker))
        // A concurrent call may have finished first; keep its folder rather
        // than delete one that may already be in use.
        if fm.fileExists(atPath: dir.appendingPathComponent(Self.completeMarker).path) { return dir }
        try? fm.removeItem(at: dir)
        try fm.moveItem(at: staging, to: dir)
        return dir
    }
}
