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

        let mediaName = (plist["MediaName"] as? String)?.trimmingCharacters(in: .whitespaces)
        let volumes = enumerateVolumes(on: bsdName)

        return DiskTarget(
            bsdName: bsdName,
            sizeInBytes: size,
            isExternal: external,
            isRemovable: removable,
            mediaName: mediaName?.isEmpty == true ? nil : mediaName,
            volumes: volumes
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

    /// Enumerate partitions / volumes on a given whole-disk BSD name.
    /// Uses `diskutil list -plist /dev/<bsd>` then probes each partition
    /// for its friendly volume name. We don't throw from this path
    /// because the calling UI should degrade gracefully if individual
    /// partitions can't be queried.
    private static func enumerateVolumes(on wholeDisk: String) -> [DiskVolumeInfo] {
        guard let r = try? Subprocess.runChecked("/usr/sbin/diskutil", ["list", "-plist", "/dev/\(wholeDisk)"]),
              let data = r.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]]
        else { return [] }

        var out: [DiskVolumeInfo] = []
        for whole in allDisks where (whole["DeviceIdentifier"] as? String) == wholeDisk {
            guard let parts = whole["Partitions"] as? [[String: Any]] else { continue }
            for part in parts {
                guard let bsd = part["DeviceIdentifier"] as? String else { continue }
                let size = (part["Size"] as? NSNumber)?.uint64Value ?? 0
                let volName = (part["VolumeName"] as? String)
                    ?? (part["Content"] as? String)
                    ?? ""
                out.append(DiskVolumeInfo(
                    bsdName: bsd,
                    volumeName: volName,
                    sizeInBytes: size
                ))
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

    /// Best-effort estimate of how many bytes of user data live on the
    /// target disk right now. Sum of `used = total - available` for
    /// every currently-mounted volume whose diskutil `DeviceIdentifier`
    /// sits on `bsdName`.
    ///
    /// Returns `nil` when no volumes on the disk are mounted (we can't
    /// peek inside an unmounted partition without reading its
    /// filesystem), which the UI presents as "up to <disk size>".
    public static func estimatedUsedBytes(bsdName: String) -> UInt64? {
        guard let mounts = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") else {
            return nil
        }
        var used: UInt64 = 0
        var matched = false

        for name in mounts {
            let path = "/Volumes/\(name)"
            guard let r = try? Subprocess.run("/usr/sbin/diskutil", ["info", "-plist", path]),
                  r.status == 0,
                  let data = r.stdout.data(using: .utf8),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let deviceIdentifier = plist["DeviceIdentifier"] as? String,
                  deviceIdentifier == bsdName || deviceIdentifier.hasPrefix(bsdName + "s")
            else { continue }

            matched = true

            let url = URL(fileURLWithPath: path)
            if let values = try? url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey
            ]),
               let total = values.volumeTotalCapacity,
               let available = values.volumeAvailableCapacity,
               total >= available {
                used += UInt64(total - available)
            }
        }

        return matched ? used : nil
    }
}
