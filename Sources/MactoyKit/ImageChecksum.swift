import Foundation

/// The SHA-256 a user gives for an image (#26): pasted, or read from a checksum file.
public enum ImageChecksum {
    /// 64 hex digits, lowercased, or nil. Spaces around it are ignored, and so is an
    /// `sha256:` prefix as some download pages show it.
    public static func normalized(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("sha256:") { s = String(s.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        return InstallPlan.isSHA256Hex(s) ? s : nil
    }

    /// The SHA-256 for `imageName` in a checksum file's text. Understands `sha256sum` lines
    /// (`<hash>  name` or `<hash> *name`), BSD lines (`SHA256 (name) = <hash>`), and a file that
    /// holds just one hash. With several entries, only an exact file-name match counts.
    public static func sha256(for imageName: String, in text: String) -> String? {
        var entries: [(name: String?, hash: String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("SHA256 ("), let close = line.range(of: ") = ") {
                let name = String(line[line.index(line.startIndex, offsetBy: 8)..<close.lowerBound])
                if let hash = normalized(String(line[close.upperBound...])) { entries.append((name, hash)) }
                continue
            }
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let hash = parts.first.flatMap({ normalized(String($0)) }) else { continue }
            var name = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
            if name?.hasPrefix("*") == true { name = String(name!.dropFirst()) }
            entries.append((name, hash))
        }
        let base = URL(fileURLWithPath: imageName).lastPathComponent
        if let match = entries.first(where: { $0.name.map { URL(fileURLWithPath: $0).lastPathComponent == base } ?? false }) {
            return match.hash
        }
        // One entry naming another file: the image was likely renamed after download.
        return entries.count == 1 ? entries[0].hash : nil
    }
}
