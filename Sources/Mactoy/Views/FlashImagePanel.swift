import SwiftUI
import MactoyKit
import UniformTypeIdentifiers
import os

private let pickerLog = Logger(subsystem: "com.mactoy", category: "ui.picker")

struct FlashImagePanel: View {
    @EnvironmentObject private var state: AppState
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Flash Image")
                .font(.title.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("What this does")
                    .font(.headline)
                Text("Writes the raw bytes of an .iso, .img, .img.xz, or .img.gz directly to the selected USB drive (equivalent to `dd`). Use this for Linux install ISOs, Raspberry Pi images, or any pre-built bootable image.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mactoyGlass(cornerRadius: 16)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("This creates bootable media from a single image. If you want to boot multiple ISOs from one drive, use the **Install Ventoy** tab, then drop your ISOs onto the `Ventoy` volume.")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mactoyGlass(cornerRadius: 14, tint: .red.opacity(0.22))

            // Locked during a run: a Retry reads the image and these options as they are then.
            DropZone(
                path: $state.selectedImagePath,
                isTargeted: $isTargeted
            )
            .disabled(state.isRunInProgress)

            if state.selectedImagePath != nil {
                ImageCheckCard()
                    .disabled(state.isRunInProgress)
            }

            if let disk = state.selectedDisk {
                if state.isTimeMachineBackup(disk) {
                    TimeMachineBanner(disk: disk)
                        .id(disk.bsdName)
                }
                DangerBanner(disk: disk)
            } else {
                Text("Select a disk in the sidebar to continue.")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

private struct DropZone: View {
    @Binding var path: String?
    @Binding var isTargeted: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
            VStack(spacing: 10) {
                Image(systemName: path == nil ? "arrow.down.doc" : "doc.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                if let p = path {
                    Text((p as NSString).lastPathComponent)
                        .font(.system(.body, design: .monospaced))
                    Button("Choose different image") { pickFile() }
                        .buttonStyle(.link)
                } else {
                    Text("Drop an ISO or IMG here")
                        .font(.headline)
                    Button("Or choose a file…") { pickFile() }
                        .buttonStyle(.link)
                }
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .mactoyGlass(cornerRadius: 14, interactive: true)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let u = url { self.path = u.path }
                }
            }
            return true
        }
    }

    func pickFile() {
        let panel = NSOpenPanel()
        // Safe-unwrap UTType lookups — `UTType(filenameExtension:)`
        // returns nil if the system's CoreServices type registry is in
        // an unusual state. Don't crash the app over a missing type;
        // just leave the corresponding extension out of the filter and
        // log a warning so the degraded state is visible in os.Logger.
        let extensions = ["iso", "img", "xz", "gz"]
        let types = extensions.compactMap { UTType(filenameExtension: $0) }
        if types.count < extensions.count {
            pickerLog.warning("UTType lookup returned \(types.count)/\(extensions.count) — CoreServices type registry may be degraded")
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            self.path = url.path
        }
    }
}

/// The image's SHA-256, checked before the drive is erased, and the check after writing (#26).
private struct ImageCheckCard: View {
    @EnvironmentObject private var state: AppState
    @State private var loadProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Check the image")
                .font(.headline)
            HStack(spacing: 8) {
                TextField("SHA-256 from the download page (optional)", text: $state.flashChecksumInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button("Load from File…") { loadChecksumFile() }
            }
            if state.flashChecksumIsInvalid {
                Label("That isn't a SHA-256 checksum. It should be 64 characters, 0 to 9 and a to f.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let loadProblem {
                Label(loadProblem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(state.flashChecksum == nil
                     ? "If the download page lists a SHA-256, paste it here. Mactoy checks the image against it before erasing the drive."
                     : "Mactoy checks the image against this before erasing the drive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Check the drive after writing", isOn: $state.flashVerifyAfterWriting)
            Text("Reads the drive back and compares it with the image. This adds some time, and can catch a failing drive or one that's smaller than it claims.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mactoyGlass(cornerRadius: 16)
        .onChange(of: state.selectedImagePath) { _ in loadProblem = nil }
    }

    /// A `.sha256`, `SHA256SUMS` or similar file from the same download page.
    private func loadChecksumFile() {
        loadProblem = nil
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the checksum file from the image's download page."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Size first: the image itself is usually next to its checksum file, and is huge.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        guard size < 1_000_000, let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            loadProblem = "Mactoy couldn't read \(url.lastPathComponent) as a checksum file."
            return
        }
        let image = state.selectedImagePath ?? ""
        if let hash = ImageChecksum.sha256(for: image, in: text) {
            state.flashChecksumInput = hash
        } else {
            loadProblem = "\(url.lastPathComponent) has no SHA-256 for \((image as NSString).lastPathComponent)."
        }
    }
}

