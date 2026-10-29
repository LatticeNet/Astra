import SwiftUI

/// The single `navigationDestination(for: AppRoute.self)` of every tab stack.
/// It switches once per module to that module's destination view.
struct AppRouteDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .inbox(let route): InboxDestination(route: route)
        case .fleet(let route): FleetDestination(route: route)
        case .monitoring(let route): MonitoringDestination(route: route)
        case .activity(let route): ActivityDestination(route: route)
        case .inventory(let route): InventoryDestination(route: route)
        case .networking(let route): NetworkingDestination(route: route)
        case .sshGuard(let route): SSHGuardDestination(route: route)
        case .platform(let route): PlatformDestination(route: route)
        case .notify(let route): NotifyDestination(route: route)
        case .evidence(let route): EvidenceDestination(route: route)
        case .terminal(let route): TerminalDestination(route: route)
        case .vpn(let route): VPNDestination(route: route)
        }
    }
}

extension View {
    /// Registers the app's destinations on a tab stack.
    func appRouteDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { AppRouteDestination(route: $0) }
    }
}
