import SwiftUI
import MactoyKit

struct ManageDiskPanel: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Manage Disk")
                .font(.title.bold())

            if let disk = state.selectedDisk, let volumeURL = ventoyVolumeURL(for: disk) {
                Text("Ventoy volume mounted at \(volumeURL.path)")
                    .foregroundStyle(.secondary)

                ISOList(volumeURL: volumeURL)
                    .frame(maxHeight: .infinity)

                HStack {
                    Button("Open in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([volumeURL])
                    }
                    Button("Add ISO…") {
                        addISO(to: volumeURL)
                    }
                    Spacer()
                }
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
                .glassEffect(.regular, in: .rect(cornerRadius: 16))

                Spacer()
            }
        }
    }

    private func ventoyVolumeURL(for disk: DiskTarget) -> URL? {
        let fm = FileManager.default
        guard let mounts = try? fm.contentsOfDirectory(atPath: "/Volumes") else { return nil }
        for name in mounts {
            if name == "Ventoy" {
                return URL(fileURLWithPath: "/Volumes/\(name)")
            }
        }
        return nil
    }

    private func addISO(to vol: URL) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for src in panel.urls {
                let dest = vol.appendingPathComponent(src.lastPathComponent)
                try? FileManager.default.copyItem(at: src, to: dest)
            }
        }
    }
}

private struct ISOList: View {
    let volumeURL: URL
    @State private var items: [URL] = []

    var body: some View {
        List(items, id: \.self) { url in
            HStack {
                Image(systemName: "opticaldisc")
                Text(url.lastPathComponent)
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Text(sizeString(for: url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    try? FileManager.default.removeItem(at: url)
                    refresh()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .listStyle(.inset)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: volumeURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        items = contents.filter { url in
            let ext = url.pathExtension.lowercased()
            return ["iso", "img", "wim", "efi", "vhd", "vhdx"].contains(ext)
        }.sorted(by: { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() })
    }

    private func sizeString(for url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 1
            ? String(format: "%.2f GB", gb)
            : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}
