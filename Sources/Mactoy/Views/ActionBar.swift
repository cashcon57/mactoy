import SwiftUI
import MactoyKit

struct ActionBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            StatusRow()
            HStack {
                KofiButton()
                Spacer()
                PrimaryButton()
            }
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
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .mactoyGlass(cornerRadius: 16)
        case .success(let m):
            HStack {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text(m).font(.callout)
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mactoyGlass(cornerRadius: 16, tint: .green.opacity(0.25))
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
            .mactoyGlass(cornerRadius: 16, tint: .red.opacity(0.25))
        }
    }
}

private struct PrimaryButton: View {
    @EnvironmentObject private var state: AppState

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
            Button(action: {}) {
                Label("Working…", systemImage: "hourglass")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .mactoyGlass()
            .disabled(true)
        case .success, .failed:
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
        case .flashImage:    return "Flash Image"
        case .manageDisk:    return "—"
        }
    }

    private var tint: Color {
        switch state.mode {
        case .installVentoy, .flashImage: return .red
        case .manageDisk:                 return .accentColor
        }
    }
}
