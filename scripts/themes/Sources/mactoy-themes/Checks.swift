import Foundation
import ImageIO
import MactoyKit

// The checks `validate` runs. They gate contributor pull requests, so each one reads the
// file system without following links: a link would let a PR make a check pass on a file
// that isn't what gets shipped.

/// `attributesOfItem` is an lstat, so a link is seen as a link.
func fileType(_ url: URL) -> FileAttributeType? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
}

/// `previews/ventoy-default.jpg` is the picture of Ventoy's own menu, for the picker's "Ventoy default"
/// tile. It sits beside the theme previews but belongs to no catalog entry (the catalog refuses that id),
/// so it is not looked up by theme and is never an orphan. When it is there it has to meet the same rules
/// as any preview, because it ships in the app the same way.
func previewProblems(_ catalog: ThemeCatalog, catalogPath: String) -> [String] {
    let dir = URL(fileURLWithPath: catalogPath).deletingLastPathComponent().appendingPathComponent("previews")
    if fileType(dir) == .typeSymbolicLink { return ["previews is a symlink; it must be a folder"] }
    var out: [String] = []
    for theme in catalog.themes {
        out += previewFileProblems(dir.appendingPathComponent("\(theme.id).jpg"), label: theme.id, mustExist: true)
    }
    // Any other file in previews/ is left alone: only what a catalog entry or the app names is checked.
    out += previewFileProblems(dir.appendingPathComponent("\(ThemeCatalogLoader.ventoyDefaultPreviewID).jpg"),
                               label: ThemeCatalogLoader.ventoyDefaultPreviewID, mustExist: false)
    return out
}

/// The rules for one preview: a regular file (not a link or folder), at most 600 KB, a readable JPEG, 16:9, at least 1280 wide.
func previewFileProblems(_ url: URL, label: String, mustExist: Bool) -> [String] {
    let name = url.lastPathComponent
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attrs[.size] as? Int else { return mustExist ? ["\(label): missing previews/\(name)"] : [] }
    // CGImageSource would follow a link, while the size above is the link's own.
    guard attrs[.type] as? FileAttributeType == .typeRegular else {
        return ["\(label): previews/\(name) must be a regular file, not a link or folder"]
    }
    var out: [String] = []
    if size > 600 * 1024 { out.append("\(label): preview is \(size / 1024) KB (max 600 KB)") }
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          (CGImageSourceGetType(src) as String?) == "public.jpeg",
          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
    else { return out + ["\(label): preview isn't a readable JPEG"] }
    if w < 1280 || abs(Double(w) / Double(h) - 16.0 / 9.0) >= 0.02 { out.append("\(label): preview is \(w)x\(h); needs 16:9, at least 1280 wide") }
    return out
}

/// What a bundled folder holds, by `/`-separated path: regular files and their bytes, plus
/// everything else found (links, odd file types), which no bundled folder may contain.
struct FolderContents {
    var files: [String: Data] = [:]
    var links: [String] = []
    var other: [String] = []
}

/// Walks `folder` including hidden entries and never descends into a link.
func contents(of folder: URL) -> FolderContents {
    var result = FolderContents()
    let fm = FileManager.default
    guard let walker = fm.enumerator(atPath: folder.path) else { return result }
    while let rel = walker.nextObject() as? String {
        let url = folder.appendingPathComponent(rel)
        switch fileType(url) {
        case .typeDirectory?: continue
        case .typeRegular?: result.files[rel] = (try? Data(contentsOf: url)) ?? Data()
        case .typeSymbolicLink?: result.links.append(rel); walker.skipDescendants()
        default: result.other.append(rel)
        }
    }
    return result
}

/// The folders under `<catalog dir>/bundled/` ship inside the app and are used without a
/// download or a checksum, so this is the one place a pull request can change shipped
/// bytes. Each folder must be named for a current catalog entry, finished, hold only what
/// the installer would copy, and (with `reference`, which returns the folder built from the
/// pinned download) match that download byte for byte.
func bundledProblems(_ catalog: ThemeCatalog, catalogPath: String,
                     reference: ((ThemeEntry) async throws -> URL)? = nil) async -> [String] {
    let root = URL(fileURLWithPath: catalogPath).deletingLastPathComponent().appendingPathComponent("bundled", isDirectory: true)
    let fm = FileManager.default
    if fileType(root) == .typeSymbolicLink { return ["bundled is a symlink; it must be a folder"] }
    guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
    var out: [String] = []
    for name in names.sorted() {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        switch fileType(folder) {
        case .typeSymbolicLink?: out.append("bundled/\(name): is a symlink"); continue
        // Plain files here (a license, say) are not theme folders.
        case .typeRegular?: continue
        case .typeDirectory?: break
        default: out.append("bundled/\(name): isn't a folder or a plain file"); continue
        }
        guard let entry = catalog.themes.first(where: { "\($0.id)-\($0.download.sha256.prefix(16))" == name }) else {
            out.append("bundled/\(name): not named <id>-<first 16 of sha256> for any catalog entry (stale after a catalog change? re-run bundle)")
            continue
        }
        let found = contents(of: folder)
        out += found.links.sorted().map { "bundled/\(name)/\($0): is a symlink" }
        out += found.other.sorted().map { "bundled/\(name)/\($0): isn't a plain file or folder" }
        var flagged = Set<String>()
        for path in found.files.keys.sorted() where path != ".complete" {
            // The same rule the assembler applies, so nothing the installer would refuse is shipped.
            let ext = (path as NSString).pathExtension.lowercased()
            if !ThemePath.isSafeRelative(path) || !ThemeAssembler.allowedExtensions.contains(ext) {
                out.append("bundled/\(name)/\(path): not a file the app copies (allowed: \(ThemeAssembler.allowedExtensions.sorted().joined(separator: ", ")))")
                flagged.insert(path)
            }
        }
        // The app only trusts a folder whose marker holds the fingerprint of the entry's current recipe.
        if let marker = found.files[".complete"] {
            if String(decoding: marker, as: UTF8.self) != ThemeFetcher.fingerprint(for: entry) {
                out.append("bundled/\(name): .complete doesn't match the catalog entry's root/files/settings (re-run bundle)")
            }
        } else {
            out.append("bundled/\(name): missing .complete")
        }
        do { try ThemeAssembler.checkSettings(entry.settings, in: folder) }
        catch { out.append("bundled/\(name): \(error.localizedDescription)") }

        guard let reference else { continue }
        // `.complete` only hashes the recipe; the bytes are checked against what the pinned download gives.
        do {
            let expected = contents(of: try await reference(entry)).files.filter { $0.key != ".complete" }
            let actual = found.files.filter { $0.key != ".complete" }
            for path in expected.keys.sorted() where actual[path] == nil { out.append("bundled/\(name)/\(path): missing (the pinned download has it)") }
            for path in actual.keys.sorted() where expected[path] == nil && !flagged.contains(path) {
                out.append("bundled/\(name)/\(path): extra (not in the pinned download)")
            }
            for path in actual.keys.sorted() where expected[path] != nil && expected[path] != actual[path] {
                out.append("bundled/\(name)/\(path): differs from the pinned download")
            }
        } catch {
            out.append("bundled/\(name): couldn't build the pinned download to compare with (\(error.localizedDescription))")
        }
    }
    return out
}
