import Foundation
import Testing
@testable import MactoyKit

/// Manage Disk must list what Ventoy's boot menu lists. Each case below
/// is a rule from `ventoy_cmd.c` / `ventoy_plugin.c`; see the doc
/// comment on `VentoyImageLibrary`.
@Suite("Ventoy image library")
struct VentoyImageLibraryTests {

    /// A fake volume: empty files at `files`, optional `/ventoy/ventoy.json`.
    private func volume(_ files: [String], json: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-lib-\(UUID().uuidString)")
        for path in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Ventoy ignores files under 32 KiB, so fixtures get exactly 32 KiB.
            try Data(count: VentoyImageLibrary.minimumImageSize).write(to: url)
        }
        if let json {
            let url = root.appendingPathComponent("ventoy/ventoy.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(json.utf8).write(to: url)
        }
        return root
    }

    /// Listed images as paths relative to the volume, sorted.
    private func listed(_ root: URL) -> [String] {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return VentoyImageLibrary.images(on: root).map { String($0.standardizedFileURL.path.dropFirst(base.count)) }.sorted()
    }

    private func searchRoot(_ value: String) -> String {
        #"{"control":[{"VTOY_DEFAULT_SEARCH_ROOT":"\#(value)"}]}"#
    }

    @Test("detects images in subfolders and filters unrelated and hidden files")
    func detectsImagesAndFiltersUnrelatedFiles() throws {
        let root = try volume(["images/linux/Ubuntu.ISO", "images/windows.img", "images/notes.txt", "images/._hidden.iso"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(listed(root) == ["images/linux/Ubuntu.ISO", "images/windows.img"])
    }

    @Test("no config: the whole volume is searched — an /images folder isn't special")
    func noConfigSearchesWholeVolume() throws {
        let root = try volume(["images/a.iso", "win.iso", "tools/b.iso"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(listed(root) == ["images/a.iso", "tools/b.iso", "win.iso"])
        #expect(VentoyImageLibrary.imageDirectory(on: root) == root.resolvingSymlinksInPath().standardizedFileURL)
    }

    @Test("VTOY_DEFAULT_SEARCH_ROOT in /ventoy/ventoy.json limits the search")
    func searchRootFromConfig() throws {
        let root = try volume(["iso/x.iso", "iso/deep/y.iso", "other/z.iso"], json: searchRoot("/iso"))
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(listed(root) == ["iso/deep/y.iso", "iso/x.iso"])
        #expect(VentoyImageLibrary.imageDirectory(on: root).lastPathComponent == "iso")
    }

    @Test("a root-level /ventoy.json is ignored, as Ventoy ignores it")
    func rootLevelJSONIgnored() throws {
        let root = try volume(["iso/x.iso", "other/y.iso"])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(searchRoot("/iso").utf8).write(to: root.appendingPathComponent("ventoy.json"))
        #expect(listed(root) == ["iso/x.iso", "other/y.iso"])
    }

    @Test("a search root without a leading / is ignored, as Ventoy ignores it")
    func searchRootNeedsLeadingSlash() throws {
        let root = try volume(["iso/x.iso", "other/y.iso"], json: searchRoot("iso"))
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(listed(root) == ["iso/x.iso", "other/y.iso"])
    }

    @Test("a search root outside the volume, or not a folder, falls back to the whole volume")
    func unusableSearchRoot() throws {
        for value in ["/../../", "/missing", "/x.iso", "/"] {
            let root = try volume(["x.iso", "other/y.iso"], json: searchRoot(value))
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(listed(root) == ["other/y.iso", "x.iso"], "root \(value)")
        }
    }

    @Test("per-boot-mode control keys: list the whole volume rather than guess the mode")
    func perModeControlKeys() throws {
        let json = #"{"control":[{"VTOY_DEFAULT_SEARCH_ROOT":"/iso"}],"control_uefi":[{"VTOY_DEFAULT_SEARCH_ROOT":"/uefi"}]}"#
        let root = try volume(["iso/x.iso", "uefi/u.iso", "other/y.iso"], json: json)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(listed(root) == ["iso/x.iso", "other/y.iso", "uefi/u.iso"])
    }

    @Test("one non-string control entry doesn't void the others")
    func mixedValueTypes() throws {
        let json = #"{"control":[{"VTOY_MENU_TIMEOUT":10},{"VTOY_DEFAULT_SEARCH_ROOT":"/iso"}]}"#
        let root = try volume(["iso/x.iso", "other/y.iso"], json: json)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(listed(root) == ["iso/x.iso"])
    }

    @Test("invalid JSON means Ventoy's defaults")
    func invalidJSON() throws {
        let root = try volume(["iso/x.iso", "other/y.iso"], json: "not json {")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(listed(root) == ["iso/x.iso", "other/y.iso"])
    }

    @Test("a folder with .ventoyignore is skipped with everything below it; the search root's own is not")
    func ventoyIgnore() throws {
        let root = try volume(["backup/.ventoyignore", "backup/old.iso", "backup/sub/older.iso", "live.iso", ".ventoyignore"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(listed(root) == ["live.iso"])
    }

    private static let levelCases: [(String, [String])] = [
        ("0", ["a.iso"]),
        ("1", ["a.iso", "l1/b.iso"]),
        ("2", ["a.iso", "l1/b.iso", "l1/l2/c.iso"]),
        ("max", ["a.iso", "l1/b.iso", "l1/l2/c.iso", "l1/l2/l3/d.iso"]),
    ]

    @Test("VTOY_MAX_SEARCH_LEVEL limits folder depth; non-numeric means unlimited", arguments: levelCases)
    func maxSearchLevel(level: String, expected: [String]) throws {
        let json = #"{"control":[{"VTOY_MAX_SEARCH_LEVEL":"\#(level)"}]}"#
        let root = try volume(["a.iso", "l1/b.iso", "l1/l2/c.iso", "l1/l2/l3/d.iso"], json: json)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(listed(root) == expected)
    }

    @Test("trash folders and Ventoy's own helper images are skipped")
    func trashAndHelpers() throws {
        let root = try volume(["$RECYCLE.BIN/x.iso", ".Trashes/y.iso", "ventoy/ventoy_wimboot.img", "ventoy/ventoy_vhdboot.img", "keep.img"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(listed(root) == ["keep.img"])
    }

    @Test("all Ventoy image types, case-insensitive")
    func imageTypes() throws {
        let names = ["a.iso", "b.WIM", "c.img", "d.vhd", "e.VHDX", "f.efi", "g.vtoy", "h.txt", "iso", "j.iso.part"]
        let root = try volume(names)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(listed(root) == ["a.iso", "b.WIM", "c.img", "d.vhd", "e.VHDX", "f.efi", "g.vtoy"])
    }

    // MARK: Release-review cases

    @Test("a control entry with two keys: Ventoy reads only the first, so list the whole volume")
    func multiKeyEntry() throws {
        let json = #"{"control":[{"VTOY_DEFAULT_SEARCH_ROOT":"/iso","VTOY_MAX_SEARCH_LEVEL":"0"}]}"#
        let root = try volume(["iso/x.iso", "iso/deep/y.iso", "other/z.iso"], json: json)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(listed(root) == ["iso/deep/y.iso", "iso/x.iso", "other/z.iso"])
    }

    @Test("a repeated key: the later entry wins, as GRUB `set` does")
    func lastEntryWins() throws {
        let json = #"{"control":[{"VTOY_DEFAULT_SEARCH_ROOT":"/a"},{"VTOY_DEFAULT_SEARCH_ROOT":"/b"}]}"#
        let root = try volume(["a/x.iso", "b/y.iso"], json: json)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(listed(root) == ["b/y.iso"])
    }

    @Test("UTF-16 ventoy.json is rejected by Ventoy, so its settings don't apply; a UTF-8 BOM is fine")
    func byteOrderMarks() throws {
        let text = searchRoot("/iso")
        for (encoding, applies) in [(String.Encoding.utf16LittleEndian, false), (.utf16BigEndian, false), (.utf8, true)] {
            let root = try volume(["iso/x.iso", "o.iso"])
            defer { try? FileManager.default.removeItem(at: root) }
            let bom: [UInt8] = switch encoding {
            case .utf16LittleEndian: [0xFF, 0xFE]
            case .utf16BigEndian: [0xFE, 0xFF]
            default: [0xEF, 0xBB, 0xBF]
            }
            var data = Data(bom)
            data.append(text.data(using: encoding)!)
            let url = root.appendingPathComponent("ventoy/ventoy.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            #expect(listed(root) == (applies ? ["iso/x.iso"] : ["iso/x.iso", "o.iso"]), "\(encoding)")
        }
    }

    @Test(".ventoyignore: any file starting with that name, case-sensitive; a folder of that name doesn't count")
    func ignoreMarkerRules() throws {
        let root = try volume([
            "a/.ventoyignore.bak", "a/x.iso",            // prefix match → ignored
            "b/.VENTOYIGNORE", "b/y.iso",                // wrong case → listed
            "c/.ventoyignore/inner.txt", "c/z.iso",      // folder, not file → listed
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(listed(root) == ["b/y.iso", "c/z.iso"])
    }

    @Test("VTOY_FILT_TRASH_DIR=0 lists $RECYCLE.BIN; dot-named trash folders stay hidden as dot-names")
    func trashFilterOff() throws {
        let json = #"{"control":[{"VTOY_FILT_TRASH_DIR":"0"}]}"#
        let root = try volume(["$RECYCLE.BIN/x.iso", ".trash-1000/y.iso", "keep.iso"], json: json)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(listed(root) == ["$RECYCLE.BIN/x.iso", "keep.iso"])
    }

    @Test("files with the macOS hidden flag are listed; only dot-names are skipped")
    func hiddenFlagListed() throws {
        let root = try volume(["flagged.iso", ".dotted.iso"])
        defer { try? FileManager.default.removeItem(at: root) }
        var values = URLResourceValues()
        values.isHidden = true
        var url = root.appendingPathComponent("flagged.iso")
        try url.setResourceValues(values)
        #expect(listed(root) == ["flagged.iso"])
    }

    /// Separate volumes per name: the test filesystem is case-insensitive,
    /// so names differing only in case would be the same file.
    @Test("helper images are excluded whatever the extension's case; the stem is case-sensitive")
    func helperImageCase() throws {
        for (name, isListed) in [("ventoy_wimboot.IMG", false), ("ventoy_vhdboot.img", false),
                                 ("Ventoy_wimboot.img", true), ("ventoy_other.img", true)] {
            let root = try volume([name])
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(listed(root) == (isListed ? [name] : []), "\(name)")
        }
    }

    @Test("search level: 0 with a search root, and values past Int32 behave as Ventoy's (int) cast")
    func levelEdgeCases() throws {
        for (level, expected) in [("0", ["iso/x.iso"]), ("4294967296", ["iso/x.iso"]), ("2147483648", ["iso/x.iso"]), ("2147483647", ["iso/deep/y.iso", "iso/x.iso"])] {
            let json = #"{"control":[{"VTOY_DEFAULT_SEARCH_ROOT":"/iso"},{"VTOY_MAX_SEARCH_LEVEL":"\#(level)"}]}"#
            let root = try volume(["iso/x.iso", "iso/deep/y.iso", "o.iso"], json: json)
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(listed(root) == expected, "level \(level)")
        }
    }

    @Test("a search root that's a symlink out of the volume falls back to the volume")
    func symlinkedRootEscape() throws {
        let outside = try volume(["secret.iso"])
        let root = try volume(["x.iso"], json: searchRoot("/link"))
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(VentoyImageLibrary.imageDirectory(on: root) == root.resolvingSymlinksInPath().standardizedFileURL)
        #expect(listed(root) == ["x.iso"])
    }

    // MARK: Second release-review round

    @Test("files under 32 KiB are not images; exactly 32 KiB is")
    func minimumSize() throws {
        let root = try volume(["ok.iso"])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: VentoyImageLibrary.minimumImageSize - 1).write(to: root.appendingPathComponent("small.iso"))
        try Data().write(to: root.appendingPathComponent("empty.iso"))
        #expect(listed(root) == ["ok.iso"])
    }

    @Test("VTOY_FILE_FLT_<TYPE>=\"1\" hides that type; any other value doesn't")
    func typeFilters() throws {
        let json = #"{"control":[{"VTOY_FILE_FLT_ISO":"1"},{"VTOY_FILE_FLT_VHD":"1"},{"VTOY_FILE_FLT_IMG":"0"}]}"#
        let root = try volume(["a.iso", "b.vhd", "c.vhdx", "d.img", "e.wim"], json: json)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(listed(root) == ["d.img", "e.wim"])
    }

    @Test("an empty VTOY_MAX_SEARCH_LEVEL is 0, as Ventoy's strtoul makes it")
    func emptyLevel() throws {
        let json = #"{"control":[{"VTOY_MAX_SEARCH_LEVEL":""}]}"#
        let root = try volume(["a.iso", "sub/b.iso"], json: json)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(listed(root) == ["a.iso"])
    }

    @Test("the can't-know fallback includes trash folders, so it's a true superset")
    func fallbackIncludesTrash() throws {
        let json = #"{"control_uefi":[{"VTOY_FILT_TRASH_DIR":"0"}]}"#
        let root = try volume(["$RECYCLE.BIN/x.iso", "keep.iso"], json: json)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(listed(root) == ["$RECYCLE.BIN/x.iso", "keep.iso"])
    }

    @Test("no config still hides trash folders, Ventoy's default")
    func defaultHidesTrash() throws {
        let root = try volume(["$RECYCLE.BIN/x.iso", "keep.iso"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(listed(root) == ["keep.iso"])
    }

    @Test("a backslash escape in ventoy.json: Ventoy reads it literally, so list the whole volume")
    func escapesInJSON() throws {
        for json in [#"{"control":[{"VTOY_DEFAULT_SEARCH_ROOT":"\/iso"}]}"#,
                     #"{"control":[{"VTOY_FILE_FLT_ISO":"\u0031"}]}"#] {
            let root = try volume(["iso/x.iso", "o.iso"], json: json)
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(listed(root) == ["iso/x.iso", "o.iso"], "\(json)")
        }
    }
}
