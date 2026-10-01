import Foundation

/// Sector 0 for an MBR-style Ventoy install (issue #11).
///
/// Matches what Ventoy2Disk writes in its default (non-GPT) mode:
/// partition 1 is the data partition, active, type 0x07 (exFAT/NTFS);
/// partition 2 is VTOYEFI, inactive, type 0xEF (EFI System). See
/// `VentoyFillMBR` in `Ventoy2Disk/Ventoy2Disk/Utility.c` and
/// `format_ventoy_disk_mbr` in `INSTALL/tool/ventoy_lib.sh`.
public enum MBR {

    /// Partition type bytes, as Ventoy2Disk uses them.
    public static let dataPartitionType: UInt8 = 0x07
    public static let efiPartitionType: UInt8 = 0xEF

    /// Build the 512-byte sector: `boot.img`'s first 446 bytes (boot code,
    /// including the areas the driver later overwrites with the Ventoy
    /// disk UUID at 384 and the disk signature at 440), the two partition
    /// entries, two empty entries, and the 0x55AA signature.
    public static func build(bootImg: Data, layout: VentoyLayout) throws -> Data {
        guard bootImg.count >= 446 else {
            throw DriverError.corruptPayload("boot.img is \(bootImg.count) bytes, expected at least 446")
        }
        // Same rule as `InstallPlan.validate()`, so the two can't disagree.
        guard layout.diskSectors <= VentoyPartitionStyle.mbrMaxSectors else {
            throw DriverError.validation(
                "Disk is too large for an MBR partition table (\(layout.diskSectors) sectors). Use GPT."
            )
        }

        var sector = Data(bootImg.prefix(446))
        sector.append(entry(
            active: true,
            type: dataPartitionType,
            start: layout.part1Start,
            sectors: layout.part1Sectors
        ))
        sector.append(entry(
            active: false,
            type: efiPartitionType,
            start: layout.part2Start,
            sectors: layout.part2Sectors
        ))
        sector.append(Data(repeating: 0, count: 32))
        sector.append(contentsOf: [0x55, 0xAA])
        precondition(sector.count == Int(SECTOR_SIZE))
        return sector
    }

    /// One 16-byte partition entry.
    static func entry(active: Bool, type: UInt8, start: UInt64, sectors: UInt64) -> Data {
        var e = Data()
        e.append(active ? 0x80 : 0x00)
        e.append(contentsOf: chs(lba: start))
        e.append(type)
        e.append(contentsOf: chs(lba: start + sectors - 1))
        e.append(uint32LE(UInt32(start)))
        e.append(uint32LE(UInt32(sectors)))
        return e
    }

    /// Standard 3-byte CHS address for `lba`, using the conventional
    /// 255-head, 63-sector geometry, clamped to 1023/254/63 past the
    /// 1024th cylinder (about 8 GB) as parted and fdisk do. Firmware that
    /// boots by LBA ignores these bytes; the clamp keeps them valid for
    /// any that checks them.
    ///
    /// Ventoy2Disk.exe computes these differently: it doubles the head
    /// count with disk size and packs the cylinder into a C bitfield,
    /// which puts the cylinder's bits in non-standard positions and wraps
    /// it at 1024 rather than clamping. `Ventoy2Disk.sh` delegates to
    /// parted/fdisk, which write the standard form used here. GRUB's
    /// `boot.img` finds `core.img` by its own sector pointer, never
    /// through these fields.
    static func chs(lba: UInt64) -> [UInt8] {
        let heads: UInt64 = 255, sectorsPerTrack: UInt64 = 63
        let cylinder = lba / (heads * sectorsPerTrack)
        guard cylinder <= 1023 else { return [0xFE, 0xFF, 0xFF] }
        let head = (lba / sectorsPerTrack) % heads
        let sector = lba % sectorsPerTrack + 1
        return [
            UInt8(head),
            UInt8(sector) | UInt8((cylinder >> 8) & 0x03) << 6,
            UInt8(cylinder & 0xFF),
        ]
    }
}
