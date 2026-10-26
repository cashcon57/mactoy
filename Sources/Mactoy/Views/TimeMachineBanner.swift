import SwiftUI
import MactoyKit

/// Shown on the Install and Flash tabs when the selected disk holds Time
/// Machine backups (PR #13). (Update never erases, and a backup drive
/// can't be a Ventoy drive, so that tab just stays disabled.) Locked by default; the user can
/// unlock that one drive for this session after an explicit warning.
struct TimeMachineBanner: View {
    @EnvironmentObject private var state: AppState
    let disk: DiskTarget
    @State private var confirmingUnlock = false

    private var locked: Bool { state.isLockedBackup(disk) }
    private var name: String { disk.mediaName ?? disk.bsdName }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                    .foregroundStyle(locked ? Color.orange : Color.red)
                Text(locked ? "This is a Time Machine backup drive" : "Time Machine drive unlocked")
                    .font(.callout.bold())
            }
            Text(locked
                 ? "Mactoy won't erase or write to it, so your backups stay safe. If you want to reuse this drive, unlock it first. Everything on it, including all of its backups, will be lost."
                 : "Mactoy will erase this drive if you continue, including all of its Time Machine backups. The unlock lasts until you lock it again, unplug the drive or quit Mactoy.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if locked {
                    Button("Unlock This Drive…") { confirmingUnlock = true }
                        .controlSize(.small)
                } else {
                    Button("Lock Again") { state.lockBackupDisk(disk) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mactoyGlass(cornerRadius: 14, tint: (locked ? Color.orange : Color.red).opacity(0.15))
        .confirmationDialog(
            "Unlock \(name) for erasing?",
            isPresented: $confirmingUnlock,
            titleVisibility: .visible
        ) {
            Button("Unlock and Allow Erasing", role: .destructive) { state.unlockBackupDisk(disk) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This drive holds Time Machine backups. Installing Ventoy or flashing an image erases the whole drive, and the backups can't be recovered.")
        }
    }
}
