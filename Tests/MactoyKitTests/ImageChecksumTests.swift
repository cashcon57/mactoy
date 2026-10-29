import Testing
@testable import MactoyKit

@Suite("ImageChecksum (#26)")
struct ImageChecksumTests {
    let a = String(repeating: "ab", count: 32)
    let b = String(repeating: "cd", count: 32)

    @Test("a pasted hash is trimmed and lowercased; anything else is refused")
    func normalized() {
        #expect(ImageChecksum.normalized("  \(a.uppercased())\n") == a)
        #expect(ImageChecksum.normalized("sha256:\(a)") == a)
        #expect(ImageChecksum.normalized(String(a.dropLast())) == nil)
        #expect(ImageChecksum.normalized(a + "0") == nil)
        #expect(ImageChecksum.normalized(String(a.dropLast()) + "g") == nil)
        #expect(ImageChecksum.normalized("") == nil)
    }

    @Test("sha256sum and BSD checksum files are read for the right image")
    func files() {
        let sums = """
        # comment
        \(b)  other.img.xz
        \(a) *ubuntu-24.04-desktop-amd64.iso
        """
        #expect(ImageChecksum.sha256(for: "/Users/x/Downloads/ubuntu-24.04-desktop-amd64.iso", in: sums) == a)
        #expect(ImageChecksum.sha256(for: "other.img.xz", in: sums) == b)
        #expect(ImageChecksum.sha256(for: "missing.iso", in: sums) == nil)

        let bsd = "SHA256 (raspios.img.xz) = \(a)\nSHA256 (other) = \(b)\n"
        #expect(ImageChecksum.sha256(for: "raspios.img.xz", in: bsd) == a)
    }

    @Test("a file with one hash is used whatever it names; several unnamed hashes are refused")
    func singleHash() {
        #expect(ImageChecksum.sha256(for: "x.iso", in: "\(a)\n") == a)
        #expect(ImageChecksum.sha256(for: "x.iso", in: "\(a)  renamed.iso\n") == a)
        #expect(ImageChecksum.sha256(for: "x.iso", in: "\(a)\n\(b)\n") == nil)
        #expect(ImageChecksum.sha256(for: "x.iso", in: "not a checksum file") == nil)
    }
}
