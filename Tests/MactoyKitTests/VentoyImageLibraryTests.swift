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
            try Data().write(to: url)
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
}
