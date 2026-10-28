import CryptoKit
import Foundation

public protocol ThemeTransport: Sendable {
    func data(from url: URL, maxBytes: Int) async throws -> Data
}

public struct URLSessionThemeTransport: ThemeTransport {
    public init() {}

    public func data(from url: URL, maxBytes: Int) async throws -> Data {
        do {
            return try await download(from: url, maxBytes: maxBytes)
        } catch let error as URLError {
            // Said in the user's terms (see ThemeError); anything else URLSession reports stays as it is.
            throw Self.themeError(for: error, host: Self.hostName(of: url)) ?? error
        }
    }

    private func download(from url: URL, maxBytes: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("Mactoy", forHTTPHeaderField: "User-Agent")
        // Streamed, so an oversized or endless body is cut off at the limit
        // instead of being held in memory first.
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let host = Self.hostName(of: url)
        guard let http = response as? HTTPURLResponse else { throw ThemeError.serverUnreachable(host: host) }
        if let failure = Self.themeError(forStatus: http.statusCode, host: host) { throw failure }
        // -1 when the server doesn't say.
        let declared = http.expectedContentLength
        guard declared <= Int64(maxBytes) else { throw ThemeError.downloadTooLarge(Int(clamping: declared)) }
        var data = Data()
        data.reserveCapacity(Int(max(0, declared)))
        // Appending a chunk at a time is much cheaper than a byte at a time.
        let chunkSize = 64 * 1024
        var chunk = [UInt8]()
        chunk.reserveCapacity(chunkSize)
        var count = 0
        for try await byte in bytes {
            count += 1
            guard count <= maxBytes else { throw ThemeError.downloadTooLarge(count) }
            chunk.append(byte)
            if chunk.count == chunkSize {
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        data.append(contentsOf: chunk)
        return data
    }

    static func hostName(of url: URL) -> String { url.host ?? "the server" }

    /// What an HTTP status means for a theme download; nil for 200, the only
    /// answer that carries a file. 404 and 410 say the file isn't there (anymore),
    /// which is for the catalog's maintainers to fix. Every other answer is treated
    /// as a server that can't be used right now: a 403 or 500 usually passes by
    /// itself, and the user can't tell it apart from being offline.
    static func themeError(forStatus status: Int, host: String) -> ThemeError? {
        switch status {
        case 200: return nil
        case 404, 410: return .downloadGone(host: host, status: status)
        default: return .serverUnreachable(host: host)
        }
    }

    /// The network failures that mean nobody answered. Others (a cancelled request,
    /// a certificate problem) are not for this to explain, so they are nil.
    static func themeError(for error: URLError, host: String) -> ThemeError? {
        switch error.code {
        case .notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
            return .serverUnreachable(host: host)
        default:
            return nil
        }
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

    /// What the `.complete` marker holds: a hash of everything besides the
    /// ZIP itself that decides which files end up in the folder. The folder
    /// name only pins the ZIP, so without this a catalog fix to `root`,
    /// `files` or `settings` would keep serving the old assembly.
    public static func fingerprint(for entry: ThemeEntry) -> String {
        struct Recipe: Encodable {
            let root: String
            let files: [ThemeEntry.FileMapping]?
            let settingsFile: String
            let fonts: [String]?
        }
        let recipe = Recipe(root: entry.download.root, files: entry.files, settingsFile: entry.settings.file, fonts: entry.settings.fonts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(recipe)) ?? Data()
        return SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
    }

    /// A finished folder made from this exact recipe that still has the
    /// files the settings name. Anything else is stale or damaged.
    static func isCurrent(_ folder: URL, for entry: ThemeEntry, fingerprint: String) -> Bool {
        guard let marker = try? Data(contentsOf: folder.appendingPathComponent(completeMarker)),
              String(decoding: marker, as: UTF8.self) == fingerprint else { return false }
        return (try? ThemeAssembler.checkSettings(entry.settings, in: folder)) != nil
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
        let fingerprint = Self.fingerprint(for: entry)
        let dir = cacheRoot.appendingPathComponent(Self.folderName(for: entry), isDirectory: true)
        if Self.isCurrent(dir, for: entry, fingerprint: fingerprint) { return dir }
        // The bundled folder is read-only, so one that doesn't match is skipped, not rebuilt.
        if let bundled = bundledRoot?.appendingPathComponent(Self.folderName(for: entry), isDirectory: true),
           Self.isCurrent(bundled, for: entry, fingerprint: fingerprint) {
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
        try Data(fingerprint.utf8).write(to: staging.appendingPathComponent(Self.completeMarker))
        // A concurrent call may have finished first; keep its folder rather
        // than delete one that may already be in use. Whatever else is at
        // `dir` is stale or half-made and gets replaced.
        if Self.isCurrent(dir, for: entry, fingerprint: fingerprint) { return dir }
        try? fm.removeItem(at: dir)
        try fm.moveItem(at: staging, to: dir)
        return dir
    }
}
