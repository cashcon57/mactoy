import Foundation

public struct VentoyDriver: InstallDriver {
    public let id: DriverID = .ventoy
    public let displayName: String = "Install Ventoy"

    public init() {}

    public func execute(plan: InstallPlan, progress: ProgressSink) async throws {
        switch plan.ventoyOperation {
        case .freshInstall:
            try await executeFreshInstall(plan: plan, progress: progress)
        case .updateInPlace:
            try await executeUpdate(plan: plan, progress: progress)
        }
    }

    private func executeFreshInstall(plan: InstallPlan, progress: ProgressSink) async throws {
        try plan.validate()
        guard case .ventoyVersion(let version) = plan.source else {
            throw DriverError.unsupportedSource("VentoyDriver requires .ventoyVersion source")
        }

        // 1. Fetch + extract Ventoy linux tarball (decompress boot images)
        progress.report(.init(phase: .preparing, message: "Ventoy \(version)"))
        let boot = try await loadBootImages(version: version, secureBoot: plan.secureBoot, progress: progress)

        // 2. Probe disk + verify the live disk still matches the
        //    captured target (Layer 5 of the iron-clad targeting
        //    defense added in v0.3.1; see issue #1). If the user
        //    confirmed disk5 (mediaName "RTL9210B-CG", 476.9 GB) but
        //    the live /dev/disk5 is now a different drive (USB hub
        //    re-enumerated, sleep/wake), we refuse to write.
        let probed = try DiskInfo.probe(bsdName: plan.target.bsdName)
        if let mismatch = plan.target.fingerprintMismatch(against: probed) {
            throw DriverError.validation(
                "Refusing to write \(plan.target.devicePath): the live disk does not match the disk you confirmed. \(mismatch)"
            )
        }
        guard probed.isExternal || probed.isRemovable else {
            throw DriverError.validation("Target disk \(plan.target.devicePath) is not external/removable")
        }
        let diskSectors = probed.sectorCount

        // 3. Compute Ventoy layout for the requested partition style
        //    (issue #11; GPT was the only option before v0.5.0).
        let layout = VentoyLayout.calculate(diskSectors: diskSectors, style: plan.partitionStyle)
        progress.report(.init(
            phase: .preparing,
            message: "Layout (\(plan.partitionStyle.rawValue.uppercased())): part1 \(layout.part1Start)-\(layout.part1End), part2 \(layout.part2Start)-\(layout.part2End)"
        ))

        // 4. Build the partition table before touching the disk, so a
        //    disk too large for MBR fails here rather than mid-write.
        let table: PartitionTable
        switch plan.partitionStyle {
        case .gpt: table = .gpt(GPT.build(diskSectors: diskSectors, layout: layout))
        case .mbr: table = .mbr(try MBR.build(bootImg: boot.bootImg, layout: layout))
        }

        // 5. Unmount + write raw device
        // **Just-in-time fingerprint re-verification (v0.3.1 issue #1).**
        // The fingerprint check at step 2 happened BEFORE the Ventoy
        // tarball download and decompression — that gap can be many
        // seconds. Re-probe the live disk one more time immediately
        // before unmounting so any USB-hub reshuffle that happened
        // during the download window is caught here, not after we've
        // started writing bytes to /dev/rdisk*.
        try plan.target.reverifyFingerprintNow()

        progress.report(.init(phase: .unmounting, message: "Unmounting \(plan.target.devicePath)..."))
        try DiskInfo.unmount(bsdName: plan.target.bsdName)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        progress.report(.init(phase: .writing, message: "Opening \(plan.target.rawDevicePath)..."))
        let writer = try DiskWriter(rawPath: plan.target.rawDevicePath)

        try Self.writeFreshLayout(
            writer: writer,
            boot: boot,
            diskSectors: diskSectors,
            layout: layout,
            table: table,
            progress: progress
        )

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

        // 8. Post-install verification (v0.3.2, issue #5). Run the
        // Ventoy version probe against the freshly-installed disk. If
        // the probe says the disk isn't a valid Ventoy install, the
        // write "succeeded" (no ENXIO, no diskutil failure) but the
        // bytes on disk aren't bootable. Root cause is usually a
        // hardware fault on the USB stick — Ventoy2Disk on Windows
        // fails on the same drives with a similar "read-back doesn't
        // match write" error. Rather than reporting success on a
        // silently-broken install, surface it as a failure so the
        // user knows to try a different stick.
        try await Task.sleep(nanoseconds: 500_000_000)  // let partition 2 settle
        let postInstallProbe = VentoyVersionProbe.probe(bsdName: plan.target.bsdName)
        if !postInstallProbe.isVentoyDisk {
            let issues = postInstallProbe.layoutIssues.joined(separator: "; ")
            throw DriverError.validation(
                "Install wrote successfully but post-install verification failed: \(issues). " +
                "The disk was written without errors, but reading it back doesn't produce a valid Ventoy layout. This usually means the USB drive has a hardware fault — try a different stick. (Cheap USB drives sometimes fail to reliably read back what was just written, and Ventoy2Disk on Windows fails on the same drives with a similar error.)"
            )
        }

        try Self.verifySecureBootLayout(postInstallProbe, written: boot.diskImg)

        // And in the partition style that was asked for (issue #11).
        let readBackStyle: VentoyPartitionStyle? = switch postInstallProbe.partitionStyle {
        case .mbr: .mbr
        case .gpt: .gpt
        case .unknown: nil
        }
        guard readBackStyle == plan.partitionStyle else {
            throw DriverError.validation(
                "Install wrote successfully, but the drive reads back as \(postInstallProbe.partitionStyle.rawValue.uppercased()) " +
                "when \(plan.partitionStyle.rawValue.uppercased()) was written. The drive may not be reliably storing what was written — try again, or try a different USB stick."
            )
        }

        // MBR only: the probe doesn't look at the fields legacy BIOS boot
        // depends on (boot code, active flag, partition types), and the
        // diskutil fallback formatter above writes through MediaKit, which
        // could rewrite sector 0. Compare it with what was written, minus
        // the per-install UUID and disk signature. Not applied to GPT so
        // that existing GPT installs can't start failing on a new check.
        if case .mbr(let written) = table {
            try Self.verifyMBRSector(rawPath: plan.target.rawDevicePath, written: written)
        }

        progress.report(.init(phase: .done, message: "Ventoy \(version) installed to \(plan.target.devicePath)"))
    }

    /// Read sector 0 back and compare it with the MBR sector that was
    /// written, ignoring the random UUID (384..<400) and disk signature
    /// (440..<444) patched in afterwards.
    static func verifyMBRSector(rawPath: String, written: Data) throws {
        let reader = try DiskWriter(rawPath: rawPath, writable: false)
        defer { reader.close() }
        let onDisk = try reader.readSector(lba: 0)
        try checkMBRSector(onDisk, matches: written)
    }

    static func checkMBRSector(_ onDisk: Data, matches written: Data) throws {
        let compared: [Range<Int>] = [0..<384, 400..<440, 444..<512]
        for range in compared where onDisk.subdata(in: range) != written.subdata(in: range) {
            throw DriverError.validation(
                "Install wrote successfully, but sector 0 reads back different from what was written " +
                "(bytes \(range.lowerBound)..<\(range.upperBound)). The drive may still boot on UEFI machines, " +
                "but may not on legacy BIOS PCs. Try again, or try a different USB stick."
            )
        }
    }

    /// Last line of the post-write verification: the VTOYEFI that reads
    /// back from the stick must be in the layout the user asked for.
    ///
    /// Compared against the image that was written rather than against
    /// `plan.secureBoot`: a Ventoy release old enough to predate the
    /// shim has no `grubx64_real.efi` to begin with, and would otherwise
    /// fail here with Secure Boot support "on".
    private static func verifySecureBootLayout(_ probe: VentoyProbeResult, written diskImg: Data) throws {
        let written = try VentoyESP.isSecureBootLayout(image: diskImg)
        guard probe.secureBootEnabled != written else { return }
        throw DriverError.validation(
            "Wrote successfully, but the drive reads back with Secure Boot support " +
            "\(probe.secureBootEnabled ? "on" : "off") when \(written ? "on" : "off") was written. " +
            "The drive may not be reliably storing what was written — try again, or try a different USB stick."
        )
    }

    /// Download (or reuse the cached) Ventoy tarball, extract it into a
    /// throwaway directory, and load the three boot images — with
    /// VTOYEFI already converted to the plain layout when the plan asks
    /// for Secure Boot support off.
    ///
    /// The tarball lives in `VentoyDownloader.cacheRoot()` so repeat
    /// runs skip the 20 MB download (issue #8). `plan.workDir` is no
    /// longer used: before v0.4.0 the app put a fresh random directory
    /// there every run, which both defeated the downloader's cache check
    /// and left the tarball plus ~23 MB of extracted files behind each
    /// time. The daemon now owns both locations.
    private func loadBootImages(
        version: String,
        secureBoot: Bool,
        progress: ProgressSink
    ) async throws -> VentoyBootImages {
        let cacheDir = try VentoyDownloader.prepareCacheDirectory()
        let runDir = try VentoyDownloader.makeRunDirectory()
        defer { try? FileManager.default.removeItem(at: runDir) }

        let downloader = VentoyDownloader()
        let tarball = try await downloader.downloadTarball(version: version, workDir: cacheDir, progress: progress)
        VentoyDownloader.pruneTarballs(in: cacheDir, keeping: tarball)

        let extractDir = runDir.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: false)
        let ventoyDir = try downloader.extractTarball(tarball, workDir: extractDir, progress: progress)

        progress.report(.init(phase: .extracting, message: "Decompressing boot images..."))
        let boot = try VentoyBootImages.load(fromVentoyDir: ventoyDir)
        guard !secureBoot else { return boot }

        progress.report(.init(phase: .extracting, message: "Converting VTOYEFI to the non-Secure-Boot layout..."))
        var diskImg = boot.diskImg
        try VentoyESP.disableSecureBoot(in: &diskImg)
        return VentoyBootImages(bootImg: boot.bootImg, coreImg: boot.coreImg, diskImg: diskImg)
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

    // MARK: - Update-in-place

    /// Update an existing Ventoy install to a new bootloader version
    /// **without** wiping partition 1 (so the user's ISOs and
    /// `/ventoy/` config survive).
    ///
    /// The byte-level operation mirrors `Ventoy2Disk.sh --update`:
    /// rewrite the MBR boot code, the GRUB2 core image in the GPT-gap
    /// reserved sectors, and the entire 32 MiB VTOYEFI partition.
    /// Preserve the existing Ventoy disk UUID (bytes 384–399 of LBA 0)
    /// and the 8 reserved sectors at LBA 2040 across the operation.
    /// VTOYEFI's secure-boot layout follows `plan.secureBoot`, which the
    /// app seeds from the probed state of the existing install.
    ///
    /// Failure modes: this operation is not transactional. If it's
    /// interrupted (USB unplugged, power loss) mid-write, the
    /// bootloader is left in an inconsistent state and the user will
    /// need to re-run update. Their ISOs are never at risk because
    /// partition 1 is never written here.
    private func executeUpdate(plan: InstallPlan, progress: ProgressSink) async throws {
        try plan.validate()
        guard case .ventoyVersion(let version) = plan.source else {
            throw DriverError.unsupportedSource("VentoyDriver requires .ventoyVersion source")
        }

        // 1a. Re-verify the live disk's fingerprint matches the
        //     captured target. Layer 5 of the iron-clad targeting
        //     defense (v0.3.1, issue #1). The Ventoy probe below also
        //     reads the disk, but it doesn't compare against the
        //     captured fingerprint — that comparison happens here.
        progress.report(.init(phase: .preparing, message: "Verifying disk identity..."))
        let probedDisk = try DiskInfo.probe(bsdName: plan.target.bsdName)
        if let mismatch = plan.target.fingerprintMismatch(against: probedDisk) {
            throw DriverError.validation(
                "Refusing to update \(plan.target.devicePath): the live disk does not match the disk you confirmed. \(mismatch)"
            )
        }

        // 1b. Probe to validate this is genuinely a Ventoy disk +
        //     capture the partition-2 start sector + secure-boot state.
        progress.report(.init(phase: .preparing, message: "Validating existing Ventoy install..."))
        let probe = VentoyVersionProbe.probe(bsdName: plan.target.bsdName)
        guard probe.isVentoyDisk else {
            let issues = probe.layoutIssues.joined(separator: "; ")
            throw DriverError.validation(
                "Refusing to update: \(plan.target.devicePath) does not have a valid Ventoy install (\(issues)). " +
                "Use 'Reinstall (erase everything)' to put a fresh Ventoy on this disk."
            )
        }

        // 2. Fetch + extract the new Ventoy tarball.
        progress.report(.init(phase: .preparing, message: "Ventoy \(version)"))
        let boot = try await loadBootImages(version: version, secureBoot: plan.secureBoot, progress: progress)

        // 3. Unmount + open raw device.
        // **Just-in-time fingerprint re-verification (v0.3.1 issue #1).**
        // The fingerprint check at step 1a happened BEFORE the Ventoy
        // tarball download and decompression — that gap can be many
        // seconds. Re-verify here so a USB-hub reshuffle during the
        // download window can't cause us to write to the wrong disk.
        try plan.target.reverifyFingerprintNow()

        progress.report(.init(phase: .unmounting, message: "Unmounting \(plan.target.devicePath)..."))
        try DiskInfo.unmount(bsdName: plan.target.bsdName)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        progress.report(.init(phase: .writing, message: "Opening \(plan.target.rawDevicePath)..."))
        let writer = try DiskWriter(rawPath: plan.target.rawDevicePath)

        // 4–10. The writes themselves.
        try Self.writeBootloaderUpdate(
            writer: writer,
            boot: boot,
            partitionStyle: probe.partitionStyle,
            partition2StartSector: probe.partition2StartSector,
            progress: progress
        )

        try writer.fsync()
        writer.close()
        progress.report(.init(phase: .writing, message: "All writes complete, fsync'd."))

        // 11. Ask macOS to re-read the partition table so it picks up
        //     any metadata changes in partition 2.
        progress.report(.init(phase: .formatting, message: "Reloading disk..."))
        _ = try? Subprocess.run("/usr/sbin/diskutil", ["reloadDisk", "/dev/\(plan.target.bsdName)"])
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try DiskInfo.remount(bsdName: plan.target.bsdName)

        // 12. Post-update verification (v0.3.2, issue #5). Same
        // check as executeFreshInstall: probe the disk after the
        // update and confirm the new bootloader parses back as a
        // valid Ventoy install. If not, the write "succeeded" but
        // the disk isn't bootable — usually a bad USB stick.
        try await Task.sleep(nanoseconds: 500_000_000)
        let postUpdateProbe = VentoyVersionProbe.probe(bsdName: plan.target.bsdName)
        if !postUpdateProbe.isVentoyDisk {
            let issues = postUpdateProbe.layoutIssues.joined(separator: "; ")
            throw DriverError.validation(
                "Update wrote successfully but post-update verification failed: \(issues). " +
                "The disk was written without errors, but reading it back doesn't produce a valid Ventoy layout. Your ISOs on partition 1 are untouched, but the bootloader is in an inconsistent state — try the update again, or use Install Ventoy to reformat the drive."
            )
        }

        try Self.verifySecureBootLayout(postUpdateProbe, written: boot.diskImg)

        progress.report(.init(phase: .done, message: "Ventoy updated to \(version) on \(plan.target.devicePath). ISOs and config preserved."))
    }

    /// Steps 4–10 of the in-place update: every byte the update writes,
    /// and nothing else (no unmount, no fsync, no diskutil). Split out
    /// of `executeUpdate` so tests can run it against a plain file —
    /// the v0.3.x MBR corruption lived here and had no coverage.
    static func writeBootloaderUpdate(
        writer: DiskWriter,
        boot: VentoyBootImages,
        partitionStyle: VentoyProbeResult.PartitionStyle,
        partition2StartSector: UInt64,
        progress: ProgressSink
    ) throws {
        // 4. Preserve bytes that must survive the update:
        //    a. The Ventoy disk UUID at bytes 384..399 of LBA 0.
        //    b. The 8 reserved sectors at LBA 2040..2047.
        progress.report(.init(phase: .preparing, message: "Preserving disk UUID + reserved sectors..."))
        let savedUUID = try writer.readBytes(at: 384, count: 16)
        let savedReserved = try writer.readBytes(at: 2040 * SECTOR_SIZE, count: 8 * Int(SECTOR_SIZE))

        // 5. Write new boot.img bytes 0..439 (preserve everything beyond
        //    that — disk UUID at 384, MBR partition table at 446, etc.).
        //    `boot.img` from the tarball is exactly 512 bytes; we take
        //    the first 440 bytes (the boot-loader code) and patch in
        //    place to leave the partition table + UUID untouched.
        progress.report(.init(phase: .writing, message: "Writing Ventoy boot.img..."))
        let bootCode = boot.bootImg.prefix(440)
        try writer.patchSector(lba: 0, offset: 0, bytes: Data(bootCode))

        // 6. Restore the saved disk UUID — boot.img.prefix(440) didn't
        //    touch bytes 384..399 of the on-disk sector (the patch is
        //    bytes 0..439), but defense in depth: a future boot.img
        //    layout change could shift the UUID position. Writing it
        //    back is cheap.
        try writer.patchSector(lba: 0, offset: 384, bytes: savedUUID)

        // 7. Write the new GRUB2 core image. Position depends on
        //    partition style. Truncate-then-pad order matches the
        //    fresh-install path (`executeFreshInstall`) — the inverse
        //    order would zero out the trailing 0..511 bytes if
        //    coreImg exceeded the cap and wasn't sector-aligned, which
        //    Ventoy's current core.img isn't but defensive code wins.
        progress.report(.init(phase: .writing, message: "Writing core.img..."))
        let coreStartLBA: UInt64
        let coreMaxSectors: Int
        switch partitionStyle {
        case .gpt:
            coreStartLBA = 34
            coreMaxSectors = 2014  // up to LBA 2047 inclusive
        case .mbr:
            coreStartLBA = 1
            coreMaxSectors = 2047
            // Upstream's update makes partition 1 the active one when it
            // finds partition 2 marked active instead (VentoyWorker.sh,
            // MBR branch of the update). Only that exact combination is
            // touched, as upstream does.
            let flags = try writer.readBytes(at: 446, count: 17)
            if flags[0] == 0x00 && flags[16] == 0x80 {
                try writer.patchSector(lba: 0, offset: 446, bytes: Data([0x80]))
                try writer.patchSector(lba: 0, offset: 462, bytes: Data([0x00]))
            }
        case .unknown:
            throw DriverError.diskIO("Update: partition style is unknown (probe was successful but didn't determine MBR/GPT)")
        }
        let coreCapBytes = coreMaxSectors * Int(SECTOR_SIZE)
        var core = Data(boot.coreImg.prefix(coreCapBytes))
        if core.count % Int(SECTOR_SIZE) != 0 {
            let pad = Int(SECTOR_SIZE) - (core.count % Int(SECTOR_SIZE))
            core.append(Data(repeating: 0, count: pad))
        }
        try writer.writeAt(offset: coreStartLBA * SECTOR_SIZE, core)

        // 8. GPT only: re-point boot.img at core.img (LBA 34 → 0x22 at
        //    byte 92) and core.img's first sector at its remainder
        //    (LBA 35 → 0x23 at byte 17908), exactly as the fresh install
        //    does. Steps 5 and 7 just reset both to their stock values.
        //    On MBR the stock values (LBA 1, LBA 2) are already right
        //    and Ventoy2Disk writes nothing here.
        //
        //    v0.3.x treated these two bytes as a secure-boot toggle and
        //    stamped 0x20/0x21 when it thought secure boot was off —
        //    which, given how it detected that, meant every MBR disk.
        //    That pointed boot.img at LBA 32 and overwrote a byte in the
        //    middle of core.img (17908 is inside it when it starts at
        //    LBA 1), breaking legacy-BIOS boot on MBR sticks. Running
        //    this update again repairs them: steps 5 and 7 rewrite both
        //    regions in full.
        if partitionStyle == .gpt {
            try writer.patchSector(lba: 0, offset: 92, bytes: Data([0x22]))
            try writer.patchSector(
                lba: UInt64(17908 / Int(SECTOR_SIZE)),
                offset: 17908 % Int(SECTOR_SIZE),
                bytes: Data([0x23])
            )
        }

        // 9. Overwrite partition 2 (VTOYEFI) wholesale with the new
        //    32 MiB disk image — already in the layout `plan.secureBoot`
        //    asked for. This is the bulk of the write — about 32 MiB on
        //    USB 2.0 takes 3-5 seconds.
        progress.report(.init(phase: .writing, message: "Updating VTOYEFI partition (32 MiB)..."))
        try writer.writeAt(offset: partition2StartSector * SECTOR_SIZE, boot.diskImg)

        // 10. Restore reserved sectors at LBA 2040..2047. These were
        //     read at step 4 *before* the boot.img + core.img writes,
        //     so they survive intact.
        try writer.writeAt(offset: 2040 * SECTOR_SIZE, savedReserved)
    }

    /// The partition table a fresh install writes, built before the disk
    /// is opened.
    enum PartitionTable {
        case gpt(GPT.BuiltGPT)
        case mbr(Data)   // the complete 512-byte sector 0
    }

    /// Every byte a fresh install writes, and nothing else (no unmount,
    /// fsync or diskutil) — split out of `executeFreshInstall` so tests
    /// can run it against a plain file for both partition styles.
    ///
    /// The GPT branch is the pre-v0.5.0 sequence unchanged. The MBR
    /// branch follows `Ventoy2Disk.sh`'s MBR path: table and boot code
    /// in sector 0, `core.img` straight after it at LBA 1 (up to 2047
    /// sectors), and no pointer patches — `boot.img` and `core.img`
    /// already point at LBA 1 and 2 as shipped.
    static func writeFreshLayout(
        writer: DiskWriter,
        boot: VentoyBootImages,
        diskSectors: UInt64,
        layout: VentoyLayout,
        table: PartitionTable,
        progress: ProgressSink
    ) throws {
        // 5a. Zero first 1MB
        progress.report(.init(phase: .writing, message: "Zeroing first 1MB..."))
        try writer.zero(range: 0..<(2048 * SECTOR_SIZE))

        // Both styles: clear whatever a previous GPT left in the last 33
        // sectors. For GPT the backup table is written there next; for
        // MBR, partition 2 covers most of it and a stale backup GPT
        // header in the rest would confuse disk tools.
        progress.report(.init(phase: .writing, message: "Zeroing backup GPT area..."))
        try writer.zero(range: (diskSectors - 33) * SECTOR_SIZE ..< diskSectors * SECTOR_SIZE)

        switch table {
        case .gpt(let built):
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

            // boot.img's pointer to core.img (byte 92 of sector 0). Stock
            // value is LBA 1, right for MBR; on GPT core.img sits at LBA 34
            // (0x22), after the partition entries.
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

            // Same again one level down: core.img's first sector points at
            // the rest of core.img. Byte 17908 is offset 500 of LBA 34;
            // 0x23 = LBA 35.
            let sectorOfMarker = UInt64(17908 / Int(SECTOR_SIZE))
            let offsetInSector = 17908 % Int(SECTOR_SIZE)
            try writer.patchSector(lba: sectorOfMarker, offset: offsetInSector, bytes: Data([0x23]))

        case .mbr(let sector0):
            // Partition table + boot code in one write.
            progress.report(.init(phase: .writing, message: "Writing MBR and Ventoy boot.img..."))
            try writer.writeAt(offset: 0, sector0)

            // core.img at LBA 1..2047 (the gap before partition 1).
            progress.report(.init(phase: .writing, message: "Writing core.img..."))
            var core = Data(boot.coreImg.prefix(Int(2047 * SECTOR_SIZE)))
            if core.count % Int(SECTOR_SIZE) != 0 {
                let pad = Int(SECTOR_SIZE) - (core.count % Int(SECTOR_SIZE))
                core.append(Data(repeating: 0, count: pad))
            }
            try writer.writeAt(offset: 1 * SECTOR_SIZE, core)
        }

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
    }
}
