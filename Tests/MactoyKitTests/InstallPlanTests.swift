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
            workDir: "/tmp/ventoy"
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
            "disk2/../disk0" // path traversal
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
        #expect(p.planVersion == 2)
    }

    @Test("ventoyOperation explicit .updateInPlace round-trip")
    func ventoyOperationUpdate() throws {
        let p = InstallPlan(
            driver: .ventoy,
            target: target(),
            source: .ventoyVersion("1.1.11"),
            workDir: "/tmp/ventoy",
            ventoyOperation: .updateInPlace
        )
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(InstallPlan.self, from: data)
        #expect(decoded.ventoyOperation == .updateInPlace)
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
    }
}
