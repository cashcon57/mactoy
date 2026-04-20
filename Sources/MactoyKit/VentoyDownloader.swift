import Foundation

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

    public func latestVersion() async throws -> String {
        let url = URL(string: "https://api.github.com/repos/ventoy/Ventoy/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("Mactoy", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw DriverError.network("GitHub releases API returned non-200")
        }
        let rel = try JSONDecoder().decode(VentoyRelease.self, from: data)
        return rel.version
    }

    /// Download the `ventoy-<version>-linux.tar.gz` tarball to `workDir`,
    /// emitting progress. Returns the URL of the downloaded file.
    public func downloadTarball(
        version: String,
        workDir: URL,
        progress: ProgressSink
    ) async throws -> URL {
        let name = "ventoy-\(version)-linux.tar.gz"
        let dest = workDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: dest.path) {
            progress.report(.init(phase: .downloading, message: "Using cached \(name)"))
            return dest
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

        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.uint64Value ?? 0
        progress.report(.init(
            phase: .downloading,
            message: "Downloaded \(name) (\(size / 1024 / 1024) MB)",
            bytesDone: size,
            bytesTotal: size
        ))
        return dest
    }

    /// Extract `ventoy-<version>-linux.tar.gz` into `workDir` and return the
    /// URL of the extracted ventoy directory.
    public func extractTarball(_ tarball: URL, workDir: URL, progress: ProgressSink) throws -> URL {
        progress.report(.init(phase: .extracting, message: "Extracting \(tarball.lastPathComponent)..."))
        try Subprocess.runChecked("/usr/bin/tar", ["xzf", tarball.path, "-C", workDir.path])

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
