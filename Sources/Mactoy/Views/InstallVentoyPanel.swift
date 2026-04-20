import SwiftUI
import MactoyKit

struct InstallVentoyPanel: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("Install Ventoy")
                    .font(.title.bold())
                if let v = state.latestVentoyVersion {
                    Text("latest: v\(v)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("What this does")
                    .font(.headline)
                Text("Downloads Ventoy from the official GitHub release, wipes the selected disk, creates a Ventoy-compatible GPT layout, and formats the data partition as exFAT. After install, drop any ISO / IMG / WIM file onto the mounted `Ventoy` volume and it will appear in the Ventoy boot menu.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular)

            VStack(alignment: .leading, spacing: 8) {
                Text("Version")
                    .font(.headline)
                HStack {
                    TextField("latest", text: $state.ventoyVersionInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                    Text("leave blank for latest")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

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

struct DangerBanner: View {
    let disk: DiskTarget

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.red)
            VStack(alignment: .leading) {
                Text("All data on /dev/\(disk.bsdName) will be erased.")
                    .font(.callout.bold())
                Text("Size: \(Self.sizeString(disk.sizeInBytes)). This cannot be undone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular.tint(.red.opacity(0.25)))
    }

    static func sizeString(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 1
            ? String(format: "%.1f GB", gb)
            : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}
