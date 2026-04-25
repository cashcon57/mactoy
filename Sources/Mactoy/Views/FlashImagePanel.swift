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

            DropZone(
                path: $state.selectedImagePath,
                isTargeted: $isTargeted
            )

            if let disk = state.selectedDisk {
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
