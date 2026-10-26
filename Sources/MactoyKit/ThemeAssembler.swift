import Foundation
import SWCompression

/// One file from a theme download or folder, by its `/`-separated path inside it.
public struct ThemeSourceFile: Sendable, Equatable {
    public let path: String
    public let data: Data
    public init(path: String, data: Data) { self.path = path; self.data = data }
}

public enum ThemeError: Error, Equatable, LocalizedError {
    case downloadTooLarge(Int)
    case checksumMismatch(expected: String, actual: String)
    case unreadableArchive(String)
    case rootNotFound(String)
    case missingFile(String)
    case themeTooLarge(Int)
    case tooManyFiles(Int)
    case noThemeFile
    case ambiguousThemes([String])
    case readOnlyVolume
    case writeFailed(String)
    case unknownTheme(String)

    public var errorDescription: String? {
        switch self {
        case .downloadTooLarge(let n): return "The theme download is too large (\(n / 1_048_576) MB)."
        case .checksumMismatch: return "The theme download doesn't match the checksum in Mactoy's theme list, so it wasn't used. The theme's author may have changed the file."
        case .unreadableArchive(let why): return "Couldn't open the theme's ZIP file (\(why))."
        case .rootNotFound(let root): return "The theme download doesn't contain the folder \(root)."
        case .missingFile(let path): return "The theme is missing \(path)."
        case .themeTooLarge(let n): return "The theme is too large (\(n / 1_048_576) MB)."
        case .tooManyFiles(let n): return "The theme has too many files (\(n))."
        case .noThemeFile: return "No theme.txt was found. A Ventoy or GRUB theme needs one."
        case .ambiguousThemes(let paths): return "This contains more than one theme (\(paths.joined(separator: ", "))). Choose the folder of the one you want."
        case .readOnlyVolume: return "This drive is read-only on this Mac (an NTFS drive is, for example), so Mactoy can't add a theme to it."
        case .writeFailed(let why): return "Couldn't save the theme settings: \(why)"
        case .unknownTheme(let id): return "The theme \(id) isn't in Mactoy's theme list any more."
        }
    }
}

public enum ThemeAssembler {
    /// File types GRUB themes use. `.cfg` is never copied: Ventoy runs
    /// `ventoy_grub.cfg` as a script.
    public static let allowedExtensions: Set<String> = ["txt", "png", "jpg", "jpeg", "tga", "pf2"]
    public static let maxThemeBytes = 40 * 1024 * 1024
    public static let maxFiles = 2000
    public static let maxUnpackedBytes = 128 * 1024 * 1024

    public static func files(fromZip data: Data) throws -> [ThemeSourceFile] {
        let infos: [ZipEntryInfo]
        do { infos = try ZipContainer.info(container: data) } catch { throw ThemeError.unreadableArchive("\(error)") }
        let declared = infos.reduce(0) { $0 + ($1.size ?? 0) }
        guard declared <= maxUnpackedBytes else { throw ThemeError.themeTooLarge(declared) }
        let entries: [ZipEntry]
        do { entries = try ZipContainer.open(container: data) } catch { throw ThemeError.unreadableArchive("\(error)") }
        var total = 0
        var out: [ThemeSourceFile] = []
        // Regular files only: directories carry no data and a symlink entry's
        // "contents" are just its target path.
        for entry in entries where entry.info.type == .regular {
            guard let d = entry.data else { continue }
            total += d.count
            guard total <= maxUnpackedBytes else { throw ThemeError.themeTooLarge(total) }
            var name = entry.info.name
            while name.hasPrefix("./") { name.removeFirst(2) }
            out.append(ThemeSourceFile(path: name, data: d))
        }
        return out
    }

    public static func files(fromFolder folder: URL) throws -> [ThemeSourceFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            throw ThemeError.noThemeFile
        }
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var out: [ThemeSourceFile] = []
        var total = 0
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            // Disallowed files are read too (assemble drops them later), so
            // the bound is looser than `maxFiles`.
            guard out.count < maxFiles * 2 else { throw ThemeError.tooManyFiles(out.count + 1) }
            total += values.fileSize ?? 0
            guard total <= maxUnpackedBytes else { throw ThemeError.themeTooLarge(total) }
            // A path that resolves outside the folder (via a symlinked parent) is left out.
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            out.append(ThemeSourceFile(path: String(path.dropFirst(base.count)), data: try Data(contentsOf: url)))
        }
        return out
    }

    /// Writes the theme's files into `destination` (which must not exist)
    /// and returns the destination paths it skipped, sorted.
    ///
    /// Every destination path is checked with `ThemePath.isSafeRelative`
    /// and its extension against `allowedExtensions` before anything is
    /// written. That one check is what keeps hidden files, `..` from archive
    /// entry names, and scripts out of the folder that later lands on a drive.
    @discardableResult
    public static func assemble(_ files: [ThemeSourceFile], root: String,
                                mappings: [ThemeEntry.FileMapping]?, into destination: URL) throws -> [String] {
        let prefix = root.isEmpty ? "" : root + "/"
        var picked: [(String, Data)] = []
        if let mappings {
            for m in mappings {
                if let ext = globExtension(m.from) {
                    // A glob's `to` is a destination folder ("." is the theme root).
                    let dir = prefix + parent(m.from)
                    let matches = files.filter { parent($0.path) == dir.trimmingSuffix("/") && ($0.path as NSString).pathExtension.lowercased() == ext }
                    guard !matches.isEmpty else { throw ThemeError.missingFile(m.from) }
                    for f in matches { picked.append((join(m.to, last(f.path)), f.data)) }
                } else {
                    guard let f = files.first(where: { $0.path == prefix + m.from }) else { throw ThemeError.missingFile(m.from) }
                    picked.append((m.to, f.data))
                }
            }
        } else {
            let inRoot = files.filter { $0.path.hasPrefix(prefix) }
            guard !inRoot.isEmpty else { throw ThemeError.rootNotFound(root) }
            picked = inRoot.map { (String($0.path.dropFirst(prefix.count)), $0.data) }
        }

        var accepted: [(String, Data)] = []
        var skipped: [String] = []
        for (path, data) in picked {
            if ThemePath.isSafeRelative(path), allowedExtensions.contains((path as NSString).pathExtension.lowercased()) {
                accepted.append((path, data))
            } else {
                skipped.append(path)
            }
        }
        guard accepted.count <= maxFiles else { throw ThemeError.tooManyFiles(accepted.count) }
        let total = accepted.reduce(0) { $0 + $1.1.count }
        guard total <= maxThemeBytes else { throw ThemeError.themeTooLarge(total) }

        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for (path, data) in accepted {
            let url = destination.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return skipped.sorted()
    }

    /// The files the settings name must exist in the assembled folder.
    public static func checkSettings(_ settings: ThemeEntry.Settings, in folder: URL) throws {
        for path in [settings.file] + (settings.fonts ?? []) where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) {
            throw ThemeError.missingFile(path)
        }
    }

    static func globExtension(_ from: String) -> String? {
        let name = last(from)
        guard name.hasPrefix("*.") else { return nil }
        return String(name.dropFirst(2)).lowercased()
    }
    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
    static func last(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
    static func join(_ dir: String, _ name: String) -> String { dir == "." ? name : dir + "/" + name }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String { hasSuffix(suffix) ? String(dropLast(suffix.count)) : self }
}
