import Foundation

/// Finds the mounted `Ventoy` data volume that lives on a given disk,
/// never just any volume with that name (two sticks can be plugged in).
public enum VentoyVolumeLocator {

    public static func find(onDisk bsdName: String,
                            volumesDirectory: URL = URL(fileURLWithPath: "/Volumes"),
                            deviceIdentifier: (URL) -> String? = VentoyVolumeLocator.deviceIdentifier) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: volumesDirectory.path)) ?? []
        for name in names.sorted() where name.hasPrefix("Ventoy") {
            let candidate = volumesDirectory.appendingPathComponent(name, isDirectory: true)
            // "<bsd>s" and not just "<bsd>": disk1 must not match disk10s1.
            if let id = deviceIdentifier(candidate), id.hasPrefix(bsdName + "s") { return candidate }
        }
        return nil
    }

    public static func deviceIdentifier(of volume: URL) -> String? {
        // Bounded: a stuck diskutil (a drive mid-eject) must not hang the caller.
        guard let info = try? Subprocess.run("/usr/sbin/diskutil", ["info", "-plist", volume.path], timeout: 10),
              info.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: Data(info.stdout.utf8), format: nil) as? [String: Any]
        else { return nil }
        return plist["DeviceIdentifier"] as? String
    }

    /// After a fresh install macOS mounts the new exFAT volume on its own;
    /// this waits for that.
    public static func waitForVolume(onDisk bsdName: String,
                                     timeout: TimeInterval = 30,
                                     pollInterval: TimeInterval = 1,
                                     volumesDirectory: URL = URL(fileURLWithPath: "/Volumes"),
                                     deviceIdentifier: @escaping @Sendable (URL) -> String? = VentoyVolumeLocator.deviceIdentifier) async -> URL? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            // Off the caller's executor: find() runs diskutil and blocks.
            let found = await Task.detached {
                find(onDisk: bsdName, volumesDirectory: volumesDirectory, deviceIdentifier: deviceIdentifier)
            }.value
            if let found { return found }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        } while Date() < deadline && !Task.isCancelled
        return nil
    }
}
