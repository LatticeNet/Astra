import SwiftUI

/// The single destination of the Settings sheet's stack.
struct SettingsDestination: View {
    let route: SettingsRoute

    var body: some View {
        switch route {
        case .page(let page):
            switch page {
            case .connection: ConnectionScreen()
            case .scopes: ScopeSummaryScreen()
            case .session: SessionForRevealsScreen()
            case .deviceSecurity: DeviceSecurityScreen()
            case .badge: BadgeRefreshScreen()
            case .display: DisplayScreen()
            case .diagnostics: DiagnosticsScreen()
            case .demo: DemoScenarioScreen()
            case .about: AboutScreen()
            case .statusSampler: statusSampler
            }
        case .account(let route):
            AccountDestination(route: route)
        }
    }

    @ViewBuilder
    private var statusSampler: some View {
        #if DEBUG
        StatusSampler()
        #else
        ContentUnavailableView("Debug builds only", systemImage: "ladybug")
        #endif
    }
}
