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

    /// One awkward file and what each edit must produce, byte for byte.
    /// `@@THEME@@` stands for the encoded theme value in `set`.
    private struct ScannerCase {
        let label: String
        let input: String
        let set: String
        let remove: String
        /// Removing after setting gives `remove` again. Not true for an
        /// empty object, where the inserted line leaves blank space behind.
        var roundTrips = true
    }

    private static let scannerCases: [ScannerCase] = [
        // Delimiter characters inside strings must not end a value early.
        ScannerCase(
            label: "}, ], comma and { inside strings, keys and nested values before and after theme",
            input: #"{"a":"x}]y,{z","k}]":["}","]",","],"theme":{"file":"/old"},"b":"}],{","c":{"d":"{,"}}"#,
            set: #"{"a":"x}]y,{z","k}]":["}","]",","],"theme":@@THEME@@,"b":"}],{","c":{"d":"{,"}}"#,
            remove: #"{"a":"x}]y,{z","k}]":["}","]",","],"b":"}],{","c":{"d":"{,"}}"#),
        ScannerCase(
            label: "delimiters inside the theme value itself, theme first",
            input: #"{"theme":{"file":"/a}]b,{c"},"z":"}"}"#,
            set: #"{"theme":@@THEME@@,"z":"}"}"#,
            remove: #"{"z":"}"}"#),
        ScannerCase(
            label: "delimiters inside the theme value itself, theme last",
            input: #"{"a":"}","theme":{"file":"/a]"}}"#,
            set: #"{"a":"}","theme":@@THEME@@}"#,
            remove: #"{"a":"}"}"#),
        ScannerCase(
            label: "delimiters in other members, theme absent",
            input: #"{"a":"}]","b":["{,"]}"#,
            set: #"{"a":"}]","b":["{,"],\#n    "theme": @@THEME@@}"#,
            remove: #"{"a":"}]","b":["{,"]}"#),
        ScannerCase(
            label: "deeply nested values and an empty object before theme",
            input: #"{"z":[[[{"a":[{}]}]]],"theme":{"file":"/old"}}"#,
            set: #"{"z":[[[{"a":[{}]}]]],"theme":@@THEME@@}"#,
            remove: #"{"z":[[[{"a":[{}]}]]]}"#),
        ScannerCase(
            label: "string theme, then a nested theme array holding a bracket string and a theme_x key",
            input: #"{"theme":"str","y":{"theme":[1,{"a":"]"}]},"theme_x":0}"#,
            set: #"{"theme":@@THEME@@,"y":{"theme":[1,{"a":"]"}]},"theme_x":0}"#,
            remove: #"{"y":{"theme":[1,{"a":"]"}]},"theme_x":0}"#),

        // CRLF line endings stay as they were; only inserted text uses \n.
        ScannerCase(
            label: "CRLF, theme in the middle",
            input: #"{\#r\#n  "control": [],\#r\#n  "theme": {"file": "/old"},\#r\#n  "z": 1\#r\#n}\#r\#n"#,
            set: #"{\#r\#n  "control": [],\#r\#n  "theme": @@THEME@@,\#r\#n  "z": 1\#r\#n}\#r\#n"#,
            remove: #"{\#r\#n  "control": [],\#r\#n  "z": 1\#r\#n}\#r\#n"#),
        ScannerCase(
            label: "CRLF, theme first",
            input: #"{\#r\#n  "theme": {"file": "/old"},\#r\#n  "control": []\#r\#n}\#r\#n"#,
            set: #"{\#r\#n  "theme": @@THEME@@,\#r\#n  "control": []\#r\#n}\#r\#n"#,
            remove: #"{\#r\#n  "control": []\#r\#n}\#r\#n"#),
        ScannerCase(
            label: "CRLF, theme last",
            input: #"{\#r\#n  "control": [],\#r\#n  "theme": {"file": "/old"}\#r\#n}\#r\#n"#,
            set: #"{\#r\#n  "control": [],\#r\#n  "theme": @@THEME@@\#r\#n}\#r\#n"#,
            remove: #"{\#r\#n  "control": []\#r\#n}\#r\#n"#),
        ScannerCase(
            label: "CRLF, theme absent",
            input: #"{\#r\#n  "control": []\#r\#n}\#r\#n"#,
            set: #"{\#r\#n  "control": [],\#n    "theme": @@THEME@@\#r\#n}\#r\#n"#,
            remove: #"{\#r\#n  "control": []\#r\#n}\#r\#n"#),
        ScannerCase(
            label: "tabs around keys, colons and commas",
            input: #"{\#t"theme"\#t:\#t{"file":"/old"}\#t,\#t"z"\#t:\#t1\#t}"#,
            set: #"{\#t"theme"\#t:\#t@@THEME@@\#t,\#t"z"\#t:\#t1\#t}"#,
            remove: #"{\#t"z"\#t:\#t1\#t}"#),
        ScannerCase(
            label: "whitespace before and after the object",
            input: #"\#n  {"a":1}  \#n"#,
            set: #"\#n  {"a":1,\#n    "theme": @@THEME@@}  \#n"#,
            remove: #"\#n  {"a":1}  \#n"#),

        // Empty objects.
        ScannerCase(
            label: "empty object",
            input: "{}",
            set: #"{\#n    "theme": @@THEME@@\#n}"#,
            remove: "{}",
            roundTrips: false),
        ScannerCase(
            label: "empty object with whitespace inside",
            input: #"{ \#n}\#n"#,
            set: #"{\#n    "theme": @@THEME@@\#n}\#n"#,
            remove: #"{ \#n}\#n"#,
            roundTrips: false),

        // A nested "theme" is some other setting's content, not ours.
        ScannerCase(
            label: "nested theme inside control, no top-level theme",
            input: #"{"control":[{"theme":{"file":"/inner"}}],"z":1}"#,
            set: #"{"control":[{"theme":{"file":"/inner"}}],"z":1,\#n    "theme": @@THEME@@}"#,
            remove: #"{"control":[{"theme":{"file":"/inner"}}],"z":1}"#),
        ScannerCase(
            label: "nested theme before and after a real top-level theme",
            input: #"{"control":[{"theme":"inner"}],"theme":{"file":"/old"},"z":{"theme":1}}"#,
            set: #"{"control":[{"theme":"inner"}],"theme":@@THEME@@,"z":{"theme":1}}"#,
            remove: #"{"control":[{"theme":"inner"}],"z":{"theme":1}}"#),
        ScannerCase(
            label: "keys that only look like theme",
            input: #"{"themes":1,"theme_x":2,"xtheme":3}"#,
            set: #"{"themes":1,"theme_x":2,"xtheme":3,\#n    "theme": @@THEME@@}"#,
            remove: #"{"themes":1,"theme_x":2,"xtheme":3}"#),

        // Literals and numbers have no closing delimiter of their own.
        ScannerCase(
            label: "true, false, null, 42 and -1.5e3 on both sides of theme",
            input: #"{"a":true,"b":false,"c":null,"theme":{"file":"/old"},"d":42,"e":-1.5e3}"#,
            set: #"{"a":true,"b":false,"c":null,"theme":@@THEME@@,"d":42,"e":-1.5e3}"#,
            remove: #"{"a":true,"b":false,"c":null,"d":42,"e":-1.5e3}"#),
        ScannerCase(
            label: "number before a last theme",
            input: #"{"a":-1.5e3,"theme":{"file":"/x"}}"#,
            set: #"{"a":-1.5e3,"theme":@@THEME@@}"#,
            remove: #"{"a":-1.5e3}"#),
        ScannerCase(
            label: "null after a first theme",
            input: #"{"theme":{"file":"/x"},"a":null}"#,
            set: #"{"theme":@@THEME@@,"a":null}"#,
            remove: #"{"a":null}"#),
        ScannerCase(
            label: "theme is itself null, between numbers",
            input: #"{"a":1,"theme":null,"b":2}"#,
            set: #"{"a":1,"theme":@@THEME@@,"b":2}"#,
            remove: #"{"a":1,"b":2}"#),
        ScannerCase(
            label: "theme is itself a number and the only member",
            input: #"{"theme":-1.5e3}"#,
            set: #"{"theme":@@THEME@@}"#,
            remove: "{}"),
        ScannerCase(
            label: "last member is a literal touching the closing brace",
            input: #"{"a":true}"#,
            set: #"{"a":true,\#n    "theme": @@THEME@@}"#,
            remove: #"{"a":true}"#),
        ScannerCase(
            label: "last member is a number followed by a space",
            input: #"{"a":42 }"#,
            set: #"{"a":42,\#n    "theme": @@THEME@@ }"#,
            remove: #"{"a":42 }"#),

        // Multi-byte text: ranges are bytes, not characters.
        ScannerCase(
            label: "non-ASCII text and a brace in a string before theme",
            input: #"{"menu_alias":[{"alias":"Ä}😀"}],"theme":{"file":"/old"},"tip":"é"}"#,
            set: #"{"menu_alias":[{"alias":"Ä}😀"}],"theme":@@THEME@@,"tip":"é"}"#,
            remove: #"{"menu_alias":[{"alias":"Ä}😀"}],"tip":"é"}"#),
    ]

    @Test("edits give exact bytes on awkward input, with and without a UTF-8 byte-order mark")
    func scannerCasesExactOutput() throws {
        let encoded = try VentoyConfigEditor.encode(theme)
        for withBOM in [false, true] {
            let bom = withBOM ? Data([0xEF, 0xBB, 0xBF]) : Data()
            for c in Self.scannerCases {
                let name = c.label + (withBOM ? " [BOM]" : "")
                let input = bom + Data(c.input.utf8)
                let expectedSet = bom + Data(c.set.replacingOccurrences(of: "@@THEME@@", with: encoded).utf8)
                let expectedRemove = bom + Data(c.remove.utf8)
                do {
                    let set = try VentoyConfigEditor.settingTheme(theme, in: input)
                    #expect(set == expectedSet, "set, \(name): got \(text(set).debugDescription)")
                    // Setting again changes nothing.
                    #expect(try VentoyConfigEditor.settingTheme(theme, in: set) == set, "set twice, \(name)")

                    let removed = try VentoyConfigEditor.removingTheme(from: input)
                    #expect(removed == expectedRemove, "remove, \(name): got \(text(removed).debugDescription)")

                    if c.roundTrips {
                        let back = try VentoyConfigEditor.removingTheme(from: set)
                        #expect(back == expectedRemove, "remove after set, \(name): got \(text(back).debugDescription)")
                    }
                } catch {
                    Issue.record("\(name): threw \(error)")
                }
            }
        }
    }

    @Test("a nested theme is not read as the top-level one")
    func nestedThemeNotRead() throws {
        let nestedOnly = Data(#"{"control":[{"theme":{"file":"/inner"}}]}"#.utf8)
        #expect(try VentoyConfigEditor.themeFiles(in: nestedOnly) == [])
        let both = Data(#"{"control":[{"theme":{"file":"/inner"}}],"theme":{"file":"/outer"}}"#.utf8)
        #expect(try VentoyConfigEditor.themeFiles(in: both) == ["/outer"])
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
