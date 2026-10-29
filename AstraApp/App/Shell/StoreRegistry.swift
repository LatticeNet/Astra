import SwiftUI

/// Every module's list store, created once at launch and injected into the
/// environment (section 8.4). Detail models are view-owned and never here.
@MainActor
final class StoreRegistry {
    let inbox: InboxStore
    let approvals: ApprovalsStore
    let fleet: FleetStore
    let groups: GroupsStore
    let monitoring: MonitoringStore
    let tasks: TasksStore
    let audit: AuditStore
    let inventory: InventoryStore
    let networking: NetworkingStore
    let sshGuard: SSHGuardStore
    let agentUpdates: AgentUpdatesStore
    let platform: PlatformStore
    let publishing: PublishingStore
    let notify: NotifyStore
    let evidence: EvidenceStore
    let access: AccessStore
    let terminal: TerminalStore
    let vpn: VPNStore

    init(session: SessionStore, changes: ChangeLog) {
        inbox = InboxStore(session: session, changes: changes)
        approvals = ApprovalsStore(session: session, changes: changes)
        fleet = FleetStore(session: session, changes: changes)
        groups = GroupsStore(session: session, changes: changes)
        monitoring = MonitoringStore(session: session, changes: changes)
        tasks = TasksStore(session: session, changes: changes)
        audit = AuditStore(session: session, changes: changes)
        inventory = InventoryStore(session: session, changes: changes)
        networking = NetworkingStore(session: session, changes: changes)
        sshGuard = SSHGuardStore(session: session, changes: changes)
        agentUpdates = AgentUpdatesStore(session: session, changes: changes)
        platform = PlatformStore(session: session, changes: changes)
        publishing = PublishingStore(session: session, changes: changes)
        notify = NotifyStore(session: session, changes: changes)
        evidence = EvidenceStore(session: session, changes: changes)
        access = AccessStore(session: session, changes: changes)
        terminal = TerminalStore(session: session, changes: changes)
        vpn = VPNStore(session: session, changes: changes)
    }
}

extension View {
    /// Injects every list store.
    func injectStores(_ stores: StoreRegistry) -> some View {
        environment(stores.inbox)
            .environment(stores.approvals)
            .environment(stores.fleet)
            .environment(stores.groups)
            .environment(stores.monitoring)
            .environment(stores.tasks)
            .environment(stores.audit)
            .environment(stores.inventory)
            .environment(stores.networking)
            .environment(stores.sshGuard)
            .environment(stores.agentUpdates)
            .environment(stores.platform)
            .environment(stores.publishing)
            .environment(stores.notify)
            .environment(stores.evidence)
            .environment(stores.access)
            .environment(stores.terminal)
            .environment(stores.vpn)
    }
}
