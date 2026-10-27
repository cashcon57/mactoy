import Foundation

/// Edits the top-level `theme` setting in Ventoy's `/ventoy/ventoy.json`
/// and nothing else. People keep menu names, search folders and boot
/// passwords in that file, so instead of re-serialising it (which would
/// reorder keys and reformat everything) this finds the byte range of
/// the `theme` member and splices only that.
///
/// The splice is safe only because Ventoy's own JSON parser doesn't
/// decode escape sequences: a file with a backslash means something
/// different to Ventoy than to any standard parser, so such files are
/// refused (as `VentoyImageLibrary` already does for reading).
public enum VentoyConfigEditor {

    public enum Refusal: Error, Equatable, LocalizedError {
        case utf16
        case containsBackslash
        case notValidJSON
        case notAnObject
        case duplicateTheme
        case internalCheckFailed

        public var errorDescription: String? {
            switch self {
            case .utf16:
                return "This drive's ventoy.json is saved as UTF-16. Ventoy can't read that, so none of its settings are in use. Re-save it as UTF-8 and try again."
            case .containsBackslash:
                return "This drive's ventoy.json contains a backslash. Ventoy reads backslashes differently from other apps, so Mactoy won't rewrite the file in case a setting changes meaning. Remove the backslash, or set the theme by hand."
            case .notValidJSON:
                return "This drive's ventoy.json has a syntax error, so Ventoy is ignoring all of its settings. Fix or delete the file and try again."
            case .notAnObject:
                return "This drive's ventoy.json isn't a settings object. Fix or delete the file and try again."
            case .duplicateTheme:
                return "This drive's ventoy.json sets \"theme\" more than once. Remove one and try again."
            case .internalCheckFailed:
                return "Mactoy stopped before saving because the edited ventoy.json didn't match the original outside the theme setting. Nothing was changed."
            }
        }
    }

    /// Theme keys that replace `theme` in one boot mode (Ventoy's
    /// multi-mode plugin suffixes).
    public static let modeSpecificThemeKeys = ["theme_aa64", "theme_ia32", "theme_legacy", "theme_mips", "theme_uefi"]

    // MARK: Reading

    /// The `theme.file` value(s), in order. Empty when there's no file or no theme.
    public static func themeFiles(in data: Data?) throws -> [String] {
        guard let data, !isBlank(data) else { return [] }
        let parsed = try parse(data)
        guard let member = parsed.members.first(where: { $0.key == "theme" }) else { return [] }
        let value = Data(parsed.bytes[member.valueStart..<member.valueEnd])
        guard let theme = try? JSONSerialization.jsonObject(with: value) as? [String: Any] else { return [] }
        if let one = theme["file"] as? String { return [one] }
        return (theme["file"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// The top-level `theme` value when it is a JSON object, so callers can see
    /// which keys it holds. Nil for no file, no `theme`, a `theme` that isn't an
    /// object, or a `theme` object that repeats a key: a standard parser keeps the
    /// last of two `file` members, and Ventoy's may use the first, so what such an
    /// object says is not known. Goes through `parse`, so the same files are refused
    /// as everywhere else.
    public static func themeObject(in data: Data?) throws -> [String: Any]? {
        guard let data, !isBlank(data) else { return nil }
        let parsed = try parse(data)
        guard let member = parsed.members.first(where: { $0.key == "theme" }) else { return nil }
        let value = Data(parsed.bytes[member.valueStart..<member.valueEnd])
        guard let object = try? JSONSerialization.jsonObject(with: value) as? [String: Any] else { return nil }
        // The same scanner that listed the top-level members lists this object's, so a repeat is seen.
        var scanner = ByteScanner(bytes: parsed.bytes, index: member.valueStart)
        guard let keys = try? scanner.objectMembers().members.map(\.key), Set(keys).count == keys.count else { return nil }
        return object
    }

    /// Whether the file has a top-level `theme` member, whatever its value
    /// (an object with no `file`, `null` and a string all count). `themeFiles`
    /// alone can't tell "no theme" from "a theme setting with no file", and
    /// the second is the user's, so it must not be mistaken for the default.
    public static func hasTheme(in data: Data?) throws -> Bool {
        guard let data, !isBlank(data) else { return false }
        return try parse(data).members.contains { $0.key == "theme" }
    }

    /// Per-mode theme keys present at the top level, sorted.
    public static func presentModeSpecificThemeKeys(in data: Data?) throws -> [String] {
        guard let data, !isBlank(data) else { return [] }
        return try parse(data).members.map(\.key).filter(modeSpecificThemeKeys.contains).sorted()
    }

    // MARK: Editing

    /// The file with its top-level `theme` set to `value`.
    public static func settingTheme(_ value: [String: Any], in data: Data?) throws -> Data {
        let encoded = try encode(value)
        guard let data, !isBlank(data) else {
            return Data("{\n    \"theme\": \(encoded)\n}\n".utf8)
        }
        let parsed = try parse(data)
        var out = parsed.bytes
        if let member = parsed.members.first(where: { $0.key == "theme" }) {
            out.replaceSubrange(member.valueStart..<member.valueEnd, with: Array(encoded.utf8))
        } else if let last = parsed.members.last {
            out.insert(contentsOf: Array(",\n    \"theme\": \(encoded)".utf8), at: last.valueEnd)
        } else {
            out.replaceSubrange((parsed.openBrace + 1)..<parsed.closeBrace,
                                with: Array("\n    \"theme\": \(encoded)\n".utf8))
        }
        let result = Data(out)
        try verify(original: parsed, result: result)
        return result
    }

    /// The file without its top-level `theme`. `nil` when there's no
    /// file to write; the input unchanged when it has no theme.
    public static func removingTheme(from data: Data?) throws -> Data? {
        guard let data, !isBlank(data) else { return nil }
        let parsed = try parse(data)
        guard let index = parsed.members.firstIndex(where: { $0.key == "theme" }) else { return data }
        var out = parsed.bytes
        let member = parsed.members[index]
        if index + 1 < parsed.members.count {
            out.removeSubrange(member.memberStart..<parsed.members[index + 1].memberStart)
        } else if index > 0 {
            out.removeSubrange(parsed.members[index - 1].valueEnd..<member.valueEnd)
        } else {
            out.removeSubrange(member.memberStart..<member.valueEnd)
        }
        let result = Data(out)
        try verify(original: parsed, result: result)
        return result
    }

    // MARK: Internals

    struct Member {
        let key: String
        let memberStart: Int   // the key's opening quote
        let valueStart: Int
        let valueEnd: Int      // one past the value's last byte
    }

    struct Parsed {
        let bytes: [UInt8]
        let openBrace: Int
        let closeBrace: Int
        let members: [Member]
    }

    static func isBlank(_ data: Data) -> Bool {
        data.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    }

    static func encode(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard !data.contains(0x5C) else { throw Refusal.containsBackslash }
        // Indent the value's inner lines to sit inside the top-level object.
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: "\n    ")
    }

    static func parse(_ data: Data) throws -> Parsed {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) { throw Refusal.utf16 }
        if bytes.contains(0x5C) { throw Refusal.containsBackslash }
        let bom = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        // A standard parser must accept it too; the scanner below only
        // finds byte ranges and relies on this for validity.
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: Data(bytes[bom...]), options: [.fragmentsAllowed]) }
        catch { throw Refusal.notValidJSON }
        guard object is [String: Any] else { throw Refusal.notAnObject }

        var s = ByteScanner(bytes: bytes, index: bom)
        s.skipWhitespace()
        let (members, open, close) = try s.objectMembers()
        if members.filter({ $0.key == "theme" }).count > 1 { throw Refusal.duplicateTheme }
        return Parsed(bytes: bytes, openBrace: open, closeBrace: close, members: members)
    }

    /// Re-parse the edit and prove only `theme` changed.
    static func verify(original: Parsed, result: Data) throws {
        let edited: Parsed
        do { edited = try parse(result) } catch { throw Refusal.internalCheckFailed }
        func others(_ p: Parsed) -> [[UInt8]] {
            p.members.filter { $0.key != "theme" }.map { Array(p.bytes[$0.memberStart..<$0.valueEnd]) }
        }
        guard others(original) == others(edited),
              VentoyImageLibrary.configuration(fromFileData: Data(original.bytes))
                == VentoyImageLibrary.configuration(fromFileData: result)
        else { throw Refusal.internalCheckFailed }
    }
}

/// Finds byte ranges in JSON already validated by `JSONSerialization`.
/// Strings end at the next quote because backslashes were refused.
private struct ByteScanner {
    let bytes: [UInt8]
    var index: Int

    var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func skipWhitespace() {
        while let b = peek, b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { index += 1 }
    }

    /// The members of the object whose `{` is at the current index, with the
    /// positions of its braces. Leaves the index on the closing brace.
    mutating func objectMembers() throws -> (members: [VentoyConfigEditor.Member], open: Int, close: Int) {
        guard peek == UInt8(ascii: "{") else { throw VentoyConfigEditor.Refusal.notAnObject }
        let open = index
        index += 1
        var members: [VentoyConfigEditor.Member] = []
        skipWhitespace()
        if peek != UInt8(ascii: "}") {
            while true {
                skipWhitespace()
                let memberStart = index
                let key = try string()
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                skipWhitespace()
                let valueStart = index
                try skipValue()
                members.append(VentoyConfigEditor.Member(key: key, memberStart: memberStart, valueStart: valueStart, valueEnd: index))
                skipWhitespace()
                if peek == UInt8(ascii: ",") { index += 1; continue }
                if peek == UInt8(ascii: "}") { break }
                throw VentoyConfigEditor.Refusal.notValidJSON
            }
        }
        return (members, open, index)
    }

    mutating func expect(_ byte: UInt8) throws {
        guard peek == byte else { throw VentoyConfigEditor.Refusal.notValidJSON }
        index += 1
    }

    mutating func string() throws -> String {
        try expect(UInt8(ascii: "\""))
        let start = index
        while let b = peek, b != UInt8(ascii: "\"") { index += 1 }
        guard peek != nil else { throw VentoyConfigEditor.Refusal.notValidJSON }
        let value = String(decoding: bytes[start..<index], as: UTF8.self)
        index += 1
        return value
    }

    mutating func skipValue() throws {
        guard let first = peek else { throw VentoyConfigEditor.Refusal.notValidJSON }
        switch first {
        case UInt8(ascii: "\""):
            _ = try string()
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            while let b = peek {
                if b == UInt8(ascii: "\"") { _ = try string(); continue }
                if b == UInt8(ascii: "{") || b == UInt8(ascii: "[") { depth += 1 }
                if b == UInt8(ascii: "}") || b == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 { index += 1; return }
                }
                index += 1
            }
            throw VentoyConfigEditor.Refusal.notValidJSON
        default:
            while let b = peek, ![0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")].contains(b) {
                index += 1
            }
        }
    }
}
