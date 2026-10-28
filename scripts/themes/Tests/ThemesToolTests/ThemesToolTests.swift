import Foundation
import ImageIO
import Testing
import MactoyKit
@testable import mactoy_themes

/// The gallery escaping and the checks that gate contributor pull requests. No network.
@Suite("mactoy-themes")
struct ThemesToolTests {
    static func entry(name: String = "Demo", author: String = "Someone", license: String = "MIT",
                      homepage: String = "https://github.com/someone/demo") -> ThemeEntry {
        ThemeEntry(id: "demo", name: name, author: author, homepage: URL(string: homepage)!, license: license,
                   showsVentoyHotkeys: true, notes: nil,
                   download: .init(url: URL(string: "https://codeload.github.com/someone/demo/zip/0123456789abcdef0123456789abcdef01234567")!,
                                   sha256: String(repeating: "a", count: 64), root: "demo"),
                   files: nil, settings: .init(file: "theme.txt"))
    }

    /// A scratch folder that is removed when the test ends.
    final class Scratch {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("themes-tool-tests-\(UUID().uuidString)")
        init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: url) }
        func write(_ path: String, _ text: String) throws {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
    }

    // MARK: Gallery escaping

    static let evil = "Evil | Name ](https://evil.example) <b>x</b> `c` *b* _i_ \\"

    /// Every Markdown-active character in `s` is preceded by a backslash.
    func allEscaped(_ s: String, _ active: String) -> Bool {
        let chars = Array(s)
        for (i, c) in chars.enumerated() where active.contains(c) {
            // Count the backslashes before it: an odd number means it is escaped.
            var n = 0
            var j = i - 1
            while j >= 0, chars[j] == "\\" { n += 1; j -= 1 }
            if n % 2 == 0 { return false }
        }
        return true
    }

    @Test func markdownEscapesEverythingActive() {
        let text = GalleryText.markdown(Self.evil)
        #expect(allEscaped(text, "|[]<>*_`&"))
        #expect(text.hasPrefix("Evil \\| Name \\]"))
        // The trailing backslash is doubled, so it can't escape what follows it in the cell.
        #expect(text.hasSuffix("\\\\"))
    }

    @Test func controlCharactersCannotEndARow() {
        #expect(!GalleryText.markdown("a\nb\r| c").contains("\n"))
        #expect(!GalleryText.attribute("a\nb\r| c").contains("\n"))
    }

    @Test func attributeHasNoRawQuoteTagPipeOrBacktick() {
        let text = GalleryText.attribute("\"> <script>x</script> | ` & '")
        for raw in ["\"", "<", ">", "|", "`", "'"] { #expect(!text.contains(raw)) }
        #expect(text.contains("&amp;"))
    }

    @Test func destinationEncodesParensSpacesAndBreakers() {
        let url = URL(string: "https://example.com/a(b)c")!
        #expect(GalleryText.destination(url) == "https://example.com/a%28b%29c")
        let encoded = GalleryText.destination(URL(string: "https://example.com/x%20y")!)
        #expect(encoded == "https://example.com/x%20y")
    }

    @Test func aHostileEntryKeepsTheTableAndAddsNoLink() {
        let catalog = ThemeCatalog(schema: 1, themes: [
            Self.entry(name: Self.evil, author: Self.evil, license: Self.evil, homepage: "https://example.com/a(b)"),
            Self.entry(),
        ])
        let md = galleryMarkdown(catalog)
        let rows = md.split(separator: "\n").filter { $0.hasPrefix("| <img") }
        #expect(rows.count == 1)
        // A two-column row has exactly three pipes that aren't escaped.
        let row = Array(rows[0])
        var bare = 0
        for (i, c) in row.enumerated() where c == "|" && (i == 0 || row[i - 1] != "\\") { bare += 1 }
        #expect(bare == 3)
        // Outside the <img> tags (whose attributes are entity-escaped), the only live brackets and
        // tags are the two author links and the two <br>s; nothing from the name adds one.
        let text = String(rows[0]).replacingOccurrences(of: "<img[^>]*>", with: "", options: .regularExpression)
        func live(_ c: Character) -> Int {
            let chars = Array(text)
            return chars.indices.filter { i in
                guard chars[i] == c else { return false }
                // Live unless an odd number of backslashes comes right before it.
                var n = 0
                var j = i - 1
                while j >= 0, chars[j] == "\\" { n += 1; j -= 1 }
                return n % 2 == 0
            }.count
        }
        #expect(live("[") == 2)
        #expect(live("]") == 2)
        #expect(live("<") == 2)
        #expect(!text.contains("<b>"))
        #expect(text.contains("](https://example.com/a%28b%29)"))
    }

    @Test func aPlainCatalogIsUnchangedByEscaping() {
        let md = galleryMarkdown(ThemeCatalog(schema: 1, themes: [Self.entry(name: "Catppuccin Mocha", author: "Diego Duarte", license: "GPL-3.0")]))
        #expect(md.contains("**Catppuccin Mocha** by [Diego Duarte](https://github.com/someone/demo) · GPL-3.0 · F1–F6 key bar"))
    }

    @Test func onlyHttpsHomepagesBecomeLinks() {
        let md = galleryMarkdown(ThemeCatalog(schema: 1, themes: [Self.entry(homepage: "http://example.com")]))
        #expect(md.contains("by Someone · MIT"))
    }

    // MARK: Preview credits

    @Test func creditsNameEachPreviewsAuthorLicenseAndHomepage() {
        let md = creditsMarkdown(ThemeCatalog(schema: 1, themes: [Self.entry(name: "Demo Theme", author: "Diego Duarte", license: "GPL-3.0")]))
        #expect(md.contains("| demo.jpg | Demo Theme | Diego Duarte | GPL-3.0 | [https://github.com/someone/demo](https://github.com/someone/demo) |"))
    }

    @Test func creditsIncludeVentoysOwnMenuAfterTheThemes() {
        let md = creditsMarkdown(ThemeCatalog(schema: 1, themes: [Self.entry()]))
        let rows = md.split(separator: "\n").filter { $0.hasPrefix("| ") && !$0.hasPrefix("| Picture") }
        #expect(rows.count == 2)
        #expect(rows.last == "| ventoy-default.jpg | Ventoy's own menu | Ventoy | GPL-3.0 | [https://www.ventoy.net](https://www.ventoy.net) |")
    }

    @Test func aHostileEntryKeepsTheCreditsTableAndAddsNoLink() {
        let md = creditsMarkdown(ThemeCatalog(schema: 1, themes: [
            Self.entry(name: Self.evil, author: Self.evil, license: Self.evil, homepage: "https://example.com/a(b)"),
        ]))
        let row = Array(md.split(separator: "\n").first { $0.hasPrefix("| demo.jpg") }!)
        // Five columns: six pipes that aren't escaped.
        var bare = 0
        for (i, c) in row.enumerated() where c == "|" && (i == 0 || row[i - 1] != "\\") { bare += 1 }
        #expect(bare == 6)
        #expect(!String(row).contains("<b>"))
        #expect(String(row).contains("](https://example.com/a%28b%29)"))
    }

    @Test func creditsLinkOnlyHttpsHomepages() {
        let md = creditsMarkdown(ThemeCatalog(schema: 1, themes: [Self.entry(homepage: "http://example.com")]))
        #expect(md.contains("| MIT | http://example.com |"))
    }

    // MARK: Previews

    @Test func aSymlinkedPreviewIsRejected() throws {
        let scratch = Scratch()
        try scratch.write("real.jpg", "not really a jpeg")
        try FileManager.default.createDirectory(at: scratch.url.appendingPathComponent("previews"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: scratch.url.appendingPathComponent("previews/demo.jpg"),
                                                   withDestinationURL: scratch.url.appendingPathComponent("real.jpg"))
        let problems = previewProblems(ThemeCatalog(schema: 1, themes: [Self.entry()]), catalogPath: scratch.url.appendingPathComponent("catalog.json").path)
        #expect(problems.contains { $0.contains("regular file") })
    }

    @Test func aSymlinkedPreviewsFolderIsRejected() throws {
        let scratch = Scratch()
        try FileManager.default.createDirectory(at: scratch.url.appendingPathComponent("elsewhere"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: scratch.url.appendingPathComponent("previews"),
                                                   withDestinationURL: scratch.url.appendingPathComponent("elsewhere"))
        let problems = previewProblems(ThemeCatalog(schema: 1, themes: [Self.entry()]), catalogPath: scratch.url.appendingPathComponent("catalog.json").path)
        #expect(problems == ["previews is a symlink; it must be a folder"])
    }

    /// A real JPEG of the given size, so the checks read it the way they read a contributor's file.
    static func writeJPEG(width: Int, height: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func previewProblemsFor(_ scratch: Scratch) -> [String] {
        previewProblems(ThemeCatalog(schema: 1, themes: [Self.entry()]), catalogPath: scratch.url.appendingPathComponent("catalog.json").path)
    }

    @Test func theVentoyDefaultPictureIsNotAnOrphanAndNeedsNoCatalogEntry() throws {
        let scratch = Scratch()
        try Self.writeJPEG(width: 1600, height: 900, to: scratch.url.appendingPathComponent("previews/demo.jpg"))
        #expect(previewProblemsFor(scratch).isEmpty, "optional: a catalog without it is fine")
        try Self.writeJPEG(width: 1600, height: 900, to: scratch.url.appendingPathComponent("previews/ventoy-default.jpg"))
        try scratch.write("previews/README.txt", "other files in previews are left alone")
        try scratch.write("previews/CREDITS.md", "# Preview credits\n")
        #expect(previewProblemsFor(scratch).isEmpty, "present, with no catalog entry of that name, is accepted; so are files that aren't pictures")
    }

    @Test func theVentoyDefaultPictureIsHeldToTheSameRulesAsAnyPreview() throws {
        let scratch = Scratch()
        try Self.writeJPEG(width: 1600, height: 900, to: scratch.url.appendingPathComponent("previews/demo.jpg"))
        let stock = scratch.url.appendingPathComponent("previews/ventoy-default.jpg")

        try Self.writeJPEG(width: 1024, height: 768, to: stock)
        #expect(previewProblemsFor(scratch).contains { $0.hasPrefix("ventoy-default: preview is 1024x768") })
        try scratch.write("previews/ventoy-default.jpg", "not a jpeg")
        #expect(previewProblemsFor(scratch) == ["ventoy-default: preview isn't a readable JPEG"])
        try FileManager.default.removeItem(at: stock)
        try FileManager.default.createSymbolicLink(at: stock, withDestinationURL: scratch.url.appendingPathComponent("previews/demo.jpg"))
        #expect(previewProblemsFor(scratch).contains { $0.hasPrefix("ventoy-default: previews/ventoy-default.jpg must be a regular file") })
    }

    @Test func aThemesOwnPreviewStillMustExist() throws {
        let scratch = Scratch()
        try FileManager.default.createDirectory(at: scratch.url.appendingPathComponent("previews"), withIntermediateDirectories: true)
        #expect(previewProblemsFor(scratch) == ["demo: missing previews/demo.jpg"])
    }

    // MARK: Bundled folders

    static let folder = "bundled/demo-aaaaaaaaaaaaaaaa"

    /// A bundled folder the checks accept, and a catalog to go with it.
    func bundledSetup() throws -> (Scratch, ThemeCatalog, String) {
        let scratch = Scratch()
        let entry = Self.entry()
        try scratch.write("\(Self.folder)/theme.txt", "title-text: \"x\"\n")
        try scratch.write("\(Self.folder)/bg.png", "png bytes")
        try scratch.write("\(Self.folder)/.complete", ThemeFetcher.fingerprint(for: entry))
        return (scratch, ThemeCatalog(schema: 1, themes: [entry]), scratch.url.appendingPathComponent("catalog.json").path)
    }

    /// The folder the fetcher would have built from the pinned download.
    func reference(theme: String = "title-text: \"x\"\n", extra: [String: String] = [:]) throws -> Scratch {
        let ref = Scratch()
        for (path, text) in ["theme.txt": theme, "bg.png": "png bytes"].merging(extra, uniquingKeysWith: { $1 }) {
            try ref.write(path, text)
        }
        try ref.write(".complete", "whatever")
        return ref
    }

    @Test func aCleanBundledFolderPasses() async throws {
        let (_, catalog, path) = try bundledSetup()
        #expect(await bundledProblems(catalog, catalogPath: path).isEmpty)
    }

    @Test func aStrayFileTypeIsRejectedWithoutDownloading() async throws {
        let (scratch, catalog, path) = try bundledSetup()
        try scratch.write("\(Self.folder)/evil.cfg", "menuentry x {}")
        try scratch.write("\(Self.folder)/.hidden.png", "x")
        let problems = await bundledProblems(catalog, catalogPath: path)
        #expect(problems.contains { $0.contains("evil.cfg") })
        #expect(problems.contains { $0.contains(".hidden.png") })
    }

    @Test func aSymlinkInsideABundledFolderIsRejected() async throws {
        let (scratch, catalog, path) = try bundledSetup()
        try FileManager.default.createSymbolicLink(at: scratch.url.appendingPathComponent("\(Self.folder)/link.png"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let problems = await bundledProblems(catalog, catalogPath: path)
        #expect(problems.contains { $0.contains("link.png") && $0.contains("symlink") })
    }

    @Test func aSymlinkedBundledFolderIsRejected() async throws {
        let (scratch, catalog, path) = try bundledSetup()
        try FileManager.default.moveItem(at: scratch.url.appendingPathComponent(Self.folder), to: scratch.url.appendingPathComponent("real"))
        try FileManager.default.createSymbolicLink(at: scratch.url.appendingPathComponent(Self.folder),
                                                   withDestinationURL: scratch.url.appendingPathComponent("real"))
        let problems = await bundledProblems(catalog, catalogPath: path)
        #expect(problems.contains { $0.contains("is a symlink") })
    }

    @Test func aSymlinkedBundledRootIsRejected() async throws {
        let (scratch, catalog, path) = try bundledSetup()
        try FileManager.default.moveItem(at: scratch.url.appendingPathComponent("bundled"), to: scratch.url.appendingPathComponent("real"))
        try FileManager.default.createSymbolicLink(at: scratch.url.appendingPathComponent("bundled"),
                                                   withDestinationURL: scratch.url.appendingPathComponent("real"))
        #expect(await bundledProblems(catalog, catalogPath: path) == ["bundled is a symlink; it must be a folder"])
    }

    @Test func bytesMatchingThePinnedDownloadPass() async throws {
        let (_, catalog, path) = try bundledSetup()
        let ref = try reference()
        #expect(await bundledProblems(catalog, catalogPath: path, reference: { _ in ref.url }).isEmpty)
    }

    @Test func tamperedMissingAndExtraFilesAreCaughtAgainstThePinnedDownload() async throws {
        let (scratch, catalog, path) = try bundledSetup()
        try scratch.write("\(Self.folder)/theme.txt", "title-text: \"tampered\"\n")
        try scratch.write("\(Self.folder)/extra.png", "x")
        let ref = try reference(extra: ["only-upstream.png": "y"])
        let problems = await bundledProblems(catalog, catalogPath: path, reference: { _ in ref.url })
        #expect(problems.contains { $0.contains("theme.txt") && $0.contains("differs") })
        #expect(problems.contains { $0.contains("extra.png") && $0.contains("extra") })
        #expect(problems.contains { $0.contains("only-upstream.png") && $0.contains("missing") })
    }

    @Test func aBadMarkerIsCaught() async throws {
        let (scratch, catalog, path) = try bundledSetup()
        try scratch.write("\(Self.folder)/.complete", "stale")
        #expect(await bundledProblems(catalog, catalogPath: path).contains { $0.contains(".complete doesn't match") })
    }
}
