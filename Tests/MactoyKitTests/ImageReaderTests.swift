import Compression
import Foundation
import Testing
import zlib
@testable import MactoyKit

/// #20: images are decompressed a chunk at a time while flashing.
@Suite("ImageReader")
struct ImageReaderTests {
    private let fm = FileManager.default

    // MARK: - Fixtures, made with Apple's and zlib's own encoders (CI may not have `xz`)

    /// Mixed data: random-ish blocks and long runs, so it compresses but not to nothing.
    private func sample(_ count: Int, seed: UInt64 = 42) -> Data {
        var rng = seed
        var out = Data(capacity: count)
        while out.count < count {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            if rng % 3 == 0 {
                out.append(contentsOf: repeatElement(UInt8(truncatingIfNeeded: rng >> 33), count: min(5000, count - out.count)))
            } else {
                for i in 0..<min(256, count - out.count) { out.append(UInt8(truncatingIfNeeded: (rng >> (i % 56)) ^ UInt64(i))) }
            }
        }
        return out
    }

    private func xz(_ data: Data) -> Data {
        let capacity = data.count + 1_000_000
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dst.deallocate() }
        let n = data.withUnsafeBytes { src in
            compression_encode_buffer(dst, capacity, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZMA)
        }
        precondition(n > 0)
        return Data(bytes: dst, count: n)
    }

    private func gzip(_ data: Data) -> Data {
        var stream = z_stream()
        precondition(deflateInit2_(&stream, 6, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
        defer { deflateEnd(&stream) }
        var input = data
        let capacity = Int(deflateBound(&stream, uLong(data.count))) + 64
        var out = Data(count: capacity)
        let written: Int = input.withUnsafeMutableBytes { src in
            out.withUnsafeMutableBytes { dst in
                stream.next_in = src.bindMemory(to: UInt8.self).baseAddress
                stream.avail_in = uInt(data.count)
                stream.next_out = dst.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = uInt(capacity)
                precondition(deflate(&stream, Z_FINISH) == Z_STREAM_END)
                return capacity - Int(stream.avail_out)
            }
        }
        return out.prefix(written)
    }

    private func file(_ data: Data, _ name: String) throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("mactoy-image-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Reads the whole image through ImageReader; also returns the largest chunk seen.
    private func readAll(_ url: URL) throws -> (data: Data, chunks: [Int]) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let reader = try ImageReader(handle: handle, format: ImageFormat(path: url.path))
        var out = Data()
        var chunks: [Int] = []
        while let chunk = try reader.next() {
            chunks.append(chunk.count)
            out.append(chunk)
        }
        return (out, chunks)
    }

    // MARK: - Tests

    @Test("format follows the file name")
    func formatByName() {
        #expect(ImageFormat(path: "/x/ubuntu.img.xz") == .xz)
        #expect(ImageFormat(path: "/x/raspios.img.XZ") == .xz)
        #expect(ImageFormat(path: "/x/image.img.gz") == .gzip)
        #expect(ImageFormat(path: "/x/image.iso") == .raw)
        #expect(ImageFormat(path: "/x/image.img") == .raw)
    }

    @Test("raw, .xz and .gz images come back byte for byte, in full-size chunks", arguments: ["raw", "xz", "gz"])
    func roundTrip(kind: String) throws {
        let original = sample(10 * 1024 * 1024 + 123_457)
        let url: URL
        switch kind {
        case "xz": url = try file(xz(original), "image.img.xz")
        case "gz": url = try file(gzip(original), "image.img.gz")
        default: url = try file(original, "image.img")
        }
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        let (data, chunks) = try readAll(url)
        #expect(data == original)
        #expect(chunks.dropLast().allSatisfy { $0 == ImageReader.chunkSize })
        #expect(chunks.last.map { $0 <= ImageReader.chunkSize } == true)
    }

    @Test("an image that compresses to almost nothing still comes back a chunk at a time", arguments: ["xz", "gz"])
    func highRatioStaysBounded(kind: String) throws {
        let original = Data(count: 64 * 1024 * 1024)   // all zeros: a few KB compressed
        let packed = kind == "xz" ? xz(original) : gzip(original)
        #expect(packed.count < 1_000_000)
        let url = try file(packed, "zeros.img.\(kind)")
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let reader = try ImageReader(handle: handle, format: ImageFormat(path: url.path))
        var total = 0
        while let chunk = try reader.next() {
            #expect(chunk.count <= ImageReader.chunkSize)
            #expect(chunk.allSatisfy { $0 == 0 })
            total += chunk.count
        }
        #expect(total == original.count)
    }

    @Test("concatenated streams and members are all read, as xz -d and gzip -d do", arguments: ["xz", "gz"])
    func concatenated(kind: String) throws {
        let a = sample(3 * 1024 * 1024, seed: 1)
        let b = sample(2 * 1024 * 1024 + 7, seed: 2)
        let packed: Data
        if kind == "xz" {
            // Stream padding (zeros, a multiple of four bytes) is allowed between xz streams.
            packed = xz(a) + Data(count: 8) + xz(b)
        } else {
            packed = gzip(a) + gzip(b)
        }
        let url = try file(packed, "two.img.\(kind)")
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try readAll(url).data == a + b)
    }

    @Test("a cut-off file is an error, not a short image", arguments: ["xz", "gz"])
    func truncated(kind: String) throws {
        let packed = kind == "xz" ? xz(sample(6 * 1024 * 1024)) : gzip(sample(6 * 1024 * 1024))
        let url = try file(packed.prefix(packed.count * 2 / 3), "cut.img.\(kind)")
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        #expect(throws: DriverError.self) { _ = try readAll(url) }
    }

    @Test("a damaged file is an error", arguments: ["xz", "gz"])
    func corrupt(kind: String) throws {
        var packed = kind == "xz" ? xz(sample(6 * 1024 * 1024)) : gzip(sample(6 * 1024 * 1024))
        packed[packed.count / 2] ^= 0xFF
        let url = try file(packed, "bad.img.\(kind)")
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        #expect(throws: DriverError.self) { _ = try readAll(url) }
    }

    @Test("a wrong checksum at the end is an error even though every byte decoded", arguments: ["xz", "gz"])
    func badChecksum(kind: String) throws {
        var packed: Data
        if kind == "gz" {
            packed = gzip(sample(2 * 1024 * 1024))
            packed[packed.count - 8] ^= 0x01            // the trailer's CRC-32
        } else {
            packed = xz(sample(2 * 1024 * 1024))
            // The footer's Backward Size gives the index's size; the block's check sits just before it.
            let backward = packed.subdata(in: packed.count - 8 ..< packed.count - 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let indexStart = packed.count - 12 - (Int(UInt32(littleEndian: backward)) + 1) * 4
            packed[indexStart - 1] ^= 0x01
        }
        let url = try file(packed, "check.img.\(kind)")
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        #expect(throws: DriverError.self) { _ = try readAll(url) }
    }

    @Test("a file that isn't the format its name says is an error before any image bytes", arguments: ["xz", "gz"])
    func wrongFormat(kind: String) throws {
        let url = try file(sample(2 * 1024 * 1024), "notreally.img.\(kind)")
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let reader = try ImageReader(handle: handle, format: ImageFormat(path: url.path))
        #expect(throws: DriverError.self) { _ = try reader.next() }
    }

    @Test("an empty raw file has no chunks; an empty .xz is an error")
    func empty() throws {
        let raw = try file(Data(), "empty.img")
        let packed = try file(Data(), "empty.img.xz")
        defer {
            try? fm.removeItem(at: raw.deletingLastPathComponent())
            try? fm.removeItem(at: packed.deletingLastPathComponent())
        }
        #expect(try readAll(raw).chunks.isEmpty)
        #expect(throws: DriverError.self) { _ = try readAll(packed) }
    }

    @Test("the size of an image is known up front for raw and .xz files, not for .gz")
    func sizeUpFront() throws {
        let a = sample(5 * 1024 * 1024 + 3, seed: 7)
        let b = sample(1024 * 1024, seed: 8)
        let cases: [(Data, String, UInt64?)] = [
            (a, "a.img", UInt64(a.count)),
            (xz(a), "a.img.xz", UInt64(a.count)),
            (xz(a) + Data(count: 4) + xz(b), "ab.img.xz", UInt64(a.count + b.count)),
            (gzip(a), "a.img.gz", nil),
            (sample(4096), "junk.img.xz", nil),
        ]
        for (bytes, name, expected) in cases {
            let url = try file(bytes, name)
            defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: 10)
            #expect(ImageReader.imageSize(of: handle, format: ImageFormat(path: url.path)) == expected, "\(name)")
            #expect(try handle.offset() == 10, "position restored for \(name)")
        }
    }

    @Test("an .xz index with absurd sizes gives no size instead of overflowing")
    func hostileIndex() throws {
        // Stream header, then an index with two records of the largest 63-bit sizes, then a footer.
        func varint(_ v: UInt64) -> [UInt8] {
            var v = v, out: [UInt8] = []
            repeat { var b = UInt8(v & 0x7F); v >>= 7; if v != 0 { b |= 0x80 }; out.append(b) } while v != 0
            return out
        }
        let huge: UInt64 = (1 << 63) - 1
        var index: [UInt8] = [0x00] + varint(2) + varint(huge) + varint(huge) + varint(huge) + varint(huge)
        while index.count % 4 != 0 { index.append(0) }
        index += [0, 0, 0, 0]    // CRC32, not checked by the size reader
        let backward = UInt32(index.count / 4 - 1)
        let footer: [UInt8] = [0, 0, 0, 0] + withUnsafeBytes(of: backward.littleEndian, Array.init) + [0, 1, 0x59, 0x5A]
        let header: [UInt8] = [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00, 0, 1, 0, 0, 0, 0]
        let url = try file(Data(header + index + footer), "hostile.img.xz")
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #expect(ImageReader.imageSize(of: handle, format: .xz) == nil)
    }

    @Test("bytes after a .gz image that aren't another member are ignored, as gzip -d does")
    func gzipTrailingGarbage() throws {
        let original = sample(3 * 1024 * 1024 + 11)
        let url = try file(gzip(original) + Data("garbage\n".utf8), "trail.img.gz")
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try readAll(url).data == original)
    }

    @Test("an .xz file ending in megabytes of zeros gets no size, quickly")
    func hugePaddingIsNotScanned() throws {
        let url = try file(xz(sample(1024 * 1024)) + Data(count: 8 * 1024 * 1024), "padded.img.xz")
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let start = Date()
        #expect(ImageReader.imageSize(of: handle, format: .xz) == nil)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("a .gz member boundary split across reads, with one byte of the next header visible, doesn't stall")
    func gzipBoundaryAtRead() throws {
        // Pad the first member so it ends one byte before a 1 MB read boundary.
        let a = sample(512 * 1024, seed: 3)
        var first = gzip(a)
        let b = sample(300 * 1024, seed: 4)
        let pad = ImageReader.inputSize - 1 - first.count
        #expect(pad > 0)
        first += Data(count: pad)                 // zero padding between members is allowed
        let url = try file(first + gzip(b), "split.img.gz")
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try readAll(url).data == a + b)
    }
}

