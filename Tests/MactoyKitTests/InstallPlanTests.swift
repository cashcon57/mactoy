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
}
