import SwiftUI
import AppKit
import MactoyKit

struct ManageDiskPanel: View {
    @EnvironmentObject private var state: AppState
    /// The selected drive's `Ventoy` volume, looked up off the main thread once per drive:
    /// the lookup runs `diskutil`, and this view redraws often.
    @State private var volumeURL: URL?
    @State private var volumeLookedUpFor: DiskTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Manage Disk")
                .font(.title.bold())

            // Up here, whichever drive is selected: Cancel must stay in reach.
            if let job = state.imageCopy {
                ImageCopyCard(job: job, progress: state.imageCopyProgress) { state.cancelImageCopy() }
            } else if let report = state.imageCopyReport {
                ImageCopyReportCard(report: report) { state.imageCopyReport = nil }
            }

            if let disk = state.selectedDisk, volumeLookedUpFor != disk {
                Text("Looking for the Ventoy volume…")
                    .foregroundStyle(.secondary)
                Spacer()
            } else if let disk = state.selectedDisk, let volumeURL {
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
        // Again when the drive's volumes change (mounted, renamed), not only for another drive.
        .task(id: state.selectedDisk) {
            guard let disk = state.selectedDisk else { volumeURL = nil; volumeLookedUpFor = nil; return }
            let bsd = disk.bsdName
            // The `Ventoy` volume on this drive, not just any volume named `Ventoy` (two
            // sticks can be plugged in at once).
            let found = await Task.detached(priority: .userInitiated) { VentoyVolumeLocator.find(onDisk: bsd) }.value
            guard !Task.isCancelled else { return }
            volumeURL = found
            volumeLookedUpFor = disk
        }
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
                            guard !isCopyingHere else { return }
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
                        .disabled(isCopyingHere)
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

    private var isCopyingHere: Bool { state.imageCopy?.diskBSD == diskBSD }

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

/// Progress of a copy onto a Ventoy volume, with Cancel. Watches only the progress object,
/// so its updates redraw this card and nothing else.
private struct ImageCopyCard: View {
    let job: AppState.ImageCopyJob
    @ObservedObject var progress: ImageCopyProgress
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.callout.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(progress.cancelRequested ? "Cancelling…" : "Cancel", action: cancel)
                    .disabled(progress.cancelRequested || progress.progress?.finishing == true)
                    .help(progress.progress?.finishing == true
                          ? "The file is being written to the drive. Cancel is back for the next file."
                          : "Stop copying. The file being copied is removed from the drive; files already copied stay.")
            }
            if let p = progress.progress, p.bytesTotal > 0 {
                ProgressView(value: Double(p.bytesDone), total: Double(p.bytesTotal))
                Text(p.finishing
                     ? "Writing the last of \(p.fileName) to the drive…"
                     : "\(Self.bytes(p.bytesDone)) of \(Self.bytes(p.bytesTotal))")
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
        guard let p = progress.progress else { return "Getting ready to copy to \(job.diskName)…" }
        let position = p.fileCount > 1 ? " (\(p.fileNumber) of \(p.fileCount))" : ""
        return "Copying \(p.fileName) to \(job.diskName)\(position)"
    }

    private static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
    }
}

/// What the last copy did, until dismissed.
private struct ImageCopyReportCard: View {
    let report: AppState.ImageCopyReport
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: report.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(report.succeeded ? Color.green : Color.orange)
            Text(report.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mactoyCard(cornerRadius: 14)
    }
}
