import Foundation

/// Secure-boot layout handling for Ventoy's 32 MiB VTOYEFI image.
///
/// `ventoy.disk.img` ships in the secure-boot layout: `BOOTX64.EFI` is
/// the UEFI shim, which chains (via `fbx64.efi` / `grubx64.efi`,
/// depending on Ventoy version) into the real GRUB at
/// `grubx64_real.efi`. Ventoy2Disk's `-S` option converts that to the
/// plain layout, where `BOOTX64.EFI` *is* GRUB and the shim, MokManager
/// and enrolment certificate are gone. Firmware the shim doesn't cope
/// with needs the plain layout — issue #9 reports a 2011 iMac (Apple
/// EFI) freezing in the shim with no output.
///
/// Upstream does the conversion on the written disk through
/// `vtoycli partresize -s` (`secureboot_proc` in `vtoycli/partresize.c`).
/// Mactoy does it on the decompressed image in memory, before a single
/// byte reaches the disk, so there is no mount and no window where the
/// stick holds a half-converted ESP.
public enum VentoyESP {

    private struct Arch {
        let bootShortName: String   // 11-byte space-padded 8.3 form
        let bootName: String
        let realName: String
        let removals: [String]
        let required: Bool
    }

    // File lists match `secureboot_proc` one for one.
    private static let arches = [
        Arch(
            bootShortName: "BOOTX64 EFI",
            bootName: "BOOTX64.EFI",
            realName: "grubx64_real.efi",
            removals: ["BOOTX64.EFI", "grubx64.efi", "MokManager.efi", "mmx64.efi"],
            required: true
        ),
        Arch(
            bootShortName: "BOOTIA32EFI",
            bootName: "BOOTIA32.EFI",
            realName: "grubia32_real.efi",
            removals: ["BOOTIA32.EFI", "grubia32.efi", "mmia32.efi"],
            required: false
        ),
    ]
    private static let bootDir = "/EFI/BOOT"
    private static let enrolmentCert = "ENROLL_THIS_KEY_IN_MOKMANAGER.cer"

    /// Same test upstream uses (`check_secure_boot` in
    /// `vtoycli/vtoyfat.c`): the secure-boot layout is the one that
    /// still has `grubx64_real.efi`. The `-S` conversion renames it
    /// away.
    public static func isSecureBootLayout(_ reader: FAT16Reader) throws -> Bool {
        try reader.fileExists(at: "\(bootDir)/grubx64_real.efi")
    }

    /// Same, for a whole VTOYEFI image held in memory.
    public static func isSecureBootLayout(image: Data) throws -> Bool {
        try isSecureBootLayout(makeReader(over: image))
    }

    /// Bounds-checked reader: a corrupt BPB must surface as a thrown
    /// error, not as a `Data` range trap inside the root daemon.
    private static func makeReader(over image: Data) throws -> FAT16Reader {
        let image = image.startIndex == 0 ? image : Data(image)
        return try FAT16Reader { offset, length in
            guard offset <= UInt64(image.count), length >= 0, Int(offset) + length <= image.count else {
                throw DriverError.corruptPayload("VTOYEFI image: read past end (\(offset)+\(length) of \(image.count))")
            }
            return image.subdata(in: Int(offset)..<(Int(offset) + length))
        }
    }

    /// Convert a secure-boot-layout VTOYEFI image to the plain layout.
    ///
    /// Rather than copy GRUB's bytes into a new file the way upstream
    /// does, this renames `grubx64_real.efi`'s directory entry to
    /// `BOOTX64.EFI` after deleting the shim — same resulting
    /// filesystem, no cluster allocation needed.
    public static func disableSecureBoot(in image: inout Data) throws {
        if image.startIndex != 0 { image = Data(image) }
        let snapshot = image
        let reader = try makeReader(over: snapshot)

        guard try isSecureBootLayout(reader) else {
            throw DriverError.corruptPayload(
                "Can't turn off Secure Boot support: this Ventoy release's EFI image has no \(bootDir)/grubx64_real.efi, " +
                "so its layout isn't one Mactoy knows how to convert. Install with Secure Boot support turned on instead."
            )
        }

        var freedClusters: [UInt16] = []

        // /EFI/BOOT
        var boot = try DirectoryBlob(reader: reader, image: snapshot, path: bootDir)
        for arch in arches {
            guard let real = boot.entry(named: arch.realName) else {
                if arch.required {
                    throw DriverError.corruptPayload("VTOYEFI image: \(arch.realName) vanished mid-conversion")
                }
                continue
            }
            for name in arch.removals {
                guard let entry = boot.entry(named: name) else { continue }
                freedClusters += try reader.clusterChain(from: entry.firstCluster)
                boot.delete(entry)
            }
            boot.rename(real, toShortName: arch.bootShortName)
        }
        boot.write(to: &image)

        // Root: the MOK enrolment certificate.
        var root = try DirectoryBlob(reader: reader, image: snapshot, path: "/")
        if let cert = root.entry(named: enrolmentCert) {
            freedClusters += try reader.clusterChain(from: cert.firstCluster)
            root.delete(cert)
        }
        root.write(to: &image)

        for cluster in freedClusters {
            for offset in reader.fatEntryByteOffsets(cluster: cluster) {
                image[offset] = 0
                image[offset + 1] = 0
            }
        }

        try verifyPlainLayout(image: image, against: snapshot, reader: reader)
    }

    /// Re-parse the converted image and confirm each boot file now
    /// holds exactly the bytes its `_real` counterpart held. Catches a
    /// conversion bug here, as an install error, instead of as a stick
    /// that won't boot.
    private static func verifyPlainLayout(image: Data, against original: Data, reader before: FAT16Reader) throws {
        let after = try makeReader(over: image)
        guard try !isSecureBootLayout(after) else {
            throw DriverError.corruptPayload("VTOYEFI conversion failed: grubx64_real.efi is still present")
        }
        for arch in arches {
            guard let expected = try? before.readFile(at: "\(bootDir)/\(arch.realName)") else { continue }
            let got = try after.readFile(at: "\(bootDir)/\(arch.bootName)")
            guard got == expected else {
                throw DriverError.corruptPayload("VTOYEFI conversion failed: \(arch.bootName) doesn't match \(arch.realName)")
            }
        }
    }

    /// A directory's raw 32-byte slots, pulled out of the image so they
    /// can be edited contiguously and written back to the (possibly
    /// non-contiguous) clusters they came from.
    private struct DirectoryBlob {
        private let ranges: [Range<Int>]
        private var bytes: Data
        private let entries: [FAT16Reader.DirEntry]

        init(reader: FAT16Reader, image: Data, path: String) throws {
            ranges = try reader.directoryByteRanges(at: path)
            entries = try reader.listDirectory(at: path)
            var bytes = Data()
            for range in ranges { bytes.append(image.subdata(in: range)) }
            self.bytes = bytes
        }

        func entry(named name: String) -> FAT16Reader.DirEntry? {
            entries.first { !$0.isDirectory && $0.matches(name83: name) }
        }

        /// Mark the entry's short slot and any LFN slots deleted.
        mutating func delete(_ entry: FAT16Reader.DirEntry) {
            for slot in entry.slots { bytes[slot * 32] = 0xE5 }
        }

        /// Give the entry a new 8.3 name and drop its long name.
        mutating func rename(_ entry: FAT16Reader.DirEntry, toShortName shortName: String) {
            precondition(shortName.utf8.count == 11)
            let shortSlot = entry.slots.upperBound - 1
            for slot in entry.slots where slot != shortSlot { bytes[slot * 32] = 0xE5 }
            let base = shortSlot * 32
            bytes.replaceSubrange(base..<(base + 11), with: Data(shortName.utf8))
            // Byte 12 holds the "stored lowercase" flags for the old
            // name; clear them so the new name reads back as written.
            bytes[base + 12] = 0
        }

        func write(to image: inout Data) {
            var cursor = 0
            for range in ranges {
                image.replaceSubrange(range, with: bytes.subdata(in: cursor..<(cursor + range.count)))
                cursor += range.count
            }
        }
    }
}
