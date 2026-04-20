import Foundation

public let SECTOR_SIZE: UInt64 = 512
public let VENTOY_EFI_SECTORS: UInt64 = 65536 // 32 MiB FAT EFI partition

public struct VentoyLayout: Sendable, Equatable {
    public let diskSectors: UInt64
    public let part1Start: UInt64
    public let part1End: UInt64
    public let part2Start: UInt64
    public let part2End: UInt64

    public var part1Sectors: UInt64 { part1End - part1Start + 1 }
    public var part2Sectors: UInt64 { part2End - part2Start + 1 }

    public static func calculate(diskSectors: UInt64) -> VentoyLayout {
        let part1Start: UInt64 = 2048
        var part1End: UInt64 = diskSectors - VENTOY_EFI_SECTORS - 34
        var part2Start: UInt64 = part1End + 1

        let mod = part2Start % 8
        if mod > 0 {
            part1End -= mod
            part2Start = part1End + 1
        }

        let part2End = part2Start + VENTOY_EFI_SECTORS - 1
        return VentoyLayout(
            diskSectors: diskSectors,
            part1Start: part1Start,
            part1End: part1End,
            part2Start: part2Start,
            part2End: part2End
        )
    }
}
