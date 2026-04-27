import SwiftUI
import MactoyKit

/// Confirmation sheet shown after the user clicks Install / Update / Flash
/// and *before* the helper is handed the plan — the actual run only
/// starts when the user explicitly confirms here.
///
/// The sheet adapts based on `info.mode`:
///
/// - **Install Ventoy / Flash Image** — destructive copy. Shows total
///   size + best-effort estimate of how much data is on the drive
///   (`DiskInfo.estimatedUsedBytes`), lists the volumes that will be
///   erased, button reads "Erase & Install Ventoy" / "Erase & Flash"
///   in red.
///
/// - **Update Ventoy** — non-destructive copy. The user's ISOs and
///   `/ventoy/` config on partition 1 are preserved by design. Button
///   reads "Update Ventoy" with default styling. The volumes panel
///   isn't shown (nothing is being erased). Warns about not unplugging
///   mid-update without scaring the user about data loss.
struct EraseConfirmationSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let info: EraseConfirmation

    private var isUpdate: Bool { info.mode == .updateVentoy }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isUpdate ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(isUpdate ? Color.accentColor : Color.red)
                Text(headerTitle)
                    .font(.title2.bold())
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                // Volumes panel only makes sense when something's being
                // erased. For Update Ventoy we hide it — the volumes
                // (specifically partition 1's "Ventoy" data partition)
                // are explicitly NOT being touched.
                if !isUpdate, !info.disk.volumes.isEmpty {
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
            .mactoyGlass(
                cornerRadius: 14,
                tint: isUpdate ? .accentColor.opacity(0.15) : .red.opacity(0.15)
            )

            Text(footnote)
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

                Button(role: isUpdate ? nil : .destructive) {
                    state.confirmRun()
                    dismiss()
                } label: {
                    Label(primaryLabel, systemImage: isUpdate ? "arrow.triangle.2.circlepath" : "trash")
                        .fontWeight(.semibold)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .tint(isUpdate ? .accentColor : .red)
            }
        }
        .padding(26)
        .frame(width: 520)
    }

    private var headerTitle: String {
        if isUpdate {
            return "Update Ventoy on \(info.disk.displayName)?"
        }
        return "Erase \(info.disk.displayName)?"
    }

    private var summary: String {
        let total = sizeString(info.totalBytes)
        switch info.mode {
        case .installVentoy:
            if let used = info.usedBytes {
                return "Installing Ventoy will wipe the entire \(total) drive. Right now about \(sizeString(used)) of data is on it. Every partition below will be destroyed and replaced with a fresh Ventoy layout."
            }
            return "Installing Ventoy will wipe the entire \(total) drive. Every partition on it will be destroyed and replaced with a fresh Ventoy layout."
        case .updateVentoy:
            return "Update the Ventoy bootloader on this drive in place. Your ISOs and `/ventoy/` configuration are preserved — only the bootloader (MBR boot code, GRUB2 core, and the 32 MB VTOYEFI partition) will be rewritten. Drive total size is \(total)."
        case .flashImage:
            if let used = info.usedBytes {
                return "Flashing this image will overwrite the entire \(total) drive. Right now about \(sizeString(used)) of data is on it and will be lost."
            }
            return "Flashing this image will overwrite the entire \(total) drive. Anything on it will be lost."
        case .manageDisk:
            return ""  // not reachable — Manage Disk doesn't trigger the confirm sheet
        }
    }

    private var footnote: String {
        if isUpdate {
            return "Don't unplug or remove the drive during the update. If interrupted (~5 seconds total), you'll need to re-run the update — your ISOs are safe regardless."
        }
        return "This cannot be undone. If you've got anything important on the drive, cancel and back it up first."
    }

    private var primaryLabel: String {
        switch info.mode {
        case .installVentoy: return "Erase & Install Ventoy"
        case .updateVentoy:  return "Update Ventoy"
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
