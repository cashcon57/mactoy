import Foundation

public enum FilesystemType: String, Codable, Sendable, CaseIterable {
    case exfat
}

public enum DriverID: String, Codable, Sendable {
    case ventoy
    case rawImage = "raw-image"
}

public struct DiskVolumeInfo: Codable, Sendable, Hashable {
    public let bsdName: String  // e.g. "disk8s1"
    public let volumeName: String  // e.g. "Ventoy" — nil on disk means unlabeled/unmounted
    public let sizeInBytes: UInt64

    public init(bsdName: String, volumeName: String, sizeInBytes: UInt64) {
        self.bsdName = bsdName
        self.volumeName = volumeName
        self.sizeInBytes = sizeInBytes
    }
}

public struct DiskTarget: Codable, Sendable, Equatable {
    public let bsdName: String
    public let sizeInBytes: UInt64
    public let isExternal: Bool
    public let isRemovable: Bool
    /// Human-readable name macOS shows in Finder (the `MediaName` key
    /// from `diskutil info`). Falls back to the BSD name when the disk
    /// has no descriptive label — typical for freshly-formatted sticks.
    public let mediaName: String?
    /// Volumes currently on this disk (partition + friendly label). Empty
    /// for a completely unformatted disk.
    public let volumes: [DiskVolumeInfo]

    public init(
        bsdName: String,
        sizeInBytes: UInt64,
        isExternal: Bool,
        isRemovable: Bool,
        mediaName: String? = nil,
        volumes: [DiskVolumeInfo] = []
    ) {
        self.bsdName = bsdName
        self.sizeInBytes = sizeInBytes
        self.isExternal = isExternal
        self.isRemovable = isRemovable
        self.mediaName = mediaName
        self.volumes = volumes
    }

    public var devicePath: String { "/dev/\(bsdName)" }
    public var rawDevicePath: String { "/dev/r\(bsdName)" }
    public var sectorCount: UInt64 { sizeInBytes / 512 }

    /// Best display name for the sidebar / warning copy. Prefers the
    /// disk's `MediaName`, then the first volume's label, then the BSD
    /// name as a last resort. This is what turns "disk8" into
    /// something like "SanDisk Ultra USB 3.0" in the UI.
    public var displayName: String {
        if let mediaName, !mediaName.isEmpty { return mediaName }
        if let first = volumes.first(where: { !$0.volumeName.isEmpty }) {
            return first.volumeName
        }
        return bsdName
    }

    /// Iron-clad TOCTOU defense: verify that this captured DiskTarget
    /// still describes the same physical disk as `fresh` (typically a
    /// `DiskInfo.probe(bsdName:)` result taken right before any write).
    /// Returns `nil` when everything matches; otherwise a human-readable
    /// description of the FIRST mismatch encountered.
    ///
    /// Why this exists: a user's report (issue #1, 2026-04-25) showed
    /// Mactoy wiping disk6 after the user explicitly confirmed disk5,
    /// because the disk-enumeration poll fired during the confirmation
    /// window and snapped `selectedDiskBSD` to a different disk. The
    /// drivers and AppState now call `fingerprintMismatch` and refuse
    /// to write if the live disk doesn't match what the user confirmed.
    /// `volumes` is intentionally NOT compared — partition layouts are
    /// expected to change during a fresh install and we'd be comparing
    /// against a captured snapshot that's already stale by design.
    /// Just-in-time re-verification: probe the live disk via `DiskInfo`
    /// and assert its fingerprint still matches `self`. Throws
    /// `DriverError.validation` on any mismatch. Drivers must call this
    /// **immediately before unmount/write** — not just at the start of
    /// the execute flow — because the gap between an early probe and
    /// the actual write can be tens of seconds (Ventoy tarball
    /// download, raw-image xz decompression). A USB hub
    /// re-enumeration during that gap could put a different drive
    /// behind the same `/dev/disk<N>` slot. v0.3.1 issue #1.
    func reverifyFingerprintNow() throws {
        let live = try DiskInfo.probe(bsdName: bsdName)
        if let mismatch = fingerprintMismatch(against: live) {
            throw DriverError.validation(
                "Refusing to write \(devicePath): the live disk does not match the disk you confirmed. \(mismatch). " +
                "Re-select the target disk and try again."
            )
        }
    }

    public func fingerprintMismatch(against fresh: DiskTarget) -> String? {
        if self.bsdName != fresh.bsdName {
            return "BSD name changed: confirmed \(self.bsdName), live \(fresh.bsdName)"
        }
        if self.sizeInBytes != fresh.sizeInBytes {
            return "Size changed: confirmed \(self.sizeInBytes) bytes, live \(fresh.sizeInBytes) bytes"
        }
        if self.isExternal != fresh.isExternal {
            return "External flag changed: confirmed \(self.isExternal), live \(fresh.isExternal)"
        }
        if self.isRemovable != fresh.isRemovable {
            return "Removable flag changed: confirmed \(self.isRemovable), live \(fresh.isRemovable)"
        }
        if self.mediaName != fresh.mediaName {
            return "Media name changed: confirmed \(self.mediaName ?? "nil"), live \(fresh.mediaName ?? "nil")"
        }
        return nil
    }
}

public enum InstallSource: Codable, Sendable {
    case ventoyVersion(String)
    case localImage(path: String)
}

/// What flavor of Ventoy operation an install plan represents.
/// Only meaningful when `driver == .ventoy`.
public enum VentoyOperation: String, Codable, Sendable {
    /// Wipe the disk and write a fresh GPT + Ventoy layout. The current
    /// behaviour for v0.1.x and v0.2.x.
    case freshInstall

    /// Update the bootloader (MBR boot code, GRUB2 core, partition 2)
    /// in-place on a disk that already has a valid Ventoy install.
    /// Partition 1 — including all ISOs and `/ventoy/` config — is
    /// preserved.
    case updateInPlace
}

public struct InstallPlan: Codable, Sendable {
    public let driver: DriverID
    public let target: DiskTarget
    public let source: InstallSource
    public let filesystem: FilesystemType
    public let workDir: String
    public let planVersion: Int
    /// Only meaningful when `driver == .ventoy`. Defaults to
    /// `.freshInstall` for backwards compatibility with v0.2.x plans.
    public let ventoyOperation: VentoyOperation

    public init(
        driver: DriverID,
        target: DiskTarget,
        source: InstallSource,
        filesystem: FilesystemType = .exfat,
        workDir: String,
        ventoyOperation: VentoyOperation = .freshInstall
    ) {
        self.driver = driver
        self.target = target
        self.source = source
        self.filesystem = filesystem
        self.workDir = workDir
        self.planVersion = 2
        self.ventoyOperation = ventoyOperation
    }

    // Backwards-compat decoder: v0.2.x plans (planVersion == 1) didn't
    // carry `ventoyOperation`. Decode them as `.freshInstall` so the
    // daemon can still execute legacy plans during a rolling upgrade.
    enum CodingKeys: String, CodingKey {
        case driver, target, source, filesystem, workDir, planVersion, ventoyOperation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.driver = try c.decode(DriverID.self, forKey: .driver)
        self.target = try c.decode(DiskTarget.self, forKey: .target)
        self.source = try c.decode(InstallSource.self, forKey: .source)
        self.filesystem = try c.decode(FilesystemType.self, forKey: .filesystem)
        self.workDir = try c.decode(String.self, forKey: .workDir)
        self.planVersion = try c.decode(Int.self, forKey: .planVersion)
        self.ventoyOperation = try c.decodeIfPresent(VentoyOperation.self, forKey: .ventoyOperation) ?? .freshInstall
    }
}

public enum PlanValidationError: Error, CustomStringConvertible {
    case invalidDisk(String)
    case refusedSystemDisk(String)
    case nonexternalDisk
    case tooSmall(UInt64, minimum: UInt64)

    public var description: String {
        switch self {
        case .invalidDisk(let d):
            return "Invalid disk device: \(d)"
        case .refusedSystemDisk(let d):
            return "Refusing to operate on system disk \(d)"
        case .nonexternalDisk:
            return "Target disk is not external/removable"
        case .tooSmall(let got, let min):
            return "Target disk (\(got) bytes) is smaller than minimum (\(min) bytes)"
        }
    }
}

public extension InstallPlan {
    static let minimumDiskBytes: UInt64 = 512 * 1024 * 1024

    /// Whole-disk node names only (`disk2`, `disk3`, ...). Slice names
    /// (`disk2s1`) and nonsense (`disk`, `diskfoo`) are rejected before
    /// they ever reach `/dev/rdisk*` as root.
    static func isWholeDiskBSDName(_ s: String) -> Bool {
        guard s.hasPrefix("disk") else { return false }
        let rest = s.dropFirst(4)
        return !rest.isEmpty && rest.allSatisfy { $0.isNumber }
    }

    func validate() throws {
        let name = target.bsdName
        guard Self.isWholeDiskBSDName(name) else {
            throw PlanValidationError.invalidDisk(name)
        }
        guard name != "disk0", name != "disk1" else {
            throw PlanValidationError.refusedSystemDisk(name)
        }
        guard target.isExternal || target.isRemovable else {
            throw PlanValidationError.nonexternalDisk
        }
        guard target.sizeInBytes >= Self.minimumDiskBytes else {
            throw PlanValidationError.tooSmall(target.sizeInBytes, minimum: Self.minimumDiskBytes)
        }
    }
}
