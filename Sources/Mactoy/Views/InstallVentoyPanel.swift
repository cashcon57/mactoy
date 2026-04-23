import SwiftUI
import MactoyKit

struct InstallVentoyPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
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
            .mactoyGlass(cornerRadius: 16)

            VStack(alignment: .leading, spacing: 8) {
                Text("Version")
                    .font(.headline)
                HStack(spacing: 12) {
                    Menu {
                        Button("Latest") {
                            state.useCustomVentoyVersion = false
                            state.ventoyVersionInput = ""
                        }
                        if !state.availableVentoyVersions.isEmpty {
                            Divider()
                            ForEach(state.availableVentoyVersions, id: \.self) { v in
                                Button("v\(v)") {
                                    state.useCustomVentoyVersion = false
                                    state.ventoyVersionInput = v
                                }
                            }
                        }
                        Divider()
                        Button("Custom…") {
                            state.useCustomVentoyVersion = true
                            if state.customVentoyVersion.isEmpty {
                                state.customVentoyVersion = state.ventoyVersionInput
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(versionMenuLabel)
                                .fontWeight(.medium)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(minWidth: 200, alignment: .leading)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .mactoyGlass(cornerRadius: 10, interactive: true)

                    if state.useCustomVentoyVersion {
                        TextField("e.g. 1.1.11", text: $state.customVentoyVersion)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                        Text("enter a Ventoy release tag")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(state.availableVentoyVersions.isEmpty
                             ? "resolves latest at install time"
                             : "pick an older release or choose Custom…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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

    private var versionMenuLabel: String {
        if state.useCustomVentoyVersion {
            return "Custom"
        }
        let sel = state.ventoyVersionInput.trimmingCharacters(in: .whitespaces)
        if sel.isEmpty {
            if let latest = state.latestVentoyVersion {
                return "Latest (v\(latest))"
            }
            return "Latest"
        }
        return "v\(sel)"
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
        .mactoyGlass(cornerRadius: 14, tint: .red.opacity(0.25))
    }

    static func sizeString(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 1
            ? String(format: "%.1f GB", gb)
            : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}
