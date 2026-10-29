import SwiftUI

/// M4 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M4 may add cases but must not rename or remove these.
enum ActivityRoute: Hashable, Codable, Sendable {
    case task(id: String)
    case taskNode(taskID: String, nodeID: String)
    case auditEvent(id: String)
    case trace(correlationID: String)
}

/// M4's demo hooks for `-AstraPresent` (section 9.2), over the Shared
/// invented tasks:
/// `confirm:activity.cancel:<task>`, `confirm:activity.rerun:<task>`,
/// `confirm:activity.rerunNode:<task>:<node name>`,
/// `confirm:activity.rerunFailed:<task>`, `confirm:activity.delete:<task>`,
/// `reveal:activity.script:<task>` and the sheet `auditVerify`.
/// The default demo token is the Operator preset, which holds no task:run,
/// so the write hooks show the runner's "Needs task:run" refusal; with
/// `-AstraDemoScenario root-token` they open their confirmation. The reveal
/// runs on the demo session.
extension ActivityRoute: DemoHooks {
    static func demoIntent(_ id: String, session: SessionStore) -> WriteIntent? {
        guard session.isDemo, id.hasPrefix("activity.") else { return nil }
        let parts = id.dropFirst("activity.".count).split(separator: ":").map(String.init)
        guard parts.count >= 2, let task = demoTask(parts[1]) else { return nil }
        let names = Dictionary(task.targets.map { ($0, DemoWorld.node(id: $0)?.name ?? $0) }, uniquingKeysWith: { a, _ in a })
        switch parts[0] {
        case "cancel": return TasksIntents.cancel(task)
        case "rerun": return TasksIntents.rerun(task, nodeNames: names)
        case "delete": return TasksIntents.delete(task)
        case "rerunNode":
            guard parts.count >= 3, let node = DemoWorld.nodes.first(where: { $0.name == parts[2] || $0.id == parts[2] }) else { return nil }
            return TasksIntents.rerunNode(task, nodeID: node.id, nodeName: node.name)
        case "rerunFailed":
            let failed = SharedFixtures.tasks.first { $0.id == task.id }?.outcomes.filter { $0.value.status == "failed" }.keys.sorted() ?? []
            return TasksIntents.rerunFailed(task, nodes: failed.map { ObjectRef(kind: "node", id: $0, name: names[$0] ?? $0) })
        default: return nil
        }
    }

    static func demoReveal(_ id: String) -> RevealIntent? {
        let prefix = "activity.script:"
        guard id.hasPrefix(prefix), let task = demoTask(String(id.dropFirst(prefix.count))) else { return nil }
        return TasksIntents.revealScript(task)
    }

    static func demoSheet(_ name: String, argument: String?) -> AnyView? {
        name == "auditVerify" ? AnyView(AuditVerifySheet()) : nil
    }

    /// The Shared demo task with that id, decoded the way the server sends it.
    private static func demoTask(_ id: String) -> LatticeTask? {
        guard let task = SharedFixtures.tasks.first(where: { $0.id == id }) else { return nil }
        let json = DemoClock().substitute(SharedFixtures.taskJSON(task).text)
        return try? JSONDecoder().decode(LatticeTask.self, from: Data(json.utf8))
    }
}
