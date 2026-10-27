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

    public static func current(on volume: URL) throws -> Current {
        let config = try readConfig(volume)
        // Any `theme` member that isn't Mactoy's is the user's: apply and remove
        // overwrite or delete the whole value, so it must never read as the default.
        guard try VentoyConfigEditor.hasTheme(in: config) else { return .ventoyDefault }
        guard let file = try VentoyConfigEditor.themeFiles(in: config).first else { return .other(file: "") }
        let parts = file.split(separator: "/").map(String.init)
        if parts.count >= 4, parts[0] == "ventoy", parts[1] == "themes", parts[2].hasPrefix(managedPrefix),
           let marker = readMarker(volume.appendingPathComponent("\(themesPath)/\(parts[2])")) {
            return .managed(id: marker.id, name: marker.name)
        }
        return .other(file: file)
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
        if let theme = try themeObject(in: config) {
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

    /// The `theme` object in `ventoy.json`, if it is one.
    private static func themeObject(in config: Data?) throws -> [String: Any]? {
        guard let config, !VentoyConfigEditor.isBlank(config) else { return nil }
        let parsed = try VentoyConfigEditor.parse(config)
        guard let member = parsed.members.first(where: { $0.key == "theme" }) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(parsed.bytes[member.valueStart..<member.valueEnd])) as? [String: Any]
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
        removeManagedFolders(in: themes, except: folder)
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
        removeManagedFolders(in: volume.appendingPathComponent(themesPath, isDirectory: true), except: nil)
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
        if let original, !exists(backup) { try original.write(to: backup) }
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
    static func removeManagedFolders(in themes: URL, except keep: String?) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: themes.path)) ?? [] where name != keep {
            let folder = themes.appendingPathComponent(name, isDirectory: true)
            guard !isSymlink(folder) else { continue }
            if (name.hasPrefix(managedPrefix) && readMarker(folder) != nil) || isLeftover(name) {
                try? fm.removeItem(at: folder)
            }
        }
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
