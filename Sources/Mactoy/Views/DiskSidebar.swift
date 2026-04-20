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
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.bsdName)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                    Text(sizeString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSelected
            ? .regular.tint(.accentColor).interactive()
            : .regular.interactive()
        )
    }

    var sizeString: String {
        let bytes = Double(disk.sizeInBytes)
        let gb = bytes / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = bytes / 1_048_576
        return String(format: "%.0f MB", mb)
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
        .glassEffect(.regular)
    }
}
