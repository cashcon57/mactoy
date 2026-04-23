import SwiftUI
import MactoyKit

struct ModeTabs: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        MactoyGlassContainer(spacing: 8) {
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
        .mactoyGlass(
            tint: isActive ? .accentColor : nil,
            interactive: true
        )
    }
}
