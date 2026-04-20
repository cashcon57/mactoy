import SwiftUI
import MactoyKit

struct ModeTabs: View {
    @Environment(AppState.self) private var state

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(AppMode.allCases, id: \.self) { mode in
                    ModeChip(
                        mode: mode,
                        isActive: state.mode == mode,
                        action: { state.mode = mode }
                    )
                }
                Spacer()
            }
        }
    }
}

private struct ModeChip: View {
    let mode: AppMode
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: mode.symbol)
                Text(mode.displayName)
                    .font(.system(.body, design: .rounded).weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .glassEffect(
            isActive
            ? .regular.tint(.accentColor).interactive()
            : .regular.interactive()
        )
    }
}
