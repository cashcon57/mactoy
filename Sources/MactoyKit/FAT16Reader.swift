import Foundation

/// Read-only FAT16 filesystem parser.
///
/// Implemented from the Microsoft FAT specification (1.03). Only the
/// subset Mactoy actually needs is supported:
///
///   - **FAT16 only.** Not FAT12, not FAT32, not exFAT. Ventoy's VTOYEFI
///     partition is always FAT16 32 MiB; there's no need to handle the
///     others.
///   - **8.3 short filenames only.** Long File Name (LFN) entries
///     (attribute byte `0x0F`) are skipped during directory walking;
///     they're never *interpreted*. Every file Mactoy looks up
///     (`/grub/grub.cfg`, `/EFI/BOOT/...`) fits cleanly in 8.3.
///   - **Read only.** This type never writes back to FAT structures. The
///     update flow rewrites partition 2 wholesale — there's no in-place
///     edit path.
///
/// Caller responsibility: provide a closure that reads bytes
/// **partition-relative** (i.e. offset 0 = first byte of the FAT16
/// partition, NOT the start of the disk). `VentoyVersionProbe` wraps
/// `DiskWriter` to translate disk-relative offsets accordingly.
public struct FAT16Reader {

    /// Closure signature: `(byteOffset, length) throws -> Data`. Returns
    /// exactly `length` bytes starting at `byteOffset` from the start of
    /// the partition.
    public typealias DataReader = (UInt64, Int) throws -> Data

    /// Parsed BIOS Parameter Block from sector 0 of the partition.
    public struct BPB: Sendable {
        public let bytesPerSector: UInt16
        public let sectorsPerCluster: UInt8
        public let reservedSectorCount: UInt16
        public let numFATs: UInt8
        public let rootEntCnt: UInt16
        public let totalSectors: UInt32
        public let fatSizeSectors: UInt16
        /// Volume label as encoded in the BPB extended fields (offset 43,
        /// 11 bytes, space-padded). Empty if the field is missing.
        public let volumeLabel: String
    }

    /// One directory entry (8.3 short-name only — LFN entries are
    /// transparently skipped during enumeration).
    public struct DirEntry: Sendable {
        public let name: String          // "GRUB.CFG" / "GRUB" — uppercase 8.3
        public let isDirectory: Bool
        public let firstCluster: UInt16
        public let fileSize: UInt32
    }

    public let bpb: BPB
    public let firstFATSector: UInt32
    public let firstRootDirSector: UInt32
    public let firstDataSector: UInt32
    private let dataReader: DataReader

    /// Parse the BPB and compute sector layout. Throws if the partition
    /// doesn't look like a valid FAT16 volume.
    public init(_ dataReader: @escaping DataReader) throws {
        self.dataReader = dataReader
        let bpbBytes = try dataReader(0, 512)
        let bpb = try Self.parseBPB(bpbBytes)
        self.bpb = bpb

        // Layout:
        //   [reserved] [FAT0] [FAT1] [root dir] [data clusters]
        let reserved = UInt32(bpb.reservedSectorCount)
        let fatTotal = UInt32(bpb.numFATs) * UInt32(bpb.fatSizeSectors)
        let rootSectors = (UInt32(bpb.rootEntCnt) * 32 + UInt32(bpb.bytesPerSector) - 1) / UInt32(bpb.bytesPerSector)

        self.firstFATSector = reserved
        self.firstRootDirSector = reserved + fatTotal
        self.firstDataSector = reserved + fatTotal + rootSectors
    }

    private static func parseBPB(_ data: Data) throws -> BPB {
        guard data.count >= 512 else {
            throw DriverError.diskIO("FAT16: BPB sector short (\(data.count) bytes)")
        }

        // 0x55 0xAA boot signature lives at the end of sector 0 of any
        // bootable FAT volume. Absent → not a FAT volume (or not FAT16,
        // since FAT32 also has it).
        let sigLow = data[510]
        let sigHigh = data[511]
        guard sigLow == 0x55 && sigHigh == 0xAA else {
            throw DriverError.diskIO("FAT16: missing 0x55AA boot signature")
        }

        let bytesPerSector = data.readLE16(at: 11)
        let sectorsPerCluster = data[13]
        let reservedSectorCount = data.readLE16(at: 14)
        let numFATs = data[16]
        let rootEntCnt = data.readLE16(at: 17)
        let totSec16 = data.readLE16(at: 19)
        let fatSz16 = data.readLE16(at: 22)
        let totSec32 = data.readLE32(at: 32)

        // Sanity: bytesPerSector must be 512/1024/2048/4096 and a power of
        // two. Ventoy uses 512 universally; reject anything else for now.
        guard bytesPerSector == 512 else {
            throw DriverError.diskIO("FAT16: unsupported bytesPerSector \(bytesPerSector) (expected 512)")
        }
        guard sectorsPerCluster > 0 && (sectorsPerCluster & (sectorsPerCluster - 1)) == 0 else {
            throw DriverError.diskIO("FAT16: invalid sectorsPerCluster \(sectorsPerCluster)")
        }
        guard reservedSectorCount > 0 else {
            throw DriverError.diskIO("FAT16: reservedSectorCount is 0")
        }
        guard numFATs >= 1 && numFATs <= 2 else {
            throw DriverError.diskIO("FAT16: unusual numFATs \(numFATs)")
        }
        guard rootEntCnt > 0 else {
            throw DriverError.diskIO("FAT16: rootEntCnt is 0 (FAT32 volume?)")
        }
        guard fatSz16 > 0 else {
            throw DriverError.diskIO("FAT16: fatSz16 is 0 (FAT32 volume?)")
        }

        let totalSectors: UInt32 = totSec16 != 0 ? UInt32(totSec16) : totSec32

        // Volume label sits in the extended BIOS parameter block at byte
        // offset 43, padded with spaces to 11 bytes. Trim trailing
        // whitespace; we only care about it for "is this VTOYEFI?"
        // sniff in `VentoyVersionProbe`.
        let labelBytes = data.subdata(in: 43..<54)
        let labelStr = String(data: labelBytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces)
            ?? ""

        return BPB(
            bytesPerSector: bytesPerSector,
            sectorsPerCluster: sectorsPerCluster,
            reservedSectorCount: reservedSectorCount,
            numFATs: numFATs,
            rootEntCnt: rootEntCnt,
            totalSectors: totalSectors,
            fatSizeSectors: fatSz16,
            volumeLabel: labelStr
        )
    }

    /// Read a file by 8.3 path. Path components are case-insensitive on
    /// the matching side (FAT directory entries are stored uppercase).
    /// Leading slashes are tolerated.
    public func readFile(at path: String) throws -> Data {
        let components = Self.splitPath(path)
        guard !components.isEmpty else {
            throw DriverError.diskIO("FAT16: readFile() requires non-empty path")
        }

        // Walk directory tree to the parent of the leaf.
        var currentEntries = try readRootDirectory()
        for (i, component) in components.enumerated() {
            let isLeaf = (i == components.count - 1)
            guard let match = currentEntries.first(where: { $0.matches(name83: component) }) else {
                throw DriverError.diskIO("FAT16: '\(component)' not found")
            }
            if isLeaf {
                guard !match.isDirectory else {
                    throw DriverError.diskIO("FAT16: '\(path)' is a directory, expected file")
                }
                return try readFileBytes(firstCluster: match.firstCluster, size: match.fileSize)
            } else {
                guard match.isDirectory else {
                    throw DriverError.diskIO("FAT16: '\(component)' is a file, expected directory")
                }
                currentEntries = try readDirectory(firstCluster: match.firstCluster)
            }
        }
        throw DriverError.diskIO("FAT16: unreachable in readFile()")
    }

    /// List directory entries by 8.3 path. Pass an empty string or "/" for the root.
    public func listDirectory(at path: String) throws -> [DirEntry] {
        let components = Self.splitPath(path)
        if components.isEmpty {
            return try readRootDirectory()
        }
        var currentEntries = try readRootDirectory()
        for (i, component) in components.enumerated() {
            let isLeaf = (i == components.count - 1)
            guard let match = currentEntries.first(where: { $0.matches(name83: component) }) else {
                throw DriverError.diskIO("FAT16: '\(component)' not found")
            }
            guard match.isDirectory else {
                throw DriverError.diskIO("FAT16: '\(component)' is a file, expected directory")
            }
            if isLeaf {
                return try readDirectory(firstCluster: match.firstCluster)
            } else {
                currentEntries = try readDirectory(firstCluster: match.firstCluster)
            }
        }
        return []
    }

    // MARK: - Internals

    private static func splitPath(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// FAT16 root directory is a fixed-size flat region right after the
    /// FATs — NOT a regular cluster chain. `rootEntCnt * 32` bytes.
    private func readRootDirectory() throws -> [DirEntry] {
        let rootByteCount = Int(bpb.rootEntCnt) * 32
        let rootStartByte = UInt64(firstRootDirSector) * UInt64(bpb.bytesPerSector)
        let raw = try dataReader(rootStartByte, rootByteCount)
        return Self.parseDirEntries(raw)
    }

    /// A non-root directory's contents follow the cluster chain that
    /// starts at `firstCluster`. Read all clusters, concatenate, and
    /// parse as a flat array of 32-byte entries.
    private func readDirectory(firstCluster: UInt16) throws -> [DirEntry] {
        let raw = try readClusterChain(firstCluster: firstCluster, sizeLimit: nil)
        return Self.parseDirEntries(raw)
    }

    /// Read a file's cluster chain, capping at `size` bytes (the FAT
    /// rounds up to whole clusters; the directory entry's `fileSize`
    /// gives the actual byte count).
    private func readFileBytes(firstCluster: UInt16, size: UInt32) throws -> Data {
        guard size > 0 else { return Data() }
        let raw = try readClusterChain(firstCluster: firstCluster, sizeLimit: Int(size))
        return raw.prefix(Int(size))
    }

    /// Walk a cluster chain via the FAT16 table, collecting cluster
    /// payloads. Pass `sizeLimit` to stop early once enough bytes are
    /// gathered (saves work on multi-cluster files we don't need
    /// in full).
    private func readClusterChain(firstCluster: UInt16, sizeLimit: Int?) throws -> Data {
        let bytesPerCluster = Int(bpb.sectorsPerCluster) * Int(bpb.bytesPerSector)
        var result = Data()
        var cluster: UInt16 = firstCluster
        // Belt-and-suspenders cap: a corrupt FAT could form an infinite
        // cycle. 65536 clusters * 2 KiB/cluster = 128 MiB; well above any
        // file we actually need to read on a 32 MiB partition.
        var hops = 0
        let maxHops = 65536

        while cluster >= 2 && cluster < 0xFFF8 && hops < maxHops {
            let dataSectorOffset = (UInt32(cluster) - 2) * UInt32(bpb.sectorsPerCluster)
            let absSector = firstDataSector + dataSectorOffset
            let byteOffset = UInt64(absSector) * UInt64(bpb.bytesPerSector)
            let chunk = try dataReader(byteOffset, bytesPerCluster)
            result.append(chunk)

            if let limit = sizeLimit, result.count >= limit {
                return result
            }
            cluster = try readFATEntry(cluster: cluster)
            hops += 1
        }
        if hops >= maxHops {
            throw DriverError.diskIO("FAT16: cluster chain exceeds \(maxHops) hops (corrupt FAT)")
        }
        return result
    }

    /// Read a single FAT16 entry. Each entry is 2 bytes little-endian.
    private func readFATEntry(cluster: UInt16) throws -> UInt16 {
        let byteOffset = UInt64(firstFATSector) * UInt64(bpb.bytesPerSector) + UInt64(cluster) * 2
        let bytes = try dataReader(byteOffset, 2)
        return bytes.readLE16(at: 0)
    }

    /// Parse a raw directory blob into a list of 8.3 entries. LFN
    /// entries (attribute byte `0x0F`) are skipped without
    /// interpretation. Volume-label entries (`0x08`) are also skipped.
    private static func parseDirEntries(_ data: Data) -> [DirEntry] {
        var out: [DirEntry] = []
        let entrySize = 32
        let count = data.count / entrySize
        for i in 0..<count {
            let base = i * entrySize
            let firstByte = data[base]
            // 0x00 → no further entries in this directory
            if firstByte == 0x00 { break }
            // 0xE5 → entry deleted; skip
            if firstByte == 0xE5 { continue }

            let attr = data[base + 11]
            // 0x0F → long file name; we don't interpret these
            if attr == 0x0F { continue }
            // 0x08 → volume label entry in root dir; skip
            if (attr & 0x08) != 0 { continue }

            let nameRaw = data.subdata(in: (base + 0)..<(base + 8))
            let extRaw = data.subdata(in: (base + 8)..<(base + 11))
            let name = (String(data: nameRaw, encoding: .ascii) ?? "")
                .trimmingCharacters(in: .whitespaces)
            let ext = (String(data: extRaw, encoding: .ascii) ?? "")
                .trimmingCharacters(in: .whitespaces)
            // FAT stores 0x05 to mean "real first byte is 0xE5" (Kanji-
            // safe encoding). Translate back. Mactoy only reads ASCII
            // names, but be correct.
            let trueName: String
            if firstByte == 0x05 {
                trueName = "\u{E5}" + name.dropFirst()
            } else {
                trueName = name
            }
            let combined = ext.isEmpty ? trueName : "\(trueName).\(ext)"

            let firstCluster = data.readLE16(at: base + 26)
            let fileSize = data.readLE32(at: base + 28)
            let isDirectory = (attr & 0x10) != 0

            out.append(DirEntry(
                name: combined.uppercased(),
                isDirectory: isDirectory,
                firstCluster: firstCluster,
                fileSize: fileSize
            ))
        }
        return out
    }
}

extension FAT16Reader.DirEntry {
    /// Case-insensitive 8.3 match. Compares the entry's "NAME.EXT" form
    /// (always uppercase, period included only when the extension is
    /// non-empty) against the queried path component.
    func matches(name83 query: String) -> Bool {
        return name == query.uppercased()
    }
}

// MARK: - Little-endian helpers

// Module-internal so both FAT16Reader and VentoyVersionProbe can use
// them. Not public — these are byte-fiddling helpers that don't belong
// in MactoyKit's API surface.
extension Data {
    func readLE16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readLE32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func readLE64(at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(self[offset + i]) << (8 * i)
        }
        return v
    }
}
