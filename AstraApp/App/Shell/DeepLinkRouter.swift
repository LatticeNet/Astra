import SwiftUI
import UIKit

/// Applies `lattice://` links and same-origin console links (section 2.5).
///
/// Rules: select the owning tab and reset that tab's path to the route (or
/// present Review for approvals), leave other tabs alone; hold a link until
/// the shell has restored its scene state and while the welcome flow is up;
/// queue it while a write or decision is in flight.
/// A link to an object the token cannot read still opens the screen, which
/// shows its missing-scope state.
@MainActor @Observable
final class DeepLinkRouter {
    private let appState: AppState
    private let router: Router
    private let runner: ActionRunner
    private let session: SessionStore
    /// A link that arrived before the shell restored or the app was connected.
    private(set) var held: LatticeDeepLink?

    init(appState: AppState, router: Router, runner: ActionRunner, session: SessionStore) {
        self.appState = appState
        self.router = router
        self.runner = runner
        self.session = session
    }

    /// Handles a URL from `onOpenURL`, a pasted link or a launch argument.
    /// Foreign HTTPS hosts and unmapped console routes open in the browser.
    func handle(_ url: URL) {
        guard let link = LatticeDeepLink(url: url, console: session.consoleURL) else {
            if url.scheme == "https" || url.scheme == "http" { UIApplication.shared.open(url) }
            return
        }
        handle(link)
    }

    func handle(_ link: LatticeDeepLink) {
        guard appState.shellRestored, session.isConnected, !appState.welcomePresented else {
            held = link
            return
        }
        runner.whenIdle { [weak self] in self?.apply(link) }
    }

    /// Applies the link held before restoration or during the welcome flow.
    func releaseHeld() {
        guard let link = held else { return }
        held = nil
        handle(link)
    }

    private func apply(_ link: LatticeDeepLink) {
        switch link {
        case .inbox:
            show(.inbox, [])
        case .approval(let id):
            router.present(.review(.single(id)))
        case .node(let id, let view):
            show(.fleet, [.fleet(.node(id: id, tab: view ?? .overview))])
        case .monitor(let id), .check(let id):
            show(.monitor, [.monitoring(.check(id: id))])
        case .definition(let id):
            show(.monitor, [.monitoring(.definition(id: id))])
        case .path(let key):
            show(.monitor, [.monitoring(.path(key: key))])
        case .incident(let id):
            show(.monitor, [.monitoring(.incident(id: id))])
        case .maintenanceWindow(let id):
            show(.monitor, [.monitoring(.maintenanceWindow(id: id))])
        case .task(let id):
            show(.activity, [.activity(.task(id: id))])
        case .taskNode(let taskID, let nodeID):
            show(.activity, [.activity(.task(id: taskID)), .activity(.taskNode(taskID: taskID, nodeID: nodeID))])
        case .auditEvent(let id):
            show(.activity, [.activity(.auditEvent(id: id))])
        case .trace(let id):
            show(.activity, [.activity(.trace(correlationID: id))])
        case .machine(let id):
            appState.fleetScope = .machines
            show(.fleet, [.inventory(.machine(id: id))])
        case .upcoming:
            appState.fleetScope = .machines
            show(.fleet, [.inventory(.upcoming)])
        case .group(let id):
            show(.fleet, [.fleet(.group(id: id))])
        case .policy(let id):
            show(.browse, [.networking(.policy(id: id))])
        case .dnsDeployment(let id):
            show(.browse, [.networking(.dnsDeployment(id: id))])
        case .ddnsProfile(let id):
            show(.browse, [.networking(.ddnsProfile(id: id))])
        case .geoRoute(let id):
            show(.browse, [.networking(.geoRoute(id: id))])
        case .tunnel(let id):
            show(.browse, [.networking(.tunnel(id: id))])
        case .sshGuardNode(let nodeID):
            show(.browse, [.sshGuard(.node(id: nodeID))])
        case .agentUpdateNode(let nodeID):
            show(.browse, [.sshGuard(.agentUpdates(view: "nodes", nodeID: nodeID))])
        case .plugin(let id):
            show(.browse, [.platform(.plugin(id: id))])
        case .share(let id):
            show(.browse, [.platform(.share(id: id))])
        case .notifyChannel(let id):
            show(.browse, [.notify(.channel(id: id))])
        case .notifyDelivery(let id):
            appState.activityScope = .sent
            show(.activity, [.notify(.delivery(id: id))])
        case .webhook(let id):
            show(.browse, [.notify(.webhook(id: id))])
        case .token(let id):
            router.openSettings([.account(.access(view: "tokens")), .account(.token(id: id))])
        case .user(let id):
            router.openSettings([.account(.access(view: "users")), .account(.user(id: id))])
        case .terminalSession(let id):
            show(.browse, [.terminal(.transcript(sessionID: id))])
        case .vpnUser(let id):
            show(.browse, [.vpn(.user(id: id))])
        case .connection(let id):
            show(.browse, [.evidence(.connection(id: id))])
        case .settingsConnection:
            router.openSettings([.page(.connection)])
        case .fleet(let scope, let query):
            router.select(tab: .fleet, scope: scope?.rawValue, query: query)
            dismissAndReset(.fleet)
        case .monitoring(let segment, let view, let query):
            appState.monitorView = view
            router.select(tab: .monitor, scope: segment?.rawValue, query: query)
            dismissAndReset(.monitor)
        case .activity(let scope, let view, let query):
            appState.approvalsView = view
            router.select(tab: .activity, scope: scope?.rawValue, query: query)
            dismissAndReset(.activity)
        }
    }

    private func show(_ tab: AppTab, _ path: [AppRoute]) {
        router.dismissPresented { [appState] in
            appState.selectedTab = tab
            appState.paths[tab] = path
        }
    }

    private func dismissAndReset(_ tab: AppTab) {
        router.dismissPresented { [appState] in appState.paths[tab] = [] }
    }
}
