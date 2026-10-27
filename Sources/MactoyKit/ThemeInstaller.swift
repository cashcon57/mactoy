import Foundation

/// Puts a boot theme on a mounted Ventoy volume, or takes it off.
///
/// Mactoy owns only folders it created: `ventoy/themes/mactoy-<id>/`
/// with a `.mactoy-theme.json` marker. Anything else under `ventoy/` is
/// the user's and is never deleted. The only change to `ventoy.json` is
/// its top-level `theme` (see `VentoyConfigEditor`).
public enum ThemeInstaller {
    public static let themesPath = "ventoy/themes"
    public static let managedPrefix = "mactoy-"
    public static let markerName = ".mactoy-theme.json"
    public static let backupName = "ventoy.json.mactoy-backup"

    public enum Current: Equatable, Sendable {
        case ventoyDefault
        case managed(id: String, name: String)
        /// The user's own `theme` setting. `file` is empty when the setting
        /// names no theme file (only `gfxmode`, say, or a value that isn't an object).
        case other(file: String)
    }

    public struct Outcome: Equatable, Sendable {
        public var warnings: [String]
    }

    struct Marker: Codable { let id: String; let name: String }

    public static func isReadOnly(_ volume: URL) -> Bool {
        (try? volume.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    }

    /// `^[a-z0-9][a-z0-9-]{1,59}$`, checked by unicode scalar. The id becomes
    /// a folder name that is later deleted, so it must never hold `/` or `..`,
    /// and a regex `$` would also let a trailing newline through.
    public static func isValidID(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard (2...60).contains(scalars.count) else { return false }
        func alnum(_ s: Unicode.Scalar) -> Bool { ("a"..."z").contains(s) || ("0"..."9").contains(s) }
        return alnum(scalars[0]) && scalars.dropFirst().allSatisfy { alnum($0) || $0 == "-" }
    }

    /// Whether `volume` looks like a drive Mactoy has only just installed Ventoy
    /// on: no `ventoy/ventoy.json`, and `ventoy/themes` missing or empty.
    ///
    /// The install-time theme is applied to whatever Ventoy volume shows up on
    /// the installed disk's number, and macOS can hand that number to a different
    /// stick if the user swaps drives meanwhile. A drive someone has used already
    /// has settings or themes, and applying would replace the user's own theme
    /// and delete `mactoy-*` folders on a drive they never agreed to change.
    ///
    /// Reads only, and without following links (`attributesOfItem` is an lstat):
    /// a link where a folder or file should be is not a fresh drive.
    public static func looksFreshlyInstalled(_ volume: URL) -> Bool {
        let ventoy = volume.appendingPathComponent("ventoy", isDirectory: true)
        switch fileType(ventoy) {
        case nil: return true            // a brand new Ventoy volume has no settings folder yet
        case .typeDirectory?: break
        default: return false            // a link or a file: not ours to look through
        }
        guard !exists(configURL(volume)) else { return false }
        let themes = volume.appendingPathComponent(themesPath, isDirectory: true)
        switch fileType(themes) {
        case nil: return true
        case .typeDirectory?:
            // A listing that fails is not "empty". Raw, so a stray `._` file counts as something being there.
            guard let entries = rawEntries(of: themes) else { return false }
            return entries.isEmpty
        default: return false
        }
    }

    public static func current(on volume: URL) throws -> Current {
        let config = try readConfig(volume)
        // Any `theme` member that isn't Mactoy's is the user's: apply and remove
        // overwrite or delete the whole value, so it must never read as the default.
        guard try VentoyConfigEditor.hasTheme(in: config) else { return .ventoyDefault }
        guard let file = try VentoyConfigEditor.themeFiles(in: config).first else { return .other(file: "") }
        if let managed = try managedTheme(file: file, in: config, on: volume) { return managed }
        return .other(file: file)
    }

    /// The keys `settingsValue` writes: a `theme` with any other key has been edited since.
    private static let managedKeys = Set(ThemeEntry.Settings.CodingKeys.allCases.map(\.rawValue))

    /// `.managed` only for the exact shape Mactoy writes, because "managed" lets a
    /// replacement go ahead without asking: the `theme` object holds nothing but
    /// Mactoy's own keys, `file` is one string in a `mactoy-<id>` folder that
    /// holds a trustworthy marker for that same id, and so are the fonts. Anything
    /// else (a file list, `display_mode`, `default_file`, a path that climbs out of
    /// the folder, a marker that isn't a plain file) is the user's, and is shown as such.
    private static func managedTheme(file: String, in config: Data?, on volume: URL) throws -> Current? {
        guard let theme = try VentoyConfigEditor.themeObject(in: config),
              theme["file"] is String, Set(theme.keys).isSubset(of: managedKeys),
              let parts = pathParts(file), parts.count >= 4, parts[0] == "ventoy", parts[1] == "themes",
              // `pathParts` skips empty parts; Mactoy never writes one, so a path with one was not written by Mactoy.
              file == "/" + parts.joined(separator: "/"),
              parts[2].hasPrefix(managedPrefix)
        else { return nil }
        // Each step down is a real folder: a link could lead the marker read anywhere on this Mac.
        var folder = volume
        for part in parts.prefix(3) {
            folder.appendPathComponent(part, isDirectory: true)
            guard fileType(folder) == .typeDirectory else { return nil }
        }
        guard let marker = markerIfPlain(folder), parts[2] == managedPrefix + marker.id else { return nil }
        if let fonts = theme["fonts"] {
            // Mactoy writes an array of strings, every one inside the same folder.
            guard let list = fonts as? [String], list.allSatisfy({ font in
                pathParts(font).map { $0.count > 3 && $0.prefix(3).elementsEqual(parts.prefix(3)) } == true
            }) else { return nil }
        }
        // Read off a drive: shown in a dialog, so no control or bidi characters.
        return .managed(id: marker.id, name: ThemeLibrary.cleaned(marker.name, limit: ThemeLibrary.maxNameLength, fallback: marker.id))
    }

    /// The theme a drive is set to use, found on the drive, so it can be kept
    /// before something else replaces it.
    public struct DriveTheme: Sendable, Equatable {
        /// The theme's folder on the drive.
        public let folder: URL
        public let name: String
        /// Paths are relative to `folder`. Not checked: `ThemeLibrary.save` does that.
        public let settings: ThemeEntry.Settings
        /// The id in the marker when `folder` is one Mactoy installed (`mactoy-<id>`).
        public let managedID: String?

        public init(folder: URL, name: String, settings: ThemeEntry.Settings, managedID: String?) {
            self.folder = folder; self.name = name; self.settings = settings; self.managedID = managedID
        }
    }

    /// The theme `ventoy.json` points at, or nil when there is nothing safe to
    /// keep: the default theme, a `theme` setting with no usable `file`, or a
    /// theme file that is missing, sits at the volume root, or reaches outside
    /// the volume or through a link. A drive that isn't ours can name any path,
    /// and the answer is read and copied, so only a plain folder inside it counts.
    /// Throws only when `ventoy.json` can't be read.
    ///
    /// The folder is the theme file's own folder, except for one Mactoy
    /// installed: that is the whole `mactoy-<id>` folder, so a theme file in a
    /// subfolder keeps the pictures beside that subfolder.
    public static func driveTheme(on volume: URL) throws -> DriveTheme? {
        let config = try readConfig(volume)
        guard try VentoyConfigEditor.hasTheme(in: config),
              let file = try VentoyConfigEditor.themeFiles(in: config).first,
              let parts = pathParts(file), parts.count >= 2
        else { return nil }
        func url(_ parts: some Sequence<String>) -> URL { parts.reduce(volume) { $0.appendingPathComponent($1) } }

        // Each step down must be a real folder, and the file a real file.
        let folders = Array(parts.dropLast())
        for depth in 1...folders.count where fileType(url(folders.prefix(depth))) != .typeDirectory {
            return nil
        }
        guard fileType(url(parts)) == .typeRegular else { return nil }

        let managedRoot = parts.count >= 4 && parts[0] == "ventoy" && parts[1] == "themes" && parts[2].hasPrefix(managedPrefix)
        let marker = managedRoot ? markerIfPlain(url(parts.prefix(3))) : nil
        let folderParts = marker == nil ? folders : Array(parts.prefix(3))
        let folder = url(folderParts)

        // Belt and braces: wherever the folder really is, it's inside the volume and isn't the volume.
        let root = volume.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(root.hasSuffix("/") ? root : root + "/"), resolved != root else { return nil }

        var settings = ThemeEntry.Settings(file: parts.dropFirst(folderParts.count).joined(separator: "/"))
        if let theme = try VentoyConfigEditor.themeObject(in: config) {
            settings.fonts = fontPaths(theme["fonts"]).compactMap { font -> String? in
                guard let fontParts = pathParts(font), fontParts.count > folderParts.count,
                      zip(fontParts, folderParts).allSatisfy({ $0.caseInsensitiveCompare($1) == .orderedSame })
                else { return nil }
                return fontParts.dropFirst(folderParts.count).joined(separator: "/")
            }
            if settings.fonts?.isEmpty == true { settings.fonts = nil }
            settings.gfxmode = theme["gfxmode"] as? String
            settings.ventoyLeft = theme["ventoy_left"] as? String
            settings.ventoyTop = theme["ventoy_top"] as? String
            settings.ventoyColor = theme["ventoy_color"] as? String
        }

        let name: String
        if let marker {
            name = ThemeLibrary.cleaned(marker.name, limit: ThemeLibrary.maxNameLength, fallback: marker.id)
        } else if folderParts.last?.lowercased() == "ventoy" {
            // `/ventoy/theme.txt`: the folder's own name says nothing about the theme.
            name = ThemeLibrary.cleaned("Theme from \(volume.lastPathComponent)", limit: ThemeLibrary.maxNameLength)
        } else {
            name = ThemeLibrary.cleaned(folderParts.last ?? "", limit: ThemeLibrary.maxNameLength, fallback: "Theme")
        }
        return DriveTheme(folder: folder, name: name, settings: settings, managedID: marker?.id)
    }

    /// `/ventoy/themes/x/theme.txt` as its parts. nil for a name that could
    /// leave the volume (`..`, `.`), for a backslash, and for no parts at all.
    private static func pathParts(_ path: String) -> [String]? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains("\\") }) else { return nil }
        return parts
    }

    /// The marker of a folder Mactoy installed, only from a plain file with a usable id:
    /// what a drive says about itself is not trusted past this point.
    private static func markerIfPlain(_ folder: URL) -> Marker? {
        guard fileType(folder.appendingPathComponent(markerName)) == .typeRegular,
              let marker = readMarker(folder), isValidID(marker.id)
        else { return nil }
        return marker
    }

    private static func fontPaths(_ value: Any?) -> [String] {
        if let one = value as? String { return [one] }
        return (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// The `theme` object for a folder installed at `ventoy/themes/<folder>`.
    public static func settingsValue(_ s: ThemeEntry.Settings, folder: String) -> [String: Any] {
        let base = "/\(themesPath)/\(folder)/"
        var value: [String: Any] = ["file": base + s.file, "gfxmode": s.gfxmode ?? ThemeEntry.Settings.defaultGfxmode]
        if let fonts = s.fonts, !fonts.isEmpty { value["fonts"] = fonts.map { base + $0 } }
        if let v = s.ventoyLeft { value["ventoy_left"] = v }
        if let v = s.ventoyTop { value["ventoy_top"] = v }
        if let v = s.ventoyColor { value["ventoy_color"] = v }
        return value
    }

    @discardableResult
    public static func apply(themeDirectory: URL, id: String, name: String, settings: ThemeEntry.Settings,
                             to volume: URL, isReadOnly: (URL) -> Bool = ThemeInstaller.isReadOnly) throws -> Outcome {
        try install(themeDirectory: themeDirectory, id: id, name: name, settings: settings, to: volume,
                    isReadOnly: isReadOnly, move: moveItem)
    }

    /// `move` is a seam so tests can make a rename fail.
    @discardableResult
    static func install(themeDirectory: URL, id: String, name: String, settings: ThemeEntry.Settings,
                        to volume: URL, isReadOnly: (URL) -> Bool, move: (URL, URL) throws -> Void) throws -> Outcome {
        guard isValidID(id) else { throw ThemeError.unknownTheme(id) }
        guard !isReadOnly(volume) else { throw ThemeError.readOnlyVolume }
        try requireNoLinks(on: volume)
        let folder = managedPrefix + id
        let original = try readConfig(volume)
        // Everything that can be checked without writing is checked first: if
        // the settings can't be edited safely or the theme is incomplete,
        // nothing on the drive changes (not even an empty themes folder).
        let updated = try VentoyConfigEditor.settingTheme(settingsValue(settings, folder: folder), in: original)
        let warnings = try modeWarnings(original) + caseWarnings(volume)
        let files = try installableFiles(in: themeDirectory)
        let present = Set(files.map(\.path))
        for needed in [settings.file] + (settings.fonts ?? []) where !present.contains(needed) {
            throw ThemeError.missingFile(needed)
        }

        let fm = FileManager.default
        let themes = volume.appendingPathComponent(themesPath, isDirectory: true)
        let destination = themes.appendingPathComponent(folder, isDirectory: true)
        // Only a folder with our marker is ours to replace.
        let replacing = exists(destination)
        if replacing {
            if isSymlink(destination) { throw ThemeError.unsafeVolumeLayout("\(themesPath)/\(folder)") }
            if readMarker(destination) == nil { throw ThemeError.destinationExists(destination.path) }
        }
        let createdVentoyFolder = !exists(volume.appendingPathComponent("ventoy", isDirectory: true))
        try fm.createDirectory(at: themes, withIntermediateDirectories: true)
        let staging = themes.appendingPathComponent(".mactoy-staging-\(UUID().uuidString)", isDirectory: true)
        let old = themes.appendingPathComponent(".mactoy-old-\(UUID().uuidString)", isDirectory: true)
        var setAside = false
        do {
            try copyFiles(files, to: staging)
            try JSONEncoder().encode(Marker(id: id, name: name)).write(to: staging.appendingPathComponent(markerName))
            // The installed copy is renamed aside, not deleted, until the new
            // one is in place: ventoy.json may already point at it.
            if replacing { try move(destination, old); setAside = true }
            try move(staging, destination)
        } catch {
            if setAside { try? move(old, destination) }
            try? fm.removeItem(at: staging)
            throw error
        }
        defer { if setAside { try? fm.removeItem(at: old) } }
        // Settings go last, so a failure above never leaves ventoy.json
        // pointing at a theme that isn't there.
        try writeConfig(updated, original: original, volume: volume)
        let removed = removeManagedFolders(in: themes, except: folder)
        // The staging and old folders are renamed or removed by now (or just about to be).
        removeAppleDoubleClutter(on: volume, installed: folder, gone: removed + [staging.lastPathComponent, old.lastPathComponent],
                                 createdVentoyFolder: createdVentoyFolder, removeEmptyThemesFolder: false)
        return Outcome(warnings: warnings)
    }

    @discardableResult
    public static func removeTheme(from volume: URL, isReadOnly: (URL) -> Bool = ThemeInstaller.isReadOnly) throws -> Outcome {
        guard !isReadOnly(volume) else { throw ThemeError.readOnlyVolume }
        try requireNoLinks(on: volume)
        let original = try readConfig(volume)
        if let updated = try VentoyConfigEditor.removingTheme(from: original), updated != original {
            try writeConfig(updated, original: original, volume: volume)
        }
        let removed = removeManagedFolders(in: volume.appendingPathComponent(themesPath, isDirectory: true), except: nil)
        removeAppleDoubleClutter(on: volume, installed: nil, gone: removed, createdVentoyFolder: false, removeEmptyThemesFolder: true)
        return Outcome(warnings: try modeWarnings(original))
    }

    // MARK: Internals

    static let tempName = ".ventoy.json.mactoy-tmp"

    static func configURL(_ volume: URL) -> URL { volume.appendingPathComponent("ventoy/ventoy.json") }

    static func moveItem(_ from: URL, _ to: URL) throws { try FileManager.default.moveItem(at: from, to: to) }

    /// Neither of these follows a symlink: `attributesOfItem` is an lstat.
    static func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil }
    static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }
    /// What is at `url`, or nil when nothing is. A link is reported as a link, not followed.
    static func fileType(_ url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    /// A drive that isn't ours can make any of the paths Mactoy writes to a
    /// link to somewhere on this Mac, so none may be one. Checked before the
    /// first write (and before reading) in both `apply` and `removeTheme`.
    static func requireNoLinks(on volume: URL) throws {
        for path in ["ventoy", themesPath, "ventoy/ventoy.json", "ventoy/\(backupName)", "ventoy/\(tempName)"]
        where isSymlink(volume.appendingPathComponent(path)) {
            throw ThemeError.unsafeVolumeLayout(path)
        }
        // Belt and braces: wherever the themes folder really is, it's inside the volume.
        let root = volume.resolvingSymlinksInPath().standardizedFileURL.path
        let themes = volume.appendingPathComponent(themesPath).resolvingSymlinksInPath().standardizedFileURL.path
        guard themes.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { throw ThemeError.unsafeVolumeLayout(themesPath) }
    }

    /// `nil` only when the file doesn't exist; an unreadable file throws,
    /// so it's never mistaken for "no settings" and overwritten.
    static func readConfig(_ volume: URL) throws -> Data? {
        let url = configURL(volume)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    static func writeConfig(_ data: Data, original: Data?, volume: URL) throws {
        let fm = FileManager.default
        let url = configURL(volume)
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // The first file is the one worth keeping: later ones only differ by our own edits.
        let backup = dir.appendingPathComponent(backupName)
        // Atomic: a write cut short must not leave a half file that `exists` then protects forever as "the user's first file".
        if let original, !exists(backup) { try original.write(to: backup, options: .atomic) }
        let temp = dir.appendingPathComponent(tempName)
        do { try data.write(to: temp) } catch { try? fm.removeItem(at: temp); throw error }
        guard rename(temp.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: temp)
            throw ThemeError.writeFailed(reason)
        }
        guard (try? Data(contentsOf: url)) == data else { throw ThemeError.writeFailed("ventoy.json didn't read back as written") }
    }

    static func readMarker(_ folder: URL) -> Marker? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(markerName)) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    /// Deletes folders Mactoy made: `mactoy-*` ones that carry our marker, and
    /// the `.mactoy-staging-<uuid>` / `.mactoy-old-<uuid>` ones an interrupted
    /// install can leave. Links are never followed or removed.
    /// Returns the names of the folders it removed.
    @discardableResult
    static func removeManagedFolders(in themes: URL, except keep: String?) -> [String] {
        let fm = FileManager.default
        var removed: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: themes.path)) ?? [] where name != keep {
            let folder = themes.appendingPathComponent(name, isDirectory: true)
            guard !isSymlink(folder) else { continue }
            if (name.hasPrefix(managedPrefix) && readMarker(folder) != nil) || isLeftover(name) {
                if (try? fm.removeItem(at: folder)) != nil { removed.append(name) }
            }
        }
        return removed
    }

    // MARK: AppleDouble clutter

    /// The first four bytes of every AppleDouble file.
    static let appleDoubleMagic: [UInt8] = [0x00, 0x05, 0x16, 0x07]
    /// A companion that only carries extended attributes is tiny; a bigger one holds something else.
    static let maxAppleDoubleBytes = 64 * 1024

    /// On exFAT, macOS keeps a file's extended attributes (the `com.apple.provenance`
    /// it puts on every file an app writes) in a hidden `._<name>` beside it, so one
    /// theme install can leave over a hundred of them on a user's stick. Removes the
    /// ones that belong to what Mactoy just wrote or removed, and nothing else.
    ///
    /// Best effort: the change itself already succeeded, so a failure here is ignored.
    /// Never reads or follows anything but plain files, and a `._X` goes only when
    /// `isAppleDouble` agrees and `X` is there or was removed by Mactoy:
    /// - everything under the installed theme folder, and the folder's own;
    /// - those of the folders removed (`gone`) from `ventoy/themes`;
    /// - beside `ventoy/themes`, `ventoy.json` and its backup (and `ventoy`, if Mactoy made it).
    ///
    /// With `removeEmptyThemesFolder`, `ventoy/themes` goes too once nothing is left in it.
    static func removeAppleDoubleClutter(on volume: URL, installed: String?, gone: [String],
                                         createdVentoyFolder: Bool, removeEmptyThemesFolder: Bool) {
        let ventoy = volume.appendingPathComponent("ventoy", isDirectory: true)
        let themes = ventoy.appendingPathComponent("themes", isDirectory: true)
        if let installed {
            let folder = themes.appendingPathComponent(installed, isDirectory: true)
            removeCompanions(under: folder)
            removeCompanion(of: installed, in: themes, counterpartRemoved: false)
        }
        for name in gone { removeCompanion(of: name, in: themes, counterpartRemoved: true) }

        // "Empty" is measured after the companions of what was removed are gone.
        var themesRemoved = false
        if removeEmptyThemesFolder, fileType(themes) == .typeDirectory,
           let left = rawEntries(of: themes), left.isEmpty {
            // rmdir, not removeItem: it refuses a folder that has anything in it.
            themesRemoved = rmdir(themes.path) == 0
        }

        removeCompanion(of: "themes", in: ventoy, counterpartRemoved: themesRemoved)
        removeCompanion(of: "ventoy.json", in: ventoy, counterpartRemoved: false)
        removeCompanion(of: backupName, in: ventoy, counterpartRemoved: false)
        // Renamed over ventoy.json, so a companion left under this name has no file left.
        removeCompanion(of: tempName, in: ventoy, counterpartRemoved: true)
        if createdVentoyFolder { removeCompanion(of: "ventoy", in: volume, counterpartRemoved: false) }
    }

    /// Deletes `directory/._<name>` when it is an AppleDouble file and `name` is
    /// beside it (or Mactoy has just removed it).
    private static func removeCompanion(of name: String, in directory: URL, counterpartRemoved: Bool) {
        guard counterpartRemoved || exists(directory.appendingPathComponent(name)) else { return }
        let companion = directory.appendingPathComponent("._" + name)
        if isAppleDouble(companion) { _ = unlink(companion.path) }
    }

    /// Every name in a folder, `._` files included. `FileManager.contentsOfDirectory`
    /// leaves out a `._X` that sits beside an `X`, which is exactly what is wanted here.
    /// Nil when the folder can't be read.
    static func rawEntries(of directory: URL) -> [String]? {
        guard let stream = opendir(directory.path) else { return nil }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// Every `._X` under a folder Mactoy just built whose `X` is beside it.
    private static func removeCompanions(under folder: URL) {
        let names = rawEntries(of: folder) ?? []
        let present = Set(names)
        for name in names {
            if name.hasPrefix("._"), name.count > 2 {
                if present.contains(String(name.dropFirst(2))) { removeCompanion(of: String(name.dropFirst(2)), in: folder, counterpartRemoved: false) }
            } else if fileType(folder.appendingPathComponent(name)) == .typeDirectory {
                removeCompanions(under: folder.appendingPathComponent(name, isDirectory: true))
            }
        }
    }

    /// A regular file (not a link), at most `maxAppleDoubleBytes`, that starts with the AppleDouble magic.
    static func isAppleDouble(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size >= appleDoubleMagic.count, size <= maxAppleDoubleBytes
        else { return false }
        // O_NOFOLLOW: a link put there after the check above is not opened.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var head = [UInt8](repeating: 0, count: appleDoubleMagic.count)
        return read(descriptor, &head, head.count) == head.count && head == appleDoubleMagic
    }

    static func isLeftover(_ name: String) -> Bool {
        [".mactoy-staging-", ".mactoy-old-"].contains { prefix in
            name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
        }
    }

    /// What may land on a drive, whoever prepared the folder: no hidden files
    /// (the cache's `.complete` marker, `.DS_Store`, `._` files), only the
    /// theme file types, and the same limits `ThemeAssembler.assemble` applies.
    /// All checked before anything is written.
    static func installableFiles(in source: URL) throws -> [ThemeSourceFile] {
        let files = try ThemeAssembler.files(fromFolder: source).filter {
            ThemePath.isSafeRelative($0.path)
                && ThemeAssembler.allowedExtensions.contains(($0.path as NSString).pathExtension.lowercased())
        }
        guard files.count <= ThemeAssembler.maxFiles else { throw ThemeError.tooManyFiles(files.count) }
        let total = files.reduce(0) { $0 + $1.data.count }
        guard total <= ThemeAssembler.maxThemeBytes else { throw ThemeError.themeTooLarge(total) }
        return files
    }

    /// Writes the bytes already read, so no extended attributes follow the
    /// files (on exFAT they'd become `._` files).
    static func copyFiles(_ files: [ThemeSourceFile], to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in files {
            let url = destination.appendingPathComponent(file.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
        }
    }

    static func modeWarnings(_ config: Data?) throws -> [String] {
        let names = ["theme_legacy": "Legacy BIOS", "theme_uefi": "UEFI", "theme_ia32": "32-bit UEFI",
                     "theme_aa64": "ARM64 UEFI", "theme_mips": "MIPS"]
        return try VentoyConfigEditor.presentModeSpecificThemeKeys(in: config).map { key in
            "This drive also sets a separate theme for \(names[key] ?? key) boot (\"\(key)\" in ventoy.json). Ventoy uses that one instead when it boots in that mode."
        }
    }

    static func caseWarnings(_ volume: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: volume.path)) ?? []
        guard let wrong = names.first(where: { $0.lowercased() == "ventoy" && $0 != "ventoy" }) else { return [] }
        return ["The drive's settings folder is named \"\(wrong)\". Ventoy only reads a folder named \"ventoy\" in lowercase, so rename it or the theme won't load."]
    }
}

/// `ThemeInstaller.DriveTheme`, spelled the way callers read it.
public typealias DriveTheme = ThemeInstaller.DriveTheme
