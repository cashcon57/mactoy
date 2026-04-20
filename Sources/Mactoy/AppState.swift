import Foundation
import Observation
import MactoyKit

enum AppMode: String, CaseIterable, Hashable {
    case installVentoy
    case flashImage
    case manageDisk

    var displayName: String {
        switch self {
        case .installVentoy: return "Install Ventoy"
        case .flashImage:    return "Flash Image"
        case .manageDisk:    return "Manage Disk"
        }
    }

    var symbol: String {
        switch self {
        case .installVentoy: return "externaldrive.badge.plus"
        case .flashImage:    return "bolt.horizontal.circle"
        case .manageDisk:    return "folder.badge.gearshape"
        }
    }
}

enum InstallStatus {
    case idle
    case preparing(String)
    case running(ProgressUpdate)
    case success(String)
    case failed(String)
}

@MainActor
@Observable
final class AppState {
    // disk enumeration
    var disks: [DiskTarget] = []
    var selectedDiskBSD: String?

    // mode
    var mode: AppMode = .installVentoy

    // ventoy mode
    var ventoyVersionInput: String = ""    // empty = latest
    var latestVentoyVersion: String?

    // flash mode
    var selectedImagePath: String?

    // run state
    var status: InstallStatus = .idle
    var log: [ProgressUpdate] = []

    var selectedDisk: DiskTarget? {
        guard let b = selectedDiskBSD else { return nil }
        return disks.first { $0.bsdName == b }
    }

    var canRun: Bool {
        guard case .idle = status else { return false }
        guard selectedDisk != nil else { return false }
        switch mode {
        case .installVentoy: return true
        case .flashImage:    return selectedImagePath != nil
        case .manageDisk:    return false
        }
    }

    private var enumeratorTask: Task<Void, Never>?

    func startDiskEnumeration() {
        enumeratorTask?.cancel()
        enumeratorTask = Task { [weak self] in
            while !Task.isCancelled {
                let disks = (try? DiskInfo.enumerateExternal()) ?? []
                await self?.applyDiskList(disks)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        Task { [weak self] in
            if let v = try? await VentoyDownloader().latestVersion() {
                await self?.setLatestVentoyVersion(v)
            }
        }
    }

    private func applyDiskList(_ disks: [DiskTarget]) {
        self.disks = disks
        if let sel = selectedDiskBSD, !disks.contains(where: { $0.bsdName == sel }) {
            selectedDiskBSD = nil
        }
        if selectedDiskBSD == nil, let first = disks.first {
            selectedDiskBSD = first.bsdName
        }
    }

    private func setLatestVentoyVersion(_ v: String) {
        self.latestVentoyVersion = v
    }

    func run() async {
        guard canRun, let target = selectedDisk else { return }

        log = []
        status = .preparing("Preparing install plan...")

        let source: InstallSource
        let driver: DriverID
        switch mode {
        case .installVentoy:
            driver = .ventoy
            let v = ventoyVersionInput.trimmingCharacters(in: .whitespaces)
            source = .ventoyVersion(v.isEmpty ? (latestVentoyVersion ?? "") : v)
        case .flashImage:
            driver = .rawImage
            guard let p = selectedImagePath else { return }
            source = .localImage(path: p)
        case .manageDisk:
            return
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactoy-\(UUID().uuidString.prefix(8))")

        var plan = InstallPlan(
            driver: driver,
            target: target,
            source: source,
            filesystem: .exfat,
            workDir: workDir.path
        )

        do {
            try plan.validate()
        } catch {
            status = .failed("\(error)")
            return
        }

        // Resolve latest Ventoy version if blank
        if case .ventoyVersion(let v) = plan.source, v.isEmpty {
            do {
                let latest = try await VentoyDownloader().latestVersion()
                plan = InstallPlan(
                    driver: plan.driver,
                    target: plan.target,
                    source: .ventoyVersion(latest),
                    filesystem: plan.filesystem,
                    workDir: plan.workDir
                )
            } catch {
                status = .failed("Failed to resolve latest Ventoy version: \(error)")
                return
            }
        }

        do {
            try await HelperInvoker.run(
                plan: plan,
                onUpdate: { [weak self] update in
                    self?.log.append(update)
                    self?.status = .running(update)
                }
            )
            status = .success("Install complete")
        } catch {
            status = .failed("\(error)")
        }
    }

    func reset() {
        status = .idle
        log = []
    }
}
