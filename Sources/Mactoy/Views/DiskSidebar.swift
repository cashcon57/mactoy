import SwiftUI
import MactoyKit

struct DiskSidebar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 16) {
            Text("Mactoy")
                .font(.largeTitle.bold())
                .padding(.top, 8)
                .padding(.horizontal, 20)

            Text("External disks")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            ScrollView {
                GlassEffectContainer(spacing: 12) {
                    VStack(spacing: 12) {
                        if state.disks.isEmpty {
                            EmptyDisksHint()
                        } else {
                            ForEach(state.disks, id: \.bsdName) { disk in
                                DiskCard(
                                    disk: disk,
                                    isSelected: state.selectedDiskBSD == disk.bsdName,
                                    onTap: { state.selectedDiskBSD = disk.bsdName }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct DiskCard: View {
    let disk: DiskTarget
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "externaldrive.fill")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(disk.displayName)
                            .font(.body.bold())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(disk.bsdName)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(Self.sizeString(disk.sizeInBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !disk.volumes.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(disk.volumes, id: \.bsdName) { vol in
                                HStack(spacing: 6) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 4))
                                        .foregroundStyle(.secondary)
                                    Text(vol.volumeName.isEmpty ? vol.bsdName : vol.volumeName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer(minLength: 0)
                                    Text(Self.sizeString(vol.sizeInBytes))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSelected
            ? .regular.tint(.accentColor).interactive()
            : .regular.interactive(),
            in: .rect(cornerRadius: 14)
        )
    }

    static func sizeString(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        let gb = b / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = b / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", b / 1024)
    }
}

private struct EmptyDisksHint: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No external disks detected")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Plug in a USB drive to get started.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}
