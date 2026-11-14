import Foundation
import Testing
@testable import MactoyKit

/// Manage Disk's copy onto a Ventoy volume (#45): off the main thread, with progress and Cancel,
/// and never a half-written image under a name Ventoy would list.
@Suite("Image copier")
final class ImageCopierTests {
    private let fm = FileManager.default
    private var made: [URL] = []

    deinit {
        for url in made {
            // Unreadable fixtures must be readable again to be deleted.
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            if let names = try? fm.contentsOfDirectory(atPath: url.path) {
                for name in names {
                    try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.appendingPathComponent(name).path)
                }
            }
            try? fm.removeItem(at: url)
        }
    }

    private func tempDir(_ label: String) throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("mactoy-copy-\(label)-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        made.append(url)
        return url
    }

    /// A file of `size` bytes with varying content, so a misplaced chunk is caught.
    private func file(_ name: String, size: Int, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ name.count) }).write(to: url)
        return url
    }

    private func contents(_ dir: URL) throws -> [String] {
        try fm.contentsOfDirectory(atPath: dir.path).sorted()
    }

    @Test("copies every file byte for byte, reporting progress up to the total")
    func copiesWithProgress() throws {
        let src = try tempDir("src"), dst = try tempDir("dst")
        let a = try file("a.iso", size: 100_000, in: src)
        let b = try file("b.img", size: 33_333, in: src)
        var seen: [ImageCopier.Progress] = []
        let result = ImageCopier.copy([a, b], into: dst, chunkSize: 4096, isCancelled: { false }) { seen.append($0) }

        #expect(result.copied == ["a.iso", "b.img"])
        #expect(result.failures.isEmpty && !result.cancelled && result.notEnoughSpace == nil)
        #expect(try Data(contentsOf: dst.appendingPathComponent("a.iso")) == Data(contentsOf: a))
        #expect(try Data(contentsOf: dst.appendingPathComponent("b.img")) == Data(contentsOf: b))
        #expect(try contents(dst) == ["a.iso", "b.img"], "no temporary files left behind")
        #expect(seen.map(\.bytesDone) == seen.map(\.bytesDone).sorted(), "progress never goes back")
        #expect(seen.last?.bytesDone == 133_333 && seen.last?.bytesTotal == 133_333)
        #expect(seen.last?.fileNumber == 2 && seen.last?.fileCount == 2 && seen.last?.fileName == "b.img")
        #expect(seen.filter(\.finishing).map(\.fileName) == ["a.iso", "b.img"], "each file says when it's being flushed")
    }

    @Test("a file already on the drive is skipped and left alone; the others are copied")
    func skipsExisting() throws {
        let src = try tempDir("src"), dst = try tempDir("dst")
        let a = try file("a.iso", size: 5000, in: src)
        let b = try file("b.iso", size: 5000, in: src)
        try Data("keep me".utf8).write(to: dst.appendingPathComponent("a.iso"))
        let result = ImageCopier.copy([a, b], into: dst, isCancelled: { false }) { _ in }

        #expect(result.copied == ["b.iso"])
        #expect(result.failures == [.init(fileName: "a.iso", message: ImageCopier.alreadyThere)])
        #expect(try String(contentsOf: dst.appendingPathComponent("a.iso"), encoding: .utf8) == "keep me")
    }

    @Test("a file with the same name that appears during the copy is kept, and the copy reports it")
    func renameNeverReplaces() throws {
        let src = try tempDir("src"), dst = try tempDir("dst")
        let a = try file("a.iso", size: 50_000, in: src)
        let user = dst.appendingPathComponent("a.iso")
        let result = ImageCopier.copy([a], into: dst, chunkSize: 4096, isCancelled: { false }) { p in
            if p.bytesDone > 10_000, !FileManager.default.fileExists(atPath: user.path) {
                try? Data("the user's file".utf8).write(to: user)
            }
        }
        #expect(result.copied.isEmpty)
        #expect(result.failures == [.init(fileName: "a.iso", message: ImageCopier.alreadyThere)])
        #expect(try String(contentsOf: user, encoding: .utf8) == "the user's file")
        #expect(try contents(dst) == ["a.iso"], "no temporary file left")
    }

    @Test("two picked files whose names differ only in case: only the first is copied")
    func duplicateNamesIgnoreCase() throws {
        let src1 = try tempDir("s1"), src2 = try tempDir("s2"), dst = try tempDir("dst")
        let a1 = try file("Same.iso", size: 1000, in: src1)
        let a2 = try file("same.ISO", size: 2000, in: src2)
        var total: UInt64 = 0
        let result = ImageCopier.copy([a1, a2], into: dst, isCancelled: { false }) { total = $0.bytesTotal }
        #expect(result.copied == ["Same.iso"])
        #expect(result.failures.map(\.fileName) == ["same.ISO"])
        #expect(total == 1000, "the skipped file isn't counted against the free space")
    }

    @Test("if the files don't fit, nothing is copied")
    func notEnoughSpace() throws {
        let src = try tempDir("src"), dst = try tempDir("dst")
        let a = try file("a.iso", size: 6000, in: src)
        let b = try file("b.iso", size: 6000, in: src)
        let result = ImageCopier.copy([a, b], into: dst, availableCapacity: { _ in 10_000 }, isCancelled: { false }) { _ in }
        #expect(result.notEnoughSpace != nil)
        #expect(result.copied.isEmpty)
        #expect(try contents(dst).isEmpty)
    }

    @Test("Cancel mid-file deletes that file, keeps the ones before it and copies no more")
    func cancelMidFile() throws {
        let src = try tempDir("src"), dst = try tempDir("dst")
        let a = try file("a.iso", size: 10_000, in: src)
        let b = try file("b.iso", size: 100_000, in: src)
        let c = try file("c.iso", size: 10_000, in: src)
        var stop = false
        let result = ImageCopier.copy([a, b, c], into: dst, chunkSize: 4096, isCancelled: { stop }) { p in
            if p.fileName == "b.iso", p.bytesDone > 10_000 + 20_000 { stop = true }
        }
        #expect(result.cancelled)
        #expect(result.removedUnfinished == "b.iso")
        #expect(result.copied == ["a.iso"])
        #expect(try contents(dst) == ["a.iso"], "no partial b.iso, no c.iso")
    }

    @Test("when the drive goes away mid-batch, the copy stops and says why for the rest")
    func driveGone() throws {
        let src = try tempDir("src"), dst = try tempDir("dst")
        let files = try ["a.iso", "b.iso", "c.iso"].map { try file($0, size: 1000, in: src) }
        var mounted = true
        let result = ImageCopier.copy(files, into: dst, volumeIdentity: { _ in mounted ? AnyHashable("vol-1") : nil },
                                      isCancelled: { false }) { p in
            if p.fileName == "a.iso", p.finishing { mounted = false }
        }
        #expect(result.copied == ["a.iso"])
        #expect(result.failures == [.init(fileName: "b.iso", message: ImageCopier.driveGone),
                                    .init(fileName: "c.iso", message: ImageCopier.driveGone)])
    }

    @Test("another drive mounted at the same path stops the copy too")
    func driveReplaced() throws {
        let src = try tempDir("src"), dst = try tempDir("dst")
        let files = try ["a.iso", "b.iso"].map { try file($0, size: 1000, in: src) }
        var volume = "stick-1"
        let result = ImageCopier.copy(files, into: dst, volumeIdentity: { _ in AnyHashable(volume) },
                                      isCancelled: { false }) { p in
            if p.fileName == "a.iso", p.finishing { volume = "stick-2" }
        }
        #expect(result.copied == ["a.iso"])
        #expect(result.failures.map(\.message) == [ImageCopier.driveGone])
    }

    @Test("something that isn't a regular file is reported, not copied")
    func notAFile() throws {
        let src = try tempDir("src"), dst = try tempDir("dst")
        let folder = src.appendingPathComponent("folder.iso")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let missing = src.appendingPathComponent("gone.iso")
        let ok = try file("ok.iso", size: 100, in: src)
        let result = ImageCopier.copy([folder, missing, ok], into: dst, isCancelled: { false }) { _ in }
        #expect(result.copied == ["ok.iso"])
        #expect(Set(result.failures.map(\.fileName)) == ["folder.iso", "gone.iso"])
    }

    @Test("an unreadable source is reported and the next file is still copied")
    func unreadableSourceContinues() throws {
        let src = try tempDir("src"), dst = try tempDir("dst")
        let a = try file("a.iso", size: 5000, in: src)
        let b = try file("b.iso", size: 5000, in: src)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: a.path)
        let result = ImageCopier.copy([a, b], into: dst, isCancelled: { false }) { _ in }
        #expect(result.failures.map(\.fileName) == ["a.iso"])
        #expect(result.failures.first?.message.hasPrefix("Mactoy couldn't read it") == true)
        #expect(result.copied == ["b.iso"])
        #expect(try contents(dst) == ["b.iso"])
    }

    @Test("a failure after writing has started leaves neither the image nor a temporary file")
    func failureMidWriteCleansUp() throws {
        let src = try tempDir("src"), dst = try tempDir("dst")
        let a = try file("a.iso", size: 50_000, in: src)
        // Deleting the temporary file mid-copy makes the final rename fail.
        let result = ImageCopier.copy([a], into: dst, chunkSize: 4096, isCancelled: { false }) { p in
            guard p.bytesDone > 10_000, let names = try? FileManager.default.contentsOfDirectory(atPath: dst.path) else { return }
            for name in names where ImageCopier.isPartialName(name) {
                try? FileManager.default.removeItem(at: dst.appendingPathComponent(name))
            }
        }
        #expect(result.copied.isEmpty)
        #expect(result.failures.first?.message.hasPrefix("Couldn't write it to the drive") == true)
        #expect(try contents(dst).isEmpty)
    }

    @Test("temporary files left by an interrupted copy are removed; other hidden files are not")
    func leftoversRemoved() throws {
        let src = try tempDir("src"), dst = try tempDir("dst")
        let a = try file("a.iso", size: 5000, in: src)
        try Data(count: 4096).write(to: dst.appendingPathComponent(".big.iso.1A2B3C4D.mactoy-partial"))
        try Data("user".utf8).write(to: dst.appendingPathComponent(".hidden-notes"))
        let result = ImageCopier.copy([a], into: dst, isCancelled: { false }) { _ in }
        #expect(result.copied == ["a.iso"])
        #expect(try contents(dst) == [".hidden-notes", "a.iso"])
    }

    @Test("the temporary name is hidden and has no image extension, so nothing lists it")
    func partialNameIsNotListed() throws {
        let vol = try tempDir("vol")
        let partial = ImageCopier.partialURL(for: vol.appendingPathComponent("big.iso"))
        #expect(partial.lastPathComponent.hasPrefix(".big.iso."))
        #expect(ImageCopier.isPartialName(partial.lastPathComponent))
        try Data(count: VentoyImageLibrary.minimumImageSize).write(to: partial)
        #expect(VentoyImageLibrary.images(on: vol).isEmpty)
    }
}
