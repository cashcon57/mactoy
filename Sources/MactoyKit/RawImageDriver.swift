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
        // Layer 5 of the iron-clad targeting defense (v0.3.1, issue #1):
        // verify the live disk's fingerprint matches the captured
        // target. If a USB hub re-enumerated between confirmation and
        // execution and /dev/<bsd> now points at a different physical
        // drive, refuse to write rather than silently flash the wrong
        // device.
        if let mismatch = plan.target.fingerprintMismatch(against: live) {
            throw DriverError.validation(
                "Refusing to flash \(plan.target.devicePath): the live disk does not match the disk you confirmed. \(mismatch)"
            )
        }
        guard live.isExternal || live.isRemovable else {
            throw PlanValidationError.nonexternalDisk
        }

        let src = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw DriverError.validation("Source image not found: \(path)")
        }

        // Probe + unmount
        progress.report(.init(phase: .preparing, message: "Preparing \(plan.target.devicePath)..."))
        // Just-in-time fingerprint re-check immediately before unmount
        // (v0.3.1 issue #1). Cheap, closes the small window between
        // the early probe at the top of execute() and the unmount/open.
        try plan.target.reverifyFingerprintNow()
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

        // **Final fingerprint re-check immediately before the write
        // loop (v0.3.1 issue #1).** Decompression of a multi-GB
        // .xz/.gz can take tens of seconds; that's the longest TOCTOU
        // window in the install pipeline. If a USB-hub reshuffle
        // landed a different drive at /dev/<bsdName> while we were
        // decompressing, abort here rather than write the user's
        // bytes to the wrong device.
        try plan.target.reverifyFingerprintNow()

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
        // Release the raw-disk fd so macOS can re-probe the newly
        // written image. The kernel refuses to re-scan a disk that
        // still has an open writer — same root-cause as the Ventoy
        // driver's post-install format stall before v0.1.3.
        writer.close()

        progress.report(.init(phase: .formatting, message: "Asking macOS to re-read the partition table…"))
        _ = try? Subprocess.run("/usr/sbin/diskutil", ["reloadDisk", "/dev/\(plan.target.bsdName)"])
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        // Attempt to mount whatever's on the flashed image. Silent on
        // failure — some images (pure raw partitions, non-macOS
        // filesystems) won't mount without extra drivers and that's OK.
        _ = try? Subprocess.run("/usr/sbin/diskutil", ["mountDisk", "/dev/\(plan.target.bsdName)"])

        progress.report(.init(phase: .done, message: "Flashed \(src.lastPathComponent) to \(plan.target.devicePath)"))
    }
}
