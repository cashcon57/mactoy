import Testing
import Foundation
@testable import MactoyKit

@Suite("InstallPlan.validate")
struct InstallPlanValidateTests {

    private func target(
        bsd: String = "disk6",
        size: UInt64 = 124 * 1024 * 1024 * 1024,
        external: Bool = true,
        removable: Bool = true
    ) -> DiskTarget {
        DiskTarget(bsdName: bsd, sizeInBytes: size, isExternal: external, isRemovable: removable)
    }

    private func plan(_ t: DiskTarget) -> InstallPlan {
        InstallPlan(
            driver: .ventoy,
            target: t,
            source: .ventoyVersion("1.1.11"),
            workDir: "/tmp/ventoy",
            partitionStyle: .gpt
        )
    }

    @Test("valid external disk passes")
    func validPasses() throws {
        try plan(target()).validate()
    }

    @Test("rejects disk0/disk1")
    func rejectsSystemDisk() {
        #expect(throws: PlanValidationError.self) {
            try plan(target(bsd: "disk0")).validate()
        }
        #expect(throws: PlanValidationError.self) {
            try plan(target(bsd: "disk1")).validate()
        }
    }

    @Test("rejects slice names and malformed bsdNames")
    func rejectsNonWholeDisk() {
        let bad = [
            "disk2s1",       // a slice, not a whole disk
            "disk",          // empty index
            "diskfoo",       // non-numeric
            "disk10s3",      // two-digit slice
            "disk2 ",        // trailing space
            "../disk2",      // path traversal
            "disk2/../disk0", // path traversal
            "disk\u{0663}",  // Arabic-Indic three: a number, not an ASCII digit (#21)
            "disk\u{FF12}",  // fullwidth two
            "disk\u{2167}",  // Roman numeral eight
            "disk\u{00BD}",  // one half
            "disk2\u{301}",  // an ASCII digit with a combining accent
            "disk0\u{338}",  // would also slip past the disk0 guard
        ]
        for name in bad {
            #expect(throws: PlanValidationError.self) {
                try plan(target(bsd: name)).validate()
            }
        }
    }

    @Test("accepts multi-digit disk indices")
    func acceptsTwoDigitIndex() throws {
        try plan(target(bsd: "disk10")).validate()
        try plan(target(bsd: "disk127")).validate()
    }

    @Test("rejects non-external non-removable")
    func rejectsInternal() {
        #expect(throws: PlanValidationError.self) {
            try plan(target(external: false, removable: false)).validate()
        }
    }

    @Test("rejects tiny disks")
    func rejectsTooSmall() {
        #expect(throws: PlanValidationError.self) {
            try plan(target(size: 128 * 1024 * 1024)).validate()
        }
    }

    @Test("codable round-trip")
    func codableRoundTrip() throws {
        let p = plan(target())
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(InstallPlan.self, from: data)
        #expect(decoded.target.bsdName == p.target.bsdName)
        #expect(decoded.target.sizeInBytes == p.target.sizeInBytes)
        if case .ventoyVersion(let v) = decoded.source {
            #expect(v == "1.1.11")
        } else {
            Issue.record("expected .ventoyVersion source")
        }
    }

    @Test("ventoyOperation defaults to .freshInstall")
    func ventoyOperationDefault() {
        let p = plan(target())
        #expect(p.ventoyOperation == .freshInstall)
        #expect(p.planVersion == 5)
    }

    @Test("secureBoot defaults to true and round-trips when false")
    func secureBootRoundTrip() throws {
        #expect(plan(target()).secureBoot == true)
        let p = InstallPlan(
            driver: .ventoy,
            target: target(),
            source: .ventoyVersion("1.1.11"),
            workDir: "/tmp/ventoy",
            secureBoot: false,
            partitionStyle: .gpt
        )
        let decoded = try JSONDecoder().decode(InstallPlan.self, from: JSONEncoder().encode(p))
        #expect(decoded.secureBoot == false)
    }

    @Test("ventoyOperation explicit .updateInPlace round-trip")
    func ventoyOperationUpdate() throws {
        let p = InstallPlan(
            driver: .ventoy,
            target: target(),
            source: .ventoyVersion("1.1.11"),
            workDir: "/tmp/ventoy",
            ventoyOperation: .updateInPlace,
            partitionStyle: .gpt
        )
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(InstallPlan.self, from: data)
        #expect(decoded.ventoyOperation == .updateInPlace)
    }

    @Test("plans from before v0.8.0 decode with no checksum and no read-back; a bad checksum fails validation")
    func checksumFields() throws {
        let old = try JSONEncoder().encode(plan(target()))
        var dict = try JSONSerialization.jsonObject(with: old) as! [String: Any]
        dict.removeValue(forKey: "expectedImageSHA256")
        dict.removeValue(forKey: "verifyAfterWriting")
        let decoded = try JSONDecoder().decode(InstallPlan.self, from: JSONSerialization.data(withJSONObject: dict))
        #expect(decoded.expectedImageSHA256 == nil)
        #expect(decoded.verifyAfterWriting == false)

        let bad = InstallPlan(driver: .rawImage, target: target(), source: .localImage(path: "/x.img"), workDir: "/tmp",
                              partitionStyle: .mbr, expectedImageSHA256: "ABC")
        #expect(throws: PlanValidationError.self) { try bad.validate() }
        let upper = InstallPlan(driver: .rawImage, target: target(), source: .localImage(path: "/x.img"), workDir: "/tmp",
                                partitionStyle: .mbr, expectedImageSHA256: String(repeating: "AB", count: 32))
        #expect(throws: PlanValidationError.self) { try upper.validate() }
    }

    @Test("v0.2.x plan (planVersion=1, no ventoyOperation field) decodes as .freshInstall")
    func backwardsCompat() throws {
        // Hand-craft a JSON blob in the v1 schema (no ventoyOperation
        // key). Daemon during a rolling upgrade would receive this from
        // a v0.2.x app — legacy plans must still execute as fresh
        // installs.
        let legacyJSON = """
        {
            "driver": "ventoy",
            "target": {
                "bsdName": "disk6",
                "sizeInBytes": 133143986176,
                "isExternal": true,
                "isRemovable": true,
                "mediaName": "USB Drive",
                "volumes": []
            },
            "source": { "ventoyVersion": { "_0": "1.1.11" } },
            "filesystem": "exfat",
            "workDir": "/tmp/ventoy",
            "planVersion": 1
        }
        """
        let decoded = try JSONDecoder().decode(InstallPlan.self, from: Data(legacyJSON.utf8))
        #expect(decoded.ventoyOperation == .freshInstall)
        #expect(decoded.planVersion == 1)
        // No secureBoot key either: pre-v0.4.0 always wrote the shim layout.
        #expect(decoded.secureBoot == true)
        // Nor partitionStyle: pre-v0.5.0 always installed GPT.
        #expect(decoded.partitionStyle == .gpt)
    }

    @Test("partitionStyle round-trips")
    func partitionStyleRoundTrip() throws {
        let p = InstallPlan(driver: .ventoy, target: target(), source: .ventoyVersion("1.1.17"),
                            workDir: "/tmp/ventoy", partitionStyle: .mbr)
        let decoded = try JSONDecoder().decode(InstallPlan.self, from: JSONEncoder().encode(p))
        #expect(decoded.partitionStyle == .mbr)
    }

    @Test("MBR fresh install on a disk past 2 TiB is refused by validate(); GPT and update are not")
    func mbrSizeValidation() throws {
        let big = target(size: 0x1_0000_0000 * 512)
        let mbr = InstallPlan(driver: .ventoy, target: big, source: .ventoyVersion("1.1.17"),
                              workDir: "/tmp/ventoy", partitionStyle: .mbr)
        #expect(throws: PlanValidationError.self) { try mbr.validate() }
        let gpt = InstallPlan(driver: .ventoy, target: big, source: .ventoyVersion("1.1.17"),
                              workDir: "/tmp/ventoy", partitionStyle: .gpt)
        try gpt.validate()
        let update = InstallPlan(driver: .ventoy, target: big, source: .ventoyVersion("1.1.17"),
                                 workDir: "/tmp/ventoy", ventoyOperation: .updateInPlace, partitionStyle: .mbr)
        try update.validate()
        let atLimit = InstallPlan(driver: .ventoy, target: target(size: 0xFFFF_FFFF * 512), source: .ventoyVersion("1.1.17"),
                                  workDir: "/tmp/ventoy", partitionStyle: .mbr)
        try atLimit.validate()
    }
}
