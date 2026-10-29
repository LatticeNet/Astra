import SwiftUI
import UIKit

/// The demo launch arguments of section 9.2. Every override is honored only
/// in demo mode (`-AstraDemo YES`); outside demo they are ignored.
struct LaunchOverrides: Sendable {
    enum ColorFilter: String, Sendable { case grayscale, deuteranopia }

    var demo = false
    var route: URL?
    /// `-AstraTab browse`: selects a tab root, for the Browse directory,
    /// which has no deep link of its own.
    var tab: AppTab?
    /// One or more comma-separated sheets, opened in order.
    var present: String?
    var auth: DeviceAuthOutcome?
    var autoConfirm = false
    var scenario: DemoScenario?
    /// `-AstraDemoToken triage|operator|root|admin`: the token's preset in any scenario.
    var demoToken: DemoToken?
    var demoNow: String?
    var landscape = false
    var colorFilter: ColorFilter?
    var boldText = false
    var differentiateWithoutColor = false

    /// Read once at launch from the argument domain.
    static let current = LaunchOverrides(defaults: .standard)

    init(defaults: UserDefaults) {
        demo = defaults.bool(forKey: "AstraDemo")
        guard demo else { return }
        route = defaults.string(forKey: "AstraRoute").flatMap(URL.init(string:))
        tab = defaults.string(forKey: "AstraTab").flatMap(AppTab.init(rawValue:))
        present = defaults.string(forKey: "AstraPresent")
        auth = switch defaults.string(forKey: "AstraAuth") {
        case "succeed": .confirmed
        case "cancel": .cancelled
        default: nil
        }
        autoConfirm = defaults.bool(forKey: "AstraAutoConfirm")
        scenario = defaults.string(forKey: "AstraDemoScenario").flatMap(DemoScenario.init(argument:))
        demoToken = defaults.string(forKey: "AstraDemoToken").flatMap(DemoToken.init(argument:))
        demoNow = defaults.string(forKey: "AstraDemoNow")
        landscape = defaults.string(forKey: "AstraOrientation") == "landscape"
        colorFilter = defaults.string(forKey: "AstraColorFilter").flatMap(ColorFilter.init(rawValue:))
        boldText = defaults.bool(forKey: "AstraBoldText")
        differentiateWithoutColor = defaults.bool(forKey: "AstraDifferentiateWithoutColor")
    }

    init() {}
}

/// What a module offers `-AstraPresent`: its intents by id (`confirm:<id>`,
/// `reveal:<id>`) and its sheets by name. Each module's route type conforms in
/// its own route file; the defaults offer nothing.
@MainActor
protocol DemoHooks {
    static func demoIntent(_ id: String, session: SessionStore) -> WriteIntent?
    static func demoReveal(_ id: String) -> RevealIntent?
    static func demoSheet(_ name: String, argument: String?) -> AnyView?
}

extension DemoHooks {
    static func demoIntent(_ id: String, session: SessionStore) -> WriteIntent? { nil }
    static func demoReveal(_ id: String) -> RevealIntent? { nil }
    static func demoSheet(_ name: String, argument: String?) -> AnyView? { nil }
}

/// Every module's hooks, pre-populated in M0.
@MainActor
enum DemoHookRegistry {
    static let modules: [any DemoHooks.Type] = [
        FoundationDemoIntents.self,
        InboxRoute.self, FleetRoute.self, MonitoringRoute.self, ActivityRoute.self,
        InventoryRoute.self, NetworkingRoute.self, SSHGuardRoute.self, PlatformRoute.self,
        NotifyRoute.self, EvidenceRoute.self, AccountRoute.self, TerminalRoute.self, VPNRoute.self,
    ]

    static func intent(_ id: String, session: SessionStore) -> WriteIntent? {
        modules.lazy.compactMap { $0.demoIntent(id, session: session) }.first
    }

    static func reveal(_ id: String) -> RevealIntent? {
        modules.lazy.compactMap { $0.demoReveal(id) }.first
    }

    static func sheet(named name: String, argument: String?) -> AnyView? {
        modules.lazy.compactMap { $0.demoSheet(name, argument: argument) }.first
    }
}

/// Applies the route, presentation and orientation overrides once the root is up.
@MainActor
enum LaunchActions {
    static func apply(_ overrides: LaunchOverrides, services: AppServices) async {
        guard overrides.demo else { return }
        if overrides.landscape, let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
        }
        // Give the first frame a moment, so links land on a laid-out stack.
        try? await Task.sleep(for: .milliseconds(400))
        if let tab = overrides.tab {
            services.appState.selectedTab = tab
            services.appState.paths[tab] = []
        }
        if let route = overrides.route {
            services.deepLinks.handle(route)
        }
        // Several sheets in a row ("settings,confirm:sample.t3") show a gate
        // started inside a sheet, and the banner above it.
        for (index, value) in (overrides.present?.split(separator: ",").map(String.init) ?? []).enumerated() {
            if index > 0 { try? await Task.sleep(for: .milliseconds(900)) }
            if value.hasPrefix("confirm:") || value.hasPrefix("reveal:") {
                Task { await self.present(value, services: services) }
            } else {
                await self.present(value, services: services)
            }
        }
    }

    private static func present(_ value: String, services: AppServices) async {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts[0]
        let argument = parts.count > 1 ? parts[1] : nil
        switch name {
        case "review":
            if let argument { services.router.present(.review(.single(argument))) }
        case "batch":
            if let argument { services.router.present(.review(.batch(groupKey: argument, ids: []))) }
        case "renew":
            if let argument { services.router.present(.renew(machineID: argument)) }
        case "maintenanceStart":
            services.router.present(.maintenanceStart(nodeID: argument))
        case "settings":
            let page = argument.flatMap(SettingsPage.init(rawValue:))
            services.router.openSettings(page.map { [.page($0)] } ?? [])
        case "sampler":
            services.router.openSettings([.page(.statusSampler)])
        case "confirm":
            if let argument, let intent = DemoHookRegistry.intent(argument, session: services.session) {
                await services.runner.run(intent)
            }
        case "reveal":
            if let argument, let intent = DemoHookRegistry.reveal(argument) {
                await services.runner.reveal(intent)
            }
        default:
            services.router.present(.demoModule(name: name, argument: argument))
        }
    }
}

/// Foundation sample intents, demo only, so the gates can be shown before any
/// module exists: `confirm:sample.t2|t3|t4|plan|bulk|rotate|filed` and
/// `reveal:sample.reveal`. They talk to no server; the fleet names are invented.
enum FoundationDemoIntents: DemoHooks {
    private static let node = ObjectRef(kind: "node", id: "n-edge-tyo-3", name: "edge-tyo-3")

    static func demoIntent(_ id: String, session: SessionStore) -> WriteIntent? {
        guard session.isDemo else { return nil }
        switch id {
        case "sample.t2":
            return WriteIntent(
                tier: .t2, verb: "Enable", object: node, scopes: ["node:admin"],
                consequence: "edge-tyo-3 can authenticate again and receives plans and tasks.",
                changes: [.nodes], perform: { _, _ in .done("Enabled edge-tyo-3") }
            )
        case "sample.t3":
            let enable: WriteIntent? = demoIntent("sample.t2", session: session)
            let inverse: (@Sendable () -> WriteIntent)? = enable.map { intent in { @Sendable in intent } }
            return WriteIntent(
                tier: .t3, verb: "Disable", object: node, scopes: ["node:admin"],
                consequence: "edge-tyo-3 can no longer authenticate: it stops reporting and receives no plans or tasks. Services on it keep running.",
                affected: [node],
                inverse: inverse,
                idempotent: true, changes: [.nodes],
                perform: { _, _ in
                    try await Task.sleep(for: .milliseconds(300))
                    return .done("Disabled edge-tyo-3")
                }
            )
        case "sample.t4":
            return WriteIntent(
                tier: .t4, verb: "Delete node", object: node, scopes: ["node:admin"],
                consequence: "Removes edge-tyo-3 and everything below from the control plane. This cannot be undone.",
                affected: [node], confirmPhrase: "edge-tyo-3",
                dryRun: { _ in
                    try await Task.sleep(for: .milliseconds(300))
                    return DryRunReport(lines: [
                        DetailLine(label: "Managed lines", value: "2", group: "Services"),
                        DetailLine(label: "DNS deployments", value: "1", group: "Services"),
                        DetailLine(label: "Monitors", value: "6", group: "Configuration"),
                        DetailLine(label: "Group memberships", value: "3", group: "Configuration"),
                        DetailLine(label: "Tasks", value: "41", group: "History"),
                        DetailLine(label: "Metrics", value: "8 days", group: "History"),
                    ], fingerprint: "2-1-6-3-41-8")
                },
                changes: [.nodes],
                perform: { _, _ in .done("Deleted node edge-tyo-3") }
            )
        case "sample.plan":
            return WriteIntent(
                tier: .plan, verb: "Plan beacon for", object: node, scopes: ["monitor:admin", "node:admin", "network:plan"],
                consequence: "Files a beacon plan for edge-tyo-3. Nothing changes until the plan is approved.",
                affected: [node],
                toggles: [ConfirmToggle(id: "accept_findings", label: "Accept findings", consequence: "File the plan even though the server flagged the problems above.", revealedByConflict: true)],
                changes: [.approvals],
                perform: { _, choices in
                    try await Task.sleep(for: .milliseconds(300))
                    guard choices.isAccepted("accept_findings") else {
                        throw LatticeAPIError.conflict(code: "conflict", message: "plan blocked by lint findings", findings: [
                            "Port 7443 is already bound by another service on edge-tyo-3.",
                            "The NetGuard zone for edge-tyo-3 does not admit beacon traffic yet.",
                        ])
                    }
                    return .filed(approvalIDs: ["apr-demo-0101"], refused: [], notes: [])
                }
            )
        case "sample.bulk":
            let nodes = ["edge-tyo-3", "edge-sgp-1", "relay-fra-2"].map { (name: String) in ObjectRef(kind: "node", id: "n-\(name)", name: name) }
            return WriteIntent(
                tier: .t3, verb: "Disable", object: ObjectRef(kind: "nodes", id: "bulk", name: "3 nodes"), scopes: ["node:admin"],
                consequence: "These nodes can no longer authenticate. Services on them keep running.",
                affected: nodes, changes: [.nodes],
                perform: { _, _ in
                    .partial(succeeded: Array(nodes.prefix(2)), failed: [ObjectFailure(object: nodes[2], reason: "Not found")], message: "2 disabled, 1 not done")
                }
            )
        case "sample.rotate":
            return WriteIntent(
                tier: .t3, verb: "Rotate token for", object: node, scopes: ["node:admin"],
                consequence: "edge-tyo-3 stops reporting and receives no plans until the new token is installed on the host. You cannot do that from this iPhone.",
                affected: [node], changes: [.nodes],
                perform: { _, _ in
                    .done("Rotated the token for edge-tyo-3", secret: RevealedSecret(title: "New node token for edge-tyo-3", value: "lat_demo_node_7f3a.notasecret", followUp: .init(title: "Reconfigure on web", path: .node(id: "n-edge-tyo-3", view: .settings))))
                }
            )
        default:
            return nil
        }
    }

    static func demoReveal(_ id: String) -> RevealIntent? {
        guard id == "sample.reveal" else { return nil }
        return RevealIntent(purpose: .knockSequence, object: node, scopes: ["sshguard:read", "network:plan"]) { _, _ in
            RevealedSecret(title: "Knock sequence for edge-tyo-3", value: "demo-knock-7000-8000-9000")
        }
    }
}
