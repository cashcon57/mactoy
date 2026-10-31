import SwiftUI
import MactoyKit

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        // A real split view, so macOS draws the window the modern way: the
        // sidebar runs to the top edge with the window buttons on it, and the
        // toolbar shares their row. On macOS 26 the sidebar and toolbar are
        // Liquid Glass; on 13 to 15 the sidebar is the standard translucent one.
        NavigationSplitView {
            DiskSidebar()
                .frame(minWidth: 260)
                .background { WindowTranslucency(material: .sidebar).ignoresSafeArea() }
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
                .modifier(KeepSidebarOpen())
        } detail: {
            DetailPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { WindowTranslucency(material: .underWindowBackground).ignoresSafeArea() }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                ModePicker()
            }
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
        }
        .modifier(FloatingActionBar())
    }
}

/// The action bar floats over the bottom of the panel. On macOS 26 the
/// content scrolls underneath it and blurs at the edge; earlier versions get
/// a translucent bar with a divider.
private struct FloatingActionBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.safeAreaBar(edge: .bottom) {
                ActionBar()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
            }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    ActionBar().padding(20)
                }
                .background(.bar)
            }
        }
    }
}

/// The drive list is how you pick a drive, so its button to hide the sidebar
/// is removed where macOS allows it (14 and later).
private struct KeepSidebarOpen: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(ThemeStore())
        .frame(width: 900, height: 600)
}
