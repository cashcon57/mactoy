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

public struct DiskTarget: Codable, Sendable {
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
}

public enum InstallSource: Codable, Sendable {
    case ventoyVersion(String)
    case localImage(path: String)
}

public struct InstallPlan: Codable, Sendable {
    public let driver: DriverID
    public let target: DiskTarget
    public let source: InstallSource
    public let filesystem: FilesystemType
    public let workDir: String
    public let planVersion: Int

    public init(
        driver: DriverID,
        target: DiskTarget,
        source: InstallSource,
        filesystem: FilesystemType = .exfat,
        workDir: String
    ) {
        self.driver = driver
        self.target = target
        self.source = source
        self.filesystem = filesystem
        self.workDir = workDir
        self.planVersion = 1
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
