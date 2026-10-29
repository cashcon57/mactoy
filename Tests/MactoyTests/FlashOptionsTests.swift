import Foundation
import Testing
@testable import Mactoy
import MactoyKit

/// #26: the image's SHA-256 and the check after writing reach the plan.
@MainActor
@Suite("Flash image options")
struct FlashOptionsTests {
    private let disk = DiskTarget(bsdName: "disk7", sizeInBytes: 32_000_000_000, isExternal: true, isRemovable: true, mediaName: "Stick")
    private let hash = String(repeating: "0f", count: 32)

    private func state() -> AppState {
        let s = AppState()
        s.timeMachineLookup = { [] }
        s.ventoyProber = { .unknownDisk(bsdName: $0, reason: "stub") }
        s.applyDiskList([disk], timeMachine: [])
        s.mode = .flashImage
        s.selectedImagePath = "/tmp/image.img.xz"
        return s
    }

    @Test("a pasted checksum and the read-back choice go into the Flash plan")
    func intoPlan() throws {
        let s = state()
        s.flashChecksumInput = "  \(hash.uppercased()) "
        s.flashVerifyAfterWriting = false
        let plan = try #require(s.makePlan(target: disk, mode: .flashImage, secureBoot: true, partitionStyle: .mbr))
        #expect(plan.expectedImageSHA256 == hash)
        #expect(plan.verifyAfterWriting == false)
        try plan.validate()
    }

    @Test("read-back is on by default, and neither option reaches a Ventoy plan")
    func defaultsAndOtherModes() throws {
        let s = state()
        #expect(s.flashVerifyAfterWriting)
        s.flashChecksumInput = hash
        let flash = try #require(s.makePlan(target: disk, mode: .flashImage, secureBoot: true, partitionStyle: .mbr))
        #expect(flash.verifyAfterWriting)
        let install = try #require(s.makePlan(target: disk, mode: .installVentoy, secureBoot: true, partitionStyle: .mbr))
        #expect(install.expectedImageSHA256 == nil)
        #expect(!install.verifyAfterWriting)
    }

    @Test("an invalid checksum blocks Flash; an empty one doesn't")
    func invalidBlocks() {
        let s = state()
        #expect(s.canRun)
        s.flashChecksumInput = "not a hash"
        #expect(s.flashChecksumIsInvalid)
        #expect(!s.canRun)
        s.flashChecksumInput = "   "
        #expect(!s.flashChecksumIsInvalid)
        #expect(s.canRun)
    }

    @Test("picking another image clears the checksum, which belonged to the old one")
    func clearedOnNewImage() {
        let s = state()
        s.flashChecksumInput = hash
        s.selectedImagePath = "/tmp/other.iso"
        #expect(s.flashChecksumInput.isEmpty)
        s.flashChecksumInput = hash
        s.selectedImagePath = "/tmp/other.iso"      // same image again: kept
        #expect(s.flashChecksumInput == hash)
    }
}
