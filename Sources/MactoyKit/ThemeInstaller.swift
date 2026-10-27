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
        guard let file = try VentoyConfigEditor.themeFiles(in: readConfig(volume)).first else { return .ventoyDefault }
        let parts = file.split(separator: "/").map(String.init)
        if parts.count >= 4, parts[0] == "ventoy", parts[1] == "themes", parts[2].hasPrefix(managedPrefix),
           let marker = readMarker(volume.appendingPathComponent("\(themesPath)/\(parts[2])")) {
            return .managed(id: marker.id, name: marker.name)
        }
        return .other(file: file)
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
        guard isValidID(id) else { throw ThemeError.unknownTheme(id) }
        guard !isReadOnly(volume) else { throw ThemeError.readOnlyVolume }
        let folder = managedPrefix + id
        let original = try readConfig(volume)
        // Everything that can be checked without writing is checked first: if
        // the settings can't be edited safely or the theme is incomplete,
        // nothing on the drive changes (not even an empty themes folder).
        let updated = try VentoyConfigEditor.settingTheme(settingsValue(settings, folder: folder), in: original)
        let warnings = try modeWarnings(original) + caseWarnings(volume)
        let files = try visibleFiles(in: themeDirectory)
        let present = Set(files.map(\.path))
        for needed in [settings.file] + (settings.fonts ?? []) where !present.contains(needed) {
            throw ThemeError.missingFile(needed)
        }

        let fm = FileManager.default
        let themes = volume.appendingPathComponent(themesPath, isDirectory: true)
        let destination = themes.appendingPathComponent(folder, isDirectory: true)
        // attributesOfItem doesn't follow symlinks, so a link here counts too.
        // Only a folder with our marker is ours to replace.
        if (try? fm.attributesOfItem(atPath: destination.path)) != nil, readMarker(destination) == nil {
            throw ThemeError.destinationExists(destination.path)
        }
        try fm.createDirectory(at: themes, withIntermediateDirectories: true)
        let staging = themes.appendingPathComponent(".mactoy-staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try copyVisibleFiles(files, to: staging)
            try JSONEncoder().encode(Marker(id: id, name: name)).write(to: staging.appendingPathComponent(markerName))
            if (try? fm.attributesOfItem(atPath: destination.path)) != nil { try fm.removeItem(at: destination) }
            try fm.moveItem(at: staging, to: destination)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        // Settings go last, so a failure above never leaves ventoy.json
        // pointing at a theme that isn't there.
        try writeConfig(updated, original: original, volume: volume)
        removeManagedFolders(in: themes, except: folder)
        return Outcome(warnings: warnings)
    }

    @discardableResult
    public static func removeTheme(from volume: URL, isReadOnly: (URL) -> Bool = ThemeInstaller.isReadOnly) throws -> Outcome {
        guard !isReadOnly(volume) else { throw ThemeError.readOnlyVolume }
        let original = try readConfig(volume)
        if let updated = try VentoyConfigEditor.removingTheme(from: original), updated != original {
            try writeConfig(updated, original: original, volume: volume)
        }
        removeManagedFolders(in: volume.appendingPathComponent(themesPath, isDirectory: true), except: nil)
        return Outcome(warnings: try modeWarnings(original))
    }

    // MARK: Internals

    static func configURL(_ volume: URL) -> URL { volume.appendingPathComponent("ventoy/ventoy.json") }

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
        if let original { try original.write(to: dir.appendingPathComponent(backupName)) }
        let temp = dir.appendingPathComponent(".ventoy.json.mactoy-tmp")
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

    static func removeManagedFolders(in themes: URL, except keep: String?) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: themes.path)) ?? []
        where name.hasPrefix(managedPrefix) && name != keep {
            let folder = themes.appendingPathComponent(name, isDirectory: true)
            if readMarker(folder) != nil { try? fm.removeItem(at: folder) }
        }
    }

    /// The source folder's files, minus hidden ones (the cache's `.complete`
    /// marker, `.DS_Store`, `._` files), which `isSafeRelative` rejects.
    static func visibleFiles(in source: URL) throws -> [ThemeSourceFile] {
        try ThemeAssembler.files(fromFolder: source).filter { ThemePath.isSafeRelative($0.path) }
    }

    /// Copies by writing the bytes already read, so no extended attributes
    /// follow the files (on exFAT they'd become `._` files).
    static func copyVisibleFiles(_ files: [ThemeSourceFile], to destination: URL) throws {
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
