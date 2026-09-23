import Testing
import Foundation
@testable import MactoyKit

/// `VentoyDriver.writeBootloaderUpdate` against a plain file standing in
/// for the disk. Covers the v0.3.x bug where bytes 92 and 17908 — GRUB's
/// pointers to core.img, which Ventoy patches on GPT only — were
/// rewritten on MBR sticks as though they were a secure-boot flag.
@Suite("Update Ventoy: bytes written (MBR vs GPT)")
struct VentoyUpdateWriteTests {

    private struct NullSink: ProgressSink { func report(_ update: ProgressUpdate) {} }

    private static let part2Start: UInt64 = 4096
    private static let diskBytes = Int(part2Start) * 512 + 64 * 1024

    /// Recognisable stand-ins: boot.img byte 92 is 0x01 and core.img
    /// byte 500 is 0x02, as in the real images (LBA 1 / LBA 2).
    private func bootImages() -> VentoyBootImages {
        var bootImg = Data(repeating: 0xB0, count: 512)
        bootImg[92] = 0x01
        var coreImg = Data(repeating: 0xC0, count: 2047 * 512)
        coreImg[500] = 0x02
        return VentoyBootImages(bootImg: bootImg, coreImg: coreImg, diskImg: Data(repeating: 0xD0, count: 64 * 1024))
    }

    /// A "disk" pre-filled with 0xEE so untouched regions are visible.
    private func run(style: VentoyProbeResult.PartitionStyle) throws -> (before: Data, after: Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-update-\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: url) }
        let before = Data(repeating: 0xEE, count: Self.diskBytes)
        try before.write(to: url)

        let writer = try DiskWriter(rawPath: url.path)
        try VentoyDriver.writeBootloaderUpdate(
            writer: writer,
            boot: bootImages(),
            partitionStyle: style,
            partition2StartSector: Self.part2Start,
            progress: NullSink()
        )
        try writer.fsync()
        writer.close()
        return (before, try Data(contentsOf: url))
    }

    @Test("MBR: boot.img and core.img land verbatim — no pointer bytes stamped")
    func mbr() throws {
        let (_, disk) = try run(style: .mbr)
        let boot = bootImages()
        #expect(disk[92] == 0x01, "boot.img's core.img pointer must stay LBA 1 (v0.3.x wrote 0x20)")
        // 384..<400 is the preserved disk UUID, checked in `preserved`.
        #expect(disk.subdata(in: 0..<384) == boot.bootImg.prefix(384))
        #expect(disk.subdata(in: 400..<440) == boot.bootImg.subdata(in: 400..<440))
        // core.img starts at LBA 1; all of it that precedes the
        // reserved sectors must be exactly core.img (v0.3.x wrote 0x21
        // over disk byte 17908, which is inside this range).
        let coreOnDisk = disk.subdata(in: 512..<(2040 * 512))
        #expect(coreOnDisk == boot.coreImg.prefix(2039 * 512))
        #expect(disk[17908] == 0xC0)
    }

    @Test("GPT: both pointers re-stamped to LBA 34 / LBA 35")
    func gpt() throws {
        let (_, disk) = try run(style: .gpt)
        #expect(disk[92] == 0x22)
        #expect(disk[17908] == 0x23)
        // Primary GPT header + entries (LBA 1..33) are not the update's to touch.
        #expect(disk.subdata(in: 512..<(34 * 512)) == Data(repeating: 0xEE, count: 33 * 512))
        // core.img at LBA 34, apart from the one stamped byte.
        var expected = Data(bootImages().coreImg.prefix((2040 - 34) * 512))
        expected[500] = 0x23
        #expect(disk.subdata(in: (34 * 512)..<(2040 * 512)) == expected)
    }

    @Test("both styles: UUID, partition table, reserved sectors and partition 1 survive; VTOYEFI is replaced",
          arguments: [VentoyProbeResult.PartitionStyle.mbr, .gpt])
    func preserved(style: VentoyProbeResult.PartitionStyle) throws {
        let (before, disk) = try run(style: style)
        #expect(disk.subdata(in: 440..<512) == before.subdata(in: 440..<512))
        #expect(disk.subdata(in: 384..<400) == before.subdata(in: 384..<400))
        #expect(disk.subdata(in: (2040 * 512)..<(2048 * 512)) == before.subdata(in: (2040 * 512)..<(2048 * 512)))
        let p2 = Int(Self.part2Start) * 512
        #expect(disk.subdata(in: (2048 * 512)..<p2) == before.subdata(in: (2048 * 512)..<p2))
        #expect(disk.subdata(in: p2..<disk.count) == Data(repeating: 0xD0, count: 64 * 1024))
    }

    @Test("unknown partition style writes nothing")
    func unknownStyle() throws {
        #expect(throws: DriverError.self) { _ = try run(style: .unknown) }
    }
}
