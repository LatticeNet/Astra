import Foundation
import AstraCore

public func checkNetworking() async throws {
    try await checkPoliciesGraphAndTunnels()
}

private func checkPoliciesGraphAndTunnels() async throws {
    let transport = MockTransport(responses: [
        "https://lattice.example.com/api/netpolicy": (
            200,
            """
            {"policies":[
              {"id":"node-a","target_node_id":"node-a","target_node_name":"Edge","enabled":true,
               "rules":[{"id":"r1","action":"allow","direction":"egress","protocol":"tcp","ports":[443],
                         "remote":{"kind":"cidr","cidr":"10.0.0.0/8"},"comment":"https"},
                        {"id":"r2","action":"deny","direction":"ingress","protocol":"any",
                         "remote":{"kind":"any"},"disabled":true}],
               "last_plan_sha":"abc","updated_at":"2026-06-17T02:00:00Z"}
            ]}
            """.data(using: .utf8)!
        ),
        "https://lattice.example.com/api/netpolicy/graph": (
            200,
            """
            {"nodes":[{"id":"node-a","name":"Edge","online":true},{"id":"node-b","name":"Core","online":false}],
             "edges":[{"from":"node-a","to":"node-b","action":"allow","protocol":"tcp","ports":[22],"direction":"egress","rule_id":"r1"}],
             "externals":[{"target_node_id":"node-a","action":"deny","remote":"0.0.0.0/0","protocol":"any","direction":"ingress","rule_id":"r2"}]}
            """.data(using: .utf8)!
        ),
        "https://lattice.example.com/api/tunnels": (
            200,
            #"[{"id":"t1","name":"web","node_id":"node-a","tunnel_id":"cf-123","ingress":[{"hostname":"app.example.com","service":"http://localhost:8088"}],"created_at":"2026-06-17T00:00:00Z"}]"#.data(using: .utf8)!
        ),
    ])
    let client = LatticeClient(baseURL: URL(string: "https://lattice.example.com")!, credential: LatticeCredential(sessionCookie: "sid", csrfToken: "csrf-token"), transport: transport)

    let policies = try await client.listNetPolicies()
    let policy = try expectUnwrapped(policies.first, "policy decoded from envelope")
    try expectEqual(policy.targetNodeName, "Edge", "policy node name")
    try expectEqual(policy.rules.count, 2, "policy rule count")
    try expectEqual(policy.activeRules.count, 1, "policy active (non-disabled) rules")
    let rule = try expectUnwrapped(policy.rules.first, "first rule")
    try expect(rule.isAllow, "rule allow")
    try expectEqual(rule.proto, "tcp", "rule protocol via 'protocol' key")
    try expectEqual(rule.remote.displayText, "10.0.0.0/8", "rule remote cidr display")
    try expectEqual(policy.rules[1].remote.displayText, "any", "deny rule remote any")

    let graph = try await client.netPolicyGraph()
    try expectEqual(graph.nodes.count, 2, "graph nodes")
    try expectEqual(graph.edges.first?.ruleID, "r1", "graph edge rule id")
    try expectEqual(graph.externals.first?.remote, "0.0.0.0/0", "graph external remote")
    try expect(!(graph.externals.first?.isAllow ?? true), "graph external deny")

    let tunnels = try await client.listTunnels()
    try expectEqual(tunnels.first?.ingress.first?.hostname, "app.example.com", "tunnel ingress hostname")
}
