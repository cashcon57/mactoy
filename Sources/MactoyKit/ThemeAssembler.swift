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
    /// A ZIP file the user picked (`downloadTooLarge` is for a download, which this wasn't).
    case fileTooLarge(Int)
    case checksumMismatch(expected: String, actual: String)
    /// The server answered "not found" or "gone" for a catalog theme's download.
    case downloadGone(host: String, status: Int)
    /// No answer from the server (or any answer but a file, "gone" or "refused"): a connection problem, not a bad link.
    case serverUnreachable(host: String)
    /// The server answered 403 or 429: it won't serve the file just now (a rate limit, say). The link is fine, and
    /// so is the connection.
    case serverRefused(host: String)
    case unreadableArchive(String)
    case rootNotFound(String)
    case missingFile(String)
    case themeTooLarge(Int)
    case tooManyFiles(Int)
    case noThemeFile
    case ambiguousThemes([String])
    /// More themes than can be listed to choose from.
    case tooManyThemes(Int)
    /// A file that is none of a ZIP, a folder or a theme.txt.
    case unsupportedSource
    /// A theme.txt picked from one of the user's top-level folders (named here), which isn't the theme's own folder.
    case looseThemeFile(folder: String)
    case readOnlyVolume
    case writeFailed(String)
    case unknownTheme(String)
    case destinationExists(String)
    case unsafeVolumeLayout(String)

    public var errorDescription: String? {
        switch self {
        case .downloadTooLarge(let n): return "The theme download is too large (\(n / 1_048_576) MB)."
        // Rounded up, so a file just over the limit doesn't say it is as big as the limit.
        case .fileTooLarge(let n): return "That file is too large to be a theme (\((n + 1_048_575) / 1_048_576) MB)."
        case .checksumMismatch: return "The theme's download has changed since it was added to Mactoy's theme list, so it wasn't used."
        case .downloadGone: return "The theme's download isn't where Mactoy's theme list says it should be."
        case .serverUnreachable(let host): return "Couldn't reach \(host). Check your internet connection and try again."
        case .serverRefused(let host): return "\(host) turned the download away for now. Try again in a while."
        case .unreadableArchive(let why): return "Couldn't open the theme's ZIP file (\(why))."
        case .rootNotFound(let root): return "The theme download doesn't contain the folder \(root)."
        case .missingFile(let path): return "The theme is missing \(path)."
        case .themeTooLarge(let n): return "The theme is too large (\(n / 1_048_576) MB)."
        case .tooManyFiles(let n): return "The theme has too many files (\(n))."
        case .noThemeFile: return "No theme.txt was found. A Ventoy or GRUB theme needs one."
        case .ambiguousThemes(let paths): return "This contains more than one theme (\(paths.joined(separator: ", "))). Choose the folder of the one you want."
        case .tooManyThemes(let n): return "This contains \(n) themes, which is too many to choose from here. Choose the folder of the one you want instead."
        case .unsupportedSource: return "Choose the theme's folder, its .zip file, or its theme.txt."
        case .looseThemeFile(let folder): return "That theme.txt is loose in \(folder). Put the theme's files in their own folder, then choose that folder."
        case .readOnlyVolume: return "This drive is read-only on this Mac (an NTFS drive is, for example), so Mactoy can't add a theme to it."
        case .writeFailed(let why): return "Couldn't save the theme settings: \(why)"
        // The id is all this error knows; callers that know the theme's name say it instead.
        case .unknownTheme(let id): return "“\(id)” is no longer in Mactoy's theme list. Choose another theme."
        case .destinationExists(let path): return "Couldn't save the theme because \(path) already exists."
        case .unsafeVolumeLayout(let path): return "The drive has a link to somewhere else at \(path), so Mactoy won't write to it."
        }
    }

    /// Whether the failure is about the theme's download itself: it moved, or it
    /// changed since the catalog was written. That is worth telling the project about.
    /// A connection problem is not: trying again, or later, is the fix.
    public var meansThemeIsUnavailable: Bool {
        switch self {
        case .downloadGone, .checksumMismatch: return true
        default: return false
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
        guard infos.count <= maxFiles * 2 else { throw ThemeError.tooManyFiles(infos.count) }
        // SWCompression inflates each entry before it checks the entry's size,
        // so these declared sizes are the only guard before `open`. They can
        // understate, which is why catalog ZIPs are unzipped only after their
        // SHA-256 matched; for a ZIP the user picked, that risk is accepted.
        // Directories carry no data, so everything else counts, symlinks included.
        try checkDeclaredSizes(infos.filter { $0.type != .directory }.map(\.size))
        // A stored entry is sliced straight out of the archive, and SWCompression
        // traps (it doesn't throw) when the declared size runs past the end.
        // This only catches a size bigger than the whole archive; entry offsets
        // aren't exposed, so it can't catch every overrun.
        guard infos.allSatisfy({ $0.compressionMethod != .copy || ($0.size ?? 0) <= data.count }) else {
            throw ThemeError.unreadableArchive("an entry is larger than the archive")
        }
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

    /// Entries that will be inflated must declare a size, and the sizes must
    /// add up to no more than `maxUnpackedBytes`. The sum stops at the first
    /// entry that crosses the limit, so a huge declared size can't wrap it.
    static func checkDeclaredSizes(_ sizes: [Int?]) throws {
        var total = 0
        for size in sizes {
            guard let size, size >= 0 else { throw ThemeError.unreadableArchive("an entry doesn't declare a valid size") }
            let (sum, overflow) = total.addingReportingOverflow(size)
            guard !overflow, sum <= maxUnpackedBytes else { throw ThemeError.themeTooLarge(overflow ? Int.max : sum) }
            total = sum
        }
    }

    public static func files(fromFolder folder: URL) throws -> [ThemeSourceFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            throw ThemeError.noThemeFile
        }
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var out: [ThemeSourceFile] = []
        var total = 0
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            // A cloned repository: its history is hidden files that can never be kept, and it
            // can be large enough to trip the caps below before any theme file is looked at.
            if values.isDirectory == true, url.lastPathComponent == ".git" {
                walker.skipDescendants()
                continue
            }
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
        let fm = FileManager.default
        // attributesOfItem doesn't follow symlinks, so a link at `destination`
        // (even a dangling one) counts as existing and is never written through.
        guard (try? fm.attributesOfItem(atPath: destination.path)) == nil else {
            throw ThemeError.destinationExists(destination.path)
        }
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

        // The last component is created without intermediates so that losing a
        // race for the name fails instead of reusing someone else's folder.
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
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
