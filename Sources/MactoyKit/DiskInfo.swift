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
        // Before `diskutil list`: a backup drive plugged in between the two
        // calls is then in neither set, never in the list unfiltered.
        let backups = try timeMachineWholeDisks()
        let r = try Subprocess.runChecked("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"])
        guard let data = r.stdout.data(using: .utf8) else { return [] }
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
        let whole = plist["WholeDisks"] as? [String] ?? []

        var out: [DiskTarget] = []
        for name in whole where !backups.contains(name) {
            if let info = try? probe(bsdName: name) {
                out.append(info)
            }
        }
        return out
    }

    /// Whole disks that hold a Time Machine backup. Hidden from the disk
    /// list so a backup drive can never be picked as an erase target.
    /// One `diskutil apfs list` call; it reports volume roles even when
    /// the backup volume is not mounted.
    ///
    /// Throws rather than returning an empty set: a failed lookup must not
    /// quietly put a backup drive back in the list. The caller treats a
    /// throw as "no disks this poll" and retries two seconds later.
    static func timeMachineWholeDisks() throws -> Set<String> {
        let r = try Subprocess.runChecked("/usr/sbin/diskutil", ["apfs", "list", "-plist"])
        guard let data = r.stdout.data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw DriverError.diskIO("diskutil apfs list produced unreadable output") }
        return timeMachineWholeDisks(apfsList: plist)
    }

    /// Pure half of `timeMachineWholeDisks()`, split out for tests.
    static func timeMachineWholeDisks(apfsList plist: [String: Any]) -> Set<String> {
        var out = Set<String>()
        for container in plist["Containers"] as? [[String: Any]] ?? [] {
            let volumes = container["Volumes"] as? [[String: Any]] ?? []
            let isBackup = volumes.contains { ($0["Roles"] as? [String] ?? []).contains("Backup") }
            guard isBackup else { continue }
            for store in container["PhysicalStores"] as? [[String: Any]] ?? [] {
                guard let id = store["DeviceIdentifier"] as? String else { continue }
                out.insert(wholeDisk(of: id))
            }
        }
        return out
    }

    /// disk4s2 -> disk4. A whole-disk name comes back unchanged.
    static func wholeDisk(of bsdName: String) -> String {
        guard let r = bsdName.range(of: #"^disk[0-9]+"#, options: .regularExpression) else { return bsdName }
        return String(bsdName[r])
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
    /// One mount point from the APFS container whose physical
    /// store is `physicalStore` (e.g. disk4s2 -> disk5 -> /Volumes/X).
    private static func apfsMountPoints(physicalStore: String) -> [String] {
        guard let info = try? Subprocess.run("/usr/sbin/diskutil", ["info", "-plist", physicalStore]),
              info.status == 0,
              let infoData = info.stdout.data(using: .utf8),
              let infoPlist = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              let container = infoPlist["APFSContainerReference"] as? String,
              let list = try? Subprocess.run("/usr/sbin/diskutil", ["list", "-plist", "/dev/\(container)"]),
              list.status == 0,
              let listData = list.stdout.data(using: .utf8),
              let listPlist = try? PropertyListSerialization.propertyList(from: listData, format: nil) as? [String: Any],
              let allDisks = listPlist["AllDisksAndPartitions"] as? [[String: Any]]
        else { return [] }
        // Every volume in a container reports the container's capacity,
        // so one mounted volume measures the whole container. Returning
        // all of them would count its used space once per volume.
        let first = allDisks
            .filter { ($0["DeviceIdentifier"] as? String) == container }
            .flatMap { $0["APFSVolumes"] as? [[String: Any]] ?? [] }
            .compactMap { $0["MountPoint"] as? String }
            .first { !$0.isEmpty }
        return first.map { [$0] } ?? []
    }

    public static func estimatedUsedBytes(bsdName: String) -> UInt64? {
        // Ask diskutil for this disk's own mount points. The old version
        // listed /Volumes and ran `diskutil info` on every entry, so a
        // Time Machine or network volume unrelated to the target could
        // block it for seconds.
        guard let r = try? Subprocess.run("/usr/sbin/diskutil", ["list", "-plist", "/dev/\(bsdName)"]),
              r.status == 0,
              let data = r.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]]
        else { return nil }

        var mountPoints: [String] = []
        func add(_ mp: Any?) {
            if let mp = mp as? String, !mp.isEmpty { mountPoints.append(mp) }
        }
        for whole in allDisks where (whole["DeviceIdentifier"] as? String) == bsdName {
            add(whole["MountPoint"])
            for part in whole["Partitions"] as? [[String: Any]] ?? [] {
                add(part["MountPoint"])
                // APFS volumes mount on a synthesized container disk, not
                // on this partition. Follow the partition to its container.
                if (part["Content"] as? String) == "Apple_APFS",
                   let partBSD = part["DeviceIdentifier"] as? String {
                    for mp in apfsMountPoints(physicalStore: partBSD) { add(mp) }
                }
            }
        }
        guard !mountPoints.isEmpty else { return nil }

        var used: UInt64 = 0
        for path in mountPoints {
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
        return used
    }
}
