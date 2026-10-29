import Foundation

/// Every pushed screen on a tab's stack (section 2.4). One case per module,
/// each wrapping that module's own route enum. Frozen after M0.
enum AppRoute: Hashable, Codable, Sendable {
    case inbox(InboxRoute)              // M1
    case fleet(FleetRoute)              // M2
    case monitoring(MonitoringRoute)    // M3
    case activity(ActivityRoute)        // M4
    case inventory(InventoryRoute)      // M5
    case networking(NetworkingRoute)    // M6
    case sshGuard(SSHGuardRoute)        // M7
    case platform(PlatformRoute)        // M8
    case notify(NotifyRoute)            // M9
    case evidence(EvidenceRoute)        // M10
    case terminal(TerminalRoute)        // M12
    case vpn(VPNRoute)                  // M13
}
