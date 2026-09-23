import Foundation
import CryptoKit

public struct VentoyRelease: Codable, Sendable {
    public let tagName: String
    public let prerelease: Bool
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case prerelease
    }
    public var version: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }
}

public struct VentoyDownloader: Sendable {
    public init() {}

    /// Whitelist for Ventoy version strings. Matches `1.1.11`, `1.2.0`,
    /// `2.0.0.1`, etc. Rejects anything that could escape the
    /// `/releases/download/v<version>/...` URL template (path traversal,
    /// shell metacharacters, whitespace, query strings).
    public static func isValidVersion(_ v: String) -> Bool {
        guard !v.isEmpty, v.count <= 32,
              v.allSatisfy({ $0.isNumber || $0 == "." }) else { return false }
        let parts = v.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.count <= 4 && parts.allSatisfy { !$0.isEmpty }
    }

    public static func validateVersion(_ v: String) throws {
        guard isValidVersion(v) else {
            throw DriverError.validation("Invalid Ventoy version string: \(v)")
        }
    }

    public func latestVersion() async throws -> String {
        let url = URL(string: "https://api.github.com/repos/ventoy/Ventoy/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("Mactoy", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw DriverError.network("GitHub releases API returned non-200")
        }
        let rel = try JSONDecoder().decode(VentoyRelease.self, from: data)
        try Self.validateVersion(rel.version)
        return rel.version
    }

    /// List recent stable Ventoy releases, newest first. Excludes prereleases.
    public func recentVersions(limit: Int = 20) async throws -> [String] {
        var comps = URLComponents(string: "https://api.github.com/repos/ventoy/Ventoy/releases")!
        comps.queryItems = [URLQueryItem(name: "per_page", value: "\(max(1, limit))")]
        var req = URLRequest(url: comps.url!)
        req.setValue("Mactoy", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw DriverError.network("GitHub releases API returned non-200")
        }
        let releases = try JSONDecoder().decode([VentoyRelease].self, from: data)
        return releases
            .filter { !$0.prerelease }
            .map(\.version)
            .filter(Self.isValidVersion)
    }

    // MARK: - On-disk locations

    /// Where downloaded tarballs persist between runs (issue #8).
    ///
    /// As root (the daemon) this is under `/Library/Application Support`,
    /// which only root can create entries in. `/Library/Caches` would be
    /// the conventional spot but it's world-writable, so any local user
    /// could pre-create our directory and own what root later writes
    /// into. Unprivileged callers (tests, debugging) get the per-user
    /// caches directory.
    public static func cacheRoot() -> URL {
        if geteuid() == 0 {
            return URL(fileURLWithPath: "/Library/Application Support/Mactoy/Cache", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("com.mactoy.Mactoy/Ventoy", isDirectory: true)
    }

    /// Create (if needed) and return the tarball cache directory.
    /// Refuses a pre-existing path that is a symlink, isn't ours, or is
    /// writable by anyone else — a cache we can't trust is worse than
    /// re-downloading 20 MB, so callers fall back to a run directory.
    public static func prepareCacheDirectory(at root: URL = cacheRoot()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        var st = stat()
        guard lstat(root.path, &st) == 0 else {
            throw DriverError.diskIO("cache: lstat(\(root.path)) failed: \(String(cString: strerror(errno)))")
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == geteuid(), (st.st_mode & 0o022) == 0 else {
            throw DriverError.validation("cache: \(root.path) has unexpected ownership or permissions; not using it")
        }
        return root
    }

    /// A fresh private directory for one run's extracted files, inside
    /// the (verified) cache root. The caller deletes it when the run
    /// ends. Leftovers from runs that died before cleaning up are swept
    /// here once they're a day old. Throws rather than falling back to
    /// a shared temp location if the cache root can't be trusted.
    public static func makeRunDirectory(in root: URL = cacheRoot()) throws -> URL {
        let fm = FileManager.default
        let parent = try prepareCacheDirectory(at: root)
        let cutoff = Date().addingTimeInterval(-86_400)
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix(runDirectoryPrefix) {
            let url = parent.appendingPathComponent(name)
            if let modified = try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
        let dir = parent.appendingPathComponent(runDirectoryPrefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return dir
    }

    private static let runDirectoryPrefix = "mactoy-run-"

    /// Delete every cached Ventoy tarball in `directory` except `keep`.
    /// One version is all an install needs; without this the cache
    /// grows by ~20 MB per Ventoy release forever.
    public static func pruneTarballs(in directory: URL, keeping keep: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix("ventoy-") && name.hasSuffix("-linux.tar.gz") && name != keep.lastPathComponent {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Download the `ventoy-<version>-linux.tar.gz` tarball to `workDir`,
    /// emitting progress. Returns the URL of the downloaded file. If
    /// `workDir` already holds a copy whose SHA-256 matches the
    /// release's published `sha256.txt`, that copy is returned instead.
    public func downloadTarball(
        version: String,
        workDir: URL,
        progress: ProgressSink
    ) async throws -> URL {
        try Self.validateVersion(version)
        let name = "ventoy-\(version)-linux.tar.gz"
        let dest = workDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // Always fetch the checksum first so we can verify a cached
        // tarball on reuse. If the cache bytes don't match the published
        // sha256.txt we refuse to use them.
        let expectedHash = try await fetchSHA256(version: version, filename: name)

        if FileManager.default.fileExists(atPath: dest.path) {
            if try hash(of: dest) == expectedHash {
                progress.report(.init(phase: .downloading, message: "Using cached \(name) (verified)"))
                return dest
            }
            // Mismatched cache — stale download. Blow away and re-fetch.
            try FileManager.default.removeItem(at: dest)
        }

        let urlStr = "https://github.com/ventoy/Ventoy/releases/download/v\(version)/\(name)"
        guard let url = URL(string: urlStr) else {
            throw DriverError.network("Bad URL: \(urlStr)")
        }

        progress.report(.init(phase: .downloading, message: "Downloading Ventoy \(version)..."))

        // Delegate-driven download so we can emit byte-by-byte progress
        // to the UI. `URLSession.shared.download(for:)` gives us no
        // progress visibility — the whole transfer looks like a single
        // silent pause to the user.
        let tmp = try await downloadWithProgress(
            url: url,
            displayName: name,
            progress: progress
        )

        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tmp, to: dest)

        let actual = try hash(of: dest)
        guard actual == expectedHash else {
            try? FileManager.default.removeItem(at: dest)
            throw DriverError.validation("SHA256 mismatch for \(name): expected \(expectedHash), got \(actual)")
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.uint64Value ?? 0
        progress.report(.init(
            phase: .downloading,
            message: "Downloaded \(name) (\(size / 1024 / 1024) MB, SHA256 OK)",
            bytesDone: size,
            bytesTotal: size
        ))
        return dest
    }

    /// Fetch and parse Ventoy's `sha256.txt` release asset and return the
    /// expected hex SHA256 for `filename`. Throws if the file is missing
    /// or doesn't list the asset.
    private func fetchSHA256(version: String, filename: String) async throws -> String {
        let urlStr = "https://github.com/ventoy/Ventoy/releases/download/v\(version)/sha256.txt"
        guard let url = URL(string: urlStr) else {
            throw DriverError.network("Bad checksum URL: \(urlStr)")
        }
        var req = URLRequest(url: url)
        req.setValue("Mactoy", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw DriverError.network("Checksum fetch failed: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        for raw in text.split(separator: "\n") {
            let parts = raw.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, parts.last == Substring(filename) {
                let hex = String(parts[0]).lowercased()
                guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else {
                    throw DriverError.validation("Malformed SHA256 line for \(filename)")
                }
                return hex
            }
        }
        throw DriverError.validation("sha256.txt missing entry for \(filename)")
    }

    /// Download a file and emit per-chunk progress updates so the UI's
    /// progress bar actually moves. `URLSessionDownloadDelegate` gives us
    /// `didWriteData` callbacks with `totalBytesWritten` /
    /// `totalBytesExpectedToWrite`, which map cleanly onto
    /// `ProgressUpdate.bytesDone` / `bytesTotal`.
    private func downloadWithProgress(
        url: URL,
        displayName: String,
        progress: ProgressSink
    ) async throws -> URL {
        var req = URLRequest(url: url)
        req.setValue("Mactoy", forHTTPHeaderField: "User-Agent")

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let delegate = DownloadProgressDelegate(
                displayName: displayName,
                progress: progress,
                completion: { cont.resume(with: $0) }
            )
            let session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )
            let task = session.downloadTask(with: req)
            task.resume()
        }
    }

    private func hash(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Extract `ventoy-<version>-linux.tar.gz` into `workDir` and return the
    /// URL of the extracted ventoy directory.
    public func extractTarball(_ tarball: URL, workDir: URL, progress: ProgressSink) throws -> URL {
        progress.report(.init(phase: .extracting, message: "Extracting \(tarball.lastPathComponent)..."))
        // `bsdtar` on macOS strips leading `/` and parent-component `..`,
        // and `--no-same-owner`/`--no-same-permissions` prevent the
        // tarball from picking its own UID/GID/mode when we're running
        // as root. Combined with verify-before-extract in downloadTarball
        // this keeps zip-slip and bad-ownership out.
        try Subprocess.runChecked("/usr/bin/tar", [
            "xzf", tarball.path,
            "-C", workDir.path,
            "--no-same-owner",
            "--no-same-permissions",
        ])

        // Directory inside is "ventoy-<version>"
        let items = try FileManager.default.contentsOfDirectory(atPath: workDir.path)
        for name in items where name.hasPrefix("ventoy-") && !name.hasSuffix(".tar.gz") {
            let candidate = workDir.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        throw DriverError.corruptPayload("Could not find extracted ventoy-* directory in \(workDir.path)")
    }
}

/// URLSession delegate that forwards download progress to a
/// `ProgressSink` and resolves the continuation with the final
/// temp-file URL on success (or the error on failure).
///
/// Declared `@unchecked Sendable` because URLSession delegate callbacks
/// happen on URLSession's delegate queue, which serializes access to
/// stored state. We only mutate inside the callbacks.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let displayName: String
    private let progress: ProgressSink
    private let completion: (Result<URL, Error>) -> Void
    private var lastReported: Date = .distantPast
    private var finalLocation: URL?

    init(
        displayName: String,
        progress: ProgressSink,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        self.displayName = displayName
        self.progress = progress
        self.completion = completion
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Throttle to ~8 Hz so we don't flood the NDJSON stream.
        let now = Date()
        if now.timeIntervalSince(lastReported) < 0.12 && totalBytesWritten < totalBytesExpectedToWrite {
            return
        }
        lastReported = now

        let done = UInt64(max(0, totalBytesWritten))
        let total: UInt64? = totalBytesExpectedToWrite > 0
            ? UInt64(totalBytesExpectedToWrite)
            : nil
        let mb = Double(done) / 1_048_576
        let message: String
        if let total {
            let totalMB = Double(total) / 1_048_576
            message = String(format: "Downloading %@ (%.1f / %.1f MB)", displayName, mb, totalMB)
        } else {
            message = String(format: "Downloading %@ (%.1f MB)", displayName, mb)
        }
        progress.report(.init(
            phase: .downloading,
            message: message,
            bytesDone: done,
            bytesTotal: total
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move out of the ephemeral delegate-owned temp into a path we
        // control, since the system deletes `location` as soon as this
        // callback returns.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactoy-dl-\(UUID().uuidString.prefix(8))")
        do {
            try FileManager.default.moveItem(at: location, to: tmp)
            finalLocation = tmp
        } catch {
            completion(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        defer { session.finishTasksAndInvalidate() }
        if let error {
            completion(.failure(error))
            return
        }
        if let resp = task.response as? HTTPURLResponse, resp.statusCode != 200 {
            completion(.failure(DriverError.network("Download failed: HTTP \(resp.statusCode)")))
            return
        }
        if let url = finalLocation {
            completion(.success(url))
        } else {
            completion(.failure(DriverError.network("Download finished but no file was produced")))
        }
    }
}
