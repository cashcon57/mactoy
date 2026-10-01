import Foundation

/// Finds the boot images Ventoy's menu will list on a mounted Ventoy
/// volume, so Manage Disk shows the same set (PR #10).
///
/// Mirrors Ventoy's image collection in
/// `GRUB2/MOD_SRC/grub-2.04/grub-core/ventoy/ventoy_cmd.c`
/// (`ventoy_collect_img_files`, `ventoy_check_ignore_flag`) and the
/// `control` plugin in `ventoy_plugin.c`:
///
/// - Config is read from `/ventoy/ventoy.json` only.
/// - `VTOY_DEFAULT_SEARCH_ROOT` is used only when it starts with `/`;
///   otherwise the whole volume is searched.
/// - `VTOY_MAX_SEARCH_LEVEL`: a decimal number limits subfolder depth
///   (0 = the search root's own files only); anything else is unlimited.
/// - A folder containing a `.ventoyignore` file is skipped, with
///   everything below it. Trash folders (`.Trashes`, `.trash-*`,
///   `$RECYCLE.BIN`) are skipped, as Ventoy does by default.
///
/// Where Mactoy can't know what the menu will show, it shows more rather
/// than fewer: if `ventoy.json` has per-boot-mode `control_<mode>` keys
/// (which replace `control` in that mode), or the configured root isn't
/// a folder on this volume, the whole volume is listed.
///
/// One deliberate difference: hidden files and folders (names starting
/// with `.`) are never listed. Ventoy lists them unless configured not
/// to, but on a drive used from a Mac they're almost always `._`
/// metadata files, which aren't images.
public enum VentoyImageLibrary {

    /// Image file extensions Ventoy recognises (case-insensitive).
    public static let imageExtensions: Set<String> = ["iso", "wim", "img", "vhd", "vhdx", "efi", "vtoy"]

    public struct Configuration: Equatable, Sendable {
        /// Raw `VTOY_DEFAULT_SEARCH_ROOT` value, when one applies.
        public var searchRoot: String?
        /// `nil` = unlimited.
        public var maxSearchLevel: Int?
    }

    public struct Scan: Sendable {
        /// Folder the menu's search starts from. "Add ISO…" copies here.
        public let directory: URL
        /// Images in menu-search order, as absolute URLs.
        public let images: [URL]
    }

    /// Read the parts of `/ventoy/ventoy.json` that decide what's listed.
    /// A missing or unreadable file means Ventoy's defaults.
    public static func configuration(on volume: URL) -> Configuration {
        let url = volume.appendingPathComponent("ventoy/ventoy.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return Configuration() }

        // A `control_<mode>` key replaces `control` entirely in that boot
        // mode, so plain `control` no longer tells us what every mode
        // shows. Fall back to listing everything.
        if json.keys.contains(where: { $0.hasPrefix("control_") }) {
            return Configuration()
        }

        // Ventoy reads each entry on its own and skips any whose value
        // isn't a string, so one malformed entry doesn't void the rest.
        var values: [String: String] = [:]
        for case let entry as [String: Any] in (json["control"] as? [Any]) ?? [] {
            for (key, value) in entry {
                if let string = value as? String, values[key] == nil {
                    values[key] = string
                }
            }
        }

        var config = Configuration()
        if let root = values["VTOY_DEFAULT_SEARCH_ROOT"], root.hasPrefix("/") {
            config.searchRoot = root
        }
        if let level = values["VTOY_MAX_SEARCH_LEVEL"], !level.isEmpty, level.allSatisfy(\.isASCIIDigit) {
            config.maxSearchLevel = Int(level) ?? Int.max
        }
        return config
    }

    /// The folder the menu searches from: the configured search root when
    /// it's a folder on this volume, otherwise the volume itself.
    public static func imageDirectory(on volume: URL, configuration: Configuration? = nil) -> URL {
        let root = volume.resolvingSymlinksInPath().standardizedFileURL
        let config = configuration ?? self.configuration(on: volume)
        guard let searchRoot = config.searchRoot else { return root }
        let relative = searchRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else { return root }
        let candidate = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        // Never let a config redirect file management outside the volume.
        guard candidate.path.hasPrefix(root.path + "/"), isDirectory(candidate) else { return root }
        return candidate
    }

    /// Everything Manage Disk needs, in one pass. Does file I/O; call it
    /// off the main thread.
    public static func scan(volume: URL) -> Scan {
        let config = configuration(on: volume)
        let directory = imageDirectory(on: volume, configuration: config)
        var found: [URL] = []
        collect(in: directory, level: 0, maxLevel: config.maxSearchLevel ?? Int.max, into: &found)
        found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return Scan(directory: directory, images: found)
    }

    public static func images(on volume: URL) -> [URL] {
        scan(volume: volume).images
    }

    private static func collect(in directory: URL, level: Int, maxLevel: Int, into found: inout [URL]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in entries {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true
            else { continue }
            let name = url.lastPathComponent

            if values.isDirectory == true {
                guard level + 1 <= maxLevel,
                      !name.hasPrefix("$RECYCLE.BIN"),
                      !fm.fileExists(atPath: url.appendingPathComponent(".ventoyignore").path)
                else { continue }
                collect(in: url, level: level + 1, maxLevel: maxLevel, into: &found)
            } else if values.isRegularFile == true, isImageName(name) {
                found.append(url)
            }
        }
    }

    /// Ventoy's file filter: a known extension, minus its own two helper
    /// images (`ventoy_wimboot.img`, `ventoy_vhdboot.img`).
    static func isImageName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard imageExtensions.contains(ext), name.count > ext.count + 1 else { return false }
        if name == "ventoy_wimboot.img" || name == "ventoy_vhdboot.img" { return false }
        return true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
