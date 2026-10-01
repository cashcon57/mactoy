import Testing
import Foundation
import CryptoKit
@testable import MactoyKit

/// MBR-style fresh install (issue #11): layout math, sector 0, CHS
/// encoding, and the bytes `writeFreshLayout` puts on a disk for both
/// partition styles.
@Suite("MBR install")
struct MBRInstallTests {

    // MARK: Layout

    /// `format_ventoy_disk_mbr` / `format_ventoy_disk_gpt` from
    /// `ventoy_lib.sh`, transcribed independently of `VentoyLayout`.
    private func upstream(_ sectors: UInt64, gpt: Bool) -> (p1End: UInt64, p2Start: UInt64, p2End: UInt64) {
        var p1End = sectors - 65536 - (gpt ? 34 : 1)
        var p2Start = p1End + 1
        let mod = p2Start % 8
        if mod > 0 { p1End -= mod; p2Start = p1End + 1 }
        return (p1End, p2Start, p2Start + 65536 - 1)
    }

    @Test("layout matches ventoy_lib.sh for both styles", arguments: [
        UInt64(1_048_576),        // 512 MiB, the minimum Mactoy accepts
        242_147_328,              // 124 GB stick (existing GPT reference)
        250_069_680, 500_118_192, // common 128/256 GB sizes, part2 needs aligning
        3_907_029_168,            // 2 TB drive, still under the MBR limit
        4_294_967_295,            // exactly the MBR maximum
    ])
    func layoutMatchesUpstream(sectors: UInt64) {
        for style in VentoyPartitionStyle.allCases {
            let l = VentoyLayout.calculate(diskSectors: sectors, style: style)
            let u = upstream(sectors, gpt: style == .gpt)
            #expect(l.part1Start == 2048)
            #expect(l.part1End == u.p1End, "\(style) \(sectors)")
            #expect(l.part2Start == u.p2Start, "\(style) \(sectors)")
            #expect(l.part2End == u.p2End, "\(style) \(sectors)")
            #expect(l.part2Start % 8 == 0)
            #expect(l.part2Sectors == VENTOY_EFI_SECTORS)
            #expect(l.part2End <= sectors - 1)
        }
    }

    @Test("GPT layout is unchanged when style is omitted")
    func gptIsDefault() {
        for sectors: UInt64 in [242_147_328, 250_069_680, 3_907_029_168] {
            #expect(VentoyLayout.calculate(diskSectors: sectors) == VentoyLayout.calculate(diskSectors: sectors, style: .gpt))
        }
        // Pinned pre-v0.5.0 values for the 124 GB reference stick.
        let l = VentoyLayout.calculate(diskSectors: 242_147_328)
        #expect(l.part1End == 242_081_751 && l.part2Start == 242_081_752 && l.part2End == 242_147_287)
    }

    // MARK: Style choice

    @Test("recommended style is MBR up to the MBR limit, GPT beyond it")
    func recommended() {
        #expect(VentoyPartitionStyle.recommended(forDiskBytes: 128 * 1_000_000_000) == .mbr)
        #expect(VentoyPartitionStyle.recommended(forDiskBytes: 0xFFFF_FFFF * 512) == .mbr)
        #expect(VentoyPartitionStyle.recommended(forDiskBytes: 0x1_0000_0000 * 512) == .gpt)
        #expect(VentoyPartitionStyle.recommended(forDiskBytes: 4_000_787_030_016) == .gpt)   // "4 TB"
    }

    // MARK: Sector 0

    private func bootImg() -> Data {
        var b = Data((0..<512).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        b[92] = 0x01
        return b
    }

    @Test("sector 0: boot code, two Ventoy entries, empty slots, signature")
    func sector0() throws {
        let sectors: UInt64 = 250_069_680
        let layout = VentoyLayout.calculate(diskSectors: sectors, style: .mbr)
        let s = try MBR.build(bootImg: bootImg(), layout: layout)

        #expect(s.count == 512)
        #expect(s.prefix(446) == bootImg().prefix(446))

        let e1 = s.subdata(in: 446..<462), e2 = s.subdata(in: 462..<478)
        #expect(e1[0] == 0x80)
        #expect(e1[4] == 0x07)
        #expect(e1.readLE32(at: 8) == 2048)
        #expect(UInt64(e1.readLE32(at: 12)) == layout.part1Sectors)
        #expect(e2[0] == 0x00)
        #expect(e2[4] == 0xEF)
        #expect(UInt64(e2.readLE32(at: 8)) == layout.part2Start)
        #expect(e2.readLE32(at: 12) == 65536)
        #expect(UInt64(e1.readLE32(at: 8)) + UInt64(e1.readLE32(at: 12)) == UInt64(e2.readLE32(at: 8)), "partitions are contiguous")
        #expect(s.subdata(in: 478..<510) == Data(repeating: 0, count: 32))
        #expect(s[510] == 0x55 && s[511] == 0xAA)
        // The probe must read this back as MBR, not GPT.
        #expect(s[450] != 0xEE)
    }

    private static let chsCases: [(UInt64, [UInt8])] = [
        (0, [0x00, 0x01, 0x00]),
        (2048, [0x20, 0x21, 0x00]),                  // c0 h32 s33
        (16065, [0x00, 0x01, 0x01]),                 // first sector of cylinder 1
        (16065 * 300, [0x00, 0x41, 0x2C]),           // cylinder 300: high bits into byte 2
        (16065 * 1024 - 1, [0xFE, 0xFF, 0xFF]),      // last addressable: c1023 h254 s63
        (16065 * 1024, [0xFE, 0xFF, 0xFF]),          // beyond: clamped
        (4_000_000_000, [0xFE, 0xFF, 0xFF]),
    ]

    @Test("CHS encoding", arguments: chsCases)
    func chs(lba: UInt64, expected: [UInt8]) {
        #expect(MBR.chs(lba: lba) == expected)
    }

    @Test("a disk past the MBR limit is refused, not truncated")
    func tooLarge() {
        let layout = VentoyLayout.calculate(diskSectors: 0x1_0000_0000 + 4096, style: .mbr)
        #expect(throws: DriverError.self) { _ = try MBR.build(bootImg: bootImg(), layout: layout) }
    }

    @Test("a short boot.img is refused")
    func shortBootImg() {
        let layout = VentoyLayout.calculate(diskSectors: 1_048_576, style: .mbr)
        #expect(throws: DriverError.self) { _ = try MBR.build(bootImg: Data(count: 100), layout: layout) }
    }

    // MARK: Bytes on disk

    private struct NullSink: ProgressSink { func report(_ update: ProgressUpdate) {} }

    /// 512 MiB plus 4 sectors: not a multiple of 8, so partition 2's
    /// alignment leaves a non-empty tail after it in the MBR layout.
    private static let diskSectors: UInt64 = 1_048_580

    private func images() -> VentoyBootImages {
        var core = Data(repeating: 0xC0, count: 2047 * 512)
        core[500] = 0x02
        return VentoyBootImages(bootImg: bootImg(), coreImg: core, diskImg: Data(repeating: 0xD0, count: 65536 * 512))
    }

    /// Run `writeFreshLayout` over a sparse file pre-filled at the ends
    /// with 0xEE, standing in for a used disk.
    private func install(_ style: VentoyPartitionStyle) throws -> (disk: FileHandle, url: URL, layout: VentoyLayout) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-fresh-\(UUID().uuidString).img")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forUpdating: url)
        try h.truncate(atOffset: Self.diskSectors * 512)
        let junk = Data(repeating: 0xEE, count: 4 * 1024 * 1024)
        try h.seek(toOffset: 0); h.write(junk)
        try h.seek(toOffset: Self.diskSectors * 512 - UInt64(junk.count)); h.write(junk)
        try h.close()

        let layout = VentoyLayout.calculate(diskSectors: Self.diskSectors, style: style)
        // Fixed GUIDs so the GPT output is deterministic (see gptGolden).
        let table: VentoyDriver.PartitionTable = switch style {
        case .gpt: .gpt(GPT.build(
            diskSectors: Self.diskSectors, layout: layout,
            diskGUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            part1GUID: UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!,
            part2GUID: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        ))
        case .mbr: .mbr(try MBR.build(bootImg: images().bootImg, layout: layout))
        }
        let writer = try DiskWriter(rawPath: url.path)
        try VentoyDriver.writeFreshLayout(
            writer: writer, boot: images(), diskSectors: Self.diskSectors,
            layout: layout, table: table, progress: NullSink()
        )
        try writer.fsync()
        writer.close()
        return (try FileHandle(forReadingFrom: url), url, layout)
    }

    private func read(_ h: FileHandle, _ offset: UInt64, _ count: Int) throws -> Data {
        try h.seek(toOffset: offset)
        return try h.read(upToCount: count) ?? Data()
    }

    @Test("MBR: table in sector 0, core.img verbatim at LBA 1, no pointer patches, VTOYEFI at part2")
    func mbrBytes() throws {
        let (h, url, layout) = try install(.mbr)
        defer { try? h.close(); try? FileManager.default.removeItem(at: url) }
        let s0 = try read(h, 0, 512)
        let expected = try MBR.build(bootImg: bootImg(), layout: layout)
        // Everything but the per-install UUID (384..<400) and signature (440..<444).
        #expect(s0.prefix(384) == expected.prefix(384))
        #expect(s0.subdata(in: 400..<440) == expected.subdata(in: 400..<440))
        #expect(s0.subdata(in: 444..<512) == expected.subdata(in: 444..<512))
        #expect(s0[92] == 0x01, "boot.img must keep pointing at LBA 1 on MBR")

        #expect(try read(h, 512, 2047 * 512) == images().coreImg, "core.img fills LBA 1...2047 untouched")
        #expect(try read(h, layout.part2Start * 512, 65536 * 512) == images().diskImg)
        // Partition 1's area is left for newfs_exfat.
        #expect(try read(h, 2048 * 512, 512) == Data(repeating: 0xEE, count: 512))
        // Old GPT backup area wiped where VTOYEFI doesn't cover it.
        let tailStart = (layout.part2End + 1) * 512
        let tail = try read(h, tailStart, Int(Self.diskSectors * 512 - tailStart))
        #expect(!tail.isEmpty, "test disk size must leave a tail after partition 2")
        #expect(tail == Data(repeating: 0, count: tail.count))
        // No GPT anywhere it'd be looked for.
        #expect(try read(h, 512, 8) != Data("EFI PART".utf8))
        #expect(try read(h, (Self.diskSectors - 1) * 512, 8) != Data("EFI PART".utf8))
    }

    @Test("GPT: pre-v0.5.0 bytes — protective MBR, both headers, LBA 34 core.img with pointers patched")
    func gptBytes() throws {
        let (h, url, layout) = try install(.gpt)
        defer { try? h.close(); try? FileManager.default.removeItem(at: url) }
        let s0 = try read(h, 0, 512)
        #expect(s0.prefix(92) == bootImg().prefix(92))
        #expect(s0[92] == 0x22)
        #expect(s0[450] == 0xEE)
        #expect(s0[510] == 0x55 && s0[511] == 0xAA)
        #expect(try read(h, 512, 8) == Data("EFI PART".utf8))
        #expect(try read(h, (Self.diskSectors - 1) * 512, 8) == Data("EFI PART".utf8))
        var core = Data(images().coreImg.prefix(2014 * 512))
        core[500] = 0x23
        #expect(try read(h, 34 * 512, 2014 * 512) == core)
        #expect(try read(h, layout.part2Start * 512, 65536 * 512) == images().diskImg)
    }

    /// SHA-256 of the whole GPT test image — every sector, including the
    /// untouched partition 1 area and any gaps — with the per-install
    /// random UUID and signature zeroed. Recorded from this code after
    /// three reviewers confirmed statement by statement that its GPT
    /// branch is v0.4.0's sequence unchanged; it doesn't independently
    /// prove that, it pins it so any later change to a GPT byte fails.
    @Test("GPT output is pinned (golden hash over the whole image)")
    func gptGolden() throws {
        let (h, url, _) = try install(.gpt)
        defer { try? h.close(); try? FileManager.default.removeItem(at: url) }
        var hasher = SHA256()
        var head = try read(h, 0, 512)
        head.replaceSubrange(384..<400, with: Data(count: 16))
        head.replaceSubrange(440..<444, with: Data(count: 4))
        hasher.update(data: head)
        try h.seek(toOffset: 512)
        while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.gptGoldenDigest, "GPT bytes changed: \(digest)")
    }

    @Test("sector-0 read-back check: accepts what was written, ignoring UUID and signature; rejects any other change")
    func mbrSectorCheck() throws {
        let written = try MBR.build(bootImg: bootImg(), layout: VentoyLayout.calculate(diskSectors: Self.diskSectors, style: .mbr))
        var onDisk = written
        onDisk.replaceSubrange(384..<400, with: Data(repeating: 0xAB, count: 16))
        onDisk.replaceSubrange(440..<444, with: Data(repeating: 0xCD, count: 4))
        try VentoyDriver.checkMBRSector(onDisk, matches: written)
        for offset in [0, 92, 383, 400, 439, 444, 446, 450, 466, 510] {
            var bad = onDisk
            bad[offset] ^= 0xFF
            #expect(throws: DriverError.self, "byte \(offset)") { try VentoyDriver.checkMBRSector(bad, matches: written) }
        }
    }

    static let gptGoldenDigest = "aa0c0000425dc0a8a265024b5969c3b150d9082115bf2bcd50f630c4e408eaa5"
}
