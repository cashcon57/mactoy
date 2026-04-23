import SwiftUI

/// Shown the first time a user clicks Install / Flash if the mactoyd
/// daemon has not yet been registered + approved. Explains what Mactoy
/// is about to ask macOS for, so the "Background Items Added"
/// notification doesn't feel like it came out of nowhere.
struct HelperExplainerSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                Text("One-time setup")
                    .font(.title2.bold())
                Spacer()
            }

            VStack(alignment: .leading, spacing: 14) {
                bullet(icon: "externaldrive.badge.minus",
                       title: "Why Mactoy needs this",
                       body: "macOS blocks ordinary apps from writing directly to USB drives. To install Ventoy (which requires raw disk writes), Mactoy has to go through a privileged helper registered with the system.")

                bullet(icon: "bolt.slash.fill",
                       title: "It does not run in the background",
                       body: "The helper (`mactoyd`) only starts when Mactoy asks it to — during an install or flash — and exits when the job is done. It doesn't run at login, doesn't poll, and doesn't use resources when idle. macOS still files it under 'Allow in the Background' because that's where the toggle lives.")

                bullet(icon: "hand.raised.fill",
                       title: "Approval is a one-time click",
                       body: "When you continue, macOS will show a 'Background Items Added' notification and open \(SystemSettingsStrings.loginItemsPane). Turn the Mactoy toggle on once — you won't be asked again.")

                bullet(icon: "trash",
                       title: "You can remove the helper when you're done",
                       body: "Leave the checkbox below ticked to have Mactoy automatically remove the helper after this install completes. Untick it if you plan to flash more drives soon.")
            }

            Toggle(isOn: $state.uninstallHelperAfterRun) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove the helper after this install")
                        .font(.callout.bold())
                    Text(state.uninstallHelperAfterRun
                         ? "Mactoy will unregister the daemon as soon as this run finishes."
                         : "The daemon will stay registered — future installs will skip this sheet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mactoyGlass(cornerRadius: 14)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) {
                    state.cancelHelperApproval()
                    state.showHelperExplainer = false
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    state.showHelperExplainer = false
                    state.beginHelperApproval()
                    dismiss()
                } label: {
                    Label("Allow & Open Settings", systemImage: "arrow.up.right.square")
                        .fontWeight(.semibold)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
        }
        .padding(26)
        .frame(width: 560)
    }

    private func bullet(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.bold())
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Shown while the daemon is registered but waiting on the user to flip
/// the toggle in Login Items & Extensions. Polls `helperStatus` in the
/// background and dismisses automatically when the state is `.enabled`.
struct HelperAwaitingApprovalSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Waiting for macOS approval")
                    .font(.title2.bold())
            }
            Text("System Settings should be open at **\(SystemSettingsStrings.loginItemsPane)**. Scroll to **Allow in the Background** and turn on **Mactoy**. This window will close automatically as soon as macOS confirms the toggle.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Re-open Settings") {
                    HelperLifecycle.openLoginItemsSettings()
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    state.cancelHelperApproval()
                    dismiss()
                }
            }
        }
        .padding(26)
        .frame(width: 480)
        .onChange(of: state.helperStatus) { new in
            if new == .enabled { dismiss() }
        }
    }
}
