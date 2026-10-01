import SwiftUI
import MactoyKit

/// MBR / GPT choice for a fresh install (issue #11). Same choice as
/// Ventoy2Disk's default versus `-g`.
struct PartitionStyleCard: View {
    @EnvironmentObject private var state: AppState
    let disk: DiskTarget?

    private var mbrPossible: Bool {
        guard let disk else { return true }
        return VentoyPartitionStyle.mbrCanAddress(diskBytes: disk.sizeInBytes)
    }

    private var selection: Binding<VentoyPartitionStyle> {
        Binding(
            get: { state.effectiveInstallPartitionStyle(for: disk) },
            set: { state.installPartitionStyleChoice = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Partition style")
                    .font(.headline)
                Spacer()
                Picker("Partition style", selection: selection) {
                    Text("MBR").tag(VentoyPartitionStyle.mbr)
                    Text("GPT").tag(VentoyPartitionStyle.gpt)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(!mbrPossible)
            }

            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mactoyGlass(cornerRadius: 16)
    }

    private var description: String {
        if !mbrPossible {
            return "GPT is required: this drive is larger than 2 TiB (about 2.2 TB), the most MBR can address."
        }
        switch state.effectiveInstallPartitionStyle(for: disk) {
        case .mbr:
            return "Boots on both older BIOS PCs and modern UEFI machines. This is Ventoy's default and the safest choice if you're not sure."
        case .gpt:
            return "The modern partition table. Choose it if you know a machine you'll use needs GPT. Some older BIOS PCs won't boot a GPT drive."
        }
    }
}
