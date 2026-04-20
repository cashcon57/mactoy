import Foundation

/// Writes raw bytes to a block device. Intended to be used only inside the
/// privileged helper (mactoyd), since /dev/rdisk* requires root.
public final class DiskWriter {
    public let rawPath: String
    private let fd: Int32

    public init(rawPath: String, writable: Bool = true) throws {
        self.rawPath = rawPath
        let flags: Int32 = writable ? (O_RDWR) : O_RDONLY
        let fd = open(rawPath, flags)
        if fd < 0 {
            throw DriverError.diskIO("open(\(rawPath)): \(String(cString: strerror(errno)))")
        }
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    public func seek(to offset: UInt64) throws {
        let r = lseek(fd, off_t(offset), SEEK_SET)
        if r < 0 {
            throw DriverError.diskIO("lseek: \(String(cString: strerror(errno)))")
        }
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var written = 0
            while written < data.count {
                let remaining = data.count - written
                let n = Darwin.write(fd, base.advanced(by: written), remaining)
                if n < 0 {
                    throw DriverError.diskIO("write: \(String(cString: strerror(errno)))")
                }
                written += n
            }
        }
    }

    public func writeAt(offset: UInt64, _ data: Data) throws {
        try seek(to: offset)
        try write(data)
    }

    public func fsync() throws {
        if Darwin.fsync(fd) != 0 {
            throw DriverError.diskIO("fsync: \(String(cString: strerror(errno)))")
        }
    }

    public func readSector(lba: UInt64) throws -> Data {
        try seek(to: lba * SECTOR_SIZE)
        var buf = Data(count: Int(SECTOR_SIZE))
        try buf.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                throw DriverError.diskIO("read: no buffer")
            }
            let n = Darwin.read(fd, base, Int(SECTOR_SIZE))
            if n < 0 {
                throw DriverError.diskIO("read: \(String(cString: strerror(errno)))")
            }
            if n != Int(SECTOR_SIZE) {
                throw DriverError.diskIO("read: short (\(n)/\(SECTOR_SIZE))")
            }
        }
        return buf
    }

    /// Read sector, patch a sub-sector range, write it back.
    public func patchSector(lba: UInt64, offset: Int, bytes: Data) throws {
        var sector = try readSector(lba: lba)
        sector.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        try seek(to: lba * SECTOR_SIZE)
        try write(sector)
    }

    public func zero(range: Range<UInt64>) throws {
        try seek(to: range.lowerBound)
        let chunk = Data(repeating: 0, count: 1024 * 1024)
        var remaining = Int(range.upperBound - range.lowerBound)
        while remaining > 0 {
            let n = min(remaining, chunk.count)
            try write(chunk.prefix(n))
            remaining -= n
        }
    }
}
