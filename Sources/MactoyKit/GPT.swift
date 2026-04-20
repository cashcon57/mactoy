import Foundation

/// GPT partition type GUID for Microsoft Basic Data (used by Ventoy for both
/// its data and VTOYEFI partitions).
public let GPT_BASIC_DATA_GUID = UUID(uuidString: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7")!

public enum GPT {

    /// Convert a UUID (stored big-endian per RFC 4122) to GPT's mixed-endian
    /// wire format: first three fields little-endian, last two as-is.
    public static func mixedEndianBytes(_ uuid: UUID) -> [UInt8] {
        let t = uuid.uuid
        let raw: [UInt8] = [
            t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7,
            t.8, t.9, t.10, t.11, t.12, t.13, t.14, t.15
        ]
        var out = [UInt8](repeating: 0, count: 16)
        // first 4 reversed
        out[0] = raw[3]; out[1] = raw[2]; out[2] = raw[1]; out[3] = raw[0]
        // next 2 reversed
        out[4] = raw[5]; out[5] = raw[4]
        // next 2 reversed
        out[6] = raw[7]; out[7] = raw[6]
        // last 8 as-is
        for i in 8..<16 { out[i] = raw[i] }
        return out
    }

    public static func makeEntry(
        typeGUID: UUID,
        uniqueGUID: UUID,
        startLBA: UInt64,
        endLBA: UInt64,
        attributes: UInt64,
        name: String
    ) -> Data {
        var out = Data()
        out.append(contentsOf: mixedEndianBytes(typeGUID))
        out.append(contentsOf: mixedEndianBytes(uniqueGUID))
        out.append(uint64LE(startLBA))
        out.append(uint64LE(endLBA))
        out.append(uint64LE(attributes))
        var nameBytes = Data()
        for scalar in name.unicodeScalars {
            let v = UInt16(scalar.value & 0xFFFF)
            nameBytes.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
        }
        if nameBytes.count > 72 { nameBytes = nameBytes.prefix(72) }
        nameBytes.append(Data(repeating: 0, count: 72 - nameBytes.count))
        out.append(nameBytes)
        precondition(out.count == 128, "GPT entry must be exactly 128 bytes")
        return out
    }

    public struct HeaderParams {
        public var myLBA: UInt64
        public var altLBA: UInt64
        public var firstUsable: UInt64
        public var lastUsable: UInt64
        public var diskGUID: UUID
        public var entryStart: UInt64
        public var numEntries: UInt32
        public var entrySize: UInt32
        public var entriesCRC: UInt32

        public init(
            myLBA: UInt64,
            altLBA: UInt64,
            firstUsable: UInt64,
            lastUsable: UInt64,
            diskGUID: UUID,
            entryStart: UInt64,
            numEntries: UInt32,
            entrySize: UInt32,
            entriesCRC: UInt32
        ) {
            self.myLBA = myLBA
            self.altLBA = altLBA
            self.firstUsable = firstUsable
            self.lastUsable = lastUsable
            self.diskGUID = diskGUID
            self.entryStart = entryStart
            self.numEntries = numEntries
            self.entrySize = entrySize
            self.entriesCRC = entriesCRC
        }
    }

    /// Build a GPT header (512 bytes, zero-padded) for the given params.
    /// CRC field is computed over the 92 significant bytes.
    public static func makeHeader(_ p: HeaderParams) -> Data {
        var d = Data()
        d.append("EFI PART".data(using: .ascii)!)       // 8
        d.append(uint32LE(0x00010000))                    // 4  revision
        d.append(uint32LE(92))                            // 4  header size
        d.append(uint32LE(0))                             // 4  CRC placeholder
        d.append(uint32LE(0))                             // 4  reserved
        d.append(uint64LE(p.myLBA))                       // 8
        d.append(uint64LE(p.altLBA))                      // 8
        d.append(uint64LE(p.firstUsable))                 // 8
        d.append(uint64LE(p.lastUsable))                  // 8
        d.append(contentsOf: mixedEndianBytes(p.diskGUID))// 16
        d.append(uint64LE(p.entryStart))                  // 8
        d.append(uint32LE(p.numEntries))                  // 4
        d.append(uint32LE(p.entrySize))                   // 4
        d.append(uint32LE(p.entriesCRC))                  // 4
        precondition(d.count == 92)

        let crc = CRC32.checksum(d)
        // Patch CRC at offset 16
        d.replaceSubrange(16..<20, with: uint32LE(crc))

        // Pad to 512-byte sector
        d.append(Data(repeating: 0, count: Int(SECTOR_SIZE) - d.count))
        precondition(d.count == Int(SECTOR_SIZE))
        return d
    }

    public struct BuiltGPT: Sendable {
        public let protectiveMBR: Data        // 512 bytes
        public let primaryHeader: Data        // 512 bytes
        public let entries: Data              // 128 * 128 = 16384 bytes
        public let backupHeader: Data         // 512 bytes
    }

    /// Build a complete GPT (MBR + primary header + entries + backup header) for the
    /// given disk and Ventoy layout. GUIDs are randomly generated.
    public static func build(
        diskSectors: UInt64,
        layout: VentoyLayout,
        diskGUID: UUID = UUID(),
        part1GUID: UUID = UUID(),
        part2GUID: UUID = UUID()
    ) -> BuiltGPT {
        // Build entries: Ventoy (exFAT) + VTOYEFI (FAT16), both Basic-Data typed
        let e1 = makeEntry(
            typeGUID: GPT_BASIC_DATA_GUID,
            uniqueGUID: part1GUID,
            startLBA: layout.part1Start,
            endLBA: layout.part1End,
            attributes: 0,
            name: "Ventoy"
        )
        let e2 = makeEntry(
            typeGUID: GPT_BASIC_DATA_GUID,
            uniqueGUID: part2GUID,
            startLBA: layout.part2Start,
            endLBA: layout.part2End,
            attributes: 0,
            name: "VTOYEFI"
        )

        var entries = Data()
        entries.append(e1)
        entries.append(e2)
        // pad to 128 entries * 128 bytes = 16384
        entries.append(Data(repeating: 0, count: 128 * 128 - entries.count))
        precondition(entries.count == 128 * 128)

        let entriesCRC = CRC32.checksum(entries)

        let primary = makeHeader(.init(
            myLBA: 1,
            altLBA: diskSectors - 1,
            firstUsable: 2048,
            lastUsable: diskSectors - 34,
            diskGUID: diskGUID,
            entryStart: 2,
            numEntries: 128,
            entrySize: 128,
            entriesCRC: entriesCRC
        ))
        let backup = makeHeader(.init(
            myLBA: diskSectors - 1,
            altLBA: 1,
            firstUsable: 2048,
            lastUsable: diskSectors - 34,
            diskGUID: diskGUID,
            entryStart: diskSectors - 33,
            numEntries: 128,
            entrySize: 128,
            entriesCRC: entriesCRC
        ))

        // Protective MBR
        var mbr = Data(repeating: 0, count: Int(SECTOR_SIZE))
        // Partition entry at offset 446..462
        mbr[446] = 0x00           // boot indicator
        mbr[447] = 0x00           // starting head (filled by GRUB/Ventoy later via boot.img)
        mbr[448] = 0x02           // starting sector
        mbr[449] = 0x00           // starting cylinder
        mbr[450] = 0xEE           // partition type = GPT protective
        mbr[451] = 0xFF
        mbr[452] = 0xFF
        mbr[453] = 0xFF
        // first LBA = 1
        mbr.replaceSubrange(454..<458, with: uint32LE(1))
        // size in LBAs = disk - 1 (clamped to 32-bit max)
        let size32 = min(diskSectors - 1, UInt64(UInt32.max))
        mbr.replaceSubrange(458..<462, with: uint32LE(UInt32(size32)))
        // signature
        mbr[510] = 0x55
        mbr[511] = 0xAA

        return BuiltGPT(
            protectiveMBR: mbr,
            primaryHeader: primary,
            entries: entries,
            backupHeader: backup
        )
    }
}

// MARK: - little-endian helpers

@inlinable
public func uint32LE(_ v: UInt32) -> Data {
    var le = v.littleEndian
    return withUnsafeBytes(of: &le) { Data($0) }
}

@inlinable
public func uint64LE(_ v: UInt64) -> Data {
    var le = v.littleEndian
    return withUnsafeBytes(of: &le) { Data($0) }
}
