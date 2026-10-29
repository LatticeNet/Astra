import Foundation

/// Every Tasks write and reveal, at the tier the parity matrix gives it
/// (section 3.2): cancel T2, rerun and rerun one node T3, delete T4, and
/// reveal script S. Each runs through `ActionRunner`; none is ever sent
/// from a deep link, a launch or a poll.
public enum TasksIntents {
    public static let runScope = "task:run"
    public static let readScope = "task:read"

    /// What a rerun says before it runs (the console's rerun confirm).
    static let rerunConsequence = "This runs now. No approval is filed: each node runs the script again as soon as its agent picks it up, and the script can change those hosts."

    public static func object(_ task: LatticeTask) -> ObjectRef {
        ObjectRef(kind: "task", id: task.id, name: task.id)
    }

    /// T2. Stops pending work; a node that already has the script is not stopped.
    public static func cancel(_ task: LatticeTask) -> WriteIntent {
        let object = object(task)
        return WriteIntent(
            tier: .t2, verb: "Cancel task", object: object, scopes: [runScope],
            consequence: "It will not be handed to any agent, and a result that arrives late is refused. A run already under way on a node is not stopped.",
            verify: { client in
                guard let fresh = try await client.tasksFind(id: task.id) else { return "\(task.id) is no longer listed." }
                return "\(task.id) is now \(TaskRunState(serverValue: fresh.status).tasksWord)."
            },
            idempotent: false, changes: [.tasks, .audit],
            perform: { client, _ in
                let updated = try await client.cancelTask(id: task.id)
                return .done("Cancelled \(task.id): \(TaskRunState(serverValue: updated.status).tasksWord)")
            }
        )
    }

    /// T3. A fresh task on every target, from the stored script.
    public static func rerun(_ task: LatticeTask, nodeNames: [String: String] = [:]) -> WriteIntent {
        let targets = task.targets.map { ObjectRef(kind: "node", id: $0, name: nodeNames[$0] ?? $0) }
        let count = targets.count == 1 ? "1 node" : "\(targets.count) nodes"
        return WriteIntent(
            tier: .t3, verb: "Rerun", object: object(task), scopes: [runScope],
            consequence: "Runs the same script again on \(count). \(rerunConsequence)",
            affected: targets, idempotent: false, changes: [.tasks, .audit],
            perform: { client, _ in
                let fresh = try await client.tasksRerun(id: task.id)
                return .done("Queued \(fresh.id) on \(count)")
            }
        )
    }

    /// T3. A fresh task on one target (swipe on a node row).
    public static func rerunNode(_ task: LatticeTask, nodeID: String, nodeName: String) -> WriteIntent {
        let node = ObjectRef(kind: "node", id: nodeID, name: nodeName)
        return WriteIntent(
            tier: .t3, verb: "Rerun on", object: node, scopes: [runScope],
            consequence: "Runs the script of \(task.id) again on \(nodeName). \(rerunConsequence)",
            affected: [node], idempotent: false, changes: [.tasks, .audit],
            perform: { client, _ in
                let fresh = try await client.tasksRerunNode(id: task.id, nodeID: nodeID)
                return .done("Queued \(fresh.id) on \(nodeName)")
            }
        )
    }

    /// T3. Sequential `rerun-node` calls, one per failed node, each its own
    /// task run; per-node outcomes, and a node whose answer was lost is
    /// reported as unconfirmed, never retried.
    public static func rerunFailed(_ task: LatticeTask, nodes: [ObjectRef]) -> WriteIntent {
        let count = nodes.count == 1 ? "1 failed node" : "\(nodes.count) failed nodes"
        return WriteIntent(
            tier: .t3, verb: "Rerun", object: ObjectRef(kind: "nodes", id: "\(task.id).failed", name: count), scopes: [runScope],
            consequence: "Each node becomes a separate task run. \(rerunConsequence)",
            affected: nodes, idempotent: false, changes: [.tasks, .audit],
            perform: { client, _ in
                await sequentialReruns(task, nodes: nodes, client: client)
            }
        )
    }

    static func sequentialReruns(_ task: LatticeTask, nodes: [ObjectRef], client: LatticeClient) async -> WriteOutcome {
        var succeeded: [ObjectRef] = []
        var failed: [ObjectFailure] = []
        for node in nodes {
            do {
                _ = try await client.tasksRerunNode(id: task.id, nodeID: node.id)
                succeeded.append(node)
            } catch {
                let api = LatticeAPIError(error)
                let reason = WriteFlow.answerLostAfterSending(api)
                    ? "Could not confirm: check the task list before trying again"
                    : api.localizedDescription
                failed.append(ObjectFailure(object: node, reason: reason))
            }
        }
        if failed.isEmpty {
            return .done(succeeded.count == 1 ? "Queued a rerun on \(succeeded[0].name)" : "Queued \(succeeded.count) reruns")
        }
        if succeeded.isEmpty, failed.count == 1 {
            return .refused(.validation(failed[0].reason), "Not queued on \(failed[0].object.name): \(failed[0].reason)")
        }
        return .partial(succeeded: succeeded, failed: failed, message: "\(succeeded.count) queued, \(failed.count) not queued")
    }

    /// T4. Irreversible: the task and every result it reported.
    public static func delete(_ task: LatticeTask) -> WriteIntent {
        WriteIntent(
            tier: .t4, verb: "Delete task", object: object(task), scopes: [runScope],
            consequence: "The results every target reported are deleted with it. A run already under way on a node is not stopped. The audit log keeps a task.delete event.",
            verify: { client in
                try await client.tasksFind(id: task.id) == nil ? "\(task.id) is deleted." : "\(task.id) is still listed."
            },
            idempotent: false, changes: [.tasks, .audit],
            perform: { client, _ in
                try await client.tasksDelete(id: task.id)
                return .done("Deleted \(task.id)")
            }
        )
    }

    /// S. The script body, behind a step-up on the session client.
    public static func revealScript(_ task: LatticeTask) -> RevealIntent {
        RevealIntent(purpose: .taskScript, object: object(task), scopes: [readScope]) { client, grant in
            let reveal = try await client.tasksRevealScript(id: task.id, grant: grant)
            return RevealedSecret(title: "Script of \(task.id)", value: reveal.script)
        }
    }
}

public extension TaskRunState {
    /// The vocabulary word (section 4.2).
    var tasksWord: String {
        switch self {
        case .pending: "pending"
        case .queued: "queued"
        case .leased: "running"
        case .finished: "finished"
        case .failed: "failed"
        case .stalled: "stalled"
        case .expired: "expired"
        case .cancelled: "cancelled"
        }
    }
}
