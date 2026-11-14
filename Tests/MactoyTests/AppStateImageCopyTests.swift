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

    /// A copier that reports one progress update, then runs until cancelled (at most 5 s).
    private static func waitingCopier(started: Flag)
        -> @Sendable ([URL], URL, RunControl, @escaping @Sendable (ImageCopier.Progress) -> Void) -> ImageCopier.Result {
        { _, _, control, progress in
            progress(ImageCopier.Progress(fileNumber: 1, fileCount: 2, fileName: "a.iso", bytesDone: 10, bytesTotal: 100))
            started.set()
            let deadline = Date().addingTimeInterval(5)
            while !control.isCancelled, Date() < deadline { usleep(5_000) }
            var result = ImageCopier.Result()
            result.cancelled = control.isCancelled
            result.removedUnfinished = control.isCancelled ? "a.iso" : nil
            return result
        }
    }

    /// Waits for `condition`, failing the test if it isn't met within 2 s.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        try #require(condition(), "timed out waiting for: \(what)")
    }

    @Test("while copying: Install is disabled, progress shows, and Cancel stops the copy")
    func copyBlocksRunsAndCancels() async throws {
        let state = makeState()
        state.mode = .installVentoy
        #expect(state.canRun)

        let started = Flag()
        state.imageCopier = Self.waitingCopier(started: started)
        let ended = Flag()
        state.onImageCopyEnded = { ended.set() }
        let copy = Task { await state.copyImages(picked, into: volume, onDisk: "disk5") }
        try await waitUntil("progress") { started.value && state.imageCopyProgress.progress != nil }

        #expect(state.imageCopy?.diskBSD == "disk5")
        #expect(state.imageCopy?.diskName == "Test Disk disk5")
        #expect(state.imageCopyProgress.progress?.fileName == "a.iso")
        #expect(!state.canRun, "no erase while files are copied to the drive")
        #expect(!state.canCopyImages, "one copy at a time")

        state.cancelImageCopy()
        #expect(state.imageCopyProgress.cancelRequested)
        let result = await copy.value
        #expect(result?.cancelled == true)
        #expect(state.imageCopy == nil)
        #expect(state.imageCopyProgress.progress == nil)
        #expect(ended.value, "the quit confirmation is told the copy ended")
        #expect(state.canRun)
        #expect(state.imageCopyReport?.succeeded == false)
        #expect(state.imageCopyReport?.text.contains("The unfinished copy of a.iso was removed") == true)
    }

    @Test("a run started during a copy is refused, even by a path that skips canRun")
    func runRefusedDuringCopy() async throws {
        let state = makeState()
        let started = Flag()
        state.imageCopier = Self.waitingCopier(started: started)
        let copy = Task { await state.copyImages(picked, into: volume, onDisk: "disk5") }
        try await waitUntil("copy started") { started.value }

        await state.run(confirmedTarget: disk("disk5"), confirmedMode: .installVentoy,
                        confirmedSecureBoot: true, confirmedPartitionStyle: .mbr)
        if case .failed(let message) = state.status {
            #expect(message.contains("still copying"))
            #expect(message.contains("Nothing was written"))
        } else {
            Issue.record("expected the run to be refused, got \(state.status)")
        }
        state.cancelImageCopy()
        _ = await copy.value
    }

    @Test("no copy starts during a run or while a sheet that leads to one is open")
    func noCopyWhenBusy() async {
        let state = makeState()
        let called = Flag()
        state.imageCopier = { _, _, _, _ in called.set(); return ImageCopier.Result() }

        state.status = .preparing("Preparing install plan...")
        #expect(!state.canCopyImages)
        #expect(await state.copyImages(picked, into: volume, onDisk: "disk5") == nil)
        state.status = .idle

        state.pendingEraseConfirmation = EraseConfirmation(mode: .installVentoy, disk: disk("disk5"), usedBytes: nil,
                                                           totalBytes: 100_000_000_000, partitionStyle: .mbr)
        #expect(!state.canCopyImages)
        state.pendingEraseConfirmation = nil

        state.showHelperExplainer = true
        #expect(!state.canCopyImages)
        state.showHelperExplainer = false

        state.isAwaitingHelperApproval = true
        #expect(!state.canCopyImages)
        state.isAwaitingHelperApproval = false

        #expect(state.canCopyImages)
        #expect(!called.value)
    }

    @Test("the report: a short success line, the reason when it didn't fit, one line per failed file")
    func report() {
        var ok = ImageCopier.Result()
        ok.copied = ["a.iso", "b.iso"]
        #expect(AppState.imageCopyReport(for: ok) == .init(succeeded: true, text: "2 files were copied to the drive."))

        #expect(AppState.imageCopyReport(for: ImageCopier.Result()) == nil, "nothing picked, nothing to say")

        var full = ImageCopier.Result()
        full.notEnoughSpace = "The files need 9 GB, and the drive has 2 GB free. Nothing was copied."
        full.failures = [.init(fileName: "c.iso", message: "A file with this name is already on the drive.")]
        #expect(AppState.imageCopyReport(for: full)?.text
                == full.notEnoughSpace! + "\nc.iso: A file with this name is already on the drive.")

        var mixed = ImageCopier.Result()
        mixed.copied = ["a.iso"]
        mixed.failures = [.init(fileName: "b.iso", message: "A file with this name is already on the drive.")]
        #expect(AppState.imageCopyReport(for: mixed) == .init(succeeded: false, text:
            "1 file was copied; 1 couldn't be:\nb.iso: A file with this name is already on the drive."))

        var betweenFiles = ImageCopier.Result()
        betweenFiles.copied = ["a.iso"]
        betweenFiles.cancelled = true
        #expect(AppState.imageCopyReport(for: betweenFiles)?.text == "Copy cancelled. 1 file was copied.")
    }
}

/// A thread-safe one-way flag for the stub copier, which runs off the main actor.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    func set() { lock.lock(); isSet = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return isSet }
}
