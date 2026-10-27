import CryptoKit
import Foundation
import ImageIO
import MactoyKit

let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadCatalog(_ path: String) -> ThemeCatalog {
    do { return try JSONDecoder().decode(ThemeCatalog.self, from: Data(contentsOf: URL(fileURLWithPath: path))) }
    catch { fail("Can't read \(path): \(error)") }
}

func previewProblems(_ catalog: ThemeCatalog, catalogPath: String) -> [String] {
    let dir = URL(fileURLWithPath: catalogPath).deletingLastPathComponent().appendingPathComponent("previews")
    var out: [String] = []
    for theme in catalog.themes {
        let url = dir.appendingPathComponent("\(theme.id).jpg")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { out.append("\(theme.id): missing previews/\(theme.id).jpg"); continue }
        if size > 600 * 1024 { out.append("\(theme.id): preview is \(size / 1024) KB (max 600 KB)") }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              (CGImageSourceGetType(src) as String?) == "public.jpeg",
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
        else { out.append("\(theme.id): preview isn't a readable JPEG"); continue }
        if w < 1280 || abs(Double(w) / Double(h) - 16.0 / 9.0) >= 0.02 { out.append("\(theme.id): preview is \(w)x\(h); needs 16:9, at least 1280 wide") }
    }
    return out
}

/// The folders under `<catalog dir>/bundled/` ship inside the app and are used without a
/// download, so each must be one the app would accept: named for a current catalog entry,
/// finished, and holding what that entry's settings point at.
func bundledProblems(_ catalog: ThemeCatalog, catalogPath: String) -> [String] {
    let root = URL(fileURLWithPath: catalogPath).deletingLastPathComponent().appendingPathComponent("bundled", isDirectory: true)
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
    var out: [String] = []
    for name in names.sorted() {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        var isDirectory: ObjCBool = false
        // Plain files here (a license, say) are not theme folders.
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
        guard let entry = catalog.themes.first(where: { "\($0.id)-\($0.download.sha256.prefix(16))" == name }) else {
            out.append("bundled/\(name): not named <id>-<first 16 of sha256> for any catalog entry (stale after a catalog change? re-run bundle)")
            continue
        }
        // The app only trusts a folder whose marker holds the fingerprint of the entry's current recipe.
        guard let marker = try? String(contentsOf: folder.appendingPathComponent(".complete"), encoding: .utf8) else {
            out.append("bundled/\(name): missing .complete"); continue
        }
        if marker != ThemeFetcher.fingerprint(for: entry) {
            out.append("bundled/\(name): .complete doesn't match the catalog entry's root/files/settings (re-run bundle)")
        }
        do { try ThemeAssembler.checkSettings(entry.settings, in: folder) }
        catch { out.append("bundled/\(name): \(error.localizedDescription)") }
    }
    return out
}

/// Keeps the last download so `validate` can say what the assembler skipped without fetching twice.
actor CapturingTransport: ThemeTransport {
    private let inner = URLSessionThemeTransport()
    private var last: Data?
    func data(from url: URL, maxBytes: Int) async throws -> Data {
        let data = try await inner.data(from: url, maxBytes: maxBytes)
        last = data
        return data
    }
    func takeLast() -> Data? { defer { last = nil }; return last }
}

func validate(_ rest: [String]) async {
    guard let path = rest.first else { fail("usage: validate <catalog.json> [--download] [--only a,b]") }
    let catalog = loadCatalog(path)
    var problems = catalog.problems() + previewProblems(catalog, catalogPath: path) + bundledProblems(catalog, catalogPath: path)
    if rest.contains("--download") {
        let only = rest.firstIndex(of: "--only").flatMap { rest.indices.contains($0 + 1) ? Set(rest[$0 + 1].split(separator: ",").map(String.init)) : nil }
        for id in (only ?? []).sorted() where !catalog.themes.contains(where: { $0.id == id }) { problems.append("--only: no theme \(id)") }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-themes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let transport = CapturingTransport()
        // bundledRoot nil: always build from the real download, never from a shipped copy.
        let fetcher = ThemeFetcher(transport: transport, cacheRoot: cache, bundledRoot: nil)
        for theme in catalog.themes where only == nil || only!.contains(theme.id) {
            do {
                let dir = try await fetcher.themeDirectory(for: theme)
                let files = try ThemeAssembler.files(fromFolder: dir).filter { !$0.path.hasPrefix(".") }
                let bytes = files.reduce(0) { $0 + $1.data.count }
                print("✓ \(theme.id): \(files.count) files, \(bytes / 1024) KB")
                // The fetcher drops the skipped list, so assemble the same download once more to get it.
                if let zip = await transport.takeLast() {
                    let scratch = cache.appendingPathComponent("skipped-\(theme.id)")
                    let skipped = try ThemeAssembler.assemble(ThemeAssembler.files(fromZip: zip), root: theme.download.root,
                                                              mappings: theme.files, into: scratch)
                    print(skipped.isEmpty ? "  skipped: none" : "  skipped (\(skipped.count)): " + skipped.joined(separator: ", "))
                }
            } catch {
                problems.append("\(theme.id): \(error.localizedDescription)")
            }
        }
    }
    if problems.isEmpty { print("\(catalog.themes.count) themes OK") } else { fail(problems.joined(separator: "\n")) }
}

func hash(_ rest: [String]) async {
    guard let s = rest.first, let url = URL(string: s) else { fail("usage: hash <url>") }
    do {
        let data = try await URLSessionThemeTransport().data(from: url, maxBytes: ThemeFetcher.maxDownloadBytes)
        print("sha256: " + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        for f in try ThemeAssembler.files(fromZip: data) where f.path.hasSuffix("theme.txt") { print("theme.txt at: \(f.path)") }
    } catch { fail("\(error)") }
}

/// Alt text and link text come from the catalog, so keep them from breaking out of the HTML.
func htmlEscaped(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

func galleryMarkdown(_ catalog: ThemeCatalog) -> String {
    var md = """
    # Boot menu themes

    <!-- Generated by `swift run --package-path scripts/themes mactoy-themes gallery themes/catalog.json themes/README.md`. Don't edit by hand. -->

    Mactoy can add any of these to a Ventoy drive, from **Install Ventoy** or **Manage Disk**. Each screenshot is the theme booted in Ventoy. Mactoy downloads themes from their authors, checks each download against the checksum in [`catalog.json`](catalog.json), and copies only image, font and theme files to your drive.

    Want to add one? See [Adding a boot theme](../CONTRIBUTING.md#adding-a-boot-theme).

    | | |
    |---|---|

    """
    let cells = catalog.themes.map { t -> String in
        let keys = t.showsVentoyHotkeys ? "F1–F6 key bar" : "no Ventoy key bar"
        return "<img src=\"previews/\(t.id).jpg\" width=\"420\" alt=\"\(htmlEscaped(t.name))\"><br>**\(t.name)** by [\(t.author)](\(t.homepage.absoluteString)) · \(t.license) · \(keys)"
    }
    stride(from: 0, to: cells.count, by: 2).forEach { i in
        md += "| \(cells[i]) | \(i + 1 < cells.count ? cells[i + 1] : "") |\n"
    }
    return md
}

func gallery(_ rest: [String]) {
    guard rest.count >= 2 else { fail("usage: gallery <catalog.json> <out.md> [--check]") }
    let text = galleryMarkdown(loadCatalog(rest[0]))
    let out = URL(fileURLWithPath: rest[1])
    if rest.contains("--check") {
        guard (try? String(contentsOf: out, encoding: .utf8)) == text else { fail("\(rest[1]) is out of date; run the gallery command") }
        print("gallery up to date")
    } else {
        do { try text.write(to: out, atomically: true, encoding: .utf8) } catch { fail("\(error)") }
        print("wrote \(rest[1])")
    }
}

func install(_ rest: [String]) async {
    guard rest.count >= 3 else { fail("usage: install <catalog.json> <volume> <id>") }
    let catalog = loadCatalog(rest[0])
    guard let theme = catalog.themes.first(where: { $0.id == rest[2] }) else { fail("no theme \(rest[2])") }
    // Without this a mistyped path surfaces as a confusing "volume is read only" from the installer.
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: rest[1], isDirectory: &isDirectory), isDirectory.boolValue else {
        fail("\(rest[1]) isn't a mounted volume")
    }
    do {
        let dir = try await ThemeFetcher(bundledRoot: nil).themeDirectory(for: theme)
        let outcome = try ThemeInstaller.apply(themeDirectory: dir, id: theme.id, name: theme.name, settings: theme.settings, to: URL(fileURLWithPath: rest[1]))
        print("installed \(theme.id)"); outcome.warnings.forEach { print("warning: \($0)") }
    } catch { fail(error.localizedDescription) }
}

/// `<id>-` plus 16 hex digits: the exact shape of a folder this command writes, so
/// bundling `adwaita` never touches `adwaita-blue-…`.
func isBundledFolderName(_ name: String, id: String) -> Bool {
    guard name.hasPrefix(id + "-") else { return false }
    let suffix = name.dropFirst(id.count + 1)
    return suffix.count == 16 && suffix.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
}

func bundle(_ rest: [String]) async {
    guard rest.count >= 3 else { fail("usage: bundle <catalog.json> <id> <out-dir>") }
    let catalog = loadCatalog(rest[0])
    guard let theme = catalog.themes.first(where: { $0.id == rest[1] }) else { fail("no theme \(rest[1])") }
    let out = URL(fileURLWithPath: rest[2], isDirectory: true)
    do {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let dir = try await ThemeFetcher(cacheRoot: cache, bundledRoot: nil).themeDirectory(for: theme)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? [] where isBundledFolderName(name, id: theme.id) {
            try FileManager.default.removeItem(at: out.appendingPathComponent(name))
        }
        // The copy keeps `.complete`: the app only uses a bundled folder whose marker matches the catalog entry.
        let dest = out.appendingPathComponent(dir.lastPathComponent)
        try FileManager.default.copyItem(at: dir, to: dest)
        print("bundled \(dest.path)")
    } catch { fail("\(error)") }
}

switch args.first {
case "validate": await validate(Array(args.dropFirst()))
case "hash": await hash(Array(args.dropFirst()))
case "gallery": gallery(Array(args.dropFirst()))
case "install": await install(Array(args.dropFirst()))
case "bundle": await bundle(Array(args.dropFirst()))
default: fail("usage: mactoy-themes validate|hash|gallery|install|bundle …")
}
