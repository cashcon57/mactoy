import Foundation

/// Copies images onto a mounted Ventoy volume for Manage Disk (#45).
///
/// Runs on whatever thread calls it, so the app calls it off the main thread. Each file is
/// written under a temporary name, `.<name>.<random>.mactoy-partial`, and renamed to its real
/// name only once it's complete and flushed to the drive. Ventoy lists images by extension
/// (`.iso`, `.img`, ...), and Manage Disk also skips hidden files, so a cancelled, failed or
/// interrupted copy never leaves a half-written image in the boot menu.
public enum ImageCopier {
    /// Ends the temporary name of a file being copied.
    public static let partialSuffix = ".mactoy-partial"
    public static let defaultChunkSize = 8 * 1024 * 1024

    public struct Progress: Sendable, Equatable {
        /// 1-based position of the file being copied, among the files that are being copied.
        public let fileNumber: Int
        public let fileCount: Int
        public let fileName: String
        /// Across all files being copied.
        public let bytesDone: UInt64
        public let bytesTotal: UInt64
        /// The file is read in full and is being flushed to the drive, which can take a while
        /// on a slow stick and can't be cancelled.
        public let finishing: Bool

        public init(fileNumber: Int, fileCount: Int, fileName: String, bytesDone: UInt64, bytesTotal: UInt64,
                    finishing: Bool = false) {
            self.fileNumber = fileNumber
            self.fileCount = fileCount
            self.fileName = fileName
            self.bytesDone = bytesDone
            self.bytesTotal = bytesTotal
            self.finishing = finishing
        }
    }

    public struct Failure: Sendable, Equatable {
        public let fileName: String
        public let message: String

        public init(fileName: String, message: String) {
            self.fileName = fileName
            self.message = message
        }
    }

    public struct Result: Sendable, Equatable {
        public var copied: [String] = []
        public var failures: [Failure] = []
        public var cancelled = false
        /// The file whose unfinished copy was removed when the copy was cancelled.
        public var removedUnfinished: String?
        /// Set when nothing was copied because the files don't fit.
        public var notEnoughSpace: String?

        public init() {}
    }

    static let alreadyThere = "A file with this name is already on the drive."
    static let driveGone = "The drive is no longer available. Nothing more was copied."
    static let fat32Limit: UInt64 = 4 * 1024 * 1024 * 1024 - 1

    /// Where a folder is mounted from and its file system, from `statfs`.
    public struct Mount: Sendable, Equatable {
        public let device: String      // e.g. "/dev/disk4s1"
        public let fileSystem: String  // e.g. "exfat", "msdos"

        public init(device: String, fileSystem: String) {
            self.device = device
            self.fileSystem = fileSystem
        }

        /// Whether this is a partition of `diskBSD` ("disk4" matches disk4s1, not disk41s1).
        public func isOnDisk(_ diskBSD: String) -> Bool {
            device.hasPrefix("/dev/\(diskBSD)s")
        }
    }

    /// The mount holding `url`, or nil if it can't be read (nothing mounted there any more).
    public static func mount(of url: URL) -> Mount? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        let device = withUnsafeBytes(of: &info.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let type = withUnsafeBytes(of: &info.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return Mount(device: device, fileSystem: type)
    }

    /// Whether `url` is on a mounted partition of `diskBSD`. Manage Disk checks this before
    /// deleting, in case another drive is now mounted at the same path.
    public static func isOnDisk(_ url: URL, diskBSD: String) -> Bool {
        mount(of: url)?.isOnDisk(diskBSD) == true
    }

    /// Whether `name` is a temporary file this copier makes.
    public static func isPartialName(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(partialSuffix)
    }

    /// The temporary name a file is written under while it's being copied. The real name is
    /// shortened in it if needed, so a name close to the 255-character limit still fits.
    static func partialURL(for destination: URL) -> URL {
        let token = String(UUID().uuidString.prefix(8))
        var base = destination.lastPathComponent
        while base.utf8.count > 200 { base.removeLast() }
        return destination.deletingLastPathComponent()
            .appendingPathComponent("." + base + "." + token + partialSuffix)
    }

    /// Copies `sources` into `directory`, in order.
    ///
    /// - Temporary files left in `directory` by a copy that was interrupted (the app quit, the
    ///   drive was unplugged) are deleted first, so they don't take up space unseen.
    /// - Files already in `directory`, two picked files with the same name, and anything that
    ///   isn't a regular file are skipped and reported; the rest are still copied.
    /// - If the files to copy don't fit in the free space, nothing is copied.
    /// - A file that fails is reported and the next one is tried, unless `directory` is no longer
    ///   on `diskBSD` (the drive was unplugged, or another one is mounted in its place), which
    ///   stops the copy. Nothing is copied if it isn't on `diskBSD` to begin with.
    /// - On FAT (FAT32, FAT16), files of 4 GB or more are refused up front: FAT can't hold them.
    /// - `isCancelled` is checked between chunks; the file in progress is then deleted and no
    ///   more are copied. Files already copied stay.
    public static func copy(
        _ sources: [URL],
        into directory: URL,
        onDisk diskBSD: String,
        chunkSize: Int = defaultChunkSize,
        availableCapacity: (URL) -> Int64? = Self.availableCapacity(of:),
        mount: (URL) -> Mount? = Self.mount(of:),
        exclusiveRename: (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_EXCL)) },
        isCancelled: () -> Bool,
        progress: (Progress) -> Void
    ) -> Result {
        var result = Result()
        let fm = FileManager.default
        guard let startMount = mount(directory), startMount.isOnDisk(diskBSD) else {
            result.failures = sources.map { Failure(fileName: $0.lastPathComponent, message: driveGone) }
            return result
        }
        let isFAT32 = startMount.fileSystem == "msdos"
        removeLeftovers(in: directory)

        var jobs: [(source: URL, destination: URL, size: UInt64)] = []
        var names = Set<String>()
        for source in sources {
            let name = source.lastPathComponent
            let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else {
                result.failures.append(Failure(fileName: name, message: "It isn't a file Mactoy can copy."))
                continue
            }
            // exFAT and FAT32 names ignore case and Unicode normalisation.
            guard names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                result.failures.append(Failure(fileName: name, message: "Another file you picked has the same name."))
                continue
            }
            if isFAT32, UInt64(size) > fat32Limit {
                result.failures.append(Failure(fileName: name, message:
                    "It's 4 GB or larger, and this drive's file system (FAT) can't hold files that big."))
                continue
            }
            let destination = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) {
                result.failures.append(Failure(fileName: name, message: alreadyThere))
                continue
            }
            jobs.append((source, destination, UInt64(size)))
        }

        let total = jobs.reduce(UInt64(0)) { $0 + $1.size }
        if total > 0, let free = availableCapacity(directory), free >= 0, UInt64(free) < total {
            let need = ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file)
            let have = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            result.notEnoughSpace = "The files need \(need), and the drive has \(have) free. Nothing was copied."
            return result
        }

        var done: UInt64 = 0
        for (index, job) in jobs.enumerated() {
            if isCancelled() { result.cancelled = true; break }
            let name = job.destination.lastPathComponent
            // The drive was unplugged, or another one is mounted at the same path.
            if mount(directory)?.isOnDisk(diskBSD) != true {
                for rest in jobs[index...] {
                    result.failures.append(Failure(fileName: rest.destination.lastPathComponent, message: driveGone))
                }
                break
            }
            func report(_ bytes: UInt64, _ finishing: Bool) {
                progress(Progress(fileNumber: index + 1, fileCount: jobs.count, fileName: name,
                                  bytesDone: bytes, bytesTotal: total, finishing: finishing))
            }
            report(done, false)
            let start = done
            do {
                let finished = try copyOne(job.source, to: job.destination, chunkSize: chunkSize,
                                           exclusiveRename: exclusiveRename, isCancelled: isCancelled,
                                           written: { report(start + $0, false) },
                                           finishing: { report(start + job.size, true) })
                if !finished {
                    result.cancelled = true
                    result.removedUnfinished = name
                    break
                }
                result.copied.append(name)
            } catch {
                result.failures.append(Failure(fileName: name, message: message(for: error)))
            }
            // Counted as done either way, so the overall bar still ends full.
            done = start + job.size
        }
        return result
    }

    /// Free space for a new file on the volume holding `url`.
    public static func availableCapacity(of url: URL) -> Int64? {
        // A fresh URL: resource values are cached on the URL, so asking a URL used before
        // returns the free space from then, before the last copy filled some of it.
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Deletes this copier's temporary files directly in `directory` (regular files only).
    static func removeLeftovers(in directory: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where isPartialName(name) {
            let url = directory.appendingPathComponent(name)
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                try? fm.removeItem(at: url)
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? CopyError { return error.message }
        return "Couldn't write it to the drive: \(error.localizedDescription)"
    }

    private struct CopyError: Error {
        let message: String
    }

    /// Returns false if cancelled (the temporary file is deleted). Throws on any I/O error,
    /// also after deleting the temporary file.
    private static func copyOne(
        _ source: URL,
        to destination: URL,
        chunkSize: Int,
        exclusiveRename: (String, String) -> Int32,
        isCancelled: () -> Bool,
        written: (UInt64) -> Void,
        finishing: () -> Void
    ) throws -> Bool {
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
        } catch {
            throw CopyError(message: "Mactoy couldn't read it: \(error.localizedDescription)")
        }
        defer { try? input.close() }

        // A new file only: never opens anything that's already there.
        let partial = partialURL(for: destination)
        let fd = open(partial.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw posixError(errno) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // Straight to the drive rather than into the system's cache, so progress follows what
        // the drive has taken, and the final flush doesn't hold minutes of data.
        _ = fcntl(fd, F_NOCACHE, 1)
        var keep = false
        var outputOpen = true
        defer {
            if outputOpen { try? output.close() }
            if !keep { try? FileManager.default.removeItem(at: partial) }
        }

        var count: UInt64 = 0
        while true {
            if isCancelled() { return false }
            guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            count += UInt64(chunk.count)
            written(count)
        }
        // On the drive itself before it's called done: people unplug sticks as soon as a copy
        // ends. A plain fsync leaves the data in the drive's own cache.
        finishing()
        try fullSync(fd)
        try output.close()
        outputOpen = false
        if isCancelled() { return false }

        // Fails, rather than replacing it, if a file with the real name appeared meanwhile.
        if exclusiveRename(partial.path, destination.path) != 0 {
            let code = errno
            switch code {
            case EEXIST:
                throw CopyError(message: alreadyThere)
            case ENOTSUP, EINVAL:
                // exFAT, Ventoy's usual file system, reports ENOTSUP whenever the name is free
                // (and EEXIST on a clash), so this is the normal path there. FileManager checks
                // and refuses to replace; only the instant between its check and rename is open.
                do {
                    try FileManager.default.moveItem(at: partial, to: destination)
                } catch CocoaError.fileWriteFileExists {
                    throw CopyError(message: alreadyThere)
                }
            default:
                throw posixError(code)
            }
        }
        keep = true
        // Records the rename on the drive too.
        let dirFD = open(destination.deletingLastPathComponent().path, O_RDONLY)
        if dirFD >= 0 {
            _ = try? fullSync(dirFD)
            close(dirFD)
        }
        return true
    }

    private static func fullSync(_ fd: Int32) throws {
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        // Some file systems don't support F_FULLFSYNC; a plain fsync is the best they offer.
        if fsync(fd) != 0 { throw posixError(errno) }
    }

    private static func posixError(_ code: Int32) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
