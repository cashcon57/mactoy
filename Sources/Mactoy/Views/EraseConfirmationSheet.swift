import SwiftUI
import MactoyKit

/// "This will erase everything on the drive" confirmation sheet.
/// Shown after the user clicks Install Ventoy or Flash Image and
/// *before* the helper is handed the plan — the Install / Flash run
/// only starts when the user explicitly confirms here.
///
/// Shows the disk's human-readable name + bsd name, total size, and
/// a best-effort estimate of how much data currently lives on the
/// disk (`DiskInfo.estimatedUsedBytes`). When the disk has no
/// mounted volumes — e.g. an already-Ventoy'd stick that the user is
/// re-flashing — the estimate isn't available and we say "up to
/// <total size>" instead.
struct EraseConfirmationSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let info: EraseConfirmation

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.red)
                Text("Erase \(info.disk.displayName)?")
                    .font(.title2.bold())
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                if !info.disk.volumes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Volumes that will be erased:")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(info.disk.volumes, id: \.bsdName) { vol in
                            HStack(spacing: 6) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 5))
                                    .foregroundStyle(.secondary)
                                Text(vol.volumeName.isEmpty ? vol.bsdName : vol.volumeName)
                                    .font(.callout)
                                Text("(\(sizeString(vol.sizeInBytes)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mactoyGlass(cornerRadius: 14, tint: .red.opacity(0.15))

            Text("This cannot be undone. If you've got anything important on the drive, cancel and back it up first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) {
                    state.cancelRun()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)

                Button(role: .destructive) {
                    state.confirmRun()
                    dismiss()
                } label: {
                    Label(primaryLabel, systemImage: "trash")
                        .fontWeight(.semibold)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .tint(.red)
            }
        }
        .padding(26)
        .frame(width: 520)
    }

    private var summary: String {
        let total = sizeString(info.totalBytes)
        switch (info.mode, info.usedBytes) {
        case (.installVentoy, let used?):
            return "Installing Ventoy will wipe the entire \(total) drive. Right now about \(sizeString(used)) of data is on it. Every partition below will be destroyed and replaced with a fresh Ventoy layout."
        case (.installVentoy, nil):
            return "Installing Ventoy will wipe the entire \(total) drive. Every partition on it will be destroyed and replaced with a fresh Ventoy layout."
        case (.flashImage, let used?):
            return "Flashing this image will overwrite the entire \(total) drive. Right now about \(sizeString(used)) of data is on it and will be lost."
        case (.flashImage, nil):
            return "Flashing this image will overwrite the entire \(total) drive. Anything on it will be lost."
        case (.manageDisk, _):
            return ""  // not reachable — Manage Disk doesn't trigger the confirm sheet
        }
    }

    private var primaryLabel: String {
        switch info.mode {
        case .installVentoy: return "Erase & Install Ventoy"
        case .flashImage:    return "Erase & Flash"
        case .manageDisk:    return "Proceed"
        }
    }

    private func sizeString(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        let gb = b / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = b / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", b / 1024)
    }
}
