import SwiftUI
import MactoyKit

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        NavigationSplitView {
            DiskSidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            DetailPane()
        }
        .toolbar(removing: .sidebarToggle)
        .background(BackgroundGradient())
    }
}

private struct BackgroundGradient: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .underPageBackgroundColor)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct DetailPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            ModeTabs()
                .padding(.horizontal, 20)
                .padding(.top, 16)

            Divider().padding(.horizontal, 20)

            Group {
                switch state.mode {
                case .installVentoy: InstallVentoyPanel()
                case .flashImage:    FlashImagePanel()
                case .manageDisk:    ManageDiskPanel()
                }
            }
            .padding(20)

            Spacer()

            ActionBar()
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .frame(width: 900, height: 600)
}
