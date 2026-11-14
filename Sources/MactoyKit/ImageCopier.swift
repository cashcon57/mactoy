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

    /// Whether `name` is a temporary file this copier makes.
    public static func isPartialName(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(partialSuffix)
    }

    /// The temporary name a file is written under while it's being copied.
    static func partialURL(for destination: URL) -> URL {
        let token = String(UUID().uuidString.prefix(8))
        return destination.deletingLastPathComponent()
            .appendingPathComponent("." + destination.lastPathComponent + "." + token + partialSuffix)
    }

    /// Copies `sources` into `directory`, in order.
    ///
    /// - Temporary files left in `directory` by a copy that was interrupted (the app quit, the
    ///   drive was unplugged) are deleted first, so they don't take up space unseen.
    /// - Files already in `directory`, two picked files with the same name, and anything that
    ///   isn't a regular file are skipped and reported; the rest are still copied.
    /// - If the files to copy don't fit in the free space, nothing is copied.
    /// - A file that fails is reported and the next one is tried, unless the drive is gone (or
    ///   another one is mounted in its place), which stops the copy.
    /// - `isCancelled` is checked between chunks; the file in progress is then deleted and no
    ///   more are copied. Files already copied stay.
    public static func copy(
        _ sources: [URL],
        into directory: URL,
        chunkSize: Int = defaultChunkSize,
        availableCapacity: (URL) -> Int64? = Self.availableCapacity(of:),
        volumeIdentity: (URL) -> AnyHashable? = Self.volumeIdentity(of:),
        isCancelled: () -> Bool,
        progress: (Progress) -> Void
    ) -> Result {
        var result = Result()
        let fm = FileManager.default
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

        let volume = volumeIdentity(directory)
        var done: UInt64 = 0
        for (index, job) in jobs.enumerated() {
            if isCancelled() { result.cancelled = true; break }
            let name = job.destination.lastPathComponent
            // The drive was unplugged, or another one is mounted at the same path.
            if volume == nil || volumeIdentity(directory) != volume {
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
                let finished = try copyOne(job.source, to: job.destination, chunkSize: chunkSize, isCancelled: isCancelled,
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

    /// Identifies the mounted volume holding `url`; nil when nothing is mounted there.
    public static func volumeIdentity(of url: URL) -> AnyHashable? {
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.volumeIdentifierKey])
        return (values?.volumeIdentifier as? NSObject).map(AnyHashable.init)
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
        if renamex_np(partial.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            switch code {
            case EEXIST:
                throw CopyError(message: alreadyThere)
            case ENOTSUP, EINVAL:
                // A file system without exclusive rename: FileManager also refuses to replace.
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
