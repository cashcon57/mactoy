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

                DriveThemeSection(volumeURL: volumeURL)
                    .id(volumeURL)

                // `id: volumeURL` forces the library to rebuild its state
                // when the user switches between disks, instead of
                // keeping stale items from the previously-selected
                // drive.
                ImageLibrary(volumeURL: volumeURL, diskBSD: disk.bsdName)
                    .id(volumeURL)
                    .frame(maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select a mounted Ventoy disk to manage ISOs.")
                        .font(.headline)
                    Text("This pane lists the images on the `Ventoy` partition that Ventoy's boot menu will list, following the search settings in your `/ventoy/ventoy.json`. It appears when the selected disk is a Ventoy-installed drive and its `Ventoy` volume is mounted.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mactoyCard(cornerRadius: 16)

                Spacer()
            }
        }
    }

    /// The `Ventoy` volume on the selected disk, not just any volume named
    /// `Ventoy` (two sticks can be plugged in at once).
    private func ventoyVolumeURL(for disk: DiskTarget) -> URL? {
        VentoyVolumeLocator.find(onDisk: disk.bsdName)
    }
}

/// The Ventoy volume's image list plus its actions. Scans off the main
/// thread — a drive also used for ordinary files can hold a lot of
/// folders — and rescans after any change it makes.
private struct ImageLibrary: View {
    let volumeURL: URL
    let diskBSD: String
    @EnvironmentObject private var state: AppState
    @State private var scan: VentoyImageLibrary.Scan?
    /// Bumped by every reload; a scan that finishes after a newer one
    /// started is discarded, so a slow early scan can't bring back a
    /// file that was just deleted.
    @State private var generation = 0

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
                            // The copy may be writing next to it, and the list rescans when it ends.
                            guard state.imageCopy == nil else { return }
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
                        .disabled(state.imageCopy != nil)
                    }
                }
                .listStyle(.inset)
            }
            .frame(maxHeight: .infinity)

            if let job = state.imageCopy {
                ImageCopyCard(job: job, isThisDrive: job.diskBSD == diskBSD) { state.cancelImageCopy() }
            }

            HStack {
                Button("Open in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([scan?.directory ?? volumeURL])
                }
                Button("Add ISO…") {
                    guard let directory = scan?.directory else { return }
                    addISO(to: directory)
                }
                // Until the first scan finishes we don't know the search
                // root, and would copy to the wrong folder. One copy at a
                // time, and none while a run has the drive.
                .disabled(scan == nil || !state.canCopyImages)
                Spacer()
            }
        }
        .task(id: volumeURL) { await reload() }
        // A copy started here may finish after the user looked elsewhere; rescan when it ends.
        .onChange(of: state.imageCopy == nil) { finished in
            if finished { Task { await reload() } }
        }
    }

    private func reload() async {
        generation += 1
        let mine = generation
        let volume = volumeURL
        let result = await Task.detached(priority: .userInitiated) {
            VentoyImageLibrary.scan(volume: volume)
        }.value
        if mine == generation {
            scan = result
        }
    }

    private func relativePath(_ url: URL) -> String {
        let root = volumeURL.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    /// Picks the files, then copies them off the main thread (#45): the window stays usable,
    /// with progress and Cancel below the list.
    private func addISO(to directory: URL) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        let bsd = diskBSD
        Task { await state.copyImages(urls, into: directory, onDisk: bsd) }
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

/// Progress of a copy onto a Ventoy volume, with Cancel.
private struct ImageCopyCard: View {
    let job: AppState.ImageCopyJob
    /// False when the copy is going to another drive than the one shown.
    let isThisDrive: Bool
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.callout.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(job.cancelRequested ? "Cancelling…" : "Cancel", action: cancel)
                    .disabled(job.cancelRequested)
            }
            if let p = job.progress, p.bytesTotal > 0 {
                ProgressView(value: Double(p.bytesDone), total: Double(p.bytesTotal))
                Text("\(Self.bytes(p.bytesDone)) of \(Self.bytes(p.bytesTotal))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView(value: 0, total: 1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mactoyCard(cornerRadius: 14)
    }

    private var title: String {
        let target = isThisDrive ? "" : " to /dev/\(job.diskBSD)"
        guard let p = job.progress else { return "Getting ready to copy\(target)…" }
        let position = p.fileCount > 1 ? " (\(p.fileNumber) of \(p.fileCount))" : ""
        return "Copying \(p.fileName)\(target)\(position)"
    }

    private static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
    }
}
