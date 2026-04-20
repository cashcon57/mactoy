import Foundation

public enum DiskInfo {
    /// Query `diskutil info` and return a DiskTarget for the given BSD name.
    public static func probe(bsdName: String) throws -> DiskTarget {
        let r = try Subprocess.runChecked("/usr/sbin/diskutil", ["info", "-plist", "/dev/\(bsdName)"])
        guard let data = r.stdout.data(using: .utf8) else {
            throw DriverError.diskIO("diskutil produced non-UTF8 output")
        }
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]

        let size = (plist["TotalSize"] as? NSNumber)?.uint64Value ?? (plist["Size"] as? NSNumber)?.uint64Value ?? 0
        let external = (plist["DeviceInternal"] as? NSNumber)?.boolValue == false
        let removable = (plist["Removable"] as? NSNumber)?.boolValue == true
            || (plist["RemovableMedia"] as? NSNumber)?.boolValue == true
            || (plist["Ejectable"] as? NSNumber)?.boolValue == true

        return DiskTarget(
            bsdName: bsdName,
            sizeInBytes: size,
            isExternal: external,
            isRemovable: removable
        )
    }

    /// Enumerate all external/physical whole disks on the system.
    public static func enumerateExternal() throws -> [DiskTarget] {
        let r = try Subprocess.runChecked("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"])
        guard let data = r.stdout.data(using: .utf8) else { return [] }
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
        let whole = plist["WholeDisks"] as? [String] ?? []

        var out: [DiskTarget] = []
        for name in whole {
            if let info = try? probe(bsdName: name) {
                out.append(info)
            }
        }
        return out
    }

    public static func unmount(bsdName: String) throws {
        _ = try? Subprocess.run("/usr/sbin/diskutil", ["unmountDisk", "force", "/dev/\(bsdName)"])
    }

    public static func remount(bsdName: String) throws {
        _ = try? Subprocess.run("/usr/sbin/diskutil", ["mountDisk", "/dev/\(bsdName)"])
    }
}
