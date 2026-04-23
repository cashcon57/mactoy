import Foundation
import ServiceManagement

/// Version-dependent names for System Settings panes + concepts we
/// reference in user-facing copy. macOS 15 Sequoia renamed the
/// "Login Items" pane to "Login Items & Extensions"; writing one
/// hardcoded string leaves Ventura and Sonoma users hunting for a
/// pane that doesn't exist under that name on their system.
enum SystemSettingsStrings {
    /// The name of the pane that lists registered daemons / login
    /// items. "Login Items" on 13/14, "Login Items & Extensions" on
    /// 15+.
    static var loginItemsPane: String {
        if #available(macOS 15.0, *) {
            return "Login Items & Extensions"
        } else {
            return "Login Items"
        }
    }
}

/// Lifecycle state of the `mactoyd` LaunchDaemon as far as Mactoy cares.
/// Drives the pre-install explainer sheet and the Install button's copy.
enum HelperStatus: Equatable {
    /// Not yet registered with SMAppService. Clicking Install will show
    /// the explainer sheet and then call `register()`.
    case notRegistered
    /// Registered but waiting on the user to flip the Login Items toggle.
    case requiresApproval
    /// Registered + approved. Installs run without prompts.
    case enabled
    /// SMAppService returned an unexpected status code we don't map.
    case unknown(Int)
}

enum HelperLifecycle {
    static let daemonPlistName = "com.mactoy.mactoyd.plist"

    @MainActor
    static var status: HelperStatus {
        let svc = SMAppService.daemon(plistName: daemonPlistName)
        switch svc.status {
        case .notRegistered, .notFound: return .notRegistered
        case .enabled:                  return .enabled
        case .requiresApproval:         return .requiresApproval
        @unknown default:               return .unknown(svc.status.rawValue)
        }
    }

    /// Kicks off the macOS "Background Items Added" flow. After this
    /// returns the user still needs to toggle the daemon on in System
    /// Settings — call `openLoginItemsSettings()` right after and poll
    /// `status` until it flips to `.enabled`.
    @MainActor
    static func register() throws {
        let svc = SMAppService.daemon(plistName: daemonPlistName)
        try svc.register()
    }

    @MainActor
    static func unregister() async throws {
        let svc = SMAppService.daemon(plistName: daemonPlistName)
        try await svc.unregister()
    }

    @MainActor
    static func openLoginItemsSettings() {
        // Direct deep-link to the Login Items & Extensions pane. The user
        // can still get here via the Background Items Added notification,
        // but we open it eagerly so they don't have to hunt.
        SMAppService.openSystemSettingsLoginItems()
    }
}
