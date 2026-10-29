import SwiftUI

/// M7 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M7 may add cases but must not rename or remove these.
enum SSHGuardRoute: Hashable, Codable, Sendable {
    case board(posture: String?, coverage: String?)
    case node(id: String)
    case agentUpdates(view: String?, nodeID: String?)
    case agentRelease(id: String)
}

/// M7's demo intents, reveals and sheets for `-AstraPresent`:
/// `confirm:sshguard.<action>:<node name or id>` with action arm, confirm or
/// exclude; `confirm:agent.planAll`, `confirm:agent.plan:<node>`;
/// `reveal:sshguard.knock:<node>`; and the sheets `sshguardArm:<node id>`,
/// `sshguardRotate:<node id>` and `sshguardPush:<screen>` (board,
/// board:<posture>:<coverage>, agent:<view>, release:<version>).
extension SSHGuardRoute: DemoHooks {
    private static func demoNode(_ argument: String) -> ObjectRef? {
        let world = DemoWorld.node(id: argument) ?? DemoWorld.nodes.first { $0.name == argument }
        return world.map { ObjectRef(kind: "node", id: $0.id, name: $0.name) }
    }

    static func demoIntent(_ id: String, session: SessionStore) -> WriteIntent? {
        guard session.isDemo else { return nil }
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "sshguard.arm":
            return demoNode(argument).map { SSHGuardIntents.arm($0, form: SSHGuardRotation.Form(nodeID: $0.id, outOfBandFallback: true)) }
        case "sshguard.confirm":
            return demoNode(argument).map { SSHGuardIntents.confirm($0, deadline: nil) }
        case "sshguard.exclude":
            return demoNode(argument).map { SSHGuardIntents.exclude($0) }
        case "agent.plan":
            return demoNode(argument).map { AgentUpdatesPlanning.planOne($0) }
        case "agent.planAll":
            let behind = ["edge-sin-1", "edge-sin-2", "edge-ams-1", "edge-lon-1", "lab-pi-2"].compactMap(demoNode)
            return AgentUpdatesPlanning.planAllBehind(behind)
        default:
            return nil
        }
    }

    static func demoReveal(_ id: String) -> RevealIntent? {
        guard id.hasPrefix("sshguard.knock:"), let node = demoNode(String(id.dropFirst("sshguard.knock:".count))) else { return nil }
        return SSHGuardIntents.knockReveal(node)
    }

    static func demoSheet(_ name: String, argument: String?) -> AnyView? {
        switch name {
        case "sshguardArm":
            return argument.map { AnyView(SSHGuardArmSheet(nodeID: $0)) }
        case "sshguardRotate":
            return argument.map { AnyView(SSHGuardArmSheet(nodeID: $0, rotate: true)) }
        case "sshguardPush":
            guard let route = argument.flatMap(demoRoute) else { return nil }
            return AnyView(SSHGuardDemoPusher(route: route))
        default:
            return nil
        }
    }

    private static func demoRoute(_ argument: String) -> SSHGuardRoute? {
        let parts = argument.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts[0] {
        case "board":
            return .board(posture: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil, coverage: parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil)
        case "agent":
            return .agentUpdates(view: parts.count > 1 ? parts[1] : nil, nodeID: parts.count > 2 ? parts[2] : nil)
        case "release":
            return parts.count > 1 ? .agentRelease(id: parts[1]) : nil
        case "node":
            return parts.count > 1 ? .node(id: parts[1]) : nil
        default:
            return nil
        }
    }
}

/// Closes the demo sheet it was presented in and pushes its route instead.
private struct SSHGuardDemoPusher: View {
    let route: SSHGuardRoute
    @Environment(Router.self) private var router

    var body: some View {
        Color.clear.task {
            router.dismissPresented { router.push(.sshGuard(route)) }
        }
    }
}
