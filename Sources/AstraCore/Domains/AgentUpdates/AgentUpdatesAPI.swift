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

    public static func planOne(_ node: ObjectRef, force: Bool = false) -> WriteIntent {
        WriteIntent(
            tier: .plan,
            verb: force ? "Force agent update for" : "Plan agent update for",
            object: node,
            scopes: scopes,
            consequence: force
                ? "Files an agent update plan for \(node.name) even though it already runs the target. Nothing changes until the plan is approved."
                : "Files an agent update plan for \(node.name). Nothing changes until the plan is approved.",
            affected: [node],
            changes: [.approvals, .agentUpdates],
            perform: { client, _ in
                let approval = try await client.planAgentUpdate(nodeID: node.id, force: force)
                return .filed(approvalIDs: [approval.id], refused: [], notes: ["Filed an agent update plan for \(node.name)"])
            }
        )
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
    public static func planSequentially(_ nodes: [ObjectRef], client: LatticeClient) async -> WriteOutcome {
        var filed: [String] = []
        var refused: [ObjectFailure] = []
        for node in nodes {
            do {
                let approval = try await client.planAgentUpdate(nodeID: node.id, force: false)
                if !filed.contains(approval.id) { filed.append(approval.id) }
            } catch {
                refused.append(ObjectFailure(object: node, reason: LatticeAPIError(error).localizedDescription))
            }
        }
        if filed.isEmpty {
            let reasons = refused.map { "\($0.object.name): \($0.reason)" }.joined(separator: "\n")
            return .refused(.validation(reasons), refused.count == 1 ? "Not filed. \(reasons)" : "No plan was filed.\n\(reasons)")
        }
        return .filed(approvalIDs: filed, refused: refused, notes: [])
    }
}
