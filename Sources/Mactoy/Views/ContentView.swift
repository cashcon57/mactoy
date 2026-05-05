import SwiftUI
import MactoyKit

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            DiskSidebar()
                .frame(width: 300)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            DetailPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 880, minHeight: 600)
        .task { state.refreshHelperStatus() }
        .sheet(isPresented: $state.showHelperExplainer) {
            HelperExplainerSheet()
        }
        .sheet(isPresented: $state.isAwaitingHelperApproval) {
            HelperAwaitingApprovalSheet()
        }
        .sheet(isPresented: $state.showFullDiskAccessSheet) {
            FullDiskAccessSheet()
        }
        .sheet(item: $state.pendingEraseConfirmation) { info in
            EraseConfirmationSheet(info: info)
        }
    }
}

struct DetailPane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            ModeTabs()
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()

            // **Manage Disk skips the outer ScrollView (issue #1, v0.3.1).**
            // ManageDiskPanel renders a `List`, and `List` inside
            // `ScrollView` crashes SwiftUI on macOS 26 (Sequoia/Tahoe)
            // — multiple users reported `swift_release` /
            // `swift_arrayDestroy` crashes in `HVStack.updateCache`
            // when clicking the Manage Disk tab. The List manages its
            // own vertical overflow, so wrapping it in a ScrollView
            // gives nothing but the crash. The other panels are
            // ScrollView-safe (no inner List).
            Group {
                switch state.mode {
                case .installVentoy:
                    ScrollView { InstallVentoyPanel().padding(20) }
                case .updateVentoy:
                    ScrollView { UpdateVentoyPanel().padding(20) }
                case .flashImage:
                    ScrollView { FlashImagePanel().padding(20) }
                case .manageDisk:
                    ManageDiskPanel().padding(20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ActionBar()
                .padding(20)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
        .frame(width: 900, height: 600)
}
