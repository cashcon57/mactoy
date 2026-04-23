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

            ScrollView {
                Group {
                    switch state.mode {
                    case .installVentoy: InstallVentoyPanel()
                    case .flashImage:    FlashImagePanel()
                    case .manageDisk:    ManageDiskPanel()
                    }
                }
                .padding(20)
            }

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
