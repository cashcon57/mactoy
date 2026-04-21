import Foundation

public struct VentoyDriver: InstallDriver {
    public let id: DriverID = .ventoy
    public let displayName: String = "Install Ventoy"

    public init() {}

    public func execute(plan: InstallPlan, progress: ProgressSink) async throws {
        try plan.validate()
        guard case .ventoyVersion(let version) = plan.source else {
            throw DriverError.unsupportedSource("VentoyDriver requires .ventoyVersion source")
        }

        let workDir = URL(fileURLWithPath: plan.workDir, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // 1. Fetch + extract Ventoy linux tarball (decompress boot images)
        progress.report(.init(phase: .preparing, message: "Ventoy \(version)"))
        let downloader = VentoyDownloader()
        let tarball = try await downloader.downloadTarball(version: version, workDir: workDir, progress: progress)
        let ventoyDir = try downloader.extractTarball(tarball, workDir: workDir, progress: progress)

        progress.report(.init(phase: .extracting, message: "Decompressing boot images..."))
        let boot = try VentoyBootImages.load(fromVentoyDir: ventoyDir)

        // 2. Probe disk
        let probed = try DiskInfo.probe(bsdName: plan.target.bsdName)
        guard probed.isExternal || probed.isRemovable else {
            throw DriverError.validation("Target disk \(plan.target.devicePath) is not external/removable")
        }
        let diskSectors = probed.sectorCount

        // 3. Compute Ventoy layout
        let layout = VentoyLayout.calculate(diskSectors: diskSectors)
        progress.report(.init(
            phase: .preparing,
            message: "Layout: part1 \(layout.part1Start)-\(layout.part1End), part2 \(layout.part2Start)-\(layout.part2End)"
        ))

        // 4. Build GPT structures
        let built = GPT.build(diskSectors: diskSectors, layout: layout)

        // 5. Unmount + write raw device
        progress.report(.init(phase: .unmounting, message: "Unmounting \(plan.target.devicePath)..."))
        try DiskInfo.unmount(bsdName: plan.target.bsdName)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        progress.report(.init(phase: .writing, message: "Opening \(plan.target.rawDevicePath)..."))
        let writer = try DiskWriter(rawPath: plan.target.rawDevicePath)

        // 5a. Zero first 1MB
        progress.report(.init(phase: .writing, message: "Zeroing first 1MB..."))
        try writer.zero(range: 0..<(2048 * SECTOR_SIZE))

        // 5b. Zero backup GPT area (last 33 sectors)
        progress.report(.init(phase: .writing, message: "Zeroing backup GPT area..."))
        try writer.zero(range: (diskSectors - 33) * SECTOR_SIZE ..< diskSectors * SECTOR_SIZE)

        // 5c. Protective MBR
        progress.report(.init(phase: .writing, message: "Writing protective MBR..."))
        try writer.writeAt(offset: 0, built.protectiveMBR)

        // 5d. Primary GPT header (LBA 1)
        progress.report(.init(phase: .writing, message: "Writing primary GPT header..."))
        try writer.writeAt(offset: SECTOR_SIZE, built.primaryHeader)

        // 5e. Primary GPT entries (LBA 2..33)
        progress.report(.init(phase: .writing, message: "Writing GPT entries..."))
        try writer.writeAt(offset: 2 * SECTOR_SIZE, built.entries)

        // 5f. Backup GPT entries + backup header
        progress.report(.init(phase: .writing, message: "Writing backup GPT..."))
        try writer.writeAt(offset: (diskSectors - 33) * SECTOR_SIZE, built.entries)
        try writer.writeAt(offset: (diskSectors - 1) * SECTOR_SIZE, built.backupHeader)

        // 5g. Ventoy boot.img: first 446 bytes of MBR (BIOS boot code)
        progress.report(.init(phase: .writing, message: "Writing Ventoy boot.img..."))
        let bootCode = boot.bootImg.prefix(446)
        try writer.patchSector(lba: 0, offset: 0, bytes: Data(bootCode))

        // GPT marker at offset 92 of sector 0
        try writer.patchSector(lba: 0, offset: 92, bytes: Data([0x22]))

        // 5h. core.img at sectors 34..2047 (GPT gap area)
        progress.report(.init(phase: .writing, message: "Writing core.img..."))
        let coreMax = Int(2014 * SECTOR_SIZE)
        var core = Data(boot.coreImg.prefix(coreMax))
        if core.count % Int(SECTOR_SIZE) != 0 {
            let pad = Int(SECTOR_SIZE) - (core.count % Int(SECTOR_SIZE))
            core.append(Data(repeating: 0, count: pad))
        }
        try writer.writeAt(offset: 34 * SECTOR_SIZE, core)

        // Second GPT marker at offset 17908
        let sectorOfMarker = UInt64(17908 / Int(SECTOR_SIZE))
        let offsetInSector = 17908 % Int(SECTOR_SIZE)
        try writer.patchSector(lba: sectorOfMarker, offset: offsetInSector, bytes: Data([0x23]))

        // 5i. ventoy.disk.img to partition 2 (VTOYEFI)
        progress.report(.init(phase: .writing, message: "Writing VTOYEFI partition image..."))
        try writer.writeAt(offset: layout.part2Start * SECTOR_SIZE, boot.diskImg)

        // Disk UUID at offset 384 of sector 0
        var uuidBytes = [UInt8](repeating: 0, count: 16)
        let u = UUID().uuid
        uuidBytes[0] = u.0; uuidBytes[1] = u.1; uuidBytes[2] = u.2; uuidBytes[3] = u.3
        uuidBytes[4] = u.4; uuidBytes[5] = u.5; uuidBytes[6] = u.6; uuidBytes[7] = u.7
        uuidBytes[8] = u.8; uuidBytes[9] = u.9; uuidBytes[10] = u.10; uuidBytes[11] = u.11
        uuidBytes[12] = u.12; uuidBytes[13] = u.13; uuidBytes[14] = u.14; uuidBytes[15] = u.15
        try writer.patchSector(lba: 0, offset: 384, bytes: Data(uuidBytes))

        // Disk signature at offset 440 of sector 0 (random 4 bytes)
        var sig = Data(count: 4)
        _ = sig.withUnsafeMutableBytes { raw in
            SecRandomCopyBytes(kSecRandomDefault, 4, raw.baseAddress!)
        }
        try writer.patchSector(lba: 0, offset: 440, bytes: sig)

        try writer.fsync()
        // Release the raw-disk fd so macOS can re-scan the partition
        // table. `diskutil reloadDisk` silently fails to re-probe if a
        // writer still holds /dev/rdisk* open — the kernel treats the
        // disk as busy until every fd is closed.
        writer.close()
        progress.report(.init(phase: .writing, message: "All writes complete, fsync'd."))

        // 6. Format Ventoy partition as exFAT.
        //
        // After a raw GPT write, macOS's DiskArbitration layer does not
        // immediately see the new partition entries — `diskutil info
        // /dev/<bsd>s1` returns "Unable to find disk" for a short window
        // even though the bytes are on the platter. Poll until the
        // partition node is queryable instead of guessing with a fixed
        // sleep.
        progress.report(.init(phase: .formatting, message: "Waiting for macOS to detect new partitions..."))
        try DiskInfo.unmount(bsdName: plan.target.bsdName)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let part1 = "/dev/\(plan.target.bsdName)s1"
        try await waitForPartition(bsd: plan.target.bsdName, partition: 1, timeoutSeconds: 90, progress: progress)

        progress.report(.init(phase: .formatting, message: "Formatting \(part1) as exFAT..."))

        let fmt = try Subprocess.run("/sbin/newfs_exfat", ["-v", "Ventoy", part1])
        if fmt.status != 0 {
            progress.report(.init(phase: .formatting, message: "newfs_exfat failed, falling back to diskutil..."))
            _ = try Subprocess.runChecked(
                "/usr/sbin/diskutil",
                ["eraseVolume", "ExFAT", "Ventoy", part1]
            )
        }

        // 7. Remount + verify
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try DiskInfo.remount(bsdName: plan.target.bsdName)
        progress.report(.init(phase: .done, message: "Ventoy \(version) installed to \(plan.target.devicePath)"))
    }

    /// Force macOS to re-read the partition table on the target disk,
    /// then poll until a new partition node shows up in /dev/.
    ///
    /// `diskutil list /dev/diskN` merely queries the current cached
    /// state — after a raw GPT write, the kernel still thinks the disk
    /// is empty. `diskutil reloadDisk /dev/diskN` is the missing piece:
    /// it tells the media layer to re-probe the GPT and re-emit the
    /// partition slice nodes. On older/stubborn setups, a
    /// `diskutil unmountDisk` + re-attach dance is the last resort.
    private func waitForPartition(
        bsd: String,
        partition: Int,
        timeoutSeconds: Int,
        progress: ProgressSink
    ) async throws {
        let devPath = "/dev/\(bsd)s\(partition)"
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))

        // First attempt: explicit reloadDisk, which is the supported
        // macOS API for "I changed the partition table under you, please
        // pick it up." This succeeds silently on most modern macOS.
        progress.report(.init(
            phase: .formatting,
            message: "Asking macOS to re-read the partition table…"
        ))
        _ = try? Subprocess.run("/usr/sbin/diskutil", ["reloadDisk", "/dev/\(bsd)"])
        try? await Task.sleep(nanoseconds: 500_000_000)

        var attempt = 0
        var lastReport = Date.distantPast
        while Date() < deadline {
            attempt += 1

            // newfs_exfat only needs the kernel /dev node. DiskArbitration
            // catches up some time later — we don't have to wait for it.
            if FileManager.default.fileExists(atPath: devPath) {
                return
            }

            // Retry `reloadDisk` every ~10 seconds. Some USB bridges
            // take multiple nudges before macOS picks up the new GPT.
            if attempt % 10 == 0 {
                _ = try? Subprocess.run("/usr/sbin/diskutil", ["reloadDisk", "/dev/\(bsd)"])
            }

            // Throttle progress chatter to once every 5 seconds.
            let now = Date()
            if now.timeIntervalSince(lastReport) >= 5 {
                lastReport = now
                let elapsed = Int(now.timeIntervalSince(deadline.addingTimeInterval(-TimeInterval(timeoutSeconds))))
                progress.report(.init(
                    phase: .formatting,
                    message: "Waiting for macOS to detect new partitions (\(elapsed)s / \(timeoutSeconds)s)…"
                ))
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw DriverError.diskIO(
            "partition \(devPath) never appeared after \(timeoutSeconds)s. " +
            "macOS did not pick up the new partition table. Try unplugging " +
            "and replugging the USB drive, then run Manage Disk to verify — " +
            "the GPT and boot images are already on the drive."
        )
    }
}
