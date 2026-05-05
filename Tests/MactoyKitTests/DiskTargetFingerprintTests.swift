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
        volumes: [DiskVolumeInfo] = []
    ) -> DiskTarget {
        DiskTarget(
            bsdName: bsd,
            sizeInBytes: size,
            isExternal: external,
            isRemovable: removable,
            mediaName: media,
            volumes: volumes
        )
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
