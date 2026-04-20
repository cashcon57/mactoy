import Testing
import Foundation
@testable import MactoyKit

@Suite("CRC32")
struct CRC32Tests {
    @Test("known vectors")
    func knownVectors() {
        // Standard CRC-32 test vectors
        #expect(CRC32.checksum(Data()) == 0x00000000)
        #expect(CRC32.checksum("123456789".data(using: .ascii)!) == 0xCBF43926)
        #expect(CRC32.checksum("The quick brown fox jumps over the lazy dog".data(using: .ascii)!) == 0x414FA339)
    }
}

@Suite("VentoyLayout")
struct VentoyLayoutTests {
    /// Cross-validated against the Python ventoy-macos-install.py output
    /// for the 124 GB PNY stick that we successfully flashed.
    @Test("124GB stick matches Python reference")
    func matchesPythonReference() {
        // 124.0 GB, exactly 242147328 512-byte sectors
        let layout = VentoyLayout.calculate(diskSectors: 242147328)
        #expect(layout.part1Start == 2048)
        #expect(layout.part1End == 242081751)
        #expect(layout.part2Start == 242081752)
        #expect(layout.part2End == 242147287)
    }

    @Test("part2 starts on 8-sector boundary")
    func alignment() {
        for sectors in stride(from: UInt64(1_000_000), to: UInt64(500_000_000), by: 123_457) {
            let l = VentoyLayout.calculate(diskSectors: sectors)
            #expect(l.part2Start % 8 == 0, "disk=\(sectors) part2=\(l.part2Start)")
            #expect(l.part2End - l.part2Start + 1 == VENTOY_EFI_SECTORS)
            #expect(l.part1Start == 2048)
            #expect(l.part2End <= sectors - 1)
        }
    }
}

@Suite("GPT UUID mixed-endian")
struct GPTUUIDTests {
    @Test("basic data GUID matches GPT wire format")
    func basicDataGUID() {
        let b = GPT.mixedEndianBytes(GPT_BASIC_DATA_GUID)
        // EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 in mixed-endian =
        // A2 A0 D0 EB E5 B9 33 44 87 C0 68 B6 B7 26 99 C7
        let expected: [UInt8] = [0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44,
                                 0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7]
        #expect(b == expected)
    }
}

@Suite("GPT entry encoding")
struct GPTEntryTests {
    @Test("Ventoy partition entry is 128 bytes and starts with type GUID")
    func ventoyEntry() {
        let entry = GPT.makeEntry(
            typeGUID: GPT_BASIC_DATA_GUID,
            uniqueGUID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            startLBA: 2048,
            endLBA: 242081751,
            attributes: 0,
            name: "Ventoy"
        )
        #expect(entry.count == 128)
        // Starts with basic-data type GUID in mixed-endian form
        let typePrefix: [UInt8] = [0xA2, 0xA0, 0xD0, 0xEB]
        #expect(Array(entry.prefix(4)) == typePrefix)
        // Name encoded as UTF-16LE starting at offset 56
        let nameBytes: [UInt8] = [0x56, 0x00, 0x65, 0x00, 0x6E, 0x00, 0x74, 0x00, 0x6F, 0x00, 0x79, 0x00]
        #expect(Array(entry.subdata(in: 56..<(56 + nameBytes.count))) == nameBytes)
    }
}

@Suite("Protective MBR")
struct ProtectiveMBRTests {
    @Test("signature + protective partition type")
    func mbrBasics() {
        let layout = VentoyLayout.calculate(diskSectors: 242147328)
        let built = GPT.build(diskSectors: 242147328, layout: layout)
        let mbr = built.protectiveMBR
        #expect(mbr.count == 512)
        #expect(mbr[510] == 0x55 && mbr[511] == 0xAA)
        #expect(mbr[450] == 0xEE) // protective GPT partition type
        // first LBA = 1
        #expect(Array(mbr.subdata(in: 454..<458)) == [0x01, 0x00, 0x00, 0x00])
        // size = min(disk-1, 0xFFFFFFFF) -> here disk-1 fits
        let size = UInt32(242147328 - 1)
        var expected = size.littleEndian
        let sizeBytes = withUnsafeBytes(of: &expected) { Array($0) }
        #expect(Array(mbr.subdata(in: 458..<462)) == sizeBytes)
    }
}

@Suite("GPT header")
struct GPTHeaderTests {
    @Test("header is 512 bytes, starts with EFI PART, has valid CRC")
    func headerStructure() {
        let layout = VentoyLayout.calculate(diskSectors: 242147328)
        let built = GPT.build(diskSectors: 242147328, layout: layout)

        #expect(built.primaryHeader.count == 512)
        #expect(Array(built.primaryHeader.prefix(8)) == Array("EFI PART".utf8))

        // Verify header CRC: it's computed over bytes 0..92 with CRC field zeroed.
        var body = Data(built.primaryHeader.prefix(92))
        let storedCRC = body.subdata(in: 16..<20).withUnsafeBytes { $0.load(as: UInt32.self) }
        body.replaceSubrange(16..<20, with: Data([0, 0, 0, 0]))
        let recomputed = CRC32.checksum(body)
        #expect(storedCRC == recomputed)
    }
}
