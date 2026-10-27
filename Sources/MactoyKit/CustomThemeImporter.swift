import CryptoKit
import Foundation

/// Makes an installable theme from a `.zip` or folder the user picked.
/// Same file rules as catalog themes (`ThemeAssembler`).
public enum CustomThemeImporter {
    public static let maxZipBytes = 64 * 1024 * 1024
    static let unzipTimeout: TimeInterval = 60

    public struct Imported: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let directory: URL
        public let settings: ThemeEntry.Settings
        public let previewImage: URL?
        public let skippedFiles: [String]
    }

    public static func importTheme(from source: URL, cacheRoot: URL = ThemeFetcher.defaultCacheRoot()) throws -> Imported {
        try importTheme(from: source, cacheRoot: cacheRoot, workRoot: FileManager.default.temporaryDirectory)
    }

    /// `workRoot` is where a ZIP is unpacked, so tests can see that nothing is left there.
    static func importTheme(from source: URL, cacheRoot: URL, workRoot: URL) throws -> Imported {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let isFolder = fm.fileExists(atPath: source.path, isDirectory: &isDirectory) && isDirectory.boolValue
        let files: [ThemeSourceFile]
        let baseName: String
        if isFolder {
            // A link to a folder enumerates as empty, so read the folder it points to; the name stays what the user picked.
            files = try ThemeAssembler.files(fromFolder: source.resolvingSymlinksInPath())
            baseName = source.lastPathComponent
        } else {
            files = try unpackedFiles(fromZip: source, workRoot: workRoot)
            baseName = source.deletingPathExtension().lastPathComponent
        }
        let root = try themeRoot(in: files.map(\.path))
        let name = root.isEmpty ? baseName : ThemeAssembler.last(root)
        let id = "custom-" + slug(name)
        let prefix = root.isEmpty ? "" : root + "/"
        let digest = contentDigest(files.filter { $0.path.hasPrefix(prefix) }.map { ThemeSourceFile(path: String($0.path.dropFirst(prefix.count)), data: $0.data) })

        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let directory = cacheRoot.appendingPathComponent("\(id)-\(digest)", isDirectory: true)
        let staging = cacheRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        // Always assembled: that is what yields `skippedFiles`, and it is what
        // an existing folder is checked against.
        let skipped = try ThemeAssembler.assemble(files, root: root, mappings: nil, into: staging)
        // The folder name says what went in, but the folder itself may have
        // been edited or built by an older Mactoy. Keep an intact one (it may
        // be in use); replace anything else.
        // attributesOfItem doesn't follow links, so a dangling link counts as in the way.
        if (try? fm.attributesOfItem(atPath: directory.path)) != nil {
            if !sameContents(directory, staging) {
                try fm.removeItem(at: directory)
                try fm.moveItem(at: staging, to: directory)
            }
        } else {
            try fm.moveItem(at: staging, to: directory)
        }

        let fonts = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".pf2") }.sorted()
        let themeText = (try? String(contentsOf: directory.appendingPathComponent("theme.txt"), encoding: .utf8)) ?? ""
        let preview = backgroundImage(inThemeText: themeText)
            .map { directory.appendingPathComponent($0) }
            .flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
        return Imported(id: id, name: name, directory: directory,
                        settings: .init(file: "theme.txt", fonts: fonts.isEmpty ? nil : fonts),
                        previewImage: preview, skippedFiles: skipped)
    }

    // MARK: ZIP

    /// Unpacks with `ditto` in a throwaway private folder, then reads that
    /// folder like any other. The in-process ZIP reader traps (ending the
    /// whole app) on some malformed archives, so a file the user picked never
    /// goes through it; a bad archive here only makes `ditto` exit.
    ///
    /// `ditto` writes nothing outside the folder it is given: it strips `..`
    /// and leading `/` from entry names and won't write through a stored
    /// link. Unpacking into a subfolder keeps even a stray name inside the
    /// private folder. Links it does create are skipped when the folder is read.
    private static func unpackedFiles(fromZip zip: URL, workRoot: URL) throws -> [ThemeSourceFile] {
        // Size of the file itself, not of a link to it.
        let resolved = zip.resolvingSymlinksInPath()
        let size = (try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxZipBytes else { throw ThemeError.downloadTooLarge(size) }

        let fm = FileManager.default
        let work = try makePrivateDirectory(in: workRoot)
        defer { try? fm.removeItem(at: work) }
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        do {
            // No resource forks, extended attributes or quarantine flag: only file contents are wanted.
            try Subprocess.runChecked("/usr/bin/ditto",
                                      ["-x", "-k", "--norsrc", "--noextattr", "--noqtn", resolved.path, unpacked.path],
                                      timeout: unzipTimeout)
        } catch {
            throw ThemeError.unreadableArchive(shortReason(error, hiding: [work.resolvingSymlinksInPath().path, work.path]))
        }
        return try ThemeAssembler.files(fromFolder: unpacked)
    }

    /// A new, empty folder only the current user can enter.
    static func makePrivateDirectory(in parent: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let dir = parent.appendingPathComponent("mactoy-unzip-\(UUID().uuidString)", isDirectory: true)
        // No intermediates, so a name that is already taken fails instead of being reused.
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// One line the user can read: the tool's complaint without our temp paths.
    static func shortReason(_ error: Error, hiding paths: [String]) -> String {
        guard case DriverError.subprocess(_, let status, let stderr) = error else { return error.localizedDescription }
        if status == -1, stderr.hasPrefix("timeout") { return "it took too long to unpack" }
        // ditto reports the real path (/private/var/...), so the resolved form goes first.
        var text = stderr
        for path in paths { text = text.replacingOccurrences(of: path + "/unpacked/", with: "").replacingOccurrences(of: path, with: "") }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard var reason = line else { return "unpacking failed with status \(status)" }
        if reason.hasPrefix("ditto: ") { reason.removeFirst("ditto: ".count) }
        return String(reason.prefix(120))
    }

    // MARK: cache

    /// 12 hex characters of SHA-256 over every file (path and bytes) under the
    /// theme folder, whether or not it will be kept. Lengths go in too, so a
    /// path can't swallow the start of its file's bytes.
    static func contentDigest(_ files: [ThemeSourceFile]) -> String {
        var hasher = SHA256()
        func addLength(_ n: Int) { withUnsafeBytes(of: UInt64(n).bigEndian) { hasher.update(bufferPointer: $0) } }
        for f in files.sorted(by: { $0.path < $1.path }) {
            let path = Data(f.path.utf8)
            addLength(path.count); hasher.update(data: path)
            addLength(f.data.count); hasher.update(data: f.data)
        }
        return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    private static func sameContents(_ a: URL, _ b: URL) -> Bool {
        guard let x = try? ThemeAssembler.files(fromFolder: a), let y = try? ThemeAssembler.files(fromFolder: b) else { return false }
        return x.sorted { $0.path < $1.path } == y.sorted { $0.path < $1.path }
    }

    // MARK: reading the theme

    /// Folder holding the shallowest `theme.txt`; refuses a tie.
    static func themeRoot(in paths: [String]) throws -> String {
        let candidates = paths.filter { ($0 == "theme.txt" || $0.hasSuffix("/theme.txt")) && ThemePath.isSafeRelative($0) }
        guard let minDepth = candidates.map({ $0.split(separator: "/").count }).min() else { throw ThemeError.noThemeFile }
        let shallowest = candidates.filter { $0.split(separator: "/").count == minDepth }.sorted()
        guard shallowest.count == 1 else { throw ThemeError.ambiguousThemes(shallowest) }
        return ThemeAssembler.parent(shallowest[0])
    }

    /// Lowercase ASCII letters, digits and single hyphens, at most 30 long;
    /// "theme" when nothing usable is left. "custom-" + this always fits the installer's id rule.
    static func slug(_ name: String) -> String {
        let mapped = name.lowercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        let trimmed = String(collapsed.prefix(30)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "theme" : trimmed
    }

    /// The file `desktop-image` names, if it is a safe relative path. GRUB
    /// reads `#` lines as comments and lets a later setting win.
    static func backgroundImage(inThemeText text: String) -> String? {
        var found: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let range = trimmed.range(of: #"^desktop-image\s*:\s*"([^"]+)""#, options: .regularExpression) else { continue }
            let match = String(trimmed[range])
            guard let open = match.firstIndex(of: "\""), let close = match.lastIndex(of: "\""), open < close else { continue }
            found = String(match[match.index(after: open)..<close])
        }
        guard let path = found, ThemePath.isSafeRelative(path) else { return nil }
        return path
    }
}
