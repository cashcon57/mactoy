import Foundation
import Testing
@testable import MactoyKit

/// Manage Disk's copy onto a Ventoy volume (#45): off the main thread, with progress and Cancel,
/// and never a half-written image under a name Ventoy would list.
@Suite("Image copier")
struct ImageCopierTests {
    private let fm = FileManager.default

    private func tempDir(_ label: String) throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("mactoy-copy-\(label)-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
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
    }

    @Test("a file already on the drive is skipped and left alone; the others are copied")
    func skipsExisting() throws {
        let src = try tempDir("src"), dst = try tempDir("dst")
        let a = try file("a.iso", size: 5000, in: src)
        let b = try file("b.iso", size: 5000, in: src)
        try Data("keep me".utf8).write(to: dst.appendingPathComponent("a.iso"))
        let result = ImageCopier.copy([a, b], into: dst, isCancelled: { false }) { _ in }

        #expect(result.copied == ["b.iso"])
        #expect(result.failures.map(\.fileName) == ["a.iso"])
        #expect(try String(contentsOf: dst.appendingPathComponent("a.iso"), encoding: .utf8) == "keep me")
    }

    @Test("two picked files with the same name: only the first is copied")
    func duplicateNames() throws {
        let src1 = try tempDir("s1"), src2 = try tempDir("s2"), dst = try tempDir("dst")
        let a1 = try file("same.iso", size: 1000, in: src1)
        let a2 = try file("same.iso", size: 2000, in: src2)
        let result = ImageCopier.copy([a1, a2], into: dst, isCancelled: { false }) { _ in }
        #expect(result.copied == ["same.iso"])
        #expect(result.failures.count == 1)
        #expect(try Data(contentsOf: dst.appendingPathComponent("same.iso")) == Data(contentsOf: a1))
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
        #expect(result.copied == ["a.iso"])
        #expect(try contents(dst) == ["a.iso"], "no partial b.iso, no c.iso")
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

    @Test("a write error is reported, leaves no partial file, and the next file is still tried")
    func writeErrorContinues() throws {
        let src = try tempDir("src"), dst = try tempDir("dst")
        let a = try file("a.iso", size: 5000, in: src)
        let b = try file("b.iso", size: 5000, in: src)
        // An unreadable source makes its copy fail.
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: a.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: a.path) }
        let result = ImageCopier.copy([a, b], into: dst, isCancelled: { false }) { _ in }
        #expect(result.failures.map(\.fileName) == ["a.iso"])
        #expect(result.copied == ["b.iso"])
        #expect(try contents(dst) == ["b.iso"], "no a.iso and no temporary file")
    }

    @Test("a temporary file left by a killed copy is replaced")
    func leftoverPartialReplaced() throws {
        let src = try tempDir("src"), dst = try tempDir("dst")
        let a = try file("a.iso", size: 5000, in: src)
        try Data("stale".utf8).write(to: ImageCopier.partialURL(for: dst.appendingPathComponent("a.iso")))
        let result = ImageCopier.copy([a], into: dst, isCancelled: { false }) { _ in }
        #expect(result.copied == ["a.iso"])
        #expect(try contents(dst) == ["a.iso"])
    }

    @Test("the temporary name is hidden, so Ventoy and Manage Disk don't list a file being copied")
    func partialNameIsHidden() throws {
        let vol = try tempDir("vol")
        let partial = ImageCopier.partialURL(for: vol.appendingPathComponent("big.iso"))
        #expect(partial.lastPathComponent == ".big.iso.mactoy-partial")
        try Data(count: VentoyImageLibrary.minimumImageSize).write(to: partial)
        #expect(VentoyImageLibrary.images(on: vol).isEmpty)
    }
}
