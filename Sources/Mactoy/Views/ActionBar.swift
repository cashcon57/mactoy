import SwiftUI
import MactoyKit

struct ActionBar: View {
    @EnvironmentObject private var state: AppState
    /// Here rather than on the button, whose view changes with every status.
    @State private var confirmingCancel = false

    var body: some View {
        VStack(spacing: 10) {
            StatusRow()
            HStack {
                KofiButton()
                Spacer()
                PrimaryButton(confirmingCancel: $confirmingCancel)
            }
        }
        .confirmationDialog("Stop flashing?", isPresented: $confirmingCancel) {
            Button("Stop", role: .destructive) {
                // Only if the flash is still running: the dialog closes itself when it ends.
                guard state.cancelNeedsConfirmation else { return }
                Task { @MainActor in await state.cancelRunInProgress() }
            }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("If Mactoy has started writing, the drive will be left only partly written and won't start until you flash it or install Ventoy on it again.")
        }
        .onChange(of: state.cancelNeedsConfirmation) { stillWriting in
            if !stillWriting { confirmingCancel = false }
        }
    }
}

private struct StatusRow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        switch state.status {
        case .idle:
            EmptyView()
        case .preparing(let m):
            HStack {
                ProgressView().controlSize(.small)
                Text(m).font(.callout).foregroundStyle(.secondary)
            }
        case .running(let update):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(update.phase.rawValue.capitalized)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(update.message)
                        .font(.callout)
                    Spacer()
                }
                if let frac = update.fraction {
                    ProgressView(value: frac)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if state.cancelRequested {
                    Text("Stopping…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let note = state.cancelRefusedNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .mactoyCard(cornerRadius: 16)
        case .success(let m):
            HStack {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text(m).font(.callout)
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mactoyCard(cornerRadius: 16, tint: .green.opacity(0.25))
        case .cancelled(let m):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                Text(m)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mactoyCard(cornerRadius: 16)
        case .failed(let m):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(m)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mactoyCard(cornerRadius: 16, tint: .red.opacity(0.25))
        }
    }
}

private struct PrimaryButton: View {
    @EnvironmentObject private var state: AppState
    @Binding var confirmingCancel: Bool

    private func cancelAction() {
        if state.cancelNeedsConfirmation {
            confirmingCancel = true
        } else {
            Task { @MainActor in await state.cancelRunInProgress() }
        }
    }

    var body: some View {
        switch state.status {
        case .idle:
            Button(action: runAction) {
                Label(primaryLabel, systemImage: "bolt.fill")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .mactoyGlass(
                tint: state.canRun ? tint : nil,
                interactive: state.canRun
            )
            .disabled(!state.canRun)
        case .preparing, .running:
            HStack(spacing: 8) {
                if state.canCancelRun {
                    Button(action: cancelAction) {
                        Label("Cancel", systemImage: "xmark")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .mactoyGlass(interactive: true)
                }
                Button(action: {}) {
                    Label("Working…", systemImage: "hourglass")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .mactoyGlass()
                .disabled(true)
            }
        case .failed:
            // On failure, offer both Retry (if we still have the
            // captured target from the failed run — v0.3.2, issue #5)
            // and Done. Retry re-runs against the SAME captured disk;
            // it does NOT re-derive from selectedDisk (Layers 4/5/6
            // of the iron-clad targeting defense still apply).
            HStack(spacing: 8) {
                if state.canRetryRun {
                    Button(action: { Task { @MainActor in await state.retryRun() } }) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .mactoyGlass(interactive: true)
                }
                Button(action: { Task { @MainActor in state.reset() } }) {
                    Label("Done", systemImage: "checkmark")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .mactoyGlass(interactive: true)
            }
        case .success, .cancelled:
            Button(action: { Task { @MainActor in state.reset() } }) {
                Label("Done", systemImage: "checkmark")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .mactoyGlass(interactive: true)
        }
    }

    private func runAction() {
        // Route through the confirmation sheet instead of starting the
        // install immediately. Users asked for an explicit "are you
        // sure" step showing drive name + used/total bytes before a
        // destructive operation kicks off.
        state.requestRun()
    }

    private var primaryLabel: String {
        switch state.mode {
        case .installVentoy: return "Install Ventoy"
        case .updateVentoy:  return "Update Ventoy"
        case .flashImage:    return "Flash Image"
        case .manageDisk:    return "—"
        }
    }

    private var tint: Color {
        switch state.mode {
        case .installVentoy, .flashImage: return .red
        // Update is non-destructive — accent (blue) signals safe.
        case .updateVentoy:               return .accentColor
        case .manageDisk:                 return .accentColor
        }
    }
}
