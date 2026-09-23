import Testing
import Foundation
import SWCompression
@testable import MactoyKit

/// Exercises `VentoyESP` + the LFN side of `FAT16Reader` against
/// `Fixtures/vtoyefi-mini.img.gz`: a 4 MiB FAT16 volume formatted by
/// `newfs_msdos -F 16 -c 1` and populated through the macOS msdos
/// driver with the same file names Ventoy 1.1.x ships in VTOYEFI
/// (secure-boot layout). File bodies are repeating ASCII tags so a
/// mixed-up cluster chain shows up as a content mismatch. 512-byte
/// clusters make every file, and the /EFI/BOOT directory itself,
/// span several clusters.
@Suite("VentoyESP secure-boot layout conversion")
struct VentoyESPTests {

    // Gunzip in a debug build costs ~2 s a call; do each fixture once.
    private static let fixtures: [String: Data] = {
        var out: [String: Data] = [:]
        for name in ["vtoyefi-mini", "vtoyefi-legacy"] {
            if let url = Bundle.module.resourceURL?.appendingPathComponent("Fixtures/\(name).img.gz"),
               let gz = try? Data(contentsOf: url) {
                out[name] = try? GzipArchive.unarchive(archive: gz)
            }
        }
        return out
    }()

    private func fixture(_ name: String = "vtoyefi-mini") throws -> Data {
        try #require(Self.fixtures[name], "fixture \(name) missing or not gunzippable")
    }

    private func reader(_ image: Data) throws -> FAT16Reader {
        try FAT16Reader { offset, length in
            image.subdata(in: Int(offset)..<(Int(offset) + length))
        }
    }

    private func body(_ tag: String, _ count: Int) -> Data {
        var d = Data()
        while d.count < count { d.append(Data(tag.utf8)) }
        return d.prefix(count)
    }

    /// Raw FAT copy `index`, for allocation accounting.
    private func fat(_ r: FAT16Reader, _ image: Data, copy index: Int) -> Data {
        let size = Int(r.bpb.fatSizeSectors) * 512
        let start = (Int(r.firstFATSector) + index * Int(r.bpb.fatSizeSectors)) * 512
        return image.subdata(in: start..<(start + size))
    }

    private func allocatedClusters(_ fat: Data) -> Int {
        (2..<(fat.count / 2)).filter { fat.readLE16(at: $0 * 2) != 0 }.count
    }

    @Test("long file names resolve, case-insensitively")
    func longNames() throws {
        let r = try reader(fixture())
        #expect(try r.fileExists(at: "/EFI/BOOT/grubx64_real.efi"))
        #expect(try r.fileExists(at: "/efi/boot/GRUBX64_REAL.EFI"))
        #expect(try !r.fileExists(at: "/EFI/BOOT/grubx64.efi"))
        #expect(try !r.fileExists(at: "/EFI/BOOT"))
        #expect(try !r.fileExists(at: "/NOPE/BOOT/x.efi"))
        #expect(try r.readFile(at: "/EFI/BOOT/grubx64_real.efi") == body("REAL-GRUB-X64|", 5300))
        #expect(try r.readFile(at: "/ENROLL_THIS_KEY_IN_MOKMANAGER.cer") == body("CERT|", 1400))
    }

    @Test("pristine image is detected as the secure-boot layout")
    func detectsSecureLayout() throws {
        #expect(try VentoyESP.isSecureBootLayout(reader(fixture())))
        #expect(try VentoyESP.isSecureBootLayout(image: fixture()))
    }

    @Test("conversion matches what `vtoycli partresize -s` leaves behind")
    func conversion() throws {
        var image = try fixture()
        try VentoyESP.disableSecureBoot(in: &image)
        let r = try reader(image)

        #expect(try !VentoyESP.isSecureBootLayout(r))
        #expect(try r.readFile(at: "/EFI/BOOT/BOOTX64.EFI") == body("REAL-GRUB-X64|", 5300))
        #expect(try r.readFile(at: "/EFI/BOOT/BOOTIA32.EFI") == body("REAL-GRUB-IA32|", 3100))

        for gone in ["grubx64_real.efi", "grubia32_real.efi", "grubia32.efi", "mmx64.efi", "mmia32.efi"] {
            #expect(try !r.fileExists(at: "/EFI/BOOT/\(gone)"), "\(gone) should be removed")
        }
        #expect(try !r.fileExists(at: "/ENROLL_THIS_KEY_IN_MOKMANAGER.cer"))

        // Untouched by upstream's -S, so untouched here.
        #expect(try r.readFile(at: "/EFI/BOOT/fbx64.efi") == body("PRELOADER-FB|", 1300))
        #expect(try r.readFile(at: "/grub/grub.cfg") == Data("set VENTOY_VERSION=\"9.9.99\"\n".utf8))

        let names = try r.listDirectory(at: "/EFI/BOOT").filter { !$0.isDirectory }.map(\.name).sorted()
        #expect(names == ["BOOTIA32.EFI", "BOOTX64.EFI", "FBX64.EFI"])
    }

    @Test("freed clusters are released in every FAT copy, nothing else moves")
    func fatAccounting() throws {
        let before = try fixture()
        var after = before
        try VentoyESP.disableSecureBoot(in: &after)
        let rb = try reader(before), ra = try reader(after)

        // 512-byte clusters: shim 2900→6, shim32 1700→4, grubia32 900→2,
        // mmx64 1100→3, mmia32 1000→2, cert 1400→3.
        let freed = 6 + 4 + 2 + 3 + 2 + 3
        #expect(allocatedClusters(fat(ra, after, copy: 0)) == allocatedClusters(fat(rb, before, copy: 0)) - freed)
        #expect(rb.bpb.numFATs == 2)
        #expect(fat(ra, after, copy: 0) == fat(ra, after, copy: 1))

        // Data region is byte-identical: the conversion only edits
        // directory slots and FAT entries.
        let bootDirRanges = try rb.directoryByteRanges(at: "/EFI/BOOT")
        var expected = before
        for range in bootDirRanges { expected.replaceSubrange(range, with: after.subdata(in: range)) }
        let dataStart = Int(rb.firstDataSector) * 512
        #expect(after.suffix(from: dataStart) == expected.suffix(from: dataStart))
    }

    @Test("an image that's already plain is rejected, not silently re-processed")
    func rejectsPlainImage() throws {
        var image = try fixture()
        try VentoyESP.disableSecureBoot(in: &image)
        let once = image
        #expect(throws: DriverError.self) { try VentoyESP.disableSecureBoot(in: &image) }
        #expect(image == once)
    }

    @Test("works on a Data slice with a non-zero startIndex")
    func slicedInput() throws {
        var padded = Data(repeating: 0xAA, count: 7)
        padded.append(try fixture())
        var slice = padded.dropFirst(7)
        try VentoyESP.disableSecureBoot(in: &slice)
        #expect(try reader(Data(slice)).fileExists(at: "/EFI/BOOT/BOOTX64.EFI"))
    }

    /// `Fixtures/vtoyefi-legacy.img.gz`: the pre-1.1 shape — x64 only,
    /// preloader named `grubx64.efi`, `MokManager.efi`, no certificate,
    /// plus a zero-length file (firstCluster 0) in the same directory.
    @Test("older layout: grubx64.efi + MokManager.efi removed, ia32 absent is fine, empty file survives")
    func legacyLayout() throws {
        let before = try fixture("vtoyefi-legacy")
        var image = before
        try VentoyESP.disableSecureBoot(in: &image)
        let r = try reader(image)

        #expect(try r.readFile(at: "/EFI/BOOT/BOOTX64.EFI") == body("REAL-GRUB-X64|", 5300))
        let names = try r.listDirectory(at: "/EFI/BOOT").filter { !$0.isDirectory }.map(\.name).sorted()
        #expect(names.count == 2)
        #expect(names.contains("BOOTX64.EFI"))
        #expect(try r.fileExists(at: "/EFI/BOOT/empty_marker_file.txt"))
        #expect(try !r.fileExists(at: "/EFI/BOOT/BOOTIA32.EFI"))

        // shim 2900→6, preloader 1300→3, MokManager 1100→3
        let rb = try reader(before)
        #expect(allocatedClusters(fat(r, image, copy: 0)) == allocatedClusters(fat(rb, before, copy: 0)) - 12)
        #expect(fat(r, image, copy: 0) == fat(r, image, copy: 1))
    }

    @Test("a FAT chain pointing outside the volume is an error, not a wild write")
    func corruptChainRejected() throws {
        var image = try fixture()
        let r = try reader(image)
        let shim = try #require(try r.listDirectory(at: "/EFI/BOOT").first { $0.name == "BOOTX64.EFI" })
        // Point the shim's first cluster at 0xFFF0: in the "valid
        // cluster" numeric range, far past this 8k-cluster volume.
        for offset in r.fatEntryByteOffsets(cluster: shim.firstCluster) {
            image[offset] = 0xF0; image[offset + 1] = 0xFF
        }
        let corrupted = image
        #expect(throws: DriverError.self) { try VentoyESP.disableSecureBoot(in: &image) }
        #expect(image == corrupted, "nothing may be written when the chain walk fails")
    }

    @Test("a volume with too few clusters to be FAT16 is refused")
    func fat12Refused() throws {
        var image = try fixture()
        // totSec16 at BPB offset 19: shrink the volume to 2000 sectors.
        image[19] = 0xD0; image[20] = 0x07
        #expect(throws: DriverError.self) { _ = try reader(image) }
    }

    @Test("orphaned LFN slots (checksum mismatch) don't attach to the next short entry")
    func orphanLFNIgnored() throws {
        var image = try fixture()
        let r = try reader(image)
        let entry = try #require(try r.listDirectory(at: "/EFI/BOOT").first { $0.longName == "grubx64_real.efi" })
        // Break the checksum byte (offset 13) in each of its LFN slots.
        var blob = Data()
        let ranges = try r.directoryByteRanges(at: "/EFI/BOOT")
        for range in ranges { blob.append(image.subdata(in: range)) }
        for slot in entry.slots.dropLast() { blob[slot * 32 + 13] ^= 0xFF }
        var cursor = 0
        for range in ranges {
            image.replaceSubrange(range, with: blob.subdata(in: cursor..<(cursor + range.count)))
            cursor += range.count
        }
        let after = try reader(image)
        #expect(try !after.fileExists(at: "/EFI/BOOT/grubx64_real.efi"))
        // Still reachable by its 8.3 alias.
        #expect(try after.fileExists(at: "/EFI/BOOT/\(entry.name)"))
    }

    /// Opt-in check against a real decompressed `ventoy.disk.img`:
    ///   MACTOY_REAL_VTOYEFI_IMG=/path/to/disk.img swift test --filter realImage
    /// Writes `<path>.plain` so the result can be fsck'd and mounted.
    @Test("real Ventoy image converts cleanly",
          .enabled(if: ProcessInfo.processInfo.environment["MACTOY_REAL_VTOYEFI_IMG"] != nil))
    func realImage() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MACTOY_REAL_VTOYEFI_IMG"])
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        var image = original
        try VentoyESP.disableSecureBoot(in: &image)
        let grub = try reader(original).readFile(at: "/EFI/BOOT/grubx64_real.efi")
        #expect(try reader(image).readFile(at: "/EFI/BOOT/BOOTX64.EFI") == grub)
        try image.write(to: URL(fileURLWithPath: path + ".plain"))
    }
}
