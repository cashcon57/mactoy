import CryptoKit
import Foundation

/// Flash image: writes an image file, decompressed as it goes, to a whole drive.
///
/// Order matters. Everything that can fail without touching the drive runs first: the plan and
/// fingerprint checks, the user's SHA-256 (#26), opening the image and decoding its first chunk,
/// and its size where that's known up front (#20). Only then is the drive unmounted and written.
/// Afterwards the drive is read back and compared with what was written (#26).
public struct RawImageDriver: InstallDriver {
    public let id: DriverID = .rawImage
    public let displayName: String = "Flash Image"

    /// The image, already opened by the app with the user's own permissions (#36). The helper
    /// runs as root, so it must never open a path the app sent. nil only where the caller is
    /// the user (tests, `scripts/e2e`): then the plan's path is opened here.
    private let image: FileHandle?
    /// Lets the user stop the run at any point (#21). The app asks first once writing has begun.
    private let control: RunControl

    public init(image: FileHandle? = nil, control: RunControl = RunControl()) {
        self.image = image
        self.control = control
    }

    static let stoppedBeforeWriting = "Cancelled. Nothing was written to the drive."
    static let stoppedWhileWriting = "Stopped while writing. The drive is only partly written and won't start until you flash it or install Ventoy on it again."
    static let stoppedWhileChecking = "Stopped while checking. The image was written in full, but Mactoy didn't finish reading it back."


    public func execute(plan: InstallPlan, progress: ProgressSink) async throws {
        try plan.validate()
        guard case .localImage(let path) = plan.source else {
            throw DriverError.unsupportedSource("RawImageDriver requires .localImage source")
        }
        let name = URL(fileURLWithPath: path).lastPathComponent

        // Re-probe the disk here so we never trust the plan's `isExternal`/`isRemovable` on
        // their own, and check it's still the disk the user confirmed (v0.3.1, issue #1).
        let live = try DiskInfo.probe(bsdName: plan.target.bsdName)
        if let mismatch = plan.target.fingerprintMismatch(against: live) {
            throw DriverError.validation(
                "Refusing to flash \(plan.target.devicePath): the live disk does not match the disk you confirmed. \(mismatch)"
            )
        }
        guard live.isExternal || live.isRemovable else {
            throw PlanValidationError.nonexternalDisk
        }

        // As root, only ever the handle the app opened (#36); opening `path` here would read it
        // with root's permissions.
        guard image != nil || geteuid() != 0 else {
            throw DriverError.validation("Mactoy didn't hand over the image file, so nothing was written.")
        }
        let handle = try image ?? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        try Self.requireRegularFile(handle, name: name)

        let format = ImageFormat(path: path)

        // 1. The user's checksum, before anything is erased.
        if let expected = plan.expectedImageSHA256 {
            let actual = try await Self.sha256(of: handle, name: name, progress: progress, control: control)
            guard actual == expected else {
                throw DriverError.validation(
                    "\(name) doesn't match the SHA-256 you entered, so nothing was written. " +
                    "Expected \(expected), got \(actual). The download may be incomplete or damaged; download it again." +
                    (format == .raw ? "" : " If that SHA-256 is for the unpacked image, use the one for the file you downloaded.")
                )
            }
            try handle.seek(toOffset: 0)
        }

        // 2. Can we read it, and does it fit? Decoding the first chunk now means a file Mactoy
        //    can't read never costs the user their drive.
        try handle.seek(toOffset: 0)
        let reader = try ImageReader(handle: handle, format: format)
        if format != .raw {
            progress.report(.init(phase: .preparing, message: "Checking that \(name) can be decompressed..."))
        }
        let firstChunk: Data?
        do {
            firstChunk = try reader.next()
        } catch DriverError.corruptPayload(let problem) {
            throw DriverError.corruptPayload("\(problem) Nothing was written.")
        }
        guard let first = firstChunk else {
            throw DriverError.validation("\(name) is empty. Nothing was written.")
        }
        // After the first chunk, so a file that isn't really .xz fails fast instead of having
        // its end scanned. imageSize puts the handle back where the reader left it.
        let knownSize = ImageReader.imageSize(of: handle, format: format)
        if let knownSize, knownSize > plan.target.sizeInBytes {
            throw DriverError.validation(
                "\(name) is \(Self.size(knownSize)) once decompressed, larger than the drive (\(Self.size(plan.target.sizeInBytes))). Nothing was written."
            )
        }
        let compressedSize = Self.fileSize(of: handle)

        // 3. Unmount and write.
        try control.check(Self.stoppedBeforeWriting)
        progress.report(.init(phase: .preparing, message: "Preparing \(plan.target.devicePath)..."))
        try plan.target.reverifyFingerprintNow()
        try DiskInfo.unmount(bsdName: plan.target.bsdName)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let writer = try DiskWriter(rawPath: plan.target.rawDevicePath)
        defer { writer.close() }
        // Last check right before the first write.
        try plan.target.reverifyFingerprintNow()

        var hasher = SHA256()
        var written: UInt64 = 0          // image bytes, without the padding of a final partial sector
        var lastReport = Date.distantPast
        try writer.seek(to: 0)
        progress.report(.init(phase: .writing, message: "Writing \(name)...", bytesDone: 0, bytesTotal: knownSize ?? compressedSize))

        try control.check(Self.stoppedBeforeWriting)
        var chunk: Data? = first
        while let data = chunk {
            try control.check(Self.stoppedWhileWriting)
            let padded = Self.paddedToBlock(data, roomLeft: plan.target.sizeInBytes - written)
            guard written + UInt64(padded.count) <= plan.target.sizeInBytes else {
                throw DriverError.validation(
                    "\(name) is larger than the drive (\(Self.size(plan.target.sizeInBytes))). The drive was written up to its end and won't start; flash a smaller image or use a bigger drive."
                )
            }
            try writer.write(padded)
            hasher.update(data: data)
            written += UInt64(data.count)
            if Date().timeIntervalSince(lastReport) > 0.25 {
                lastReport = Date()
                // .gz doesn't say its size up front, so its progress follows the compressed file.
                progress.report(knownSize != nil
                    ? .init(phase: .writing, message: "Writing...", bytesDone: written, bytesTotal: knownSize)
                    : .init(phase: .writing, message: "Writing... (\(Self.size(written)) so far)", bytesDone: reader.bytesRead, bytesTotal: compressedSize))
            }
            do {
                chunk = try reader.next()
            } catch DriverError.corruptPayload(let problem) {
                throw DriverError.corruptPayload(
                    "\(problem) Mactoy had written \(Self.size(written)) of it, so the drive won't start. Download the image again and flash it."
                )
            }
        }
        try writer.fsync()
        progress.report(.init(phase: .writing, message: "Wrote \(Self.size(written)).", bytesDone: written, bytesTotal: written))

        // 4. Read it back.
        if plan.verifyAfterWriting {
            try await Self.verify(writer: writer, length: written, deviceSize: plan.target.sizeInBytes, expected: hasher.finalize(),
                                  progress: progress, control: control)
        }

        // Release the raw-disk fd so macOS can re-probe the newly written image. The kernel
        // refuses to re-scan a disk that still has an open writer.
        writer.close()
        progress.report(.init(phase: .formatting, message: "Asking macOS to re-read the partition table…"))
        _ = try? Subprocess.run("/usr/sbin/diskutil", ["reloadDisk", "/dev/\(plan.target.bsdName)"])
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        // Mount whatever's on the image. Silent on failure: some images (raw partitions, other
        // systems' file systems) don't mount on macOS, and that's fine.
        _ = try? Subprocess.run("/usr/sbin/diskutil", ["mountDisk", "/dev/\(plan.target.bsdName)"])

        progress.report(.init(phase: .done, message: "Flashed \(name) to \(plan.target.devicePath)"
                              + (plan.verifyAfterWriting ? " and checked it." : ".")))
    }

    // MARK: - Steps

    /// Only a plain file: not a device (`/dev/rdisk0`), a pipe or a socket (#36).
    static func requireRegularFile(_ handle: FileHandle, name: String) throws {
        var st = stat()
        guard fstat(handle.fileDescriptor, &st) == 0 else {
            throw DriverError.diskIO("Can't read \(name): \(String(cString: strerror(errno)))")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw DriverError.validation("\(name) isn't a regular file, so Mactoy won't flash it.")
        }
    }

    static func sha256(of handle: FileHandle, name: String, progress: ProgressSink, control: RunControl) async throws -> String {
        let total = (try? handle.seekToEnd()) ?? 0
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        var done: UInt64 = 0
        var lastReport = Date.distantPast
        while let piece = try handle.read(upToCount: 4 * 1024 * 1024), !piece.isEmpty {
            try control.check(stoppedBeforeWriting)
            hasher.update(data: piece)
            done += UInt64(piece.count)
            if Date().timeIntervalSince(lastReport) > 0.25 {
                lastReport = Date()
                progress.report(.init(phase: .verifying, message: "Checking \(name)'s SHA-256...", bytesDone: done, bytesTotal: total))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reads `length` bytes back from the start of the drive and compares their SHA-256 with
    /// what was written.
    static func verify(writer: DiskWriter, length: UInt64, deviceSize: UInt64, expected: SHA256.Digest,
                       progress: ProgressSink, control: RunControl = RunControl()) async throws {
        progress.report(.init(phase: .verifying, message: "Checking what was written...", bytesDone: 0, bytesTotal: length))
        var hasher = SHA256()
        var offset: UInt64 = 0
        var lastReport = Date.distantPast
        while offset < length {
            try control.check(stoppedWhileChecking)
            let want = min(UInt64(ImageReader.chunkSize), length - offset)
            // Whole blocks, as written: 4 KB, or 512 bytes at the very end of a drive.
            let blocks = (want + blockSize - 1) / blockSize * blockSize
            let count = offset + blocks <= deviceSize ? blocks : (want + SECTOR_SIZE - 1) / SECTOR_SIZE * SECTOR_SIZE
            let data = try writer.readAligned(at: offset, count: Int(count))
            hasher.update(data: data.prefix(Int(want)))
            offset += want
            if Date().timeIntervalSince(lastReport) > 0.25 {
                lastReport = Date()
                progress.report(.init(phase: .verifying, message: "Checking what was written...", bytesDone: offset, bytesTotal: length))
            }
        }
        guard hasher.finalize() == expected else {
            throw DriverError.diskIO(
                "The drive doesn't read back what was written. It may be failing or counterfeit (reporting more space than it has). " +
                "Try another drive."
            )
        }
        progress.report(.init(phase: .verifying, message: "What was written reads back correctly.", bytesDone: length, bytesTotal: length))
    }

    /// Raw disk writes must be whole blocks of the drive. Most USB drives use 512-byte sectors,
    /// some (and every recent Mac SSD) 4 KB, so writes use 4 KB, which suits both. Only an
    /// image's last chunk can end mid-block; it's padded with zeros, which the read-back check
    /// leaves out. At the very end of a drive whose size isn't a multiple of 4 KB, it's padded
    /// to 512 bytes instead.
    static let blockSize: UInt64 = 4096

    static func paddedToBlock(_ data: Data, roomLeft: UInt64) -> Data {
        let count = UInt64(data.count)
        let toBlock = (count + blockSize - 1) / blockSize * blockSize
        let target = toBlock <= roomLeft ? toBlock : (count + SECTOR_SIZE - 1) / SECTOR_SIZE * SECTOR_SIZE
        return target == count ? data : data + Data(count: Int(target - count))
    }

    static func fileSize(of handle: FileHandle) -> UInt64 {
        var st = stat()
        return fstat(handle.fileDescriptor, &st) == 0 ? UInt64(st.st_size) : 0
    }

    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
