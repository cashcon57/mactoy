import Testing
import Foundation
@testable import Mactoy
import MactoyKit

/// Manage Disk's copy (#45) runs off the main thread, can be cancelled, and blocks any run that
/// would erase or rewrite a drive while files are copied to it.
@MainActor
@Suite("AppState image copy")
struct AppStateImageCopyTests {

    private func disk(_ bsd: String) -> DiskTarget {
        DiskTarget(bsdName: bsd, sizeInBytes: 100_000_000_000, isExternal: true, isRemovable: true,
                   mediaName: "Test Disk \(bsd)", volumes: [])
    }

    private func makeState() -> AppState {
        let state = AppState()
        state.timeMachineLookup = { [] }
        state.ventoyProber = { bsd in .unknownDisk(bsdName: bsd, reason: "stub") }
        state.disks = [disk("disk5")]
        state.selectedDiskBSD = "disk5"
        return state
    }

    private let picked = [URL(fileURLWithPath: "/tmp/a.iso"), URL(fileURLWithPath: "/tmp/b.iso")]
    private let volume = URL(fileURLWithPath: "/Volumes/Ventoy")

    /// A copier that runs until cancelled (or for at most 5 s), reporting one progress update.
    private static func waitingCopier(started: @escaping @Sendable () -> Void)
        -> @Sendable ([URL], URL, RunControl, @escaping @Sendable (ImageCopier.Progress) -> Void) -> ImageCopier.Result {
        { _, _, control, progress in
            progress(ImageCopier.Progress(fileNumber: 1, fileCount: 2, fileName: "a.iso", bytesDone: 10, bytesTotal: 100))
            started()
            let deadline = Date().addingTimeInterval(5)
            while !control.isCancelled, Date() < deadline { usleep(5_000) }
            var result = ImageCopier.Result()
            result.cancelled = control.isCancelled
            return result
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    @Test("while copying: Install is disabled, the job shows progress, and Cancel stops the copy")
    func copyBlocksRunsAndCancels() async throws {
        let state = makeState()
        state.mode = .installVentoy
        #expect(state.canRun)

        let started = Flag()
        state.imageCopier = Self.waitingCopier { started.set() }
        let copy = Task { await state.copyImages(picked, into: volume, onDisk: "disk5") }
        try await waitUntil { started.value && state.imageCopy?.progress != nil }

        #expect(state.imageCopy?.diskBSD == "disk5")
        #expect(state.imageCopy?.progress?.fileName == "a.iso")
        #expect(!state.canRun, "no erase while files are copied to the drive")
        #expect(!state.canCopyImages, "one copy at a time")

        state.cancelImageCopy()
        #expect(state.imageCopy?.cancelRequested == true)
        let result = await copy.value
        #expect(result?.cancelled == true)
        #expect(state.imageCopy == nil)
        #expect(state.canRun)
        #expect(state.imageCopyReport?.contains("cancelled") == true)
    }

    @Test("a run that resumes by itself during a copy (after helper approval) is refused")
    func runRefusedDuringCopy() async throws {
        let state = makeState()
        let started = Flag()
        state.imageCopier = Self.waitingCopier { started.set() }
        let copy = Task { await state.copyImages(picked, into: volume, onDisk: "disk5") }
        try await waitUntil { started.value }

        await state.run(confirmedTarget: disk("disk5"), confirmedMode: .installVentoy,
                        confirmedSecureBoot: true, confirmedPartitionStyle: .mbr)
        guard case .failed(let message) = state.status else {
            Issue.record("expected the run to be refused, got \(state.status)")
            state.cancelImageCopy(); _ = await copy.value
            return
        }
        #expect(message.contains("still copying"))
        #expect(message.contains("Nothing was written"))

        state.cancelImageCopy()
        _ = await copy.value
    }

    @Test("no copy starts while a run is in progress")
    func noCopyDuringRun() async {
        let state = makeState()
        state.status = .preparing("Preparing install plan...")
        #expect(!state.canCopyImages)
        let called = Flag()
        state.imageCopier = { _, _, _, _ in called.set(); return ImageCopier.Result() }
        let result = await state.copyImages(picked, into: volume, onDisk: "disk5")
        #expect(result == nil)
        #expect(!called.value)
    }

    @Test("the report: nothing on success, the reason when it didn't fit, one line per failed file")
    func report() {
        var ok = ImageCopier.Result()
        ok.copied = ["a.iso"]
        #expect(AppState.imageCopyReport(for: ok) == nil)

        var full = ImageCopier.Result()
        full.notEnoughSpace = "The files need 9 GB, and the drive has 2 GB free. Nothing was copied."
        #expect(AppState.imageCopyReport(for: full) == full.notEnoughSpace)

        var mixed = ImageCopier.Result()
        mixed.copied = ["a.iso"]
        mixed.failures = [.init(fileName: "b.iso", message: "A file with this name is already on the drive.")]
        #expect(AppState.imageCopyReport(for: mixed) == "b.iso: A file with this name is already on the drive.")

        var cancelled = ImageCopier.Result()
        cancelled.copied = ["a.iso", "b.iso"]
        cancelled.cancelled = true
        #expect(AppState.imageCopyReport(for: cancelled)?.hasPrefix("Copy cancelled. 2 files were copied") == true)
    }
}

/// A thread-safe one-way flag for the stub copier, which runs off the main actor.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    func set() { lock.lock(); isSet = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return isSet }
}
