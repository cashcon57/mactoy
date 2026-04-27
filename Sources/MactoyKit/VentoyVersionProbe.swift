import Foundation

/// Result of probing a USB drive to see whether it has a Ventoy install
/// and, if so, which version.
///
/// Carries enough detail for the UI to decide between three states:
///   1. **Not Ventoy** (`isVentoyDisk == false` with a non-empty
///      `layoutIssues`) → fresh install only.
///   2. **Recognised Ventoy** (`isVentoyDisk == true`,
///      `detectedVersion != nil`) → offer update.
///   3. **Looks-like-Ventoy-but-broken** (`isVentoyDisk == false` AND
///      one or more layout markers matched) → suggest "repair via fresh
///      install", warning that data will be lost.
///
/// `Codable` + `Sendable` because this struct crosses the XPC boundary
/// from the daemon back to the app.
public struct VentoyProbeResult: Codable, Sendable, Equatable {
    public let bsdName: String
    public let isVentoyDisk: Bool
    public let detectedVersion: String?
    public let secureBootEnabled: Bool
    public let partitionStyle: PartitionStyle
    public let partition2StartSector: UInt64
    public let layoutIssues: [String]
    /// When `false` and `isVentoyDisk == false` but at least one Ventoy
    /// marker matched (e.g. partition labels), the disk likely has a
    /// damaged Ventoy install. UI uses this to offer a repair path.
    public let looksLikeBrokenVentoy: Bool

    public enum PartitionStyle: String, Codable, Sendable {
        case mbr
        case gpt
        case unknown
    }

    public init(
        bsdName: String,
        isVentoyDisk: Bool,
        detectedVersion: String?,
        secureBootEnabled: Bool,
        partitionStyle: PartitionStyle,
        partition2StartSector: UInt64,
        layoutIssues: [String],
        looksLikeBrokenVentoy: Bool
    ) {
        self.bsdName = bsdName
        self.isVentoyDisk = isVentoyDisk
        self.detectedVersion = detectedVersion
        self.secureBootEnabled = secureBootEnabled
        self.partitionStyle = partitionStyle
        self.partition2StartSector = partition2StartSector
        self.layoutIssues = layoutIssues
        self.looksLikeBrokenVentoy = looksLikeBrokenVentoy
    }

    /// Convenience: the result struct returned when a probe attempt
    /// throws or hits a sub-MiB-class corruption that prevents any
    /// meaningful read. UI treats this identically to "not a Ventoy
    /// disk" — fresh install only.
    public static func unknownDisk(bsdName: String, reason: String) -> VentoyProbeResult {
        VentoyProbeResult(
            bsdName: bsdName,
            isVentoyDisk: false,
            detectedVersion: nil,
            secureBootEnabled: false,
            partitionStyle: .unknown,
            partition2StartSector: 0,
            layoutIssues: [reason],
            looksLikeBrokenVentoy: false
        )
    }
}

/// Detect whether a USB drive has a Ventoy install and, if so, which
/// version. Read-only; never mutates the disk.
///
/// This runs **inside `mactoyd`** because raw `/dev/rdisk*` reads need
/// root. The app calls `HelperInvoker.probeVentoy(bsdName:)` over XPC.
///
/// Future-compat: this implementation makes no version-specific
/// assumptions. Ventoy's on-disk layout has been stable since 1.0.x;
/// the version string is parsed out of `/grub/grub.cfg` regardless of
/// whether it's 1.0.99, 1.1.05, or a hypothetical 2.x — as long as the
/// `set VENTOY_VERSION="X"` line is present and the partition-2 layout
/// markers (start sector 2048 for partition 1, partition 2 size 65536
/// sectors, FAT16 with `VTOYEFI` label) survive. A non-conforming
/// future Ventoy degrades gracefully to "not Ventoy" rather than
/// breaking.
public enum VentoyVersionProbe {

    /// Expected Ventoy partition layout markers. Hardcoded constants —
    /// these have been stable across every Ventoy version since 1.0.0.
    private static let expectedPart1StartSector: UInt64 = 2048
    private static let expectedPart2SizeSectors: UInt64 = 65536  // 32 MiB / 512 B
    private static let expectedPart2Label = "VTOYEFI"
    private static let secureBootByteOffsetA = 92
    private static let secureBootByteOffsetB = 17908

    /// Probe the disk identified by `bsdName` (e.g. `disk6`). Reads only;
    /// safe to call against a mounted disk (the raw read sees whatever
    /// the kernel buffer cache last flushed, which is correct for our
    /// purposes — the user's ISOs are on partition 1, but we only ever
    /// read partition 2 here, plus a handful of bytes of sector 0).
    public static func probe(bsdName: String) -> VentoyProbeResult {
        let rawPath = "/dev/r\(bsdName)"

        let reader: DiskWriter
        do {
            reader = try DiskWriter(rawPath: rawPath, writable: false)
        } catch {
            return .unknownDisk(bsdName: bsdName, reason: "Could not open \(rawPath) for reading: \(error)")
        }
        defer { reader.close() }

        // 1. Read sector 0 (MBR / protective MBR).
        let sector0: Data
        do {
            sector0 = try reader.readSector(lba: 0)
        } catch {
            return .unknownDisk(bsdName: bsdName, reason: "Could not read LBA 0: \(error)")
        }

        // 2. Determine partition style. The protective-MBR partition
        //    entry sits at byte 446; partition type byte 450 == 0xEE
        //    means GPT.
        let partitionStyle: VentoyProbeResult.PartitionStyle
        if sector0.count >= 510 && sector0[450] == 0xEE {
            partitionStyle = .gpt
        } else if sector0.count >= 510 && sector0[510] == 0x55 && sector0[511] == 0xAA {
            partitionStyle = .mbr
        } else {
            return .unknownDisk(bsdName: bsdName, reason: "Sector 0 has no recognisable partition table signature")
        }

        // 3. Locate partition 1 start + partition 2 start/size.
        let part1Start: UInt64
        let part2Start: UInt64
        let part2SizeSectors: UInt64
        do {
            switch partitionStyle {
            case .gpt:
                let partInfo = try locatePartitionsGPT(reader: reader)
                part1Start = partInfo.p1Start
                part2Start = partInfo.p2Start
                part2SizeSectors = partInfo.p2SizeSectors
            case .mbr:
                let partInfo = try locatePartitionsMBR(sector0: sector0)
                part1Start = partInfo.p1Start
                part2Start = partInfo.p2Start
                part2SizeSectors = partInfo.p2SizeSectors
            case .unknown:
                return .unknownDisk(bsdName: bsdName, reason: "Unknown partition style")
            }
        } catch {
            return .unknownDisk(bsdName: bsdName, reason: "Failed to read partition table: \(error)")
        }

        // 4. Layout sniff. Collect every issue rather than bailing on
        //    the first — the UI's "looks like broken Ventoy" path needs
        //    the full list.
        var layoutIssues: [String] = []
        if part1Start != expectedPart1StartSector {
            layoutIssues.append("partition 1 starts at sector \(part1Start), expected \(expectedPart1StartSector)")
        }
        if part2SizeSectors != expectedPart2SizeSectors {
            layoutIssues.append("partition 2 is \(part2SizeSectors) sectors, expected \(expectedPart2SizeSectors)")
        }

        // 5. Try to read partition 2 as FAT16 and pull the volume label.
        //    A non-FAT16 partition 2 is a strong "not Ventoy" signal —
        //    or a corrupt one.
        let p2BaseByteOffset = part2Start * SECTOR_SIZE
        let fatReader: FAT16Reader
        do {
            fatReader = try FAT16Reader { partOffset, length in
                try reader.readBytes(at: p2BaseByteOffset + partOffset, count: length)
            }
        } catch {
            layoutIssues.append("partition 2 is not a FAT16 volume: \(error)")
            return VentoyProbeResult(
                bsdName: bsdName,
                isVentoyDisk: false,
                detectedVersion: nil,
                secureBootEnabled: false,
                partitionStyle: partitionStyle,
                partition2StartSector: part2Start,
                layoutIssues: layoutIssues,
                // Even partial-match the layout? If P1 started at 2048
                // OR P2 was 32 MiB, the geometry suggests a damaged
                // Ventoy attempt rather than a random disk.
                looksLikeBrokenVentoy: looksLikeBrokenIfPartial(part1Start: part1Start, part2Sectors: part2SizeSectors)
            )
        }

        if fatReader.bpb.volumeLabel != expectedPart2Label {
            layoutIssues.append("partition 2 label is '\(fatReader.bpb.volumeLabel)', expected '\(expectedPart2Label)'")
        }

        // 6. Read /grub/grub.cfg and parse out the version.
        var detectedVersion: String?
        do {
            let grubCfg = try fatReader.readFile(at: "/grub/grub.cfg")
            if let str = String(data: grubCfg, encoding: .utf8) {
                detectedVersion = parseVentoyVersion(grubCfg: str)
            }
        } catch {
            layoutIssues.append("could not read /grub/grub.cfg from partition 2: \(error)")
        }

        // 7. Secure-boot flag: read the two single bytes Ventoy stamps
        //    into the legacy-BIOS gap. Values 0x22/0x23 = secure-boot
        //    enabled, 0x20/0x21 = standard.
        var secureBootEnabled = false
        do {
            let sbA = try sectorByte(reader: reader, byteOffset: secureBootByteOffsetA)
            let sbB = try sectorByte(reader: reader, byteOffset: secureBootByteOffsetB)
            // Either pair stamped → secure boot. Be lenient: detect
            // 0x22 OR 0x23 individually rather than requiring both,
            // since older Ventoy versions only used offset 92.
            secureBootEnabled = (sbA == 0x22 || sbB == 0x23)
        } catch {
            // Non-fatal: just leave secureBootEnabled at false.
        }

        let isVentoyDisk = layoutIssues.isEmpty && detectedVersion != nil

        return VentoyProbeResult(
            bsdName: bsdName,
            isVentoyDisk: isVentoyDisk,
            detectedVersion: detectedVersion,
            secureBootEnabled: secureBootEnabled,
            partitionStyle: partitionStyle,
            partition2StartSector: part2Start,
            layoutIssues: layoutIssues,
            looksLikeBrokenVentoy: !isVentoyDisk
                && looksLikeBrokenIfPartial(part1Start: part1Start, part2Sectors: part2SizeSectors)
        )
    }

    // MARK: - Internals

    private static func sectorByte(reader: DiskWriter, byteOffset: Int) throws -> UInt8 {
        let bytes = try reader.readBytes(at: UInt64(byteOffset), count: 1)
        return bytes[0]
    }

    /// Heuristic: does this look like a partial-match Ventoy disk?
    /// Triggers if EITHER partition-1 start OR partition-2 size matches
    /// expected — but the full check failed.
    private static func looksLikeBrokenIfPartial(part1Start: UInt64, part2Sectors: UInt64) -> Bool {
        let oneMatched = (part1Start == expectedPart1StartSector) || (part2Sectors == expectedPart2SizeSectors)
        let allMatched = (part1Start == expectedPart1StartSector) && (part2Sectors == expectedPart2SizeSectors)
        return oneMatched && !allMatched
    }

    /// Extract `set VENTOY_VERSION="x.y.z"` (or single-quoted, or
    /// unquoted) from grub.cfg. Returns nil if the line isn't present.
    public static func parseVentoyVersion(grubCfg: String) -> String? {
        // Tolerant to whitespace and quote variants — Ventoy's own
        // shell-side parser uses `awk -F'"' '{print $2}'`, which only
        // handles double quotes, but ports of Ventoy tooling have been
        // seen using single quotes too. We match either.
        let patterns = [
            #"set\s+VENTOY_VERSION\s*=\s*"([^"]+)""#,
            #"set\s+VENTOY_VERSION\s*=\s*'([^']+)'"#,
            #"set\s+VENTOY_VERSION\s*=\s*([0-9][0-9A-Za-z_.\-]*)"#
        ]
        for pat in patterns {
            if let regex = try? NSRegularExpression(pattern: pat),
               let match = regex.firstMatch(in: grubCfg, range: NSRange(grubCfg.startIndex..., in: grubCfg)),
               match.numberOfRanges >= 2,
               let r = Range(match.range(at: 1), in: grubCfg) {
                return String(grubCfg[r])
            }
        }
        return nil
    }

    // MARK: - GPT partition lookup

    private static func locatePartitionsGPT(reader: DiskWriter) throws
        -> (p1Start: UInt64, p2Start: UInt64, p2SizeSectors: UInt64)
    {
        // GPT primary header is at LBA 1; partition entry array starts
        // at the LBA referenced by header byte offset 72 (UInt64 LE).
        let header = try reader.readSector(lba: 1)
        // Validate signature "EFI PART".
        guard header.count >= 92 else {
            throw DriverError.diskIO("GPT header sector short")
        }
        let signature = header.subdata(in: 0..<8)
        guard signature == Data("EFI PART".utf8) else {
            throw DriverError.diskIO("GPT header has wrong signature")
        }
        let entriesLBA = header.readLE64(at: 72)
        let numEntries = header.readLE32(at: 80)
        let entrySize = header.readLE32(at: 84)
        guard entrySize >= 128, numEntries >= 2 else {
            throw DriverError.diskIO("GPT entry table malformed")
        }

        // Read entries 0 and 1 (partition 1 and partition 2 in
        // 1-indexed user terms).
        let entriesByteOffset = entriesLBA * SECTOR_SIZE
        let entryBytes = try reader.readBytes(at: entriesByteOffset, count: Int(entrySize) * 2)

        let part1Start = entryBytes.readLE64(at: 32)         // first LBA at offset 32
        let part2EntryBase = Int(entrySize)
        let part2Start = entryBytes.readLE64(at: part2EntryBase + 32)
        let part2End = entryBytes.readLE64(at: part2EntryBase + 40)  // last LBA inclusive
        let part2SizeSectors = part2End >= part2Start ? (part2End - part2Start + 1) : 0

        return (p1Start: part1Start, p2Start: part2Start, p2SizeSectors: part2SizeSectors)
    }

    // MARK: - MBR partition lookup

    private static func locatePartitionsMBR(sector0: Data) throws
        -> (p1Start: UInt64, p2Start: UInt64, p2SizeSectors: UInt64)
    {
        // MBR partition entries start at byte 446, 16 bytes each.
        let p1 = sector0.subdata(in: 446..<462)
        let p2 = sector0.subdata(in: 462..<478)
        let p1Start = UInt64(p1.readLE32(at: 8))
        let p2Start = UInt64(p2.readLE32(at: 8))
        let p2SizeSectors = UInt64(p2.readLE32(at: 12))
        return (p1Start: p1Start, p2Start: p2Start, p2SizeSectors: p2SizeSectors)
    }
}

