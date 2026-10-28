import CryptoKit
import Foundation
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
    var problems = catalog.problems() + previewProblems(catalog, catalogPath: path)
    var assemble: ((ThemeEntry) async throws -> URL)?
    var cache: URL?
    if rest.contains("--download") {
        let only = rest.firstIndex(of: "--only").flatMap { rest.indices.contains($0 + 1) ? Set(rest[$0 + 1].split(separator: ",").map(String.init)) : nil }
        for id in (only ?? []).sorted() where !catalog.themes.contains(where: { $0.id == id }) { problems.append("--only: no theme \(id)") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-themes-\(UUID().uuidString)")
        cache = root
        let transport = CapturingTransport()
        // bundledRoot nil: always build from the real download, never from a shipped copy.
        let fetcher = ThemeFetcher(transport: transport, cacheRoot: root, bundledRoot: nil)
        for theme in catalog.themes where only == nil || only!.contains(theme.id) {
            do {
                let dir = try await fetcher.themeDirectory(for: theme)
                let files = try ThemeAssembler.files(fromFolder: dir).filter { !$0.path.hasPrefix(".") }
                let bytes = files.reduce(0) { $0 + $1.data.count }
                print("✓ \(theme.id): \(files.count) files, \(bytes / 1024) KB")
                // The fetcher drops the skipped list, so assemble the same download once more to get it.
                if let zip = await transport.takeLast() {
                    let scratch = root.appendingPathComponent("skipped-\(theme.id)")
                    let skipped = try ThemeAssembler.assemble(ThemeAssembler.files(fromZip: zip), root: theme.download.root,
                                                              mappings: theme.files, into: scratch)
                    print(skipped.isEmpty ? "  skipped: none" : "  skipped (\(skipped.count)): " + skipped.joined(separator: ", "))
                }
            } catch {
                problems.append("\(theme.id): \(error.localizedDescription)")
            }
        }
        // Bundled folders are compared with the same builds (any not fetched above, because of --only, are built now).
        assemble = { try await fetcher.themeDirectory(for: $0) }
    }
    problems += await bundledProblems(catalog, catalogPath: path, reference: assemble)
    // fail() exits without running defers, so the cache goes before it.
    if let cache { try? FileManager.default.removeItem(at: cache) }
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

/// Writes a page made from the catalog, or with `--check` says whether the file is what the catalog would make now.
func writeGenerated(_ command: String, _ rest: [String], page: (ThemeCatalog) -> String) {
    guard rest.count >= 2 else { fail("usage: \(command) <catalog.json> <out.md> [--check]") }
    let text = page(loadCatalog(rest[0]))
    let out = URL(fileURLWithPath: rest[1])
    if rest.contains("--check") {
        guard (try? String(contentsOf: out, encoding: .utf8)) == text else { fail("\(rest[1]) is out of date; run the \(command) command") }
        print("\(command) up to date")
    } else {
        do { try text.write(to: out, atomically: true, encoding: .utf8) } catch { fail("\(error)") }
        print("wrote \(rest[1])")
    }
}

func gallery(_ rest: [String]) { writeGenerated("gallery", rest, page: galleryMarkdown) }

func credits(_ rest: [String]) { writeGenerated("credits", rest, page: creditsMarkdown) }

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
case "credits": credits(Array(args.dropFirst()))
case "install": await install(Array(args.dropFirst()))
case "bundle": await bundle(Array(args.dropFirst()))
default: fail("usage: mactoy-themes validate|hash|gallery|credits|install|bundle …")
}
