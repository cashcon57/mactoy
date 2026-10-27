import Foundation
import ImageIO
import Testing
@testable import MactoyKit

@Suite("Theme catalog")
struct ThemeCatalogTests {

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func entry(_ edit: (inout ThemeEntry) -> Void = { _ in }) -> ThemeEntry {
        var e = ThemeEntry(
            id: "sample-theme", name: "Sample", author: "Someone",
            homepage: URL(string: "https://github.com/someone/sample")!, license: "MIT",
            showsVentoyHotkeys: true, notes: nil,
            download: .init(url: URL(string: "https://codeload.github.com/someone/sample/zip/0123456789abcdef0123456789abcdef01234567")!,
                            sha256: String(repeating: "a", count: 64), root: "sample-0123/theme"),
            files: nil,
            settings: .init(file: "theme.txt", fonts: ["font.pf2"], gfxmode: "1920x1080,auto",
                            ventoyLeft: "5%", ventoyTop: "95%-10", ventoyColor: "#89b4fa"))
        edit(&e)
        return e
    }

    @Test("a well-formed entry has no problems")
    func valid() { #expect(entry().problems().isEmpty) }

    @Test("each rule is enforced", arguments: [
        "id", "url-scheme", "url-host", "sha", "root", "file-ext", "font-ext", "font-path",
        "gfxmode", "left", "top", "color", "name", "mapping",
    ])
    func rules(rule: String) {
        let bad = entry { e in
            switch rule {
            case "id": e.id = "Bad Id"
            case "url-scheme": e.download.url = URL(string: "http://github.com/a/b.zip")!
            case "url-host": e.download.url = URL(string: "https://example.com/a.zip")!
            case "sha": e.download.sha256 = "ABC"
            case "root": e.download.root = "../escape"
            case "file-ext": e.settings.file = "theme.cfg"
            case "font-ext": e.settings.fonts = ["font.ttf"]
            case "font-path": e.settings.fonts = ["/abs/font.pf2"]
            case "gfxmode": e.settings.gfxmode = "huge; reboot"
            case "left": e.settings.ventoyLeft = "left"
            case "top": e.settings.ventoyTop = "95"
            case "color": e.settings.ventoyColor = "blue"
            case "name": e.name = ""
            case "mapping": e.files = [.init(from: "a/../../b.png", to: "b.png")]
            default: break
            }
        }
        #expect(!bad.problems().isEmpty, "rule \(rule) not enforced")
    }

    // ICU's `$` also matches before a final line break, so an anchored
    // pattern alone lets "value\n" through. These values end up in paths
    // and in ventoy.json, so a stray newline must be rejected.
    @Test("a trailing line break doesn't slip past the patterns", arguments: [
        "id", "sha", "gfxmode", "left", "top", "color",
    ])
    func trailingLineBreak(rule: String) {
        let bad = entry { e in
            switch rule {
            case "id": e.id = "sample-theme\n"
            case "sha": e.download.sha256 = String(repeating: "a", count: 64) + "\n"
            case "gfxmode": e.settings.gfxmode = "1920x1080,auto\n"
            case "left": e.settings.ventoyLeft = "5%\n"
            case "top": e.settings.ventoyTop = "95%-10\n"
            case "color": e.settings.ventoyColor = "#89b4fa\n"
            default: break
            }
        }
        #expect(!bad.problems().isEmpty, "rule \(rule) accepted a trailing newline")
    }

    // Each bad prefix is tried in every place a path is accepted.
    @Test("unsafe paths are rejected in root, files, settings.file and settings.fonts",
          arguments: ["..", "a/..", ".", "/abs", "a\\b", ".hidden", "a/.hidden", "a//b", "a\nb"])
    func unsafePaths(prefix: String) {
        #expect(!entry { $0.download.root = prefix }.problems().isEmpty, "root \(prefix.debugDescription)")
        #expect(!entry { $0.settings.file = prefix + "/x.txt" }.problems().isEmpty, "file \(prefix.debugDescription)")
        #expect(!entry { $0.settings.fonts = [prefix + "/x.pf2"] }.problems().isEmpty, "font \(prefix.debugDescription)")
        #expect(!entry { $0.files = [.init(from: prefix + "/x.png", to: "x.png")] }.problems().isEmpty, "from \(prefix.debugDescription)")
        #expect(!entry { $0.files = [.init(from: "x.png", to: prefix + "/x.png")] }.problems().isEmpty, "to \(prefix.debugDescription)")
        #expect(!entry { $0.files = [.init(from: prefix + "/*.png", to: ".")] }.problems().isEmpty, "glob \(prefix.debugDescription)")
    }

    // The only glob is a final `*.<ext>` component in `files.from`; the
    // assembler implements exactly that, so the catalog must not allow more.
    @Test("files.from accepts only a final *.ext glob", arguments: [
        ("assets/*.png", true), ("assets/select/1080p/*.png", true), ("*.png", true), ("a/*.pf2", true),
        ("a/b.png", true),
        ("assets/*", false), ("*", false), ("a/*/b.png", false), ("a/*.png/b", false),
        ("a/b*.png", false), ("a/*b.png", false), ("a/**.png", false), ("a/*.png*", false),
        ("a/*.", false), ("a/*.p-g", false), ("a/*.tar.gz", false), ("a/* .png", false),
        ("../*.png", false), ("a/../*.png", false), ("/*.png", false), ("a//*.png", false),
        (".hidden/*.png", false), ("a/.*.png", false), ("a\\*.png", false),
    ])
    func globFrom(from: String, allowed: Bool) {
        let e = entry { $0.files = [.init(from: from, to: ".")] }
        #expect(e.problems().isEmpty == allowed, "\(from.debugDescription)")
    }

    @Test("files.to is a plain path or '.', never a glob")
    func globTo() {
        #expect(entry { $0.files = [.init(from: "a/*.png", to: ".")] }.problems().isEmpty)
        #expect(entry { $0.files = [.init(from: "a/b.png", to: "sub/b.png")] }.problems().isEmpty)
        #expect(!entry { $0.files = [.init(from: "a/b.png", to: "*.png")] }.problems().isEmpty)
        #expect(!entry { $0.files = [.init(from: "a/b.png", to: "sub/*")] }.problems().isEmpty)
    }

    // JSON-hostile (`"`) and FAT/exFAT-reserved characters. The theme lands on
    // a FAT-family partition and in ventoy.json, so none may reach either.
    @Test("reserved characters are rejected in every path field", arguments: ["\"", "*", "?", "<", ">", "|", ":", "\\"])
    func reservedCharacters(char: String) {
        #expect(!entry { $0.settings.file = "a\(char)b.txt" }.problems().isEmpty, "settings.file")
        #expect(!entry { $0.settings.fonts = ["a\(char)b.pf2"] }.problems().isEmpty, "settings.fonts")
        #expect(!entry { $0.download.root = "dir/a\(char)b" }.problems().isEmpty, "download.root")
        #expect(!entry { $0.files = [.init(from: "a\(char)b.png", to: "b.png")] }.problems().isEmpty, "files.from")
        #expect(!entry { $0.files = [.init(from: "a/b.png", to: "a\(char)b.png")] }.problems().isEmpty, "files.to")
    }

    // A reserved character followed by a combining mark, ZWJ or variation
    // selector is one grapheme cluster (one Swift Character), so checks on
    // Characters miss it. Every path rule must look at unicode scalars.
    @Test("a reserved character can't hide behind a combining mark, ZWJ or variation selector",
          arguments: ["\"", "*", "?", "<", ">", "|", ":", "\\"], ["\u{0301}", "\u{200D}", "\u{FE0F}"])
    func reservedCharactersWithMarks(char: String, mark: String) {
        let c = char + mark
        #expect(!entry { $0.settings.file = "a\(c)b.txt" }.problems().isEmpty, "settings.file")
        #expect(!entry { $0.settings.fonts = ["a\(c)b.pf2"] }.problems().isEmpty, "settings.fonts")
        #expect(!entry { $0.download.root = "dir/a\(c)b" }.problems().isEmpty, "download.root")
        #expect(!entry { $0.files = [.init(from: "a\(c)b.png", to: "b.png")] }.problems().isEmpty, "files.from")
        #expect(!entry { $0.files = [.init(from: "a/b.png", to: "a\(c)b.png")] }.problems().isEmpty, "files.to")
    }

    @Test("a literal * with a combining mark is never a glob", arguments: [
        "a/*\u{0301}/b.png", "*\u{0301}", "a/b*\u{0301}.png", "*\u{0301}.png", "a/*.png\u{0301}", "a/*\u{200D}.png",
    ])
    func starWithMark(from: String) {
        #expect(!entry { $0.files = [.init(from: from, to: ".")] }.problems().isEmpty, "\(from.debugDescription)")
    }

    @Test("slash, dot and hidden checks work on scalars, not grapheme clusters", arguments: [
        "/\u{0301}abs/x.txt",       // leading slash followed by a mark
        "a/.\u{0301}b/x.txt",       // hidden component with a mark after the dot
        "..\u{0301}/x.txt",         // parent component with a mark after the dots
        ".\u{0301}/x.txt",
        "a/\u{0301}b/x.txt",        // component starts with a combining mark
        "\u{0301}b/x.txt",
        "a/\u{200D}b/x.txt",        // ... or a zero width joiner
        "a/\u{FE0F}b/x.txt",        // ... or a variation selector
        "a/\u{20E3}b/x.txt",        // ... or an enclosing mark
        "a/\u{0903}b/x.txt",        // ... or a spacing mark
        "a/\u{2028}b/x.txt",        // line separator
        "a/\u{2029}b/x.txt",        // paragraph separator
    ])
    func scalarLevelPaths(prefix: String) {
        #expect(!entry { $0.download.root = prefix }.problems().isEmpty, "root")
        #expect(!entry { $0.settings.file = prefix }.problems().isEmpty, "file")
    }

    @Test("a combining mark inside a component is still fine")
    func marksInsideComponents() {
        #expect(entry { $0.settings.file = "cafe\u{0301}/theme.txt" }.problems().isEmpty)
        #expect(entry { $0.download.root = "dir/cafe\u{0301}" }.problems().isEmpty)
    }

    @Test("a settings.file that closes the JSON string is rejected")
    func jsonInjection() {
        #expect(!entry { $0.settings.file = #"a","x":"y.txt"# }.problems().isEmpty)
    }

    @Test("only the listed hosts over https are accepted", arguments: [
        ("https://github.com/a/b.zip", true),
        ("https://codeload.github.com/a/b/zip/abc", true),
        ("https://gitlab.com/a/b.zip", true),
        ("https://codeberg.org/a/b.zip", true),
        ("https://github.com.evil.com/a.zip", false),
        ("https://evil.com/github.com/a.zip", false),
        ("https://github.com@evil.com/a.zip", false),
        ("https://raw.githubusercontent.com/a/b.zip", false),
        ("http://github.com/a.zip", false),
        ("ftp://github.com/a.zip", false),
        ("file:///tmp/a.zip", false),
    ])
    func hosts(url: String, allowed: Bool) {
        let e = entry { $0.download.url = URL(string: url)! }
        #expect(e.problems().isEmpty == allowed, "\(url)")
    }

    @Test("id, name, author and license limits")
    func limits() {
        #expect(entry { $0.id = "ab" }.problems().isEmpty)
        #expect(entry { $0.id = String(repeating: "a", count: 40) }.problems().isEmpty)
        #expect(!entry { $0.id = "a" }.problems().isEmpty)
        #expect(!entry { $0.id = String(repeating: "a", count: 41) }.problems().isEmpty)
        #expect(!entry { $0.id = "-lead" }.problems().isEmpty)
        #expect(!entry { $0.id = "../x" }.problems().isEmpty)
        for set in [{ (e: inout ThemeEntry, v: String) in e.name = v },
                    { (e: inout ThemeEntry, v: String) in e.author = v },
                    { (e: inout ThemeEntry, v: String) in e.license = v }] {
            #expect(entry { set(&$0, String(repeating: "x", count: 60)) }.problems().isEmpty)
            #expect(!entry { set(&$0, String(repeating: "x", count: 61)) }.problems().isEmpty)
            #expect(!entry { set(&$0, "") }.problems().isEmpty)
            #expect(!entry { set(&$0, "   ") }.problems().isEmpty)
            #expect(!entry { set(&$0, "two\nlines") }.problems().isEmpty)
        }
    }

    @Test("ids that My Themes or Mactoy use are reserved, so a catalog theme can't be mistaken for a saved one",
          arguments: ["custom-night-12345678", "custom-x", "custom-ab", "ventoy-default"])
    func reservedIDs(id: String) {
        let bad = entry { $0.id = id }
        #expect(!bad.problems().isEmpty, "\(id)")
        #expect(!ThemeCatalog(schema: 1, themes: [bad]).problems().isEmpty)
        #expect(ThemeCatalog(schema: 1, themes: [bad, entry()]).usableThemes.map(\.id) == ["sample-theme"], "dropped from what the app shows")
    }

    @Test("ids that only look like the reserved ones are fine", arguments: ["customx", "custom", "my-custom-theme", "ventoy-default-2", "ventoy", "default"])
    func nearlyReservedIDs(id: String) {
        #expect(entry { $0.id = id }.problems().isEmpty, "\(id)")
    }

    @Test("the six allowed settings keys decode")
    func allSettingsKeys() throws {
        let json = ##"{"file":"theme.txt","fonts":["a.pf2"],"gfxmode":"1920x1080,auto","ventoy_left":"5%","ventoy_top":"95%-10","ventoy_color":"#89b4fa"}"##
        let s = try JSONDecoder().decode(ThemeEntry.Settings.self, from: Data(json.utf8))
        #expect(s == .init(file: "theme.txt", fonts: ["a.pf2"], gfxmode: "1920x1080,auto",
                           ventoyLeft: "5%", ventoyTop: "95%-10", ventoyColor: "#89b4fa"))
    }

    @Test("catalog rejects duplicate ids and unknown schema")
    func catalogRules() {
        #expect(!ThemeCatalog(schema: 1, themes: [entry(), entry()]).problems().isEmpty)
        #expect(!ThemeCatalog(schema: 2, themes: [entry()]).problems().isEmpty)
    }

    @Test("unknown settings keys don't decode")
    func strictSettings() {
        let json = #"{"file":"theme.txt","menu_password":"x"}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ThemeEntry.Settings.self, from: Data(json.utf8)) }
    }

    @Test("the repo's catalog is valid and every theme has a preview")
    func realCatalog() throws {
        let url = Self.repoRoot.appendingPathComponent("themes/catalog.json")
        let catalog = try JSONDecoder().decode(ThemeCatalog.self, from: Data(contentsOf: url))
        #expect(catalog.problems().isEmpty, "\(catalog.problems())")
        #expect(catalog.themes.count >= 14)
        for theme in catalog.themes {
            let preview = Self.repoRoot.appendingPathComponent("themes/previews/\(theme.id).jpg")
            let size = try FileManager.default.attributesOfItem(atPath: preview.path)[.size] as? Int ?? 0
            #expect(size > 0 && size <= 600 * 1024, "\(theme.id) preview size \(size)")
            let source = try #require(CGImageSourceCreateWithURL(preview as CFURL, nil))
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            #expect(w >= 1280 && abs(Double(w) / Double(h) - 16.0 / 9.0) < 0.02, "\(theme.id) preview \(w)x\(h)")
        }
    }
}
