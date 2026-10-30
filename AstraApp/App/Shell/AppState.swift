import SwiftUI

/// The five tabs (section 2.1).
enum AppTab: String, CaseIterable, Codable, Hashable, Sendable {
    case inbox, fleet, monitor, activity, browse

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .fleet: "Fleet"
        case .monitor: "Monitor"
        case .activity: "Activity"
        case .browse: "Browse"
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "tray.full"
        case .fleet: "server.rack"
        case .monitor: "waveform.path.ecg"
        case .activity: "clock.arrow.circlepath"
        case .browse: "square.grid.2x2"
        }
    }
}

/// Navigation and presentation state owned by RootTabs (F-01). Persisted
/// parts are written to scene storage by RootTabs; nothing secret lives here.
@MainActor @Observable
final class AppState {
    var selectedTab: AppTab = .inbox
    var paths: [AppTab: [AppRoute]] = [:]
    var fleetScope: FleetScope = .nodes
    var monitorSegment: MonitorSegment = .overview
    var activityScope: ActivityScope = .tasks
    var monitorWindow: MonitorWindow = .oneDay
    /// A view a deep link asked for (`lattice://monitor?segment=paths&view=chains`),
    /// consumed once by the segment root.
    var monitorView: String?
    var approvalsView: ApprovalsScope?
    /// An audit layer a module asked for (Terminal's trail needs All, where
    /// reaper and agent closes are), consumed once by the Audit scope.
    var auditLayer: AuditLayer?
    /// A time range that link asked for, consumed with the layer, so a count
    /// for the last hour opens on the last hour.
    var auditRange: TimeRangeSelection?
    /// Search text a count button or link asked for, keyed by scope name,
    /// consumed once by that scope root's `.searchable`.
    var pendingQuery: [String: String] = [:]
    var globalSheet: GlobalSheet?
    /// The welcome cover. It stays up through the scope summary after the
    /// credential connects, so it is not simply "not connected".
    var welcomePresented = false
    /// Set once RootTabs has applied scene storage. A link that arrives
    /// earlier (an App Intent on a cold launch) is held until then, or the
    /// restore would overwrite the tab and path it chose.
    var shellRestored = false
    var settingsPresented = false
    var settingsPath: [SettingsRoute] = []
    /// Bumped when the selected tab is tapped again.
    var scrollToTop: [AppTab: Int] = [:]
    /// The Inbox and app icon badge; nil until something computed it.
    var badgeCount: Int?
    /// When the badge data came from (Inbox stamps it).
    var badgeSourceAt: Date?

    func path(_ tab: AppTab) -> [AppRoute] {
        paths[tab, default: []]
    }

    /// The query for `scope`, removed as it is read.
    func consumeQuery(_ scope: String) -> String? {
        pendingQuery.removeValue(forKey: scope)
    }

    /// Tapping the selected tab pops to its root and scrolls to the top.
    func reselect(_ tab: AppTab) {
        paths[tab] = []
        scrollToTop[tab, default: 0] += 1
    }
}

extension EnvironmentValues {
    /// Bumped when the current tab is tapped again; root lists scroll to the top.
    @Entry var scrollToTopSignal: Int = 0
}
