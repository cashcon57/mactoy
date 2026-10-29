import Foundation

/// A theme kept in Mactoy's own library ("My Themes"), so applying another
/// theme to a drive never makes this one disappear.
public struct SavedTheme: Codable, Sendable, Equatable, Identifiable {
    /// `custom-<slug, at most 30>-<8 hex digits of the content>`: the same files
    /// and settings always give the same id, and it fits `ThemeInstaller.isValidID`
    /// because the id also becomes the folder name on a drive.
    public let id: String
    public let name: String
    /// Paths are relative to the theme's folder.
    public let settings: ThemeEntry.Settings
    /// Where it came from, in words the user sees ("Added from a file").
    public let origin: String
    public let savedAt: Date
    /// The theme's background picture (relative path), when it has one Mactoy can show.
    public let previewFile: String?

    public init(id: String, name: String, settings: ThemeEntry.Settings, origin: String,
                savedAt: Date, previewFile: String?) {
        self.id = id; self.name = name; self.settings = settings
        self.origin = origin; self.savedAt = savedAt; self.previewFile = previewFile
    }
}

public enum ThemeLibraryError: Error, Equatable, LocalizedError {
    /// A bad id, or a folder that isn't one of the library's.
    case notInLibrary(String)
    /// The library's folder for this theme is a link, so it is left alone.
    case isALink(String)

    public var errorDescription: String? {
        switch self {
        case .notInLibrary: return "That theme isn't in My Themes."
        case .isALink: return "Mactoy won't remove that theme because its folder in My Themes is a link to somewhere else."
        }
    }
}

/// `~/Documents/Mactoy Themes/<id>/`: each theme's files plus a hidden
/// `.mactoy-library.json` describing it. The installer skips hidden files, so
/// the description never reaches a drive.
///
/// Documents, not Library: these are themes the user chose to keep, so they
/// stay where the user can see them and survive removing Mactoy. The folder
/// is only made when the first theme is saved.
public struct ThemeLibrary: Sendable {
    public static let metadataName = ".mactoy-library.json"
    /// What a tile can show as a picture.
    static let previewExtensions: Set<String> = ["png", "jpg", "jpeg", "tga"]
    static let maxNameLength = 60
    static let maxOriginLength = 120

    /// What happens to a theme folder the library lets go of.
    public enum Discard: Sendable {
        /// Moved to the Trash: the library is in Documents, where the user may have
        /// changed or added files, so nothing there is deleted outright.
        case trash
        /// Deleted. For tests, which must not fill the user's Trash.
        case delete
    }

    public let root: URL
    let discard: Discard

    public init(root: URL = ThemeLibrary.defaultRoot(), discard: Discard = .trash) {
        self.root = root
        self.discard = discard
    }

    private func discardFolder(_ url: URL) throws {
        switch discard {
        case .trash: try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        case .delete: try FileManager.default.removeItem(at: url)
        }
    }

    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        return base.appendingPathComponent("Mactoy Themes", isDirectory: true)
    }

    /// Where v0.7.0 kept My Themes, inside Mactoy's own Application Support
    /// folder. `moveThemes(from:thenRemoveIfEmpty:)` empties both.
    public static func legacyRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Mactoy/My Themes", isDirectory: true)
    }

    public func directory(for theme: SavedTheme) -> URL {
        root.appendingPathComponent(theme.id, isDirectory: true)
    }

    // MARK: Reading

    /// Whether the library's folder is there but can't be read: macOS refused
    /// access to Documents, say. `list` then looks like an empty library.
    public func isUnreadable() -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
            return false
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            return true
        } catch let error as NSError {
            let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { $0.domain == NSPOSIXErrorDomain ? $0.code : 0 } ?? 0
            return posix == Int(EPERM) || posix == Int(EACCES)
        }
    }

    /// Newest first. A folder is skipped, not reported, when its description is
    /// missing or damaged or when it no longer holds the files its settings
    /// name: one bad folder must not hide the rest.
    public func list() -> [SavedTheme] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        // Tuples compare newest date first, then name and id in ascending order, so the order never wobbles.
        return names.compactMap(theme(named:)).sorted {
            ($0.savedAt, $1.name, $1.id) > ($1.savedAt, $0.name, $0.id)
        }
    }

    /// The theme in `<root>/<name>`, if everything about it checks out.
    func theme(named name: String) -> SavedTheme? {
        guard ThemeInstaller.isValidID(name) else { return nil }
        let folder = root.appendingPathComponent(name, isDirectory: true)
        // A link is never read through: it could point anywhere on this Mac.
        guard ThemeInstaller.fileType(folder) == .typeDirectory,
              let data = try? Data(contentsOf: folder.appendingPathComponent(Self.metadataName)),
              let decoded = try? Self.decoder.decode(SavedTheme.self, from: data),
              decoded.id == name,
              isInsideRoot(directory(for: decoded)),
              Self.isUsable(name: decoded.name), Self.isValid(decoded.settings),
              (try? ThemeAssembler.checkSettings(decoded.settings, in: folder)) != nil
        else { return nil }
        // Only the optional picture is dropped when it is wrong; the theme still works without it.
        let preview = decoded.previewFile.flatMap { Self.isPreviewPath($0) ? $0 : nil }
        return SavedTheme(id: decoded.id, name: decoded.name, settings: decoded.settings,
                          origin: Self.cleaned(decoded.origin, limit: Self.maxOriginLength),
                          savedAt: decoded.savedAt, previewFile: preview)
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == root.standardizedFileURL.path
    }

    // MARK: Saving

    /// Copies a theme folder into the library and returns its entry.
    ///
    /// The folder goes through the same filter as a download (`ThemeAssembler`:
    /// allowed file types, safe paths, size and count caps), so what is stored
    /// is exactly what could later be put on a drive. `settings` come from
    /// whoever found the theme (a drive's ventoy.json, say) and are not trusted:
    /// the theme file must exist, fonts that don't are dropped, and a value
    /// that fails the catalog's own format check is dropped too.
    ///
    /// The same files and settings under the same name give the same id, and
    /// then nothing is written: the entry already there is returned.
    @discardableResult
    public func save(folder: URL, name: String, settings: ThemeEntry.Settings, origin: String) throws -> SavedTheme {
        let fm = FileManager.default
        guard try !ThemeAssembler.files(fromFolder: folder).isEmpty else { throw ThemeError.missingFile(settings.file) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        var moved = false
        defer { if !moved { try? fm.removeItem(at: staging) } }
        let (id, cleanName, kept) = try Self.stage(folder: folder, name: name, settings: settings, into: staging)
        let destination = root.appendingPathComponent(id, isDirectory: true)
        if let existing = theme(named: id) { return existing }
        // Whatever else is under this name is a damaged leftover (`list` can't show it,
        // and `remove` refuses a folder with no description), so it is replaced. It goes
        // to the Trash, not away: the user may have been editing it. A link is never
        // removed through.
        if ThemeInstaller.fileType(destination) != nil {
            guard ThemeInstaller.fileType(destination) != .typeSymbolicLink else { throw ThemeError.destinationExists(destination.path) }
            try discardFolder(destination)
        }

        // Whole seconds, so what `save` returns equals what `list` reads back.
        let saved = SavedTheme(id: id, name: cleanName, settings: kept,
                               origin: Self.cleaned(origin, limit: Self.maxOriginLength),
                               savedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
                               previewFile: Self.previewFile(for: kept, in: staging))
        try Self.encoder.encode(saved).write(to: staging.appendingPathComponent(Self.metadataName))
        do {
            try fm.moveItem(at: staging, to: destination)
            moved = true
        } catch {
            // Two saves of the same theme can race; the one that lost has nothing to add.
            if let existing = theme(named: id) { return existing }
            throw error
        }
        return saved
    }

    /// The id `save` would give these files and settings under this name. Worked out in
    /// a temporary folder: nothing is written to the library.
    public static func id(ifSaving folder: URL, name: String, settings: ThemeEntry.Settings) throws -> String {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-theme-id-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        return try stage(folder: folder, name: name, settings: settings, into: staging).id
    }

    /// Copies what can be kept of `folder` into `staging` and works out the entry's id,
    /// name and settings from what was copied.
    private static func stage(folder: URL, name: String, settings: ThemeEntry.Settings,
                              into staging: URL) throws -> (id: String, name: String, settings: ThemeEntry.Settings) {
        let files = try ThemeAssembler.files(fromFolder: folder)
        // `assemble` calls an empty folder a missing root; the settings' own file is the better thing to name.
        guard !files.isEmpty else { throw ThemeError.missingFile(settings.file) }
        try ThemeAssembler.assemble(files, root: "", mappings: nil, into: staging)
        let kept = try Self.settings(settings, keptIn: staging)
        let cleanName = cleaned(name, limit: maxNameLength, fallback: "Theme")
        // Digest what was stored, not what was offered: dropped files change nothing.
        let id = makeID(name: cleanName, files: try ThemeAssembler.files(fromFolder: staging), settings: kept)
        return (id, cleanName, kept)
    }

    // MARK: Removing

    /// Moves `<root>/<id>` to the Trash. Nothing is touched unless `id` is a valid id and
    /// the folder is a real folder (never a link) that holds a description, so
    /// a stray folder in here, or one a link points to, is never touched.
    /// A theme that is already gone is not an error.
    public func remove(id: String) throws {
        guard ThemeInstaller.isValidID(id) else { throw ThemeLibraryError.notInLibrary(id) }
        let folder = root.appendingPathComponent(id, isDirectory: true)
        guard let type = ThemeInstaller.fileType(folder) else { return }
        guard type != .typeSymbolicLink else { throw ThemeLibraryError.isALink(id) }
        guard type == .typeDirectory,
              FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.metadataName).path)
        else { throw ThemeLibraryError.notInLibrary(id) }
        try discardFolder(folder)
    }

    /// The theme with this id, read from disk now; nil when it isn't in the library.
    public func savedTheme(id: String) -> SavedTheme? { theme(named: id) }

    // MARK: Moving from an older library

    public struct MoveResult: Equatable, Sendable {
        /// Ids now in this library, whether moved or already here.
        public var moved: [String] = []
        /// Whole themes that are still in the old library: the move failed (macOS
        /// refused access to Documents, say), or something else has the name here.
        public var notMoved: [String] = []
        /// Anything else in the old library, left where it was.
        public var leftBehind: [String] = []
        public init(moved: [String] = [], notMoved: [String] = [], leftBehind: [String] = []) {
            self.moved = moved; self.notMoved = notMoved; self.leftBehind = leftBehind
        }
    }

    /// Moves every theme in `oldRoot` into this library, then removes `oldRoot`
    /// if that leaves it empty, and after it `emptyParent` (the folder that held
    /// it) if that is empty too.
    ///
    /// Only what this library would list is moved: a real folder (never a
    /// link) named by a valid id, with its description and the files its
    /// settings name. Anything else is left where it was, so nothing that
    /// isn't Mactoy's is ever moved or deleted. Mactoy's own leftovers
    /// (`.staging-` folders from a save that stopped part way) and Finder's
    /// `.DS_Store` are deleted. A theme this library already has under the
    /// same id is the same files and settings (the id is a digest of them),
    /// so the old copy is deleted.
    ///
    /// Nothing in this library's folder is read or made unless `oldRoot`
    /// holds a theme: the folder is in Documents, and macOS can ask before
    /// letting Mactoy in.
    @discardableResult
    public func moveThemes(from oldRoot: URL, thenRemoveIfEmpty emptyParent: URL? = nil) -> MoveResult {
        let fm = FileManager.default
        guard ThemeInstaller.fileType(oldRoot) == .typeDirectory,
              let names = try? fm.contentsOfDirectory(atPath: oldRoot.path) else { return MoveResult() }
        let old = ThemeLibrary(root: oldRoot, discard: discard)
        var result = MoveResult()
        for name in names.sorted() {
            let source = oldRoot.appendingPathComponent(name, isDirectory: true)
            if name.hasPrefix(".staging-") || name == ".DS_Store" {
                if ThemeInstaller.fileType(source) != .typeSymbolicLink { try? fm.removeItem(at: source) }
                continue
            }
            guard old.theme(named: name) != nil else { result.leftBehind.append(name); continue }
            if theme(named: name) != nil {
                try? fm.removeItem(at: source)
                result.moved.append(name)
                continue
            }
            let destination = root.appendingPathComponent(name, isDirectory: true)
            // Something else under this name is left alone, and so is the theme.
            guard ThemeInstaller.fileType(destination) == nil else { result.notMoved.append(name); continue }
            do {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                // Into a hidden folder first: a move to another volume is a copy, and one that stops
                // part way must not show up as a damaged theme under the real name.
                let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
                try fm.moveItem(at: source, to: staging)
                do {
                    try fm.moveItem(at: staging, to: destination)
                } catch {
                    // A save of the same theme got there first: same id, same files, so this copy isn't needed.
                    if theme(named: name) != nil, ThemeInstaller.fileType(staging) == .typeDirectory {
                        try? fm.removeItem(at: staging)
                        result.moved.append(name)
                        continue
                    }
                    try? fm.moveItem(at: staging, to: source)
                    throw error
                }
                result.moved.append(name)
            } catch {
                result.notMoved.append(name)
            }
        }
        // rmdir only removes an empty folder, so anything left behind keeps its place.
        if rmdir(oldRoot.path) == 0, let emptyParent { rmdir(emptyParent.path) }
        return result
    }

    // MARK: Internals

    /// A short name the user can read: no control or invisible format characters,
    /// no outer blanks, at most `limit` characters. Names come from drives and ZIP
    /// files, so a right-to-left override (U+202E) or a zero-width space must not
    /// survive to reorder or hide text in a dialog.
    static func cleaned(_ text: String, limit: Int, fallback: String = "") -> String {
        let scalars = text.unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }
        let trimmed = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        let short = String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? fallback : short
    }

    private static func isUsable(name: String) -> Bool {
        !name.isEmpty && name == cleaned(name, limit: maxNameLength)
    }

    /// The catalog's own checks, run on a stand-in entry so the formats
    /// (`gfxmode`, `ventoy_*`, paths and extensions) are defined in one place.
    static func isValid(_ settings: ThemeEntry.Settings) -> Bool {
        let url = URL(string: "https://github.com/cashcon57/mactoy")!
        return ThemeEntry(id: "check", name: "check", author: "check", homepage: url, license: "check",
                          showsVentoyHotkeys: false, notes: nil,
                          download: .init(url: url, sha256: String(repeating: "0", count: 64), root: ""),
                          files: nil, settings: settings).problems().isEmpty
    }

    /// `settings` cut down to what is really in `folder` and well formed.
    static func settings(_ settings: ThemeEntry.Settings, keptIn folder: URL) throws -> ThemeEntry.Settings {
        func isFile(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        let file = settings.file
        guard isValid(.init(file: file)), isFile(file) else { throw ThemeError.missingFile(file) }
        var fonts: [String] = []
        for font in settings.fonts ?? [] where !fonts.contains(font) && isValid(.init(file: file, fonts: [font])) && isFile(font) {
            fonts.append(font)
        }
        return .init(file: file, fonts: fonts.isEmpty ? nil : fonts,
                     gfxmode: settings.gfxmode.flatMap { isValid(.init(file: file, gfxmode: $0)) ? $0 : nil },
                     ventoyLeft: settings.ventoyLeft.flatMap { isValid(.init(file: file, ventoyLeft: $0)) ? $0 : nil },
                     ventoyTop: settings.ventoyTop.flatMap { isValid(.init(file: file, ventoyTop: $0)) ? $0 : nil },
                     ventoyColor: settings.ventoyColor.flatMap { isValid(.init(file: file, ventoyColor: $0)) ? $0 : nil })
    }

    static func makeID(name: String, files: [ThemeSourceFile], settings: ThemeEntry.Settings) -> String {
        // The settings ride along as one more "file". A real path never holds a NUL, so it can't clash with one.
        let canonical = JSONEncoder()
        canonical.outputFormatting = [.sortedKeys]
        let encoded = (try? canonical.encode(settings)) ?? Data()
        let digest = CustomThemeImporter.contentDigest(files + [ThemeSourceFile(path: "\u{0}settings", data: encoded)])
        return "custom-\(CustomThemeImporter.slug(name))-\(digest.prefix(8))"
    }

    /// The `desktop-image` the theme file names, when it is a picture a tile can show.
    static func previewFile(for settings: ThemeEntry.Settings, in folder: URL) -> String? {
        let text = (try? String(contentsOf: folder.appendingPathComponent(settings.file), encoding: .utf8)) ?? ""
        guard let image = CustomThemeImporter.backgroundImage(inThemeText: text) else { return nil }
        // GRUB reads the path relative to the theme file's own folder.
        let directory = ThemeAssembler.parent(settings.file)
        let path = directory.isEmpty ? image : directory + "/" + image
        var isDirectory: ObjCBool = false
        guard isPreviewPath(path),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return nil }
        return path
    }

    static func isPreviewPath(_ path: String) -> Bool {
        ThemePath.isSafeRelative(path) && previewExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
