import Foundation
import SWCompression

public struct RawImageDriver: InstallDriver {
    public let id: DriverID = .rawImage
    public let displayName: String = "Flash Image"

    public init() {}

    public func execute(plan: InstallPlan, progress: ProgressSink) async throws {
        try plan.validate()
        guard case .localImage(let path) = plan.source else {
            throw DriverError.unsupportedSource("RawImageDriver requires .localImage source")
        }

        // Re-probe the disk inside the privileged helper so we never trust
        // the `isExternal`/`isRemovable` booleans in the plan as authority
        // on our own. A spoofed plan targeting an internal volume is
        // rejected here, not just at the app layer.
        let live = try DiskInfo.probe(bsdName: plan.target.bsdName)
        guard live.isExternal || live.isRemovable else {
            throw PlanValidationError.nonexternalDisk
        }

        let src = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw DriverError.validation("Source image not found: \(path)")
        }

        // Probe + unmount
        progress.report(.init(phase: .preparing, message: "Preparing \(plan.target.devicePath)..."))
        try DiskInfo.unmount(bsdName: plan.target.bsdName)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let writer = try DiskWriter(rawPath: plan.target.rawDevicePath)

        // Decompress on the fly if needed
        let ext = src.pathExtension.lowercased()
        let imageBytes: Data
        switch ext {
        case "xz":
            progress.report(.init(phase: .extracting, message: "Decompressing .xz..."))
            let raw = try Data(contentsOf: src)
            imageBytes = try XZArchive.unarchive(archive: raw)
        case "gz":
            progress.report(.init(phase: .extracting, message: "Decompressing .gz..."))
            let raw = try Data(contentsOf: src)
            imageBytes = try GzipArchive.unarchive(archive: raw)
        default:
            imageBytes = try Data(contentsOf: src, options: .mappedIfSafe)
        }

        let total = UInt64(imageBytes.count)
        guard total <= plan.target.sizeInBytes else {
            throw DriverError.validation("Image (\(total) bytes) larger than target disk (\(plan.target.sizeInBytes) bytes)")
        }

        // Stream write in 4MB chunks with progress
        let chunkSize = 4 * 1024 * 1024
        var offset = 0
        try writer.seek(to: 0)

        progress.report(.init(phase: .writing, message: "Writing image...", bytesDone: 0, bytesTotal: total))
        while offset < imageBytes.count {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, imageBytes.count)
            try writer.write(imageBytes.subdata(in: offset..<end))
            offset = end
            progress.report(.init(
                phase: .writing,
                message: "Writing...",
                bytesDone: UInt64(offset),
                bytesTotal: total
            ))
        }

        try writer.fsync()
        progress.report(.init(phase: .done, message: "Flashed \(src.lastPathComponent) to \(plan.target.devicePath)"))
    }
}
