import Foundation

public enum FilesystemType: String, Codable, Sendable, CaseIterable {
    case exfat
}

public enum DriverID: String, Codable, Sendable {
    case ventoy
    case rawImage = "raw-image"
}

public struct DiskTarget: Codable, Sendable {
    public let bsdName: String
    public let sizeInBytes: UInt64
    public let isExternal: Bool
    public let isRemovable: Bool

    public init(bsdName: String, sizeInBytes: UInt64, isExternal: Bool, isRemovable: Bool) {
        self.bsdName = bsdName
        self.sizeInBytes = sizeInBytes
        self.isExternal = isExternal
        self.isRemovable = isRemovable
    }

    public var devicePath: String { "/dev/\(bsdName)" }
    public var rawDevicePath: String { "/dev/r\(bsdName)" }
    public var sectorCount: UInt64 { sizeInBytes / 512 }
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

    func validate() throws {
        let name = target.bsdName
        guard name.hasPrefix("disk") else {
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
