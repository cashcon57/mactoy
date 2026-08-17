import Testing
import Foundation
@testable import MactoyKit

@Suite("QuirkyEnclosureRegistry.lookup")
struct QuirkyEnclosureTests {

    @Test("RTL9210B matches the seed entry (issue #4)")
    func rtl9210bMatches() {
        let quirk = QuirkyEnclosureRegistry.lookup(mediaName: "RTL9210B-CG")
        #expect(quirk != nil)
        #expect(quirk?.mediaNameSubstring == "RTL9210")
    }

    @Test("RTL9210 (without B suffix) also matches")
    func rtl9210BareMatches() {
        #expect(QuirkyEnclosureRegistry.lookup(mediaName: "Realtek RTL9210 Bridge") != nil)
    }

    @Test("case-insensitive match")
    func caseInsensitive() {
        #expect(QuirkyEnclosureRegistry.lookup(mediaName: "rtl9210b-cg") != nil)
        #expect(QuirkyEnclosureRegistry.lookup(mediaName: "Rtl9210") != nil)
    }

    @Test("innocent enclosure name does not match")
    func noFalsePositive() {
        #expect(QuirkyEnclosureRegistry.lookup(mediaName: "SanDisk Ultra USB 3.0") == nil)
        #expect(QuirkyEnclosureRegistry.lookup(mediaName: "SSD 840 PRO Seri") == nil)
        #expect(QuirkyEnclosureRegistry.lookup(mediaName: "Samsung Portable SSD T7") == nil)
    }

    @Test("nil and empty mediaName return nil")
    func nilAndEmpty() {
        #expect(QuirkyEnclosureRegistry.lookup(mediaName: nil) == nil)
        #expect(QuirkyEnclosureRegistry.lookup(mediaName: "") == nil)
    }

    @Test("registry entries have required fields")
    func registryWellFormed() {
        for entry in QuirkyEnclosureRegistry.known {
            #expect(!entry.mediaNameSubstring.isEmpty, "entry mediaNameSubstring is empty")
            #expect(!entry.symptom.isEmpty, "entry symptom is empty for \(entry.mediaNameSubstring)")
            #expect(!entry.workaround.isEmpty, "entry workaround is empty for \(entry.mediaNameSubstring)")
        }
    }
}
