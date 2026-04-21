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

    /// Given a path to a directory containing an extracted Ventoy release,
    /// load and decompress the three boot images. Ventoy's release layout
    /// has shifted over time — `ventoy.disk.img.xz` used to live at
    /// `boot/ventoy.disk.img.xz` and moved to `ventoy/ventoy.disk.img.xz`
    /// in a recent release. We search both so new and old versions work.
    public static func load(fromVentoyDir ventoyDir: URL) throws -> VentoyBootImages {
        let bootPath = try firstExisting(
            in: ventoyDir,
            candidates: ["boot/boot.img"],
            displayName: "boot.img"
        )
        let corePath = try firstExisting(
            in: ventoyDir,
            candidates: ["boot/core.img.xz", "ventoy/core.img.xz"],
            displayName: "core.img.xz"
        )
        let diskPath = try firstExisting(
            in: ventoyDir,
            candidates: ["ventoy/ventoy.disk.img.xz", "boot/ventoy.disk.img.xz"],
            displayName: "ventoy.disk.img.xz"
        )

        let bootImg = try Data(contentsOf: bootPath)
        let coreXZ = try Data(contentsOf: corePath)
        let diskXZ = try Data(contentsOf: diskPath)

        let coreImg = try XZArchive.unarchive(archive: coreXZ)
        let diskImg = try XZArchive.unarchive(archive: diskXZ)

        return VentoyBootImages(bootImg: bootImg, coreImg: coreImg, diskImg: diskImg)
    }

    private static func firstExisting(
        in dir: URL,
        candidates: [String],
        displayName: String
    ) throws -> URL {
        for rel in candidates {
            let url = dir.appending(path: rel)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let tried = candidates.map { "  - \(dir.appending(path: $0).path)" }.joined(separator: "\n")
        throw DriverError.corruptPayload(
            "missing \(displayName); looked in:\n\(tried)"
        )
    }
}
