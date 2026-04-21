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

    /// Download the `ventoy-<version>-linux.tar.gz` tarball to `workDir`,
    /// emitting progress. Returns the URL of the downloaded file.
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

        var req = URLRequest(url: url)
        req.setValue("Mactoy", forHTTPHeaderField: "User-Agent")

        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw DriverError.network("Download failed: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }

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
