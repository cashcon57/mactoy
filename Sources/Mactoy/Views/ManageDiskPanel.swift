import SwiftUI
import AppKit
import MactoyKit

struct ManageDiskPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Manage Disk")
                .font(.title.bold())

            if let disk = state.selectedDisk, let volumeURL = ventoyVolumeURL(for: disk) {
                Text("Ventoy volume mounted at \(volumeURL.path)")
                    .foregroundStyle(.secondary)

                // `id: volumeURL` forces the library to rebuild its state
                // when the user switches between disks, instead of
                // keeping stale items from the previously-selected
                // drive.
                ImageLibrary(volumeURL: volumeURL)
                    .id(volumeURL)
                    .frame(maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select a mounted Ventoy disk to manage ISOs.")
                        .font(.headline)
                    Text("This pane lists the ISO/IMG files currently on the `Ventoy` partition. It appears when the selected disk is a Ventoy-installed drive and its `Ventoy` volume is mounted.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mactoyGlass(cornerRadius: 16)

                Spacer()
            }
        }
    }

    /// Find the `Ventoy` volume that actually lives on the selected
    /// disk, not just any volume named `Ventoy` anywhere on the system.
    /// Previously we matched by name alone, which would pick the wrong
    /// drive if the user had two Ventoy sticks plugged in.
    private func ventoyVolumeURL(for disk: DiskTarget) -> URL? {
        let fm = FileManager.default
        guard let mounts = try? fm.contentsOfDirectory(atPath: "/Volumes") else { return nil }
        for name in mounts where name == "Ventoy" || name.hasPrefix("Ventoy") {
            let candidate = URL(fileURLWithPath: "/Volumes/\(name)")
            if let info = try? Subprocess.run(
                "/usr/sbin/diskutil", ["info", "-plist", candidate.path]
            ),
               info.status == 0,
               let data = info.stdout.data(using: .utf8),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let deviceIdentifier = plist["DeviceIdentifier"] as? String,
               deviceIdentifier.hasPrefix(disk.bsdName + "s") {
                return candidate
            }
        }
        return nil
    }
}

/// The Ventoy volume's image list plus its actions. Scans off the main
/// thread — a drive also used for ordinary files can hold a lot of
/// folders — and rescans after any change it makes.
private struct ImageLibrary: View {
    let volumeURL: URL
    @State private var scan: VentoyImageLibrary.Scan?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let scan, scan.directory.standardizedFileURL != volumeURL.resolvingSymlinksInPath().standardizedFileURL {
                Text("Images folder (from `/ventoy/ventoy.json`): \(relativePath(scan.directory))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                HStack {
                    if let scan, !scan.images.isEmpty {
                        Text("\(scan.images.count) image\(scan.images.count == 1 ? "" : "s") on this drive")
                            .font(.callout.bold())
                    } else if scan != nil {
                        Text("No images on this drive yet — drop some onto the volume or use **Add ISO…** below.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Scanning…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Rescan the Ventoy volume")
                }
                .padding(.bottom, 6)

                List(scan?.images ?? [], id: \.self) { url in
                    HStack {
                        Image(systemName: "opticaldisc")
                        // Relative path, not just the name: with
                        // subfolders, two images can share a name.
                        Text(relativePath(url))
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(sizeString(for: url))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            do {
                                try FileManager.default.removeItem(at: url)
                            } catch {
                                presentError(
                                    title: "Could not delete \(url.lastPathComponent)",
                                    message: error.localizedDescription
                                )
                            }
                            Task { await reload() }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .listStyle(.inset)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Button("Open in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([scan?.directory ?? volumeURL])
                }
                Button("Add ISO…") {
                    addISO(to: scan?.directory ?? volumeURL)
                    Task { await reload() }
                }
                Spacer()
            }
        }
        .task(id: volumeURL) { await reload() }
    }

    private func reload() async {
        let volume = volumeURL
        let result = await Task.detached(priority: .userInitiated) {
            VentoyImageLibrary.scan(volume: volume)
        }.value
        scan = result
    }

    private func relativePath(_ url: URL) -> String {
        let root = volumeURL.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    private func addISO(to vol: URL) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for src in panel.urls {
                let dest = vol.appendingPathComponent(src.lastPathComponent)
                do {
                    try FileManager.default.copyItem(at: src, to: dest)
                } catch {
                    presentError(
                        title: "Could not copy \(src.lastPathComponent)",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func sizeString(for url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 1
            ? String(format: "%.2f GB", gb)
            : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}
