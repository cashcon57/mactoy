import Foundation

/// Finds the boot images Ventoy's menu will list on a mounted Ventoy
/// volume, so Manage Disk shows the same set (PR #10). Where it can't
/// match exactly (see the end of this comment) it lists more, never
/// fewer.
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
/// - A folder containing a file whose name starts with `.ventoyignore`
///   (case-sensitive) is skipped, with everything below it. Trash
///   folders (`.Trashes`, `.trash-*`, `$RECYCLE.BIN`) are skipped unless
///   `VTOY_FILT_TRASH_DIR` is `"0"`, as in Ventoy.
/// - A UTF-16 `ventoy.json` is a syntax error to Ventoy, so its settings
///   don't apply; a UTF-8 byte-order mark is fine.
/// - Each `control` entry sets one variable; a later entry overrides an
///   earlier one.
/// - `VTOY_FILE_FLT_<TYPE>` set to `"1"` hides that image type.
/// - Files smaller than 32 KiB are not images (`VTOY_FILT_MIN_FILE_SIZE`).
///
/// Where Mactoy can't know what the menu will show, it shows more rather
/// than fewer, by listing the whole volume:
/// - `ventoy.json` has per-boot-mode `control_<mode>` keys, which replace
///   `control` in that mode;
/// - a `control` entry holds more than one key — Ventoy reads only the
///   first, and JSON parsing doesn't keep key order;
/// - the configured root isn't a folder on this volume;
/// - `ventoy.json` contains a backslash escape, which Ventoy's parser
///   reads literally and Apple's decodes.
///
/// Known gaps, where Manage Disk lists more than the menu:
/// - the `image_list` / `image_blacklist` plugins aren't applied;
/// - `.efi` files are listed regardless of boot mode (Ventoy lists them
///   only when booted in UEFI mode), and `.wim` / `.vhd(x)` regardless of
///   whether Ventoy's wimboot/vhdboot support is present.
///
/// And one where it lists fewer: symlinked files are skipped. A Ventoy
/// data partition is exFAT or NTFS, which macOS mounts without symlink
/// support, so this doesn't arise on a real stick.
///
/// One deliberate difference: files and folders whose names start with
/// `.` are never listed. Ventoy lists them unless configured not to, but
/// on a drive used from a Mac they're almost always `._` metadata files,
/// which aren't images. (Only the leading dot counts — files carrying
/// the macOS or Windows "hidden" flag are listed, as Ventoy lists them.)
public enum VentoyImageLibrary {

    /// Image file extensions Ventoy recognises (case-insensitive).
    public static let imageExtensions: Set<String> = ["iso", "wim", "img", "vhd", "vhdx", "efi", "vtoy"]

    public struct Configuration: Equatable, Sendable {
        /// Raw `VTOY_DEFAULT_SEARCH_ROOT` value, when one applies.
        public var searchRoot: String?
        /// `nil` = unlimited.
        public var maxSearchLevel: Int?
        /// `false` only when `VTOY_FILT_TRASH_DIR` is `"0"`.
        public var skipTrashFolders = true
        /// Lowercase extensions hidden by `VTOY_FILE_FLT_<TYPE>` = `"1"`.
        public var hiddenExtensions: Set<String> = []

        /// When the menu's contents can't be predicted: the widest set
        /// Ventoy could show (whole volume, any depth, trash included).
        static let everything = Configuration(skipTrashFolders: false)
    }

    /// Ventoy hides files smaller than this (`VTOY_FILT_MIN_FILE_SIZE`).
    public static let minimumImageSize = 32 * 1024

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
        guard var data = try? Data(contentsOf: url) else { return Configuration() }
        // Ventoy skips a UTF-8 byte-order mark and rejects UTF-16 outright
        // (`ventoy_cmd_load_plugin`), so a UTF-16 file means defaults.
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return Configuration() }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        // Ventoy's JSON parser doesn't decode escape sequences; Apple's
        // does, so `"\/iso"` or `"\u0031"` would mean different things to
        // the two. Don't guess.
        if data.contains(0x5C) { return .everything }
        guard let json = try? JSONSerialization.jsonObject(with: Data(data)) as? [String: Any]
        else { return Configuration() }

        // A `control_<mode>` key replaces `control` entirely in that boot
        // mode, so plain `control` no longer tells us what every mode
        // shows. Fall back to listing everything.
        if json.keys.contains(where: { $0.hasPrefix("control_") }) {
            return .everything
        }

        // Ventoy reads each entry on its own, takes only its first key,
        // skips it if the value isn't a string, and lets a later entry
        // override an earlier one (each is a GRUB `set`).
        var values: [String: String] = [:]
        for case let entry as [String: Any] in (json["control"] as? [Any]) ?? [] {
            guard entry.count <= 1 else { return .everything }
            if let (key, value) = entry.first, let string = value as? String {
                values[key] = string
            }
        }

        var config = Configuration()
        if let root = values["VTOY_DEFAULT_SEARCH_ROOT"], root.hasPrefix("/") {
            config.searchRoot = root
        }
        if let level = values["VTOY_MAX_SEARCH_LEVEL"], level.allSatisfy(\.isASCIIDigit) {
            // Ventoy stores `(int)strtoul(...)`: "" is 0, values past
            // Int32 wrap, and a negative result means "search root only".
            let parsed = level.isEmpty ? 0 : (UInt64(level) ?? UInt64.max)
            config.maxSearchLevel = max(0, Int(Int32(truncatingIfNeeded: parsed)))
        }
        if values["VTOY_FILT_TRASH_DIR"] == "0" {
            config.skipTrashFolders = false
        }
        let typeFilters: [(String, [String])] = [
            ("ISO", ["iso"]), ("WIM", ["wim"]), ("IMG", ["img"]),
            ("VHD", ["vhd", "vhdx"]), ("EFI", ["efi"]), ("VTOY", ["vtoy"]),
        ]
        for (type, extensions) in typeFilters where values["VTOY_FILE_FLT_\(type)"] == "1" {
            config.hiddenExtensions.formUnion(extensions)
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
        collect(in: directory, level: 0, config: config, into: &found)
        found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return Scan(directory: directory, images: found)
    }

    public static func images(on volume: URL) -> [URL] {
        scan(volume: volume).images
    }

    private static func collect(in directory: URL, level: Int, config: Configuration, into found: inout [URL]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        else { return }
        let maxLevel = config.maxSearchLevel ?? Int.max

        // `ventoy_check_ignore_flag`: a subfolder (never the search root
        // itself) holding a regular file whose name starts with
        // `.ventoyignore`, case-sensitively, is skipped whole.
        if level > 0, entries.contains(where: { url in
            url.lastPathComponent.hasPrefix(".ventoyignore")
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }) {
            return
        }

        var images: [URL] = []
        for url in entries {
            let name = url.lastPathComponent
            guard !name.hasPrefix("."),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true
            else { continue }

            if values.isDirectory == true {
                guard level + 1 <= maxLevel,
                      !(config.skipTrashFolders && isTrashFolder(name))
                else { continue }
                collect(in: url, level: level + 1, config: config, into: &found)
            } else if values.isRegularFile == true,
                      isImageName(name),
                      !config.hiddenExtensions.contains((name as NSString).pathExtension.lowercased()),
                      (values.fileSize ?? 0) >= minimumImageSize {
                images.append(url)
            }
        }
        found.append(contentsOf: images)
    }

    /// Ventoy's trash-folder names. The dotted ones are already skipped
    /// as dot-names; listed for completeness when the filter is off.
    static func isTrashFolder(_ name: String) -> Bool {
        name.hasPrefix("$RECYCLE.BIN") || name.hasPrefix(".trash-") || name == ".Trashes"
    }

    /// Ventoy's file filter: a known extension, minus its own two helper
    /// images (`ventoy_wimboot.img`, `ventoy_vhdboot.img`).
    static func isImageName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard imageExtensions.contains(ext), name.count > ext.count + 1 else { return false }
        // Ventoy matches the stem case-sensitively, the extension not.
        if ext == "img", name.dropLast(4) == "ventoy_wimboot" || name.dropLast(4) == "ventoy_vhdboot" { return false }
        return true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
