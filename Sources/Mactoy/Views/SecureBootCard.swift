import SwiftUI

/// Secure Boot support toggle, shared by Install Ventoy and Update
/// Ventoy (issue #9). Same choice as Ventoy2Disk's `-s` / `-S`.
struct SecureBootCard: View {
    @Binding var isOn: Bool
    /// Update tab only: what the drive has right now, so flipping the
    /// toggle reads as a change rather than a fresh choice.
    var currentlyOnDrive: Bool? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $isOn) {
                Text("Secure Boot support")
                    .font(.headline)
            }
            .toggleStyle(.switch)

            Text(isOn
                 ? "The drive boots through Ventoy's signed shim, so it works on PCs that have Secure Boot turned on (you enroll Ventoy's key the first time). This is Ventoy's default."
                 : "The drive boots GRUB directly, with no shim. Choose this for Macs, and for PCs that hang on a blank screen when starting the drive. It won't boot on a PC while that PC's Secure Boot is on.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let currentlyOnDrive, currentlyOnDrive != isOn {
                Label(
                    "This drive currently has it \(currentlyOnDrive ? "on" : "off"). Updating will turn it \(isOn ? "on" : "off").",
                    systemImage: "arrow.triangle.swap"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mactoyGlass(cornerRadius: 16)
    }
}
