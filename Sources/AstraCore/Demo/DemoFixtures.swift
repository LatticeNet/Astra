import Foundation

/// Every demo route, concatenated from the per-domain fixture files (section 8.5).
public enum DemoFixtures {
    public static var all: [DemoRoute] {
        SharedFixtures.routes
            + ApprovalsFixtures.routes
            + FleetFixtures.routes
            + MonitoringFixtures.routes
            + TasksFixtures.routes
            + AuditFixtures.routes
            + InventoryFixtures.routes
            + NetworkingFixtures.routes
            + SSHGuardFixtures.routes
            + AgentUpdatesFixtures.routes
            + PlatformFixtures.routes
            + NotifyFixtures.routes
            + EvidenceFixtures.routes
            + AccessFixtures.routes
            + TerminalFixtures.routes
            + VPNFixtures.routes
    }
}
