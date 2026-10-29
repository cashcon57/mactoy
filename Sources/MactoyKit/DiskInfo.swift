import Foundation
import IOKit

public enum DiskInfo {
    /// Query `diskutil info` and return a DiskTarget for the given BSD name.
    public static func probe(bsdName: String) throws -> DiskTarget {
        let r = try Subprocess.runChecked("/usr/sbin/diskutil", ["info", "-plist", "/dev/\(bsdName)"])
        guard let data = r.stdout.data(using: .utf8) else {
            throw DriverError.diskIO("diskutil produced non-UTF8 output")
        }
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
        return target(bsdName: bsdName, info: plist, volumes: enumerateVolumes(on: bsdName),
                      serialNumber: serialNumber(bsdName: bsdName))
    }

    /// A `DiskTarget` from `diskutil info -plist` output. Separate so tests can feed it the
    /// output for each kind of drive.
    ///
    /// External: `diskutil` says `Internal = false`. Before v0.8.0 this read `DeviceInternal`,
    /// a key `diskutil` doesn't have, so no drive was ever seen as external; writes were still
    /// allowed through the removable and ejectable flags, which every USB drive sets.
    static func target(bsdName: String, info plist: [String: Any], volumes: [DiskVolumeInfo], serialNumber: String?) -> DiskTarget {
        func flag(_ key: String) -> Bool? { (plist[key] as? NSNumber)?.boolValue }
        let size = (plist["TotalSize"] as? NSNumber)?.uint64Value ?? (plist["Size"] as? NSNumber)?.uint64Value ?? 0
        let external = flag("Internal") == false || flag("DeviceInternal") == false
        let removable = flag("Removable") == true || flag("RemovableMedia") == true || flag("Ejectable") == true
        let mediaName = (plist["MediaName"] as? String)?.trimmingCharacters(in: .whitespaces)
        return DiskTarget(
            bsdName: bsdName,
            sizeInBytes: size,
            isExternal: external,
            isRemovable: removable,
            mediaName: mediaName?.isEmpty == true ? nil : mediaName,
            volumes: volumes,
            serialNumber: serialNumber
        )
    }

    /// The drive's own serial number from the IORegistry, or nil (#21).
    static func serialNumber(bsdName: String) -> String? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        // IOServiceGetMatchingService consumes `matching`.
        let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard media != IO_OBJECT_NULL else { return nil }
        return serialNumber(walkingUpFrom: IORegistryNode(retained: media))
    }

    /// Walks up from the disk's IOMedia and takes the first of: a storage device's
    /// `Device Characteristics` > `Serial Number`, or the USB device's `USB Serial Number`.
    /// The walk stops at the first USB device, so a hub's serial is never mistaken for the
    /// drive's: that would change when the same drive moves to another port. Separate from
    /// IOKit so tests can walk the device trees of each kind of drive.
    static func serialNumber(walkingUpFrom start: some RegistryNode) -> String? {
        var node: (any RegistryNode)? = start
        for _ in 0..<32 {
            guard let current = node else { return nil }
            if current.conforms(to: "IOBlockStorageDevice"),
               let characteristics = current.property("Device Characteristics") as? [String: Any],
               let serial = cleanSerial(characteristics["Serial Number"]) {
                return serial
            }
            if current.conforms(to: "IOUSBHostDevice") || current.conforms(to: "IOUSBDevice") {
                return cleanSerial(current.property("USB Serial Number"))
            }
            node = current.parent()
        }
        return nil
    }

    /// Trims spaces and NULs; nil for an empty or placeholder serial. Some drives report all
    /// zeros or all spaces, which says nothing about which drive it is.
    static func cleanSerial(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let serial = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        guard !serial.isEmpty, serial.contains(where: { $0 != "0" }) else { return nil }
        return serial
    }

    /// Enumerate all external/physical whole disks on the system.
    /// External disks plus which of them hold a Time Machine backup.
    public struct ExternalDiskScan: Sendable, Equatable {
        public let disks: [DiskTarget]
        /// Whole-disk BSD names with a Time Machine (APFS "Backup" role)
        /// volume. The app lists these but won't write to one unless the
        /// user unlocks it (PR #13, v0.6.0).
        public let timeMachineDisks: Set<String>

        public init(disks: [DiskTarget], timeMachineDisks: Set<String>) {
            self.disks = disks
            self.timeMachineDisks = timeMachineDisks
        }
    }

    /// One poll of the external disks. Throws if either lookup fails, so
    /// the caller keeps its previous list rather than showing a backup
    /// drive without its Time Machine mark.
    public static func scanExternal() throws -> ExternalDiskScan {
        // List first, then look up backups: a backup drive plugged in
        // between the two calls is then not listed this poll, rather than
        // listed without its mark. (The other order gets that wrong.) The
        // app also re-checks live in `run()`, which covers a container
        // that attaches a moment after its disk appears.
        let disks = try enumerateExternal()
        let backups = try timeMachineWholeDisks()
        return ExternalDiskScan(disks: disks, timeMachineDisks: backups.intersection(disks.map(\.bsdName)))
    }

    /// Enumerate all external/physical whole disks on the system,
    /// Time Machine drives included (see `scanExternal`).
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

    /// Whole disks that hold a Time Machine backup. Mactoy refuses to
    /// write to these unless the user unlocks the drive for the session.
    /// One `diskutil apfs list` call; it reports volume roles even when
    /// the backup volume is not mounted.
    ///
    /// Throws rather than returning an empty set: a failed lookup must not
    /// quietly list a backup drive as an ordinary disk. The caller keeps
    /// its previous list and retries two seconds later.
    public static func timeMachineWholeDisks() throws -> Set<String> {
        let r = try Subprocess.runChecked("/usr/sbin/diskutil", ["apfs", "list", "-plist"], timeout: 20)
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
            // "Backup" is Time Machine's role (diskutil(8): "T - Backup
            // (Time Machine)"). The man page also lists "C - Sidecar (Time
            // Machine)"; what creates one isn't documented, so treat it the
            // same way: locking a drive by mistake is recoverable, erasing
            // backups isn't.
            let isBackup = volumes.contains {
                let roles = $0["Roles"] as? [String] ?? []
                return roles.contains("Backup") || roles.contains("Sidecar")
            }
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

/// One entry in the device registry, as the serial-number walk sees it.
protocol RegistryNode {
    func conforms(to className: String) -> Bool
    func property(_ key: String) -> Any?
    func parent() -> (any RegistryNode)?
}

/// A live IORegistry entry in the service plane. Owns one reference, released on deinit.
final class IORegistryNode: RegistryNode {
    private let entry: io_registry_entry_t

    init(retained entry: io_registry_entry_t) { self.entry = entry }
    deinit { IOObjectRelease(entry) }

    func conforms(to className: String) -> Bool { IOObjectConformsTo(entry, className) != 0 }

    func property(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    func parent() -> (any RegistryNode)? {
        var parent: io_registry_entry_t = IO_OBJECT_NULL
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        return IORegistryNode(retained: parent)
    }
}

