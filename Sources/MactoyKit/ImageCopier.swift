import Foundation

/// Copies images onto a mounted Ventoy volume for Manage Disk (#45).
///
/// Runs on whatever thread calls it, so the app calls it off the main thread. Each file is
/// written under a hidden temporary name and renamed only once it's complete and flushed to
/// the drive, so a cancelled, failed or killed copy never leaves a half-written image that
/// Ventoy's boot menu would list (Ventoy and Manage Disk both skip hidden files).
public enum ImageCopier {
    /// Ends the temporary name of a file being copied: `.<name>.mactoy-partial`.
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

        public init(fileNumber: Int, fileCount: Int, fileName: String, bytesDone: UInt64, bytesTotal: UInt64) {
            self.fileNumber = fileNumber
            self.fileCount = fileCount
            self.fileName = fileName
            self.bytesDone = bytesDone
            self.bytesTotal = bytesTotal
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
        /// Set when nothing was copied because the files don't fit.
        public var notEnoughSpace: String?

        public init() {}
    }

    /// The hidden name a file is written under while it's being copied.
    public static func partialURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent("." + destination.lastPathComponent + partialSuffix)
    }

    /// Copies `sources` into `directory`, in order.
    ///
    /// - Files already in `directory`, and anything that isn't a regular file, are skipped and
    ///   reported as failures; the rest are still copied.
    /// - If the files to copy don't fit in the free space, nothing is copied.
    /// - A file that fails (the drive was removed, say) is reported and the next one is tried.
    /// - `isCancelled` is checked between chunks; the file in progress is then deleted and no
    ///   more are copied. Files already copied stay.
    public static func copy(
        _ sources: [URL],
        into directory: URL,
        chunkSize: Int = defaultChunkSize,
        availableCapacity: (URL) -> Int64? = Self.availableCapacity(of:),
        isCancelled: () -> Bool,
        progress: (Progress) -> Void
    ) -> Result {
        var result = Result()
        let fm = FileManager.default

        var jobs: [(source: URL, destination: URL, size: UInt64)] = []
        for source in sources {
            let name = source.lastPathComponent
            let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else {
                result.failures.append(Failure(fileName: name, message: "It isn't a file Mactoy can copy."))
                continue
            }
            let destination = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) {
                result.failures.append(Failure(fileName: name, message: "A file with this name is already on the drive."))
                continue
            }
            if jobs.contains(where: { $0.destination.lastPathComponent == name }) {
                result.failures.append(Failure(fileName: name, message: "Another file you picked has the same name."))
                continue
            }
            jobs.append((source, destination, UInt64(size)))
        }

        let total = jobs.reduce(UInt64(0)) { $0 + $1.size }
        if total > 0, let free = availableCapacity(directory), free >= 0, UInt64(free) < total {
            let need = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
            let have = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            result.notEnoughSpace = "The files need \(need), and the drive has \(have) free. Nothing was copied."
            return result
        }

        var done: UInt64 = 0
        for (index, job) in jobs.enumerated() {
            if isCancelled() { result.cancelled = true; break }
            let name = job.destination.lastPathComponent
            progress(Progress(fileNumber: index + 1, fileCount: jobs.count, fileName: name, bytesDone: done, bytesTotal: total))
            let start = done
            do {
                let finished = try copyOne(job.source, to: job.destination, chunkSize: chunkSize, isCancelled: isCancelled) { written in
                    done = start + written
                    progress(Progress(fileNumber: index + 1, fileCount: jobs.count, fileName: name, bytesDone: done, bytesTotal: total))
                }
                if !finished { result.cancelled = true; break }
                result.copied.append(name)
                done = start + job.size
            } catch {
                result.failures.append(Failure(fileName: name, message: error.localizedDescription))
                // Count the file as done, so the overall bar still ends full.
                done = start + job.size
            }
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

    /// Returns false if cancelled (the partial file is deleted). Throws on any I/O error, also
    /// after deleting the partial file.
    private static func copyOne(
        _ source: URL,
        to destination: URL,
        chunkSize: Int,
        isCancelled: () -> Bool,
        written: (UInt64) -> Void
    ) throws -> Bool {
        let fm = FileManager.default
        let partial = partialURL(for: destination)
        // Left over from a copy that was killed.
        try? fm.removeItem(at: partial)

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard fm.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        var keep = false
        defer { if !keep { try? fm.removeItem(at: partial) } }
        let output = try FileHandle(forWritingTo: partial)
        var outputOpen = true
        defer { if outputOpen { try? output.close() } }

        var count: UInt64 = 0
        while true {
            if isCancelled() { return false }
            guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            count += UInt64(chunk.count)
            written(count)
        }
        // On the drive before it's called done: people unplug sticks as soon as a copy ends.
        try output.synchronize()
        try output.close()
        outputOpen = false
        if isCancelled() { return false }
        // Fails rather than replacing a file of the same name that appeared meanwhile.
        try fm.moveItem(at: partial, to: destination)
        keep = true
        return true
    }
}
