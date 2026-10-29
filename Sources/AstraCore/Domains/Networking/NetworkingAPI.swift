import Foundation

private struct PoliciesEnvelope: Decodable { var policies: [NetPolicy] }

public extension LatticeClient {
    /// `GET /api/netpolicy` → `{"policies":[...]}`.
    func listNetPolicies() async throws -> [NetPolicy] {
        let data = try await performData(path: "/api/netpolicy")
        let envelope = try JSONDecoder().decode(PoliciesEnvelope.self, from: data)
        return envelope.policies
    }

    /// `GET /api/netpolicy/graph` → `{nodes,edges,externals}`.
    func netPolicyGraph() async throws -> NetGraph {
        try await perform(NetGraph.self, path: "/api/netpolicy/graph")
    }

    /// `GET /api/tunnels` → bare array.
    func listTunnels() async throws -> [TunnelProfile] {
        try await perform([TunnelProfile].self, path: "/api/tunnels")
    }
}
