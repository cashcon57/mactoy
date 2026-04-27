import Foundation

/// Writes raw bytes to a block device. Intended to be used only inside the
/// privileged helper (mactoyd), since /dev/rdisk* requires root.
public final class DiskWriter {
    public let rawPath: String
    private var fd: Int32
    private var closed: Bool = false

    public init(rawPath: String, writable: Bool = true) throws {
        self.rawPath = rawPath
        let flags: Int32 = writable ? (O_RDWR) : O_RDONLY
        let fd = open(rawPath, flags)
        if fd < 0 {
            let code = errno
            let base = String(cString: strerror(code))
            // EPERM when opening /dev/rdisk* means macOS TCC blocked the
            // raw-disk access even though we are root. The user has to
            // grant Full Disk Access to Mactoy in System Settings so the
            // privileged helper inherits the TCC grant.
            if code == EPERM {
                throw DriverError.diskIO(
                    """
                    open(\(rawPath)) blocked by macOS (Operation not permitted).

                    Grant Full Disk Access to Mactoy:
                      System Settings -> Privacy & Security -> Full Disk Access -> +
                      Add /Applications/Mactoy.app (or wherever Mactoy is installed).

                    Then quit and reopen Mactoy and try again.
                    """
                )
            }
            throw DriverError.diskIO("open(\(rawPath)): \(base)")
        }
        self.fd = fd
    }

    deinit {
        if !closed {
            Darwin.close(fd)
        }
    }

    /// Explicitly release the raw-disk fd. Call this before asking
    /// macOS to re-scan the partition table (e.g. `diskutil reloadDisk`)
    /// — the kernel refuses to re-probe a disk that still has an open
    /// writer, which stalls the post-install format step indefinitely.
    public func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
        fd = -1
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
        return try readSectorAtCurrentPosition()
    }

    /// Read exactly `count` bytes starting at byte offset `offset`. Built
    /// on top of full-sector reads (macOS `/dev/rdisk*` requires
    /// sector-aligned, sector-sized I/O at the syscall level), but
    /// transparently handles sub-sector starts and lengths by reading
    /// the bracketing sectors and slicing.
    ///
    /// Used by `FAT16Reader` / `VentoyVersionProbe` for partition-2
    /// reads where directory entries and FAT entries can land
    /// off-sector-boundaries.
    public func readBytes(at offset: UInt64, count: Int) throws -> Data {
        let secSize = Int(SECTOR_SIZE)
        let firstSector = offset / SECTOR_SIZE
        let firstSectorOffset = Int(offset % SECTOR_SIZE)
        let lastByteExclusive = offset + UInt64(count)
        let lastSectorExclusive = (lastByteExclusive + SECTOR_SIZE - 1) / SECTOR_SIZE
        let sectorsToRead = Int(lastSectorExclusive - firstSector)

        try seek(to: firstSector * SECTOR_SIZE)
        var buf = Data()
        buf.reserveCapacity(sectorsToRead * secSize)
        for _ in 0..<sectorsToRead {
            buf.append(try readSectorAtCurrentPosition())
        }
        return buf.subdata(in: firstSectorOffset..<(firstSectorOffset + count))
    }

    private func readSectorAtCurrentPosition() throws -> Data {
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
