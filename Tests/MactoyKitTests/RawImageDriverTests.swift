import Foundation
import Testing
@testable import MactoyKit

@Suite("RawImageDriver helpers")
struct RawImageDriverTests {
    @Test("the last chunk is padded to a 4 KB block, or to 512 bytes at the very end of a drive")
    func padding() {
        let d = Data(repeating: 1, count: 5000)
        let padded = RawImageDriver.paddedToBlock(d, roomLeft: 1_000_000)
        #expect(padded.count == 8192)
        #expect(padded.prefix(5000) == d)
        #expect(padded.suffix(3192).allSatisfy { $0 == 0 })

        // Only 5120 bytes left on the drive: 512-byte padding instead.
        #expect(RawImageDriver.paddedToBlock(d, roomLeft: 5120).count == 5120)
        // Already whole blocks: unchanged.
        #expect(RawImageDriver.paddedToBlock(Data(count: 8192), roomLeft: 8192).count == 8192)
        #expect(RawImageDriver.paddedToBlock(Data(count: 512), roomLeft: 512).count == 512)
    }

    @Test("only a regular file is accepted as the image")
    func regularFileOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-reg-\(UUID().uuidString).img")
        try Data(count: 4096).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try RawImageDriver.requireRegularFile(try FileHandle(forReadingFrom: url), name: "x")
        let zero = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/zero"))
        #expect(throws: DriverError.self) { try RawImageDriver.requireRegularFile(zero, name: "zero") }
    }
}
