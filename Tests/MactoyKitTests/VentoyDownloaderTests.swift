import Testing
@testable import MactoyKit

@Suite("VentoyDownloader.isValidVersion")
struct VentoyDownloaderTests {

    @Test("accepts well-formed versions")
    func acceptsGoodVersions() {
        for v in ["1.1.11", "1.2.0", "2.0.0.1", "1.0", "10.20.30"] {
            #expect(VentoyDownloader.isValidVersion(v), "should accept \(v)")
        }
    }

    @Test("rejects path traversal + injection")
    func rejectsBadVersions() {
        let bad = [
            "",
            "1",                             // single component
            "1.1.11/../../../etc/passwd",    // traversal
            "1.1.11\n",                      // newline
            "1.1.11 && rm -rf /",            // shell injection
            "../1.1.11",
            "1..11",                         // empty component
            ".1.1",
            "1.1.",
            "1a.2.3",                        // non-numeric
            "1.2.3.4.5",                     // too many components
            String(repeating: "1.", count: 20),
        ]
        for v in bad {
            #expect(!VentoyDownloader.isValidVersion(v), "should reject \(v)")
        }
    }
}
