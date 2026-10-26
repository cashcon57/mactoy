import Foundation
import Testing
@testable import MactoyKit

@Suite("ventoy.json theme editor")
struct VentoyConfigEditorTests {

    private let theme: [String: Any] = ["file": "/ventoy/themes/mactoy-x/theme.txt", "gfxmode": "1920x1080,auto"]

    private func text(_ d: Data?) -> String { String(decoding: d ?? Data(), as: UTF8.self) }

    @Test("missing or blank file gets a fresh object with only theme")
    func freshFile() throws {
        for input in [nil, Data(), Data("  \n".utf8)] {
            let out = try VentoyConfigEditor.settingTheme(theme, in: input)
            let obj = try JSONSerialization.jsonObject(with: out) as? [String: Any]
            #expect(obj?.keys.sorted() == ["theme"])
            #expect(!out.contains(0x5C))
            #expect(text(out).contains("\"/ventoy/themes/mactoy-x/theme.txt\""))
        }
    }

    @Test("adding theme keeps every other byte, in order")
    func addKeepsOtherBytes() throws {
        let original = """
        {
          "control": [ { "VTOY_DEFAULT_SEARCH_ROOT": "/iso" }, {"VTOY_MENU_TIMEOUT":"10"} ],
            "menu_alias":[{"image":"/iso/a.iso","alias":"Ä alias"}],
          "password" : { "bootpwd": "txt#123" }
        }

        """
        let out = text(try VentoyConfigEditor.settingTheme(theme, in: Data(original.utf8)))
        let head = String(original[..<original.range(of: "\n}")!.lowerBound])
        #expect(out.hasPrefix(head))
        #expect(out.hasSuffix(",\n    \"theme\": " + out.components(separatedBy: "\"theme\": ")[1]))
        let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        #expect(obj?.keys.sorted() == ["control", "menu_alias", "password", "theme"])
    }

    @Test("replacing theme touches only the theme value")
    func replaceOnlyValue() throws {
        let original = #"{"control":[{"VTOY_MENU_TIMEOUT":"5"}],"theme":{"file":"/ventoy/old/theme.txt"},"menu_class":[]}"#
        let out = text(try VentoyConfigEditor.settingTheme(theme, in: Data(original.utf8)))
        #expect(out.hasPrefix(#"{"control":[{"VTOY_MENU_TIMEOUT":"5"}],"theme":"#))
        #expect(out.hasSuffix(#","menu_class":[]}"#))
        #expect(!out.contains("/ventoy/old/"))
    }

    @Test("removing theme from first, middle, last and only positions")
    func removeAllPositions() throws {
        let cases: [(String, String)] = [
            (#"{"theme":{"file":"/a"},"control":[]}"#, #"{"control":[]}"#),
            (#"{"control":[], "theme":{"file":"/a"}, "menu_class":[]}"#, #"{"control":[], "menu_class":[]}"#),
            (#"{"control":[],"theme":{"file":"/a"}}"#, #"{"control":[]}"#),
            (#"{ "theme": {"file":"/a"} }"#, #"{  }"#),
        ]
        for (input, expected) in cases {
            let out = try VentoyConfigEditor.removingTheme(from: Data(input.utf8))
            #expect(text(out) == expected)
        }
        #expect(try VentoyConfigEditor.removingTheme(from: nil) == nil)
        let noTheme = Data(#"{"control":[]}"#.utf8)
        #expect(try VentoyConfigEditor.removingTheme(from: noTheme) == noTheme)
    }

    @Test("refuses files it can't edit safely", arguments: [
        (Data([0xFF, 0xFE, 0x7B, 0x00, 0x7D, 0x00]), VentoyConfigEditor.Refusal.utf16),
        (Data(#"{"menu_alias":[{"image":"\/a.iso","alias":"x"}]}"#.utf8), .containsBackslash),
        (Data(#"{"control": [ }"#.utf8), .notValidJSON),
        (Data(#"[1,2]"#.utf8), .notAnObject),
        (Data(#"{"theme":{"file":"/a"},"theme":{"file":"/b"}}"#.utf8), .duplicateTheme),
    ])
    func refusals(input: Data, expected: VentoyConfigEditor.Refusal) {
        #expect(throws: expected) { _ = try VentoyConfigEditor.settingTheme(theme, in: input) }
        #expect(throws: expected) { _ = try VentoyConfigEditor.removingTheme(from: input) }
        #expect(expected.errorDescription?.isEmpty == false)
    }

    @Test("keeps a UTF-8 byte-order mark")
    func keepsBOM() throws {
        let input = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"control":[]}"#.utf8)
        let out = try VentoyConfigEditor.settingTheme(theme, in: input)
        #expect(out.starts(with: [0xEF, 0xBB, 0xBF]))
    }

    @Test("reads theme files as string or array, and per-mode theme keys")
    func reads() throws {
        #expect(try VentoyConfigEditor.themeFiles(in: Data(#"{"theme":{"file":"/a/theme.txt"}}"#.utf8)) == ["/a/theme.txt"])
        #expect(try VentoyConfigEditor.themeFiles(in: Data(#"{"theme":{"file":["/a/t.txt","/b/t.txt"]}}"#.utf8)) == ["/a/t.txt", "/b/t.txt"])
        #expect(try VentoyConfigEditor.themeFiles(in: nil) == [])
        let modes = Data(#"{"theme_uefi":{"file":"/u"},"theme":{"file":"/a"},"theme_legacy":{"file":"/l"}}"#.utf8)
        #expect(try VentoyConfigEditor.presentModeSpecificThemeKeys(in: modes) == ["theme_legacy", "theme_uefi"])
    }

    @Test("a theme value that would need a backslash escape is refused, not written")
    func valueNeedingEscapeRefused() {
        #expect(throws: VentoyConfigEditor.Refusal.containsBackslash) {
            _ = try VentoyConfigEditor.settingTheme(["file": "/ventoy/a \"quoted\" theme.txt"], in: nil)
        }
    }

    @Test("the post-edit check rejects any result that changed another member or isn't JSON")
    func verifyRejectsOtherChanges() throws {
        let original = try VentoyConfigEditor.parse(Data(#"{"control":[],"theme":{"file":"/a"}}"#.utf8))
        // Only theme differs: fine.
        try VentoyConfigEditor.verify(original: original, result: Data(#"{"control":[],"theme":{"file":"/b"}}"#.utf8))
        // `control` differs.
        #expect(throws: VentoyConfigEditor.Refusal.internalCheckFailed) {
            try VentoyConfigEditor.verify(original: original, result: Data(#"{"control":[1],"theme":{"file":"/a"}}"#.utf8))
        }
        // Not parseable.
        #expect(throws: VentoyConfigEditor.Refusal.internalCheckFailed) {
            try VentoyConfigEditor.verify(original: original, result: Data(#"{"control":[]"#.utf8))
        }
    }

    @Test("search settings are identical before and after an edit")
    func searchSettingsUnchanged() throws {
        let input = Data(#"{"control":[{"VTOY_DEFAULT_SEARCH_ROOT":"/iso"},{"VTOY_MAX_SEARCH_LEVEL":"1"}]}"#.utf8)
        let out = try VentoyConfigEditor.settingTheme(theme, in: input)
        #expect(VentoyImageLibrary.configuration(fromFileData: out) == VentoyImageLibrary.configuration(fromFileData: input))
    }
}
