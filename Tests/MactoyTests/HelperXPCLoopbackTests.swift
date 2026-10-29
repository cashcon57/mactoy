import Compression
import CryptoKit
import Foundation
import Testing
@testable import Mactoy
import MactoyKit

/// The app's side (`HelperInvoker`) and the helper's side (`MactoydService`) talking over a real
/// XPC connection, in-process. Everything the app sends the helper goes through XPC's encoding,
/// including the open image file (#36), cancel (#21), clearing downloads (#22), progress and
/// errors. What it leaves out: launchd, root, and the helper's check of who's calling, which
/// rejects anything but the signed Mactoy app.
@Suite("Helper over real XPC", .serialized)
@MainActor
struct HelperXPCLoopbackTests {

    /// An anonymous XPC listener running the real service.
    final class Loopback: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        let listener = NSXPCListener.anonymous()
        let gate = RunGate()
        let dependencies: MactoydDependencies
        private let lock = NSLock()
        private var accepted: [NSXPCConnection] = []
        private let previousFactory = HelperInvoker.makeConnection

        init(_ dependencies: MactoydDependencies) {
            self.dependencies = dependencies
            super.init()
            listener.delegate = self
            listener.resume()
            let endpoint = listener.endpoint
            HelperInvoker.makeConnection = { NSXPCConnection(listenerEndpoint: endpoint) }
        }

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = NSXPCInterface(with: MactoydProtocol.self)
            connection.exportedObject = MactoydService(connection: connection, gate: gate, dependencies: dependencies)
            connection.remoteObjectInterface = NSXPCInterface(with: MactoyClientProtocol.self)
            connection.resume()
            lock.lock(); accepted.append(connection); lock.unlock()
            return true
        }

        /// Drops every connection from the helper's side, as a crashed helper would.
        func dropConnections() {
            lock.lock(); let all = accepted; lock.unlock()
            all.forEach { $0.invalidate() }
        }

        func stop() {
            listener.invalidate()
            HelperInvoker.makeConnection = previousFactory
        }
    }

    /// What a fake driver saw, shared with the test.
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var _imageSHA: String?
        private var _imageIsRegularFile = false
        private var _started = false
        private var _committed = false
        var committed: Bool { lock.lock(); defer { lock.unlock() }; return _committed }
        func commit() { lock.lock(); _committed = true; lock.unlock() }
        var imageSHA: String? { lock.lock(); defer { lock.unlock() }; return _imageSHA }
        var imageIsRegularFile: Bool { lock.lock(); defer { lock.unlock() }; return _imageIsRegularFile }
        var started: Bool { lock.lock(); defer { lock.unlock() }; return _started }
        func image(sha: String, regular: Bool) { lock.lock(); _imageSHA = sha; _imageIsRegularFile = regular; lock.unlock() }
        func start() { lock.lock(); _started = true; lock.unlock() }
    }

    /// Reads the handed-over image to the end, reporting progress like a real driver.
    struct ReadingDriver: InstallDriver {
        let id: DriverID = .rawImage
        let displayName = "test"
        let image: FileHandle?
        let seen: Seen
        func execute(plan: InstallPlan, progress: ProgressSink) async throws {
            guard let image else { throw DriverError.validation("no image handed over") }
            var st = stat()
            let regular = fstat(image.fileDescriptor, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
            var hasher = SHA256()
            var done: UInt64 = 0
            while let piece = try image.read(upToCount: 1 << 20), !piece.isEmpty {
                hasher.update(data: piece)
                done += UInt64(piece.count)
                progress.report(.init(phase: .writing, message: "Writing...", bytesDone: done, bytesTotal: nil))
            }
            seen.image(sha: hasher.finalize().map { String(format: "%02x", $0) }.joined(), regular: regular)
        }
    }

    /// Runs until it's told to stop, checking the run control as a real driver does.
    struct WaitingDriver: InstallDriver {
        let id: DriverID = .ventoy
        let displayName = "test"
        let control: RunControl
        let seen: Seen
        var commitAfter: Double? = nil
        func execute(plan: InstallPlan, progress: ProgressSink) async throws {
            seen.start()
            progress.report(.init(phase: .downloading, message: "Downloading..."))
            let start = Date()
            while Date().timeIntervalSince(start) < 10 {
                if let commitAfter, Date().timeIntervalSince(start) > commitAfter {
                    try control.commit(RunControl.stoppedBeforeWriting)
                    seen.commit()
                    progress.report(.init(phase: .writing, message: "Writing..."))
                    // Long enough for the test to try cancelling after the commit.
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    return
                }
                try control.check(RunControl.stoppedBeforeWriting)
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw DriverError.validation("the test's driver was never stopped")
        }
    }

    struct FailingDriver: InstallDriver {
        let id: DriverID = .rawImage
        let displayName = "test"
        func execute(plan: InstallPlan, progress: ProgressSink) async throws {
            throw DriverError.validation("Refusing to flash /dev/disk9: the live disk does not match the disk you confirmed.")
        }
    }

    private let disk = DiskTarget(bsdName: "disk9", sizeInBytes: 8_000_000_000, isExternal: true, isRemovable: true,
                                  mediaName: "SanDisk Ultra", serialNumber: "4C530001")

    private func dependencies(_ make: @escaping @Sendable (InstallPlan, FileHandle?, RunControl) throws -> any InstallDriver,
                              clearCache: @escaping @Sendable () throws -> UInt64 = { 0 }) -> MactoydDependencies {
        MactoydDependencies(makeDriver: make, clearCache: clearCache,
                            probe: { .unknownDisk(bsdName: $0, reason: "test probe") })
    }

    private func imageFile(_ bytes: Int) throws -> (URL, String) {
        var data = Data(count: bytes)
        for i in stride(from: 0, to: bytes, by: 4096) { data[i] = UInt8(truncatingIfNeeded: i / 4096) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-xpc-\(UUID().uuidString).img")
        try data.write(to: url)
        return (url, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    private func flashPlan(_ url: URL) -> InstallPlan {
        InstallPlan(driver: .rawImage, target: disk, source: .localImage(path: url.path), workDir: "/tmp", partitionStyle: .mbr)
    }

    private func ventoyPlan() -> InstallPlan {
        InstallPlan(driver: .ventoy, target: disk, source: .ventoyVersion("1.1.17"), workDir: "/tmp", partitionStyle: .mbr)
    }

    final class Updates: @unchecked Sendable {
        var phases: [ProgressUpdate.Phase] = []
        var lastBytes: UInt64?
    }

    final class IgnoredProgress: NSObject, MactoyClientProtocol {
        func receiveProgress(_ updateData: Data) {}
    }

    /// Not on the main actor: XPC calls the reply on its own queue.
    nonisolated static func executeWithoutImage(_ planData: Data, on connection: NSXPCConnection) async -> (Bool, String?) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String?), Never>) in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ err in cont.resume(returning: (false, "xpc error \(err)")) }) as? MactoydProtocol else {
                cont.resume(returning: (false, "no proxy"))
                return
            }
            proxy.executePlan(planData, image: nil) { cont.resume(returning: ($0, $1)) }
        }
    }

    /// Polls `condition` for up to five seconds; fails the test instead of hanging.
    private func waitFor(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Tests

    @Test("Flash: the app opens the image and the helper reads exactly its bytes from the handle")
    func imageHandedOver() async throws {
        let (url, sha) = try imageFile(6 * 1024 * 1024 + 4096)
        defer { try? FileManager.default.removeItem(at: url) }
        let seen = Seen()
        let loop = Loopback(dependencies { _, image, _ in ReadingDriver(image: image, seen: seen) })
        defer { loop.stop() }
        let updates = Updates()

        try await HelperInvoker.run(plan: flashPlan(url)) { update in
            updates.phases.append(update.phase)
            if let b = update.bytesDone { updates.lastBytes = b }
        }
        // Progress hops to the main actor; give the last ones a moment to land.
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(seen.imageSHA == sha)
        #expect(seen.imageIsRegularFile)
        #expect(updates.phases.contains(.writing))
        #expect(updates.phases.last == .done)
        #expect(updates.lastBytes == UInt64(6 * 1024 * 1024 + 4096))
    }

    @Test("Flash: the helper refuses a plan that comes without the image handle")
    func noHandleRefused() async throws {
        let loop = Loopback(.live)
        defer { loop.stop() }
        let connection = HelperInvoker.makeConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: MactoydProtocol.self)
        // The helper sends progress back; a client with nothing to receive it gets cut off.
        connection.exportedInterface = NSXPCInterface(with: MactoyClientProtocol.self)
        connection.exportedObject = IgnoredProgress()
        connection.resume()
        defer { connection.invalidate() }
        let planData = try JSONEncoder().encode(flashPlan(URL(fileURLWithPath: "/etc/master.passwd")))
        let (ok, message) = await Self.executeWithoutImage(planData, on: connection)
        #expect(!ok)
        #expect(message?.contains("didn't hand over the image file") == true, "got: \(message ?? "nil")")
    }

    @Test("A failure in the helper reaches the app with its message")
    func failurePassesThrough() async throws {
        let (url, _) = try imageFile(4096)
        defer { try? FileManager.default.removeItem(at: url) }
        let loop = Loopback(dependencies { _, _, _ in FailingDriver() })
        defer { loop.stop() }
        do {
            try await HelperInvoker.run(plan: flashPlan(url)) { _ in }
            Issue.record("expected a failure")
        } catch HelperInvoker.HelperError.executionFailed(let message) {
            #expect(message.contains("does not match the disk you confirmed"))
        }
    }

    @Test("Cancel reaches the running plan, which stops with nothing written; a second cancel finds nothing")
    func cancelOverXPC() async throws {
        let seen = Seen()
        let loop = Loopback(dependencies { _, _, control in WaitingDriver(control: control, seen: seen) })
        defer { loop.stop() }
        let run = Task { try await HelperInvoker.run(plan: ventoyPlan()) { _ in } }
        try await waitFor("the driver to start") { seen.started }

        #expect(try await HelperInvoker.cancelCurrentRun())
        do {
            try await run.value
            Issue.record("expected the run to stop")
        } catch HelperInvoker.HelperError.executionFailed(let message) {
            #expect(message == RunControl.stoppedBeforeWriting)
        }
        #expect(try await HelperInvoker.cancelCurrentRun() == false)
    }

    @Test("Cancel is refused once the plan has passed the point of no return, and the run finishes")
    func cancelRefusedAfterCommit() async throws {
        let seen = Seen()
        let loop = Loopback(dependencies { _, _, control in WaitingDriver(control: control, seen: seen, commitAfter: 0.1) })
        defer { loop.stop() }
        let run = Task { try await HelperInvoker.run(plan: ventoyPlan()) { _ in } }
        try await waitFor("the driver to commit") { seen.committed }

        #expect(try await HelperInvoker.cancelCurrentRun() == false)
        try await run.value
    }

    @Test("Clear downloads goes through, and is refused while a plan runs")
    func clearDownloadsOverXPC() async throws {
        let seen = Seen()
        let loop = Loopback(dependencies({ _, _, control in WaitingDriver(control: control, seen: seen) },
                                         clearCache: { 20_971_520 }))
        defer { loop.stop() }
        #expect(try await HelperInvoker.clearDownloads() == 20_971_520)

        let run = Task { try await HelperInvoker.run(plan: ventoyPlan()) { _ in } }
        try await waitFor("the driver to start") { seen.started }
        do {
            _ = try await HelperInvoker.clearDownloads()
            Issue.record("expected a refusal while writing")
        } catch HelperInvoker.HelperError.executionFailed(let message) {
            #expect(message.contains("writing a drive"))
        }
        _ = try await HelperInvoker.cancelCurrentRun()
        _ = try? await run.value
    }

    @Test("A connection the helper drops mid-run is reported as lost, never as a missing helper")
    func connectionLostMidRun() async throws {
        let seen = Seen()
        let loop = Loopback(dependencies { _, _, control in WaitingDriver(control: control, seen: seen) })
        defer { loop.stop() }
        let run = Task { try await HelperInvoker.run(plan: ventoyPlan()) { _ in } }
        try await waitFor("the driver to start") { seen.started }
        loop.dropConnections()
        do {
            try await run.value
            Issue.record("expected the run to fail")
        } catch let error as HelperInvoker.HelperError {
            if case .connectionLost = error {} else { Issue.record("expected connectionLost, got \(error)") }
            #expect(!AppState().isLookupFailure(error))
        }
        // Let the orphaned driver stop.
        _ = loop.gate.cancelAll()
    }

    @Test("The probe's result comes back through XPC")
    func probeOverXPC() async throws {
        let loop = Loopback(.live)
        defer { loop.stop() }
        // The live probe refuses a name that isn't a whole disk before opening anything.
        let result = try await HelperInvoker.probeVentoy(bsdName: "disk9s1")
        #expect(!result.isVentoyDisk)
        #expect(result.layoutIssues.first?.hasPrefix("Not a whole-disk name") == true)
    }

    // MARK: - Full stack onto a disk image (opt-in)

    /// The real drivers, behind the real service, reached through the app's real XPC client,
    /// writing a disk image. Opt-in: set MACTOY_E2E_DISK to an hdiutil-attached raw image's
    /// whole-disk name (see scripts/e2e/README.md). Refuses anything that isn't a disk image.
    nonisolated static let e2eDisk = ProcessInfo.processInfo.environment["MACTOY_E2E_DISK"]

    @Test("Full stack: flash an .xz image onto a disk image over XPC and read it back",
          .enabled(if: e2eDisk != nil))
    func fullStackFlash() async throws {
        let bsd = try #require(Self.e2eDisk)
        let target = try DiskInfo.probe(bsdName: bsd)
        try #require(target.mediaName == "Disk Image", "refusing: \(bsd) is not a disk image")

        // A 20 MB image with structure, compressed with Apple's encoder.
        var image = Data(count: 20 * 1024 * 1024 + 1000)
        for i in stride(from: 0, to: image.count, by: 512) { image[i] = UInt8(truncatingIfNeeded: i / 512) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-fullstack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("image.img.xz")
        try Self.xz(image).write(to: url)
        let sha = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()

        let loop = Loopback(.live)
        defer { loop.stop() }
        let plan = InstallPlan(driver: .rawImage, target: target, source: .localImage(path: url.path), workDir: "/tmp",
                               partitionStyle: .mbr, expectedImageSHA256: sha, verifyAfterWriting: true)
        let updates = Updates()
        try await HelperInvoker.run(plan: plan) { updates.phases.append($0.phase) }

        let device = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/r\(bsd)"))
        defer { try? device.close() }
        let onDisk = try device.read(upToCount: image.count + 4096 - (image.count % 4096)) ?? Data()
        #expect(onDisk.prefix(image.count) == image)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(updates.phases.contains(.verifying))
    }

    @Test("Full stack: install Ventoy onto a disk image over XPC", .enabled(if: e2eDisk != nil))
    func fullStackVentoy() async throws {
        let bsd = try #require(Self.e2eDisk)
        let target = try DiskInfo.probe(bsdName: bsd)
        try #require(target.mediaName == "Disk Image", "refusing: \(bsd) is not a disk image")
        let loop = Loopback(.live)
        defer { loop.stop() }
        let plan = InstallPlan(driver: .ventoy, target: target, source: .ventoyVersion("1.1.17"), workDir: "/tmp",
                               partitionStyle: .gpt)
        try await HelperInvoker.run(plan: plan) { _ in }
        let probe = try await HelperInvoker.probeVentoy(bsdName: bsd)
        #expect(probe.isVentoyDisk)
        #expect(probe.detectedVersion == "1.1.17")
        #expect(probe.partitionStyle == .gpt)
    }

    nonisolated static func xz(_ data: Data) -> Data {
        let capacity = data.count + 1_000_000
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dst.deallocate() }
        let n = data.withUnsafeBytes {
            compression_encode_buffer(dst, capacity, $0.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZMA)
        }
        return Data(bytes: dst, count: n)
    }
}

