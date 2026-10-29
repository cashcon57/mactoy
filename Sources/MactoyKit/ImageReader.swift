import Compression
import Foundation
import zlib

/// How an image file is stored, by its name.
public enum ImageFormat: Sendable, Equatable {
    case raw
    case xz
    case gzip

    public init(path: String) {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "xz": self = .xz
        case "gz", "gzip": self = .gzip
        default: self = .raw
        }
    }
}

/// The bytes of an image, decompressed a chunk at a time (#20). Memory use stays at a few
/// chunks whatever the image's size, unlike decompressing the whole file before writing.
///
/// `.xz` goes through Apple's Compression framework (`COMPRESSION_LZMA` reads the xz container,
/// including its checksums); `.gz` through the system zlib, which checks each member's CRC-32.
/// Files made of several concatenated streams (`.xz`) or members (`.gz`) are read to the end,
/// as `xz -d` and `gzip -d` do.
public final class ImageReader {
    public let format: ImageFormat
    /// Every chunk but the last is this size, a whole number of 512-byte sectors.
    public static let chunkSize = 4 * 1024 * 1024
    static let inputSize = 1024 * 1024

    private let source: FileHandle
    private var decoder: StreamDecoder?
    private var input = Data()
    private var inputOffset = 0
    private var inputEnded = false
    private var finished = false

    /// Compressed bytes read from the file so far. For `.gz`, whose decompressed size isn't
    /// known up front, progress follows this.
    public private(set) var bytesRead: UInt64 = 0

    public init(handle: FileHandle, format: ImageFormat) throws {
        self.source = handle
        self.format = format
        switch format {
        case .raw: decoder = nil
        case .xz: decoder = try XZStreamDecoder()
        case .gzip: decoder = try GzipStreamDecoder()
        }
    }

    /// The next chunk of image bytes, or nil once the image has ended. Throws on a corrupt or
    /// cut-off file; bytes returned before that were decoded correctly so far.
    public func next() throws -> Data? {
        guard !finished else { return nil }
        guard let decoder else { return try nextRaw() }

        var out = Data(capacity: Self.chunkSize)
        while out.count < Self.chunkSize {
            if inputOffset == input.count && !inputEnded {
                try refill()
            }
            let pending = input.count - inputOffset
            let step = try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> DecodeStep in
                let base = raw.bindMemory(to: UInt8.self).baseAddress.map { $0 + inputOffset }
                return try decoder.step(input: base, count: pending, inputEnded: inputEnded,
                                        outputCapacity: Self.chunkSize - out.count) { out.append($0, count: $1) }
            }
            inputOffset += step.consumed
            if step.ended {
                finished = true
                break
            }
            if step.consumed == 0 && step.produced == 0 && inputOffset == input.count && inputEnded {
                throw DriverError.corruptPayload("The image ends early: the file is cut off or damaged.")
            }
        }
        return out.isEmpty ? nil : out
    }

    private func nextRaw() throws -> Data? {
        var out = Data(capacity: Self.chunkSize)
        while out.count < Self.chunkSize {
            let piece = try source.read(upToCount: Self.chunkSize - out.count) ?? Data()
            if piece.isEmpty { break }
            bytesRead += UInt64(piece.count)
            out.append(piece)
        }
        if out.count < Self.chunkSize { finished = true }
        return out.isEmpty ? nil : out
    }

    private func refill() throws {
        let piece = try source.read(upToCount: Self.inputSize) ?? Data()
        input = piece
        inputOffset = 0
        bytesRead += UInt64(piece.count)
        if piece.isEmpty { inputEnded = true }
    }
}

struct DecodeStep {
    var consumed: Int
    var produced: Int
    /// The last stream ended and no input is left.
    var ended: Bool
}

protocol StreamDecoder: AnyObject {
    /// Decodes from `input` until `outputCapacity` bytes are produced or the input runs out,
    /// passing output to `emit`.
    func step(input: UnsafePointer<UInt8>?, count: Int, inputEnded: Bool, outputCapacity: Int,
              emit: (UnsafePointer<UInt8>, Int) -> Void) throws -> DecodeStep
}

/// `.xz` through `COMPRESSION_LZMA`. After a stream ends, zero padding is skipped and a further
/// stream, if any, gets a fresh decoder.
final class XZStreamDecoder: StreamDecoder {
    private var stream: compression_stream
    private var streamOpen = false
    private var betweenStreams = false
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024 * 1024)

    init() throws {
        stream = compression_stream(dst_ptr: buffer, dst_size: 0, src_ptr: UnsafePointer(buffer), src_size: 0, state: nil)
        try open()
    }

    deinit {
        if streamOpen { compression_stream_destroy(&stream) }
        buffer.deallocate()
    }

    private func open() throws {
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
            throw DriverError.corruptPayload("Couldn't start the .xz decoder.")
        }
        streamOpen = true
    }

    func step(input: UnsafePointer<UInt8>?, count: Int, inputEnded: Bool, outputCapacity: Int,
              emit: (UnsafePointer<UInt8>, Int) -> Void) throws -> DecodeStep {
        var consumed = 0
        if betweenStreams {
            // Stream padding is zero bytes; anything else starts another stream.
            while consumed < count, input![consumed] == 0 { consumed += 1 }
            if consumed == count {
                return DecodeStep(consumed: consumed, produced: 0, ended: inputEnded)
            }
            compression_stream_destroy(&stream)
            streamOpen = false
            try open()
            betweenStreams = false
        }

        stream.src_ptr = input.map { $0 + consumed } ?? UnsafePointer(buffer)
        stream.src_size = count - consumed
        var produced = 0
        while produced < outputCapacity {
            let room = min(1024 * 1024, outputCapacity - produced)
            stream.dst_ptr = buffer
            stream.dst_size = room
            let flags = inputEnded ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(&stream, flags)
            let made = room - stream.dst_size
            if made > 0 { emit(buffer, made); produced += made }
            switch status {
            case COMPRESSION_STATUS_END:
                betweenStreams = true
                let used = count - stream.src_size
                let rest = count - used
                return DecodeStep(consumed: used, produced: produced, ended: rest == 0 && inputEnded)
            case COMPRESSION_STATUS_OK:
                // Out of input (wait for more) or out of room (loop).
                if stream.src_size == 0 && made < room {
                    return DecodeStep(consumed: count, produced: produced, ended: false)
                }
            default:
                throw DriverError.corruptPayload("The .xz image is damaged or uses a format Mactoy can't read.")
            }
        }
        return DecodeStep(consumed: count - stream.src_size, produced: produced, ended: false)
    }
}

/// `.gz` through zlib's gzip decoder, which checks each member's CRC-32 and length. After a
/// member ends, trailing zero bytes are allowed; anything else must be another member.
final class GzipStreamDecoder: StreamDecoder {
    private var stream = z_stream()
    private var betweenMembers = false
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024 * 1024)

    private var started = false
    /// Non-gzip bytes after a member: the rest of the file is ignored, as `gzip -d` does.
    private var ignoringTrailer = false

    init() throws {
        // 15 + 16: a 32 KB window, gzip header and trailer only. deinit frees the buffer even
        // when this throws, so it isn't freed here.
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw DriverError.corruptPayload("Couldn't start the .gz decoder.")
        }
        started = true
    }

    deinit {
        if started { inflateEnd(&stream) }
        buffer.deallocate()
    }

    func step(input: UnsafePointer<UInt8>?, count: Int, inputEnded: Bool, outputCapacity: Int,
              emit: (UnsafePointer<UInt8>, Int) -> Void) throws -> DecodeStep {
        var consumed = 0
        if ignoringTrailer {
            return DecodeStep(consumed: count, produced: 0, ended: inputEnded)
        }
        if betweenMembers {
            while consumed < count, input![consumed] == 0 { consumed += 1 }
            if consumed == count {
                return DecodeStep(consumed: consumed, produced: 0, ended: inputEnded)
            }
            // Another member starts with the gzip magic number. Anything else is trailing data
            // that isn't part of the image.
            if count - consumed == 1 && !inputEnded {
                return DecodeStep(consumed: consumed, produced: 0, ended: false)
            }
            guard count - consumed >= 2, input![consumed] == 0x1F, input![consumed + 1] == 0x8B else {
                ignoringTrailer = true
                return DecodeStep(consumed: count, produced: 0, ended: inputEnded)
            }
            guard inflateReset(&stream) == Z_OK else {
                throw DriverError.corruptPayload("Couldn't restart the .gz decoder.")
            }
            betweenMembers = false
        }

        stream.next_in = UnsafeMutablePointer(mutating: input.map { $0 + consumed })
        stream.avail_in = uInt(count - consumed)
        var produced = 0
        while produced < outputCapacity {
            let room = min(1024 * 1024, outputCapacity - produced)
            stream.next_out = buffer
            stream.avail_out = uInt(room)
            let status = inflate(&stream, Z_NO_FLUSH)
            let made = room - Int(stream.avail_out)
            if made > 0 { emit(buffer, made); produced += made }
            switch status {
            case Z_STREAM_END:
                betweenMembers = true
                let rest = Int(stream.avail_in)
                return DecodeStep(consumed: count - rest, produced: produced, ended: rest == 0 && inputEnded)
            case Z_OK:
                if stream.avail_in == 0 && made < room {
                    return DecodeStep(consumed: count, produced: produced, ended: false)
                }
            case Z_BUF_ERROR:
                // No progress possible: needs more input.
                return DecodeStep(consumed: count - Int(stream.avail_in), produced: produced, ended: false)
            default:
                throw DriverError.corruptPayload("The .gz image is damaged (\(status == Z_DATA_ERROR ? "bad data or checksum" : "zlib error \(status)")).")
            }
        }
        return DecodeStep(consumed: count - Int(stream.avail_in), produced: produced, ended: false)
    }
}

extension ImageReader {
    /// The image's size once decompressed, when it can be known before reading it all: a raw
    /// file's size, or the total in an `.xz` file's indexes. nil for `.gz` (its stored size is
    /// only the low 32 bits) and for an `.xz` file whose indexes don't add up. The handle's
    /// position is restored.
    public static func imageSize(of handle: FileHandle, format: ImageFormat) -> UInt64? {
        guard let start = try? handle.offset() else { return nil }
        defer { try? handle.seek(toOffset: start) }
        guard let end = try? handle.seekToEnd() else { return nil }
        switch format {
        case .raw: return end
        case .gzip: return nil
        case .xz: return try? xzUncompressedSize(handle, fileSize: end)
        }
    }

    /// Walks the file's streams from the end: footer, index, then back over the blocks to the
    /// stream header, skipping stream padding. Returns nil on anything unexpected.
    static func xzUncompressedSize(_ handle: FileHandle, fileSize: UInt64) throws -> UInt64? {
        func read(_ offset: UInt64, _ count: Int) throws -> [UInt8]? {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else { return nil }
            return [UInt8](data)
        }
        var position = fileSize
        var total: UInt64 = 0
        var streams = 0
        while position > 0 {
            // Stream padding: zero bytes in groups of four. Real files have a few; a file with
            // more than 1 MB of them isn't a normal .xz, and isn't worth scanning.
            var padding: UInt64 = 0
            while position >= 4, let tail = try read(position - 4, 4), tail == [0, 0, 0, 0] {
                position -= 4
                padding += 4
                if padding > 1024 * 1024 { return nil }
            }
            guard position >= 24, let footer = try read(position - 12, 12),
                  footer[10] == 0x59, footer[11] == 0x5A else { return nil }
            let backward = UInt64(footer[4]) | UInt64(footer[5]) << 8 | UInt64(footer[6]) << 16 | UInt64(footer[7]) << 24
            let indexSize = (backward + 1) * 4
            guard indexSize <= 64 * 1024 * 1024, position >= 12 + indexSize + 12,
                  let index = try read(position - 12 - indexSize, Int(indexSize)), index.first == 0 else { return nil }

            var cursor = 1
            func varint() -> UInt64? {
                var value: UInt64 = 0
                for shift in stride(from: 0, to: 63, by: 7) {
                    guard cursor < index.count else { return nil }
                    let byte = index[cursor]
                    cursor += 1
                    value |= UInt64(byte & 0x7F) << UInt64(shift)
                    if byte & 0x80 == 0 { return value }
                }
                return nil
            }
            guard let records = varint(), records <= 1_000_000 else { return nil }
            var blocks: UInt64 = 0
            // Every sum is overflow-checked: the file is untrusted, and an overflow would stop
            // the helper.
            for _ in 0..<records {
                guard let unpadded = varint(), let uncompressed = varint() else { return nil }
                let (rounded, o1) = unpadded.addingReportingOverflow(3)
                let (newBlocks, o2) = blocks.addingReportingOverflow(rounded / 4 * 4)
                let (newTotal, o3) = total.addingReportingOverflow(uncompressed)
                guard !o1, !o2, !o3 else { return nil }
                blocks = newBlocks
                total = newTotal
            }
            let indexStart = position - 12 - indexSize
            let (needed, o4) = blocks.addingReportingOverflow(12)
            guard !o4, indexStart >= needed else { return nil }
            let streamStart = indexStart - needed
            guard let header = try read(streamStart, 6), header == [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00] else { return nil }
            position = streamStart
            streams += 1
            guard streams <= 10_000 else { return nil }
        }
        return total
    }
}
