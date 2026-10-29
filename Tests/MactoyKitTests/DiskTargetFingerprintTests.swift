import Testing
import Foundation
@testable import MactoyKit

@Suite("DiskTarget.fingerprintMismatch")
struct DiskTargetFingerprintTests {

    private func target(
        bsd: String = "disk5",
        size: UInt64 = 476 * 1024 * 1024 * 1024,
        external: Bool = true,
        removable: Bool = true,
        media: String? = "RTL9210B-CG",
        volumes: [DiskVolumeInfo] = [],
        serial: String? = nil
    ) -> DiskTarget {
        DiskTarget(
            bsdName: bsd,
            sizeInBytes: size,
            isExternal: external,
            isRemovable: removable,
            mediaName: media,
            volumes: volumes,
            serialNumber: serial
        )
    }

    @Test("a different drive of the same model is caught by its serial number (#21)")
    func serialMismatch() {
        let msg = target(serial: "AA0000000001").fingerprintMismatch(against: target(serial: "AA0000000002"))
        #expect(msg?.contains("Serial number changed") == true)
        #expect(msg?.contains("AA000") == false)
    }

    @Test("the same serial, or a serial on only one side, is not a mismatch")
    func serialOnlyComparedWhenBothKnown() {
        #expect(target(serial: "AA01").fingerprintMismatch(against: target(serial: "AA01")) == nil)
        #expect(target(serial: "AA01").fingerprintMismatch(against: target(serial: nil)) == nil)
        #expect(target(serial: nil).fingerprintMismatch(against: target(serial: "AA01")) == nil)
    }

    @Test("a plan from before v0.8.0, without a serial, still decodes")
    func oldPlanDecodes() throws {
        let old = #"{"bsdName":"disk5","sizeInBytes":1000,"isExternal":true,"isRemovable":true,"mediaName":"X","volumes":[]}"#
        let decoded = try JSONDecoder().decode(DiskTarget.self, from: Data(old.utf8))
        #expect(decoded.serialNumber == nil)
        let roundTrip = try JSONDecoder().decode(DiskTarget.self, from: JSONEncoder().encode(target(serial: "AA01")))
        #expect(roundTrip.serialNumber == "AA01")
    }

    @Test("placeholder serials count as none")
    func cleanSerial() {
        #expect(DiskInfo.cleanSerial("  1234ABCD \0") == "1234ABCD")
        #expect(DiskInfo.cleanSerial("") == nil)
        #expect(DiskInfo.cleanSerial("    ") == nil)
        #expect(DiskInfo.cleanSerial("000000000000") == nil)
        #expect(DiskInfo.cleanSerial(42) == nil)
        #expect(DiskInfo.cleanSerial(nil) == nil)
    }

    @Test("the serial lookup finds nothing for names that aren't disks, without crashing")
    func serialLookupForMissingDisk() {
        #expect(DiskInfo.serialNumber(bsdName: "disk999") == nil)
        #expect(DiskInfo.serialNumber(bsdName: "not-a-disk") == nil)
    }

    @Test("identical disks produce no mismatch")
    func identical() {
        let captured = target()
        let live = target()
        #expect(captured.fingerprintMismatch(against: live) == nil)
    }

    @Test("partition layout changes are NOT mismatches (volumes are expected to drift)")
    func volumesDontCount() {
        let captured = target(volumes: [
            DiskVolumeInfo(bsdName: "disk5s1", volumeName: "EFI", sizeInBytes: 100_000_000),
            DiskVolumeInfo(bsdName: "disk5s2", volumeName: "Microsoft Basic Data", sizeInBytes: 476_000_000_000)
        ])
        // Live disk has been freshly partitioned mid-flow.
        let live = target(volumes: [
            DiskVolumeInfo(bsdName: "disk5s1", volumeName: "Ventoy", sizeInBytes: 476_000_000_000),
            DiskVolumeInfo(bsdName: "disk5s2", volumeName: "VTOYEFI", sizeInBytes: 32_000_000)
        ])
        #expect(captured.fingerprintMismatch(against: live) == nil)
    }

    @Test("BSD name change is the highest-priority mismatch")
    func bsdMismatch() {
        let captured = target(bsd: "disk5")
        let live = target(bsd: "disk6")
        let mismatch = captured.fingerprintMismatch(against: live)
        #expect(mismatch != nil)
        #expect(mismatch?.contains("BSD name") == true)
    }

    @Test("size change is detected")
    func sizeMismatch() {
        let captured = target(size: 476 * 1024 * 1024 * 1024)
        let live = target(size: 238 * 1024 * 1024 * 1024)
        let mismatch = captured.fingerprintMismatch(against: live)
        #expect(mismatch?.contains("Size") == true)
    }

    @Test("media name change is detected (different physical drive in the same slot)")
    func mediaNameMismatch() {
        // The exact case from issue #1: user has "RTL9210B-CG" at disk5,
        // a USB-C hub re-enumerates and now disk5 points at the
        // "SSD 840 PRO" that used to be disk6. Sizes happen to differ
        // here but EVEN if they coincidentally matched, the media
        // name change would still flag it.
        let captured = target(bsd: "disk5", size: 476 * 1024 * 1024 * 1024, media: "RTL9210B-CG")
        let live = target(bsd: "disk5", size: 238 * 1024 * 1024 * 1024, media: "SSD 840 PRO Seri")
        #expect(captured.fingerprintMismatch(against: live) != nil)
    }

    @Test("media name nil-vs-set is a mismatch")
    func mediaNameNilSet() {
        let captured = target(media: "RTL9210B-CG")
        let live = target(media: nil)
        #expect(captured.fingerprintMismatch(against: live)?.contains("Media name") == true)
    }

    @Test("isExternal regression detected (e.g. internal disk now reachable)")
    func externalFlagMismatch() {
        let captured = target(external: true)
        let live = target(external: false)
        #expect(captured.fingerprintMismatch(against: live)?.contains("External") == true)
    }

    @Test("isRemovable change detected")
    func removableFlagMismatch() {
        let captured = target(removable: true)
        let live = target(removable: false)
        #expect(captured.fingerprintMismatch(against: live)?.contains("Removable") == true)
    }
}

@Suite("Fingerprint check before formatting (#21)")
struct FormatFingerprintTests {
    private let confirmed = DiskTarget(bsdName: "disk5", sizeInBytes: 64_000_000_000,
                                       isExternal: true, isRemovable: true, mediaName: "SanDisk Ultra")

    @Test("the same drive passes")
    func sameDrive() throws {
        try VentoyDriver.reverifyBeforeFormatting(confirmed) { _ in confirmed }
    }

    @Test("a different drive stops it, and the message says what state the confirmed drive is in")
    func differentDrive() {
        let other = DiskTarget(bsdName: "disk5", sizeInBytes: 32_000_000_000,
                               isExternal: true, isRemovable: true, mediaName: "Kingston")
        do {
            try VentoyDriver.reverifyBeforeFormatting(confirmed) { _ in other }
            Issue.record("expected a refusal")
        } catch {
            let text = "\(error)"
            #expect(text.contains("Stopped before formatting /dev/disk5"))
            #expect(text.contains("no longer the drive you confirmed"))
            #expect(text.contains("isn't formatted yet"))
            #expect(!text.contains("Re-select"))
        }
    }

    @Test("a drive that's gone stops it too")
    func driveGone() {
        do {
            try VentoyDriver.reverifyBeforeFormatting(confirmed) { _ in throw DriverError.diskIO("not found") }
            Issue.record("expected a refusal")
        } catch {
            #expect("\(error)".contains("can't see the drive any more"))
        }
    }
}
