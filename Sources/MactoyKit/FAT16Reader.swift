import Foundation

/// Read-only FAT16 filesystem parser.
///
/// Implemented from the Microsoft FAT specification (1.03). Only the
/// subset Mactoy actually needs is supported:
///
///   - **FAT16 only.** Not FAT12, not FAT32, not exFAT. Ventoy's VTOYEFI
///     partition is always FAT16 32 MiB; there's no need to handle the
///     others.
///   - **Short and long filenames.** Long File Name (LFN) entries
///     (attribute byte `0x0F`) are decoded and attached to the short
///     entry that follows them, so lookups work by either name. v0.4.0
///     needs this because `grubx64_real.efi` doesn't fit in 8.3 and its
///     generated short alias (`GRUBX6~1.EFI`) isn't stable.
///   - **Read only.** This type never writes back to FAT structures.
///     `VentoyESP` layers in-memory edits on top of the offsets this
///     type exposes; nothing here touches a disk.
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

    /// One directory entry. `name` is always the 8.3 short name;
    /// `longName` is set when LFN entries preceded it.
    public struct DirEntry: Sendable {
        public let name: String          // "GRUB.CFG" / "GRUB" — uppercase 8.3
        public let longName: String?     // "grubx64_real.efi" — case preserved
        public let isDirectory: Bool
        public let firstCluster: UInt16
        public let fileSize: UInt32
        /// 32-byte slot indices this entry occupies inside its
        /// directory: any LFN slots first, the short entry last.
        let slots: Range<Int>
    }

    public let bpb: BPB
    public let firstFATSector: UInt32
    public let firstRootDirSector: UInt32
    public let firstDataSector: UInt32
    /// Number of data clusters. Valid cluster numbers are
    /// `2...(clusterCount + 1)`.
    public let clusterCount: UInt32
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

        // The FAT type is defined by the cluster count, not by any
        // label (FAT spec 1.03, "FAT Type Determination"). Below 4085
        // this is FAT12, whose 12-bit entries we'd misread as garbage.
        guard bpb.totalSectors > firstDataSector else {
            throw DriverError.diskIO("FAT16: no data region (totalSectors \(bpb.totalSectors))")
        }
        let clusterCount = (bpb.totalSectors - firstDataSector) / UInt32(bpb.sectorsPerCluster)
        guard clusterCount >= 4085, clusterCount < 65525 else {
            throw DriverError.diskIO("FAT16: \(clusterCount) clusters is outside the FAT16 range")
        }
        guard UInt32(bpb.fatSizeSectors) * UInt32(bpb.bytesPerSector) >= (clusterCount + 2) * 2 else {
            throw DriverError.diskIO("FAT16: FAT too small for \(clusterCount) clusters")
        }
        self.clusterCount = clusterCount
    }

    /// A chain entry pointing outside the volume means a corrupt FAT.
    /// Following it would read — or, for `VentoyESP`, write — outside
    /// the structures it's meant to address.
    private func checkInRange(_ cluster: UInt16) throws {
        guard UInt32(cluster) <= clusterCount + 1 else {
            throw DriverError.diskIO("FAT16: cluster \(cluster) is past the end of the volume (\(clusterCount) clusters)")
        }
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

    /// Read a file by path. Components match case-insensitively against
    /// either the 8.3 short name or the long name. Leading slashes are
    /// tolerated.
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

    /// True when `path` resolves to a regular file. A missing parent
    /// directory is "no"; a read error is thrown, not folded into "no".
    public func fileExists(at path: String) throws -> Bool {
        var entries = try readRootDirectory()
        let components = Self.splitPath(path)
        for (i, component) in components.enumerated() {
            guard let match = entries.first(where: { $0.matches(name83: component) }) else { return false }
            if i == components.count - 1 { return !match.isDirectory }
            guard match.isDirectory else { return false }
            entries = try readDirectory(firstCluster: match.firstCluster)
        }
        return false
    }

    /// List directory entries by path. Pass an empty string or "/" for the root.
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
            try checkInRange(cluster)
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

    /// Partition-relative byte ranges that hold the directory at
    /// `path`, in order. Slot `i` of the directory lives at byte `i * 32`
    /// of the concatenation of these ranges.
    func directoryByteRanges(at path: String) throws -> [Range<Int>] {
        var firstCluster: UInt16?
        var currentEntries = try readRootDirectory()
        for component in Self.splitPath(path) {
            guard let match = currentEntries.first(where: { $0.matches(name83: component) }) else {
                throw DriverError.diskIO("FAT16: '\(component)' not found")
            }
            guard match.isDirectory else {
                throw DriverError.diskIO("FAT16: '\(component)' is a file, expected directory")
            }
            firstCluster = match.firstCluster
            currentEntries = try readDirectory(firstCluster: match.firstCluster)
        }
        guard let firstCluster else {
            let start = Int(firstRootDirSector) * Int(bpb.bytesPerSector)
            return [start..<(start + Int(bpb.rootEntCnt) * 32)]
        }
        let bytesPerCluster = Int(bpb.sectorsPerCluster) * Int(bpb.bytesPerSector)
        return try clusterChain(from: firstCluster).map { cluster in
            let start = (Int(firstDataSector) + (Int(cluster) - 2) * Int(bpb.sectorsPerCluster)) * Int(bpb.bytesPerSector)
            return start..<(start + bytesPerCluster)
        }
    }

    /// Every cluster in the chain starting at `firstCluster`.
    func clusterChain(from firstCluster: UInt16) throws -> [UInt16] {
        var chain: [UInt16] = []
        var cluster = firstCluster
        while cluster >= 2 && cluster < 0xFFF8 {
            guard chain.count < 65536 else {
                throw DriverError.diskIO("FAT16: cluster chain exceeds 65536 hops (corrupt FAT)")
            }
            try checkInRange(cluster)
            chain.append(cluster)
            cluster = try readFATEntry(cluster: cluster)
        }
        return chain
    }

    /// Partition-relative byte offset of `cluster`'s entry in each FAT copy.
    func fatEntryByteOffsets(cluster: UInt16) -> [Int] {
        (0..<Int(bpb.numFATs)).map { copy in
            (Int(firstFATSector) + copy * Int(bpb.fatSizeSectors)) * Int(bpb.bytesPerSector) + Int(cluster) * 2
        }
    }

    /// Read a single FAT16 entry. Each entry is 2 bytes little-endian.
    private func readFATEntry(cluster: UInt16) throws -> UInt16 {
        let byteOffset = UInt64(firstFATSector) * UInt64(bpb.bytesPerSector) + UInt64(cluster) * 2
        let bytes = try dataReader(byteOffset, 2)
        return bytes.readLE16(at: 0)
    }

    /// Parse a raw directory blob. LFN entries (attribute byte `0x0F`)
    /// are decoded and attached to the short entry they precede.
    /// Volume-label entries (`0x08`) are skipped.
    private static func parseDirEntries(_ data: Data) -> [DirEntry] {
        var out: [DirEntry] = []
        let entrySize = 32
        let count = data.count / entrySize
        // LFN slots seen since the last short entry: sequence number →
        // UTF-16 code units. They sit physically before their short
        // entry, highest sequence number first.
        var lfnParts: [Int: [UInt16]] = [:]
        var lfnFirstSlot: Int?
        var lfnChecksum: UInt8 = 0

        for i in 0..<count {
            let base = i * entrySize
            let firstByte = data[base]
            // 0x00 → no further entries in this directory
            if firstByte == 0x00 { break }
            // 0xE5 → entry deleted; skip
            if firstByte == 0xE5 {
                lfnParts = [:]; lfnFirstSlot = nil
                continue
            }

            let attr = data[base + 11]
            if attr == 0x0F {
                if lfnFirstSlot == nil || (firstByte & 0x40) != 0 {
                    lfnParts = [:]
                    lfnFirstSlot = i
                    lfnChecksum = data[base + 13]
                }
                var units: [UInt16] = []
                for off in [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30] {
                    units.append(data.readLE16(at: base + off))
                }
                lfnParts[Int(firstByte & 0x1F)] = units
                continue
            }
            // 0x08 → volume label entry in root dir; skip
            if (attr & 0x08) != 0 {
                lfnParts = [:]; lfnFirstSlot = nil
                continue
            }

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

            // Attach the pending long name only if its checksum matches
            // this short entry — otherwise the LFN slots are orphans
            // left behind by a non-LFN-aware tool.
            var longName: String?
            var firstSlot = i
            if let start = lfnFirstSlot,
               lfnChecksum == shortNameChecksum(data.subdata(in: base..<(base + 11))) {
                var units: [UInt16] = []
                for seq in lfnParts.keys.sorted() { units.append(contentsOf: lfnParts[seq]!) }
                if let end = units.firstIndex(of: 0x0000) { units.removeSubrange(end...) }
                longName = String(decoding: units, as: UTF16.self)
                firstSlot = start
            }
            lfnParts = [:]; lfnFirstSlot = nil

            let firstCluster = data.readLE16(at: base + 26)
            let fileSize = data.readLE32(at: base + 28)
            let isDirectory = (attr & 0x10) != 0

            out.append(DirEntry(
                name: combined.uppercased(),
                longName: longName,
                isDirectory: isDirectory,
                firstCluster: firstCluster,
                fileSize: fileSize,
                slots: firstSlot..<(i + 1)
            ))
        }
        return out
    }

    /// Checksum of an 11-byte short name, as stored in byte 13 of each
    /// LFN slot that belongs to it (FAT spec 1.03, "Long Directory
    /// Entries").
    private static func shortNameChecksum(_ shortName: Data) -> UInt8 {
        var sum: UInt8 = 0
        for byte in shortName {
            sum = ((sum & 1) << 7) &+ (sum >> 1) &+ byte
        }
        return sum
    }
}

extension FAT16Reader.DirEntry {
    /// Case-insensitive match of a path component against the entry's
    /// "NAME.EXT" short form (always uppercase, period included only
    /// when the extension is non-empty) or its long name.
    func matches(name83 query: String) -> Bool {
        let q = query.uppercased()
        return name == q || longName?.uppercased() == q
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
