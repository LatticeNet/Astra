import SwiftUI

/// M12 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M12 may add cases but must not rename or remove these.
enum TerminalRoute: Hashable, Codable, Sendable {
    case sessions(nodeID: String?)
    case transcript(sessionID: String)
}

/// M12's demo hooks for `-AstraPresent`: `confirm:terminal.close:<sessionID>`
/// with a demo session id (`term_demo_7f3k2a` on edge-tyo-1) opens the T2
/// dialog, and nothing is sent until it is confirmed; `terminalSessions[:<node>]`
/// pushes the session list, which no link reaches, onto the selected tab
/// (pair it with `-AstraTab browse`; `<node>` is a demo node name).
extension TerminalRoute: DemoHooks {
    static func demoIntent(_ id: String, session: SessionStore) -> WriteIntent? {
        guard session.isDemo, id.hasPrefix("terminal.close:") else { return nil }
        let sessionID = String(id.dropFirst("terminal.close:".count))
        guard let fixture = TerminalFixtures.session(sessionID) else { return nil }
        let record = TerminalSession(id: fixture.id, nodeID: fixture.nodeID, actorID: DemoWorld.actorID, shell: fixture.shell, status: fixture.status)
        return TerminalIntents.close(record, nodeName: fixture.node)
    }

    static func demoSheet(_ name: String, argument: String?) -> AnyView? {
        guard name == "terminalSessions" else { return nil }
        let nodeID = argument.flatMap { $0.isEmpty ? nil : DemoWorld.node($0).id }
        return AnyView(TerminalDemoPusher(route: .sessions(nodeID: nodeID)))
    }
}

/// Pushes a page with no app link, then gets out of the way (demo only).
private struct TerminalDemoPusher: View {
    let route: TerminalRoute
    @Environment(Router.self) private var router

    var body: some View {
        Color.clear.task {
            router.dismissPresented { router.push(.terminal(route)) }
        }
    }
}
