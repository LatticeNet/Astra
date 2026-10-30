import Foundation

// M7 owns GET nodes/agent-updates, nodes/agent-updates/releases,
// nodes/agent-updates/artifacts and nodes/agent-updates/mirrors. Plan filing
// (`planAgentUpdate`) is Shared.

public extension LatticeClient {
    /// `GET /api/nodes/agent-updates`: every policy on a node this caller may read.
    func agentUpdatesPolicies() async throws -> [AgentUpdatesPolicy] {
        try await perform(AgentUpdatesPolicyList.self, path: "/api/nodes/agent-updates").policies
    }

    /// `GET /api/nodes/agent-updates/releases`. The server asks the release
    /// host; 502 when it cannot.
    func agentUpdatesReleaseInfo() async throws -> AgentUpdatesReleaseInfo {
        try await perform(AgentUpdatesReleaseInfo.self, path: "/api/nodes/agent-updates/releases")
    }

    /// `GET /api/nodes/agent-updates/artifacts`: the binaries the control plane stores.
    func agentUpdatesArtifacts() async throws -> AgentUpdatesArtifactListing {
        try await perform(AgentUpdatesArtifactListing.self, path: "/api/nodes/agent-updates/artifacts")
    }

    /// `GET /api/nodes/agent-updates/mirrors`: the registry, each readable
    /// node's source order, open plans and mirror health.
    func agentUpdatesMirrors() async throws -> AgentUpdatesMirrorsView {
        try await perform(AgentUpdatesMirrorsView.self, path: "/api/nodes/agent-updates/mirrors")
    }
}

/// The plan intents of the Agent Updates screen. "Plan all behind" is one
/// intent whose `perform` posts each node in turn and returns the filed
/// approvals with the refused half (section 8.3).
public enum AgentUpdatesPlanning {
    public static let scopes = ["node:admin", "network:plan"]
    public static let plugin = "agentupdate"

    /// `running` and `target` are what the row shows; with `force` they say
    /// what the forced plan does, since force skips the server's downgrade,
    /// syntax and already-current checks.
    public static func planOne(_ node: ObjectRef, force: Bool = false, running: String = "", target: String? = nil) -> WriteIntent {
        let downgrade = force && isDowngrade(running: running, target: target)
        return WriteIntent(
            tier: .plan,
            verb: downgrade ? "Plan agent downgrade for" : (force ? "Force agent update for" : "Plan agent update for"),
            object: node,
            scopes: scopes,
            consequence: (force ? forceConsequence(name: node.name, running: running, target: target) : "Files an agent update plan for \(node.name).")
                + " Nothing changes until the plan is approved.",
            affected: [node],
            changes: [.approvals, .agentUpdates],
            perform: { client, _ in
                let approval = try await client.planAgentUpdate(nodeID: node.id, force: force)
                return .filed(approvalIDs: [approval.id], refused: [], notes: ["Filed an agent update plan for \(node.name)"])
            }
        )
    }

    /// True when a forced plan on this row would file a downgrade.
    public static func isForcedDowngrade(running: String, target: String?) -> Bool {
        isDowngrade(running: running, target: target)
    }

    static func isDowngrade(running: String, target: String?) -> Bool {
        let from = AgentUpdatesVersion.normalize(running)
        let to = AgentUpdatesVersion.normalize(target)
        return !from.isEmpty && !to.isEmpty && AgentUpdatesVersion.compare(from, to) > 0
    }

    /// The forced plan in the row's own versions.
    public static func forceConsequence(name: String, running: String, target: String?) -> String {
        let from = AgentUpdatesVersion.normalize(running)
        let to = AgentUpdatesVersion.normalize(target)
        if to.isEmpty {
            return "Files a forced agent update plan for \(name). The server takes the target from the policy and skips its version checks."
        }
        if from.isEmpty {
            return "\(name) has not reported its version, so it cannot be compared. The forced plan installs \(to) anyway."
        }
        switch AgentUpdatesVersion.compare(from, to) {
        case 1...:
            return "Files a downgrade of \(name) from \(from) to \(to). The server refuses this without force."
        case 0:
            return "Files a plan that reinstalls \(to) on \(name), the version it already runs."
        default:
            return "Files a forced plan from \(from) to \(to) on \(name), skipping the server's version checks."
        }
    }

    public static func planAllBehind(_ nodes: [ObjectRef]) -> WriteIntent {
        let count = nodes.count
        return WriteIntent(
            tier: .plan,
            verb: "Plan agent updates for",
            object: ObjectRef(kind: "nodes", id: "behind", name: count == 1 ? "1 node behind" : "\(count) nodes behind"),
            scopes: scopes,
            consequence: "Files one agent update plan per node, one after another. The server decides per node; a node it refuses is listed and the rest are still filed. Nothing changes until the plans are approved.",
            affected: nodes,
            changes: [.approvals, .agentUpdates],
            perform: { client, _ in
                await planSequentially(nodes, client: client)
            }
        )
    }

    /// Posts `{node_id, force: false}` for each node, never two at once.
    ///
    /// Only an answer from the server is a refusal. A node whose answer was
    /// lost after sending may have a plan filed (section 6.7), so its pending
    /// agent update plans are read back: one found is filed, none found or an
    /// unreadable list is "could not confirm", and nothing is retried.
    public static func planSequentially(_ nodes: [ObjectRef], client: LatticeClient) async -> WriteOutcome {
        var filed: [String] = []
        var filedNodes: [ObjectRef] = []
        var refused: [ObjectFailure] = []
        var lost: [ObjectRef] = []
        for node in nodes {
            do {
                let approval = try await client.planAgentUpdate(nodeID: node.id, force: false)
                if !filed.contains(approval.id) { filed.append(approval.id) }
                filedNodes.append(node)
            } catch {
                let api = LatticeAPIError(error)
                if WriteFlow.mayHaveLanded(api) {
                    lost.append(node)
                } else {
                    refused.append(ObjectFailure(object: node, reason: api.localizedDescription))
                }
            }
        }
        // An unconfirmed node travels with the refusals, so the Result step
        // names it and the run never reads as a clean success (6.5).
        var unconfirmed: [ObjectFailure] = []
        for node in lost {
            let pending = try? await client.listApprovals(status: "pending", nodeID: node.id, plugin: plugin, limit: 5)
            if let found = pending?.first(where: { $0.nodeID == node.id }) {
                if !filed.contains(found.id) { filed.append(found.id) }
                filedNodes.append(node)
            } else if pending == nil {
                unconfirmed.append(ObjectFailure(object: node, reason: "Could not confirm, and its approvals could not be read. Check them before planning it again."))
            } else {
                unconfirmed.append(ObjectFailure(object: node, reason: "Could not confirm: the answer was lost and no pending plan was found. Check its approvals before planning it again."))
            }
        }
        if filed.isEmpty {
            let reasons = (unconfirmed + refused).map { "\($0.object.name): \($0.reason)" }
            if !unconfirmed.isEmpty {
                return .unknown(reasons.joined(separator: "\n"))
            }
            let joined = reasons.joined(separator: "\n")
            return .refused(.validation(joined), refused.count == 1 ? "Not filed. \(joined)" : "No plan was filed.\n\(joined)")
        }
        var summary = filed.count == 1 ? "1 plan filed" : "\(filed.count) plans filed"
        if !refused.isEmpty { summary += ", \(refused.count) refused" }
        if !unconfirmed.isEmpty { summary += ", \(unconfirmed.count) not confirmed" }
        let names = filedNodes.map(\.name).joined(separator: ", ")
        return .filed(approvalIDs: filed, refused: refused + unconfirmed, notes: [summary, "Filed for \(names)."])
    }
}
