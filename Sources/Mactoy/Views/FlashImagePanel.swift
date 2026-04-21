import SwiftUI
import MactoyKit
import UniformTypeIdentifiers

struct FlashImagePanel: View {
    @Environment(AppState.self) private var state
    @State private var isTargeted = false

    var body: some View {
        @Bindable var state = state

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
            .glassEffect(.regular, in: .rect(cornerRadius: 16))

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
            .glassEffect(.regular.tint(.red.opacity(0.22)), in: .rect(cornerRadius: 14))

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
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
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
        panel.allowedContentTypes = [
            UTType(filenameExtension: "iso")!,
            UTType(filenameExtension: "img")!,
            UTType(filenameExtension: "xz")!,
            UTType(filenameExtension: "gz")!
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            self.path = url.path
        }
    }
}
