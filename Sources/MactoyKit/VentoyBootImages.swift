import Foundation
import SWCompression

/// Loads the three boot images (boot.img, core.img, ventoy.disk.img) from
/// an extracted Ventoy linux release tarball directory.
public struct VentoyBootImages: Sendable {
    public let bootImg: Data          // 512 bytes
    public let coreImg: Data          // ~1MB decompressed
    public let diskImg: Data          // 32MB decompressed (VTOYEFI partition)

    public init(bootImg: Data, coreImg: Data, diskImg: Data) {
        self.bootImg = bootImg
        self.coreImg = coreImg
        self.diskImg = diskImg
    }

    /// Given a path to a directory containing `ventoy/boot/*`, load and
    /// decompress the three boot images.
    public static func load(fromVentoyDir ventoyDir: URL) throws -> VentoyBootImages {
        let bootPath = ventoyDir.appending(path: "boot/boot.img")
        let corePath = ventoyDir.appending(path: "boot/core.img.xz")
        let diskPath = ventoyDir.appending(path: "boot/ventoy.disk.img.xz")

        guard FileManager.default.fileExists(atPath: bootPath.path) else {
            throw DriverError.corruptPayload("missing boot.img at \(bootPath.path)")
        }
        guard FileManager.default.fileExists(atPath: corePath.path) else {
            throw DriverError.corruptPayload("missing core.img.xz at \(corePath.path)")
        }
        guard FileManager.default.fileExists(atPath: diskPath.path) else {
            throw DriverError.corruptPayload("missing ventoy.disk.img.xz at \(diskPath.path)")
        }

        let bootImg = try Data(contentsOf: bootPath)
        let coreXZ = try Data(contentsOf: corePath)
        let diskXZ = try Data(contentsOf: diskPath)

        let coreImg = try XZArchive.unarchive(archive: coreXZ)
        let diskImg = try XZArchive.unarchive(archive: diskXZ)

        return VentoyBootImages(bootImg: bootImg, coreImg: coreImg, diskImg: diskImg)
    }
}
