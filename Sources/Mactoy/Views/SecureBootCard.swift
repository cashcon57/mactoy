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
                 ? "The drive starts through a small loader signed by Microsoft, so it works on PCs that have Secure Boot turned on. The first time, the PC asks you to enroll Ventoy's key. This is Ventoy's default."
                 : "The drive starts Ventoy directly. Choose this if you'll start an Intel Mac from the drive, or if a PC freezes at a blank screen when starting from it. It won't start on a PC while that PC's Secure Boot is on.")
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
