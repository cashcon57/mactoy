import Foundation

/// `themes/catalog.json`: the boot-menu themes Mactoy offers. Lives in
/// the repo so themes can be proposed by pull request; the app reads it
/// from `main` at runtime (see `ThemeCatalogLoader`).
public struct ThemeCatalog: Codable, Sendable, Equatable {
    public static let supportedSchema = 1
    public var schema: Int
    public var themes: [ThemeEntry]

    public init(schema: Int, themes: [ThemeEntry]) {
        self.schema = schema
        self.themes = themes
    }

    public func problems() -> [String] {
        var out: [String] = []
        if schema != Self.supportedSchema { out.append("schema \(schema) isn't supported (expected \(Self.supportedSchema))") }
        var seen = Set<String>()
        for theme in themes where !seen.insert(theme.id).inserted { out.append("duplicate id \(theme.id)") }
        for theme in themes { out += theme.problems().map { "\(theme.id): \($0)" } }
        return out
    }

    /// Entries safe to show: valid on their own, first of each id.
    public var usableThemes: [ThemeEntry] {
        var seen = Set<String>()
        return themes.filter { $0.problems().isEmpty && seen.insert($0.id).inserted }
    }
}

public struct ThemeEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var author: String
    public var homepage: URL
    public var license: String
    /// Whether the theme shows Ventoy's F1–F6 key bar (themes made for
    /// Ventoy do; generic GRUB themes show GRUB's own hints instead).
    public var showsVentoyHotkeys: Bool
    public var notes: String?
    public var download: Download
    /// Explicit picks from the download; `nil` copies everything under `download.root`.
    public var files: [FileMapping]?
    public var settings: Settings

    public init(id: String, name: String, author: String, homepage: URL, license: String,
                showsVentoyHotkeys: Bool, notes: String?, download: Download,
                files: [FileMapping]?, settings: Settings) {
        self.id = id; self.name = name; self.author = author; self.homepage = homepage
        self.license = license; self.showsVentoyHotkeys = showsVentoyHotkeys; self.notes = notes
        self.download = download; self.files = files; self.settings = settings
    }

    public struct Download: Codable, Sendable, Equatable {
        public var url: URL
        public var sha256: String
        public var root: String
        public init(url: URL, sha256: String, root: String) { self.url = url; self.sha256 = sha256; self.root = root }
    }

    public struct FileMapping: Codable, Sendable, Equatable {
        public var from: String
        public var to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }

    /// The Ventoy `theme` plugin settings Mactoy will write. Deliberately
    /// a closed set: unknown keys fail to decode.
    public struct Settings: Codable, Sendable, Equatable {
        public static let defaultGfxmode = "1920x1080,auto"
        public var file: String
        public var fonts: [String]?
        public var gfxmode: String?
        public var ventoyLeft: String?
        public var ventoyTop: String?
        public var ventoyColor: String?

        public init(file: String, fonts: [String]? = nil, gfxmode: String? = nil,
                    ventoyLeft: String? = nil, ventoyTop: String? = nil, ventoyColor: String? = nil) {
            self.file = file; self.fonts = fonts; self.gfxmode = gfxmode
            self.ventoyLeft = ventoyLeft; self.ventoyTop = ventoyTop; self.ventoyColor = ventoyColor
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case file, fonts, gfxmode
            case ventoyLeft = "ventoy_left", ventoyTop = "ventoy_top", ventoyColor = "ventoy_color"
        }

        public init(from decoder: any Decoder) throws {
            let known = Set(CodingKeys.allCases.map(\.rawValue))
            let any = try decoder.container(keyedBy: AnyKey.self)
            if let unknown = any.allKeys.first(where: { !known.contains($0.stringValue) }) {
                throw DecodingError.dataCorruptedError(forKey: unknown, in: any,
                    debugDescription: "settings may only contain \(known.sorted().joined(separator: ", "))")
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            file = try c.decode(String.self, forKey: .file)
            fonts = try c.decodeIfPresent([String].self, forKey: .fonts)
            gfxmode = try c.decodeIfPresent(String.self, forKey: .gfxmode)
            ventoyLeft = try c.decodeIfPresent(String.self, forKey: .ventoyLeft)
            ventoyTop = try c.decodeIfPresent(String.self, forKey: .ventoyTop)
            ventoyColor = try c.decodeIfPresent(String.self, forKey: .ventoyColor)
        }

        private struct AnyKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
    }

    static let allowedHosts: Set<String> = ["github.com", "codeload.github.com", "gitlab.com", "codeberg.org"]

    /// Ids a catalog entry may not take. `custom-` begins every id in My Themes, which
    /// sit beside catalog ids in the same picker and on drives (`mactoy-<id>`), and
    /// `ventoy-default` names the picture of Ventoy's own menu in `previews/`.
    static let reservedIDPrefix = "custom-"
    static let reservedIDs: Set<String> = [ThemeCatalogLoader.ventoyDefaultPreviewID]

    public func problems() -> [String] {
        var out: [String] = []
        if !ThemePath.matches(id, #"^[a-z0-9][a-z0-9-]{1,39}$"#) { out.append("id must be 2-40 lowercase letters, digits or hyphens") }
        if id.hasPrefix(Self.reservedIDPrefix) { out.append("id must not start with \(Self.reservedIDPrefix) (that is how themes saved on a Mac are named)") }
        if Self.reservedIDs.contains(id) { out.append("id \(id) is reserved for Mactoy") }
        for (label, value) in [("name", name), ("author", author), ("license", license)]
        where value.trimmingCharacters(in: .whitespaces).isEmpty || value.count > 60 || value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            out.append("\(label) must be 1-60 printable characters")
        }
        if homepage.scheme != "https" { out.append("homepage must be https") }
        if download.url.scheme != "https" || !Self.allowedHosts.contains(download.url.host ?? "") {
            out.append("download.url must be https on \(Self.allowedHosts.sorted().joined(separator: ", "))")
        }
        if !ThemePath.matches(download.sha256, #"^[0-9a-f]{64}$"#) { out.append("download.sha256 must be 64 lowercase hex characters") }
        if !download.root.isEmpty && !ThemePath.isSafeRelative(download.root) { out.append("download.root is not a safe relative path") }
        for m in files ?? [] {
            if !ThemePath.isSafeSource(m.from) { out.append("files.from \(m.from) must be a safe relative path, optionally ending in *.ext") }
            if m.to != "." && !ThemePath.isSafeRelative(m.to) { out.append("files.to \(m.to) is not a safe relative path") }
        }
        if !ThemePath.isSafeRelative(settings.file) || !settings.file.lowercased().hasSuffix(".txt") {
            out.append("settings.file must be a relative .txt path")
        }
        for font in settings.fonts ?? [] where !ThemePath.isSafeRelative(font) || !font.lowercased().hasSuffix(".pf2") {
            out.append("settings.fonts entry \(font) must be a relative .pf2 path")
        }
        if let g = settings.gfxmode, !ThemePath.matches(g, #"^(auto|max|[0-9]{3,4}x[0-9]{3,4})(,(auto|max|[0-9]{3,4}x[0-9]{3,4})){0,5}$"#) {
            out.append("settings.gfxmode must look like 1920x1080,auto")
        }
        for (label, v) in [("ventoy_left", settings.ventoyLeft), ("ventoy_top", settings.ventoyTop)] {
            if let v, !ThemePath.matches(v, #"^[0-9]{1,3}%([+-][0-9]{1,4})?$"#) { out.append("settings.\(label) must look like 5% or 100%-19") }
        }
        if let c = settings.ventoyColor, !ThemePath.matches(c, #"^#[0-9a-fA-F]{6}$"#) { out.append("settings.ventoy_color must look like #89b4fa") }
        return out
    }
}

/// Path rules shared by the catalog, assembler and installer.
///
/// Everything here works on unicode scalars, never on `Character`s: a
/// reserved character followed by a combining mark, ZWJ or variation
/// selector is a single `Character` that no longer equals the reserved
/// one, and the file system still sees both scalars.
public enum ThemePath {
    /// Characters that are reserved on FAT/exFAT (where themes land) or
    /// break out of a JSON string (where names are written).
    private static let reserved: Set<Unicode.Scalar> = ["\"", "*", "?", "<", ">", "|", ":", "\\"]
    private static let slash: Unicode.Scalar = "/"
    private static let dot: Unicode.Scalar = "."

    /// Relative, `/`-separated; no `.`/`..`/empty/hidden components; no
    /// control or line-break scalars; none of `reserved`; and no component
    /// starting with an invisible mark (combining, enclosing, spacing or
    /// format scalar). In particular no `*`: a glob is only accepted
    /// through `isSafeSource`.
    public static func isSafeRelative(_ path: String) -> Bool {
        isSafe(Array(path.unicodeScalars))
    }

    /// A `files.from` value: a safe relative path, or a safe directory
    /// (possibly none) plus a final `*.<ext>` component. That final glob is
    /// the only wildcard the assembler implements, so nothing else with a
    /// `*` may pass.
    public static func isSafeSource(_ path: String) -> Bool {
        let scalars = Array(path.unicodeScalars)
        guard scalars.count <= 200, let last = scalars.split(separator: slash, omittingEmptySubsequences: false).last,
              isGlobComponent(last)
        else { return isSafe(scalars) }
        // `last` is ASCII, so what's left is the directory part and its slash.
        let directory = Array(scalars.dropLast(last.count + 1))
        return directory.isEmpty ? last.count == scalars.count : isSafe(directory)
    }

    private static func isSafe(_ scalars: [Unicode.Scalar]) -> Bool {
        guard !scalars.isEmpty, scalars.count <= 200, scalars.first != slash,
              !scalars.contains(where: { reserved.contains($0) || isControlOrBreak($0) })
        else { return false }
        return scalars.split(separator: slash, omittingEmptySubsequences: false).allSatisfy { component in
            // An empty component, ".", ".." and hidden names all start with "." or nothing.
            guard let first = component.first, first != dot else { return false }
            return !isInvisibleMark(first)
        }
    }

    /// `*.<ext>` with a letters-and-digits extension, nothing else.
    private static func isGlobComponent(_ c: ArraySlice<Unicode.Scalar>) -> Bool {
        guard c.count >= 3, c[c.startIndex] == "*", c[c.startIndex + 1] == "." else { return false }
        return c.dropFirst(2).allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        }
    }

    private static func isControlOrBreak(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    private static func isInvisibleMark(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .spacingMark, .format: return true
        default: return false
        }
    }

    /// The match must cover the whole string. `^...$` alone isn't enough:
    /// ICU's `$` also matches before a final line break, so "abc\n" would
    /// pass on Foundation versions that go through NSString.
    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) == s.startIndex..<s.endIndex
    }
}
