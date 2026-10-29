import Foundation
import AstraCore

public func checkNetworking() async throws {
    try await checkPoliciesGraphAndTunnels()
    try checkNetworkingEdgeDecoding()
    try await checkNetworkingDemoDecoding()
    try await checkNetworkingRequestBodies()
    try await checkNetworkingDNSFindingsLoop()
    try await checkNetworkingGroupPlan()
    try await checkNetworkingConvert()
    try await checkNetworkingWrites()
    try checkNetworkingPreviews()
    try checkNetworkingQueries()
}

private let netClock = DemoClock(pinned: "2026-10-28T12:00:00Z")!

private func netDemo(_ scenario: DemoScenario = .normal, state: DemoState = DemoState()) -> LatticeClient {
    LatticeClient(baseURL: DemoWorld.baseURL, credential: LatticeCredential(bearerToken: DemoWorld.token),
                  transport: DemoTransport(identity: .pat, scenario: scenario, clock: netClock, state: state))
}

private struct NetworkingAuthStub: WriteAuthenticator {
    var outcome: DeviceAuthOutcome
    func authenticate(reason: String) async -> DeviceAuthOutcome { outcome }
}

private func netMock(_ responses: [String: (Int, Data)]) -> (LatticeClient, MockTransport) {
    let transport = MockTransport(responses: responses)
    let client = LatticeClient(baseURL: URL(string: "https://lattice.example.com")!, credential: LatticeCredential(bearerToken: "lat_test"), transport: transport)
    return (client, transport)
}

private func netFinished(_ result: WriteFlowResult, _ message: String) throws -> WriteOutcome {
    guard case .finished(let outcome) = result else { throw CheckFailure.failed("\(message): the flow did not finish (\(result))") }
    return outcome
}

// MARK: - Ported v2 shapes

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
            #"[{"id":"t1","name":"web","node_id":"node-a","tunnel_id":"cf-123","credentials_file":"/etc/cloudflared/cf-123.json","ingress":[{"hostname":"app.example.com","service":"http://localhost:8088"}],"created_at":"2026-06-17T00:00:00Z"}]"#.data(using: .utf8)!
        ),
    ])
    let client = LatticeClient(baseURL: URL(string: "https://lattice.example.com")!, credential: LatticeCredential(sessionCookie: "sid", csrfToken: "csrf-token"), transport: transport)

    let policies = try await client.listNetPolicies()
    let policy = try expectUnwrapped(policies.first, "policy decoded from envelope")
    try expectEqual(policy.targetNodeName, "Edge", "policy node name")
    try expectEqual(policy.rules.count, 2, "policy rule count")
    try expectEqual(policy.activeRules.count, 1, "policy active (non-disabled) rules")
    try expect(!policy.groupDerived, "an absent group_derived reads manual")
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
    try expectEqual(tunnels.first?.credentialsFile, "/etc/cloudflared/cf-123.json", "tunnel credentials file")
}

// MARK: - Edge-case decoding

private func checkNetworkingEdgeDecoding() throws {
    let endpoint = try JSONDecoder().decode(NetEndpoint.self, from: json(#"{"kind":"group","group_id":"g-dns"}"#))
    try expectEqual(endpoint.displayText, "group:g-dns", "group remote display")
    try expectEqual(try JSONDecoder().decode(NetEndpoint.self, from: json(#"{"kind":"zone","zone_id":"office"}"#)).displayText, "zone:office", "zone remote display")

    let legacy = try JSONDecoder().decode(NetworkingGroupPolicy.self, from: json(#"""
    {"id":"gnp_x","scope_group_id":"g-a","rules":null,"enabled":true,"priority":5,"group_rule_count":0,"target_node_ids":["n-1"],"label":"","updated_at":"2026-10-01T00:00:00Z"}
    """#))
    try expectEqual(legacy.target.groups, ["g-a"], "a policy without target or scope reads its scope_group_id")
    try expect(legacy.rules.isEmpty, "null rules read empty")
    try expectEqual(legacy.displayName, "gnp_x", "no label and no name fall back to the id")

    let zeroTime = try JSONDecoder().decode(NetPolicy.self, from: json(#"""
    {"id":"n","target_node_id":"n","rules":[],"enabled":true,"group_derived":true,"last_plan_sha":"ab","last_applied_at":"0001-01-01T00:00:00Z","updated_at":"2026-10-01T00:00:00Z"}
    """#))
    try expect(zeroTime.lastAppliedAt == nil, "Go's zero time reads as never applied")
    try expectEqual(NetworkingPolicyState.of(zeroTime), .planned, "planned but never applied")
    try expectEqual(NetworkingNodePolicyKind.of(zeroTime), .outbound, "group_derived is the outbound kind")

    let missingID = try? JSONDecoder().decode(NetworkingDNSDeployment.self, from: json(#"{"name":"x"}"#))
    try expect(missingID == nil, "a deployment without an id does not decode")

    let plan = try JSONDecoder().decode(NetworkingGroupPlanResult.self, from: json(#"""
    {"affected":[],"conflicts":[],"orphaned":[]}
    """#))
    guard case .done(let message, _) = plan.outcome(name: { $0 }) else { throw CheckFailure.failed("an empty plan result is done") }
    try expect(message.hasPrefix("Nothing to file"), "an empty plan says nothing was filed")

    let convert = try JSONDecoder().decode(NetworkingConvertResult.self, from: json(#"""
    {"group_policy":{"id":"gnp_c","name":"core","rules":[],"enabled":false,"priority":0,"group_rule_count":0,"target":{"nodes":["n-core"]},"target_node_ids":["n-core"],"label":"core"},"approval":null}
    """#))
    try expect(convert.approval == nil, "a disabled conversion files no approval")
    try expectEqual(convert.groupPolicy.target.nodes, ["n-core"], "converted policy targets the node")

    let guardNode = try JSONDecoder().decode(NetworkingNodeGuard.self, from: json(#"""
    {"node_id":"n-1","source":"stored","binding":{"node_id":"n-1","group_ids":["sg"],"managed":true,"version":1,"last_applied_at":"0001-01-01T00:00:00Z"},"groups":[],"derived_groups":null,"zones":[]}
    """#))
    try expectEqual(guardNode.state, .pending, "a managed node never applied is pending")
    let noBinding = try? JSONDecoder().decode(NetworkingNodeGuard.self, from: json(#"{"node_id":"n-1","source":"stored"}"#))
    try expect(noBinding == nil, "a node guard view without its binding does not decode")
}

// MARK: - Demo fixtures decode, with their derivations

private func checkNetworkingDemoDecoding() async throws {
    let client = netDemo()
    let now = netClock.anchor

    let policies = try await client.listNetPolicies()
    try expectEqual(policies.count, 11, "every node document")
    let names = Dictionary(DemoWorld.nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let rows = NetworkingNodePolicyRow.rows(policies: policies, nodes: DemoWorld.nodes.map { ($0.id, $0.name) })
    try expectEqual(rows.count, DemoWorld.nodes.count, "every node is listed, with or without a document")
    try expectEqual(rows.first?.nodeName, "edge-hkg-2", "a failed apply leads")
    try expectEqual(rows.first?.state, .failed, "edge-hkg-2 failed")
    try expectEqual(rows.first(where: { $0.nodeName == "core-lon-1" })?.kind, .manual, "core-lon-1 is manual")
    try expectEqual(rows.first(where: { $0.nodeName == "edge-sin-2" })?.state, .planned, "edited after its last apply is planned")
    try expectEqual(rows.first(where: { $0.nodeName == "home-router" })?.state, .off, "disabled document is off")
    try expectEqual(rows.first(where: { $0.nodeName == "edge-iad-1" })?.kind, NetworkingNodePolicyKind.none, "no document is none")
    _ = names

    let groupPolicies = try await client.networkingGroupPolicies()
    try expectEqual(groupPolicies.count, 4, "four outbound policies")
    let fleet = try expectUnwrapped(groupPolicies.first { $0.target.all }, "fleet policy")
    try expectEqual(fleet.targetNodeIDs.count, DemoWorld.nodes.count - 2, "the fleet target leaves out the two excluded nodes")
    try expectEqual(groupPolicies.first { $0.id == "gnp_d04" }?.displayName, "build-fra-4", "an unnamed policy is labelled by its target")

    let confined = try await netDemo(.confinedToken).networkingGroupPolicies()
    try expect(confined.first { $0.id == "gnp_d04" }.map { $0.hiddenTargetNodes == 1 && $0.targetNodeIDs.isEmpty } ?? false, "a confined token is told how many target nodes it cannot see")

    let matrix = try await client.networkingMatrix(direction: "egress")
    try expectEqual(matrix.groups.count, DemoWorld.groups.count, "matrix groups")
    let matrixRows = matrix.rows
    try expectEqual(matrixRows.first?.sourceName, "Whole fleet", "the fleet row leads")
    try expectEqual(matrixRows.first?.excludedCount, 2, "fleet row counts its exclusions")
    let europe = try expectUnwrapped(matrixRows.first { $0.sourceID == "g-europe-relays" }, "europe row")
    try expectEqual(europe.reachSentence(direction: "egress"), "can reach 2 of 5 groups", "reach sentence")
    let asia = try expectUnwrapped(matrixRows.first { $0.sourceID == "g-asia-edge" }, "asia row")
    try expectEqual(asia.reachable, 0, "a deny cell does not count as reachable")
    try expectEqual(asia.externalRules, 2, "external rules counted on the row")
    let ingress = try await client.networkingMatrix(direction: "ingress")
    try expectEqual(ingress.direction, "ingress", "ingress matrix")
    try expectEqual(ingress.rows.first?.reachSentence(direction: "ingress"), "admits 1 of 5 groups", "ingress wording")

    let deployments = try await client.networkingDNSDeployments()
    try expectEqual(deployments.count, 5, "five deployments")
    let byID = Dictionary(deployments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let external = try expectUnwrapped(byID["dns_d03"], "external engine")
    try expect(external.isExternal && !external.canPlan && !external.canPublish, "external engines are never planned or published")
    try expectEqual(external.certState(now: now), .soon(days: 9), "the measured expiry judged at the check's 21 days")
    try expectEqual(external.portsToMeasure, [8443], "853 is already measured; 53 is plain DNS")
    guard case .warning(let reason) = external.health(now: now) else { throw CheckFailure.failed("drift is a warning") }
    try expect(reason.contains("systemd-resolve"), "drift finding is the reason")
    let failing = try expectUnwrapped(byID["dns_d04"], "failing deployment")
    guard case .failing = failing.health(now: now) else { throw CheckFailure.failed("a failed apply is failing") }
    try expect(byID["dns_d05"].map { !$0.canPublish } ?? false, "a disabled deployment cannot publish")
    try expect(byID["dns_d01"]?.zones.contains { $0.summary == "3 static records" } ?? false, "static zone summary")
    try expectEqual(byID["dns_d01"]?.measureBlock, "The deployment has no hostname to measure a certificate on.", "measure needs a hostname")

    let geo = try await client.networkingGeoRoutings()
    try expectEqual(geo.count, 3, "three geo routings")
    try expect(geo.first { $0.id == "geo_g02" }?.lastAppliedAt == nil, "a never-applied routing has no applied time")
    let preview = try await client.networkingPreviewGeo(id: "geo_g01")
    try expect(preview.config.contains("dns.example.org"), "preview config")
    try expectEqual(preview.sha256, PlanHasher.sha256Hex(preview.config), "preview hash is of the config")
    try expectEqual(preview.continentChoice["EU"], DemoWorld.node("relay-fra-1").id, "continent choice")

    let tunnels = try await client.listTunnels()
    try expectEqual(tunnels.count, 3, "three tunnels")

    let groups = try await client.networkingGuardGroups()
    try expect(groups.contains { $0.isLegacy && $0.nodeID == DemoWorld.node("home-router").id }, "a legacy baseline group")
    try expectEqual(groups.first { $0.id == "sg_web" }?.rules.first?.trafficText, "tcp 80, 443", "guard rule traffic text")
    let zones = try await client.networkingGuardZones()
    try expectEqual(zones.first { $0.id == "loopback" }?.summary, "lo", "zone summary")
    let guardNodes = try await client.networkingGuardNodes()
    let states = Dictionary(guardNodes.map { ($0.displayName, $0.state) }, uniquingKeysWith: { first, _ in first })
    try expectEqual(states["edge-tyo-1"], .enforced, "enforced")
    try expectEqual(states["edge-tyo-2"], .pending, "pending")
    try expectEqual(states["dns-fra-1"], .failed, "failed")
    try expectEqual(states["relay-fra-1"], .observing, "observe only")
    try expectEqual(states["home-router"], .legacy, "legacy")
    try expectEqual(guardNodes.first { $0.displayName == "dns-tyo-1" }?.derivedGroups.first?.viaNodeGroupName, "DNS nodes", "derived group names its node group")
    let bindings = try await client.networkingNodeGroupBindings()
    try expectEqual(bindings.first { $0.groupID == "g-dns" }?.activeCount, 2, "active members")
    let snapshot = NetworkingFirewallSnapshot(groups: groups, zones: zones, nodes: guardNodes, nodeGroupBindings: bindings)
    try expectEqual(snapshot.boundNodes(of: "sg_dns").count, 2, "sg_dns reaches two nodes through their node group")
    try expectEqual(snapshot.boundNodeGroups(of: "sg_web").map(\.groupID), ["g-asia-edge"], "sg_web is bound to Asia edge")

    // Global NetGuard objects refuse a confined token; its nodes stay readable.
    do {
        _ = try await netDemo(.confinedToken).networkingGuardGroups()
        throw CheckFailure.failed("a confined token cannot read security groups")
    } catch LatticeAPIError.forbidden(let code, _) {
        try expectEqual(code, "capability_denied", "confinement refusal code")
    }
    let observed233 = try await netDemo(.confinedToken).networkingGuardNodes().allSatisfy { DemoWorld.confinedNodeIDs.contains($0.nodeID) }
    try expect(observed233, "confined node list")
    do {
        _ = try await netDemo(.limitedToken).networkingDNSDeployments()
        throw CheckFailure.failed("the Triage preset holds no dns:admin")
    } catch LatticeAPIError.forbidden {}

    // Empty scenario serves an empty envelope for every list.
    let observed240 = try await netDemo(.empty).networkingDNSDeployments().isEmpty
    try expect(observed240, "empty deployments")
    let observed241 = try await netDemo(.empty).networkingGuardNodes().isEmpty
    try expect(observed241, "empty guard nodes")
}

// MARK: - Request bodies

/// Runs one call against a fresh mock answering `path` and returns the
/// method, URL and the request body with sorted keys.
private func netRequest(_ path: String, answer: String, _ call: (LatticeClient) async throws -> Void) async throws -> (method: String, url: String, body: String) {
    let url = "https://lattice.example.com\(path)"
    let (client, transport) = netMock([url: (200, json(answer))])
    try await call(client)
    let method = await transport.methods.last ?? nil
    let seen = await transport.requestURLs
    try expectEqual(seen.count, 1, "one request for \(path)")
    var body = ""
    if let data = await transport.lastBody {
        let object = try JSONSerialization.jsonObject(with: data)
        body = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    return (method ?? "", seen[0], body)
}

private func checkNetworkingRequestBodies() async throws {
    let approval = #"{"id":"approval_x","node_id":"n-1","plugin":"nftpolicy","action":"apply-ruleset","plan":"p","plan_sha256":"148de9c5a7a44d19e56cd9ae1a554bf67847afb0c58f6e12fa29ac7ddfca9940","status":"pending"}"#
    // handleTunnelPlan answers with a raw model.Approval: no plan_sha256.
    let rawApproval = #"{"id":"approval_t","node_id":"n-1","plugin":"cftunnel","action":"apply-config","plan":"p","status":"pending"}"#
    let ok = #"{"ok":true}"#
    let cases: [(String, String, String, (LatticeClient) async throws -> Void)] = [
        ("/api/netpolicy/plan", approval, #"{"node_id":"n-1"}"#, { _ = try await $0.networkingPlanNodePolicy(nodeID: "n-1") }),
        ("/api/netpolicy/convert", #"{"group_policy":{"id":"g","rules":[],"enabled":true,"priority":5,"group_rule_count":0,"target":{"nodes":["n-1"]},"target_node_ids":["n-1"],"label":"core"},"approval":\#(approval)}"#,
         #"{"name":"core","priority":5,"target_node_id":"n-1"}"#, { _ = try await $0.networkingConvertPolicy(NetworkingConvertBody(targetNodeID: "n-1", name: "  core  ", priority: 5)) }),
        ("/api/group-policies/plan", #"{"affected":[],"conflicts":[],"orphaned":[]}"#, "{}", { _ = try await $0.networkingPlanGroupPolicies() }),
        ("/api/dns/plan", #"{"approval":\#(approval),"findings":[]}"#, #"{"id":"dns_1"}"#, { _ = try await $0.networkingPlanDNS(NetworkingDNSPlanBody(id: "dns_1")) }),
        ("/api/dns/plan", #"{"approval":\#(approval),"findings":[]}"#, #"{"accept_lockout_risk":true,"id":"dns_1"}"#, { _ = try await $0.networkingPlanDNS(NetworkingDNSPlanBody(id: "dns_1", acceptLockoutRisk: true)) }),
        ("/api/dns/publish", #"{"ok":true,"ipv4":"203.0.113.9","ipv6":""}"#, #"{"id":"dns_1"}"#, { _ = try await $0.networkingPublishDNS(id: "dns_1") }),
        ("/api/dns/measure-cert", #"{"created":["mon_1"],"linked":[]}"#, #"{"id":"dns_3","ports":[853,8443]}"#, { _ = try await $0.networkingMeasureCert(NetworkingMeasureCertBody(id: "dns_3", ports: [853, 8443])) }),
        ("/api/ddns/run", #"{"id":"d1","name":"x"}"#, #"{"id":"d1"}"#, { _ = try await $0.networkingRunDDNS(id: "d1") }),
        ("/api/ddns/delete", ok, #"{"id":"d1"}"#, { try await $0.networkingDeleteDDNS(id: "d1") }),
        ("/api/geo-routing/plan", #"{"geo_routing_id":"g1","hostname":"h","strategy":"geoip","config":"c","sha256":"s"}"#, #"{"id":"g1"}"#, { _ = try await $0.networkingPreviewGeo(id: "g1") }),
        ("/api/geo-routing/delete", ok, #"{"id":"g1"}"#, { try await $0.networkingDeleteGeo(id: "g1") }),
        ("/api/tunnels/plan", rawApproval, #"{"id":"t1"}"#, { _ = try await $0.networkingPlanTunnel(id: "t1") }),
        ("/api/tunnels/delete", ok, #"{"id":"t1"}"#, { try await $0.networkingDeleteTunnel(id: "t1") }),
    ]
    for (path, answer, expected, call) in cases {
        let request = try await netRequest(path, answer: answer, call)
        try expectEqual(request.method, "POST", "\(path) is a POST")
        try expectEqual(request.body, expected, "\(path) body")
    }
    let blank = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(NetworkingConvertBody(targetNodeID: "n-1", name: " "))) as? [String: String]
    try expectEqual(blank, ["target_node_id": "n-1"], "a blank name and no priority are left out")

    let matrix = try await netRequest("/api/netpolicy/matrix?direction=ingress", answer: #"{"direction":"ingress","groups":[],"cells":[],"external":[]}"#) {
        _ = try await $0.networkingMatrix(direction: "ingress")
    }
    try expectEqual(matrix.method, "GET", "matrix is a read")
    try expectEqual(matrix.url, "https://lattice.example.com/api/netpolicy/matrix?direction=ingress", "matrix direction query")
}

// MARK: - DNS plan findings loop

private func checkNetworkingDNSFindingsLoop() async throws {
    let state = DemoState()
    let client = netDemo(state: state)
    let deployment = ObjectRef(kind: "DNS deployment", id: "dns_d02", name: "public resolver fra")
    let node = ObjectRef(kind: "node", id: DemoWorld.node("dns-fra-1").id, name: "dns-fra-1")
    let intent = NetworkingIntents.planDNS(deployment, node: node)
    try expectEqual(intent.tier, .plan, "DNS plan is plan filing")
    try expectEqual(intent.scopes, ["dns:admin", "network:plan"], "DNS plan scopes")
    try expect(intent.toggles.allSatisfy { $0.revealedByConflict && $0.id == "accept_lockout_risk" }, "the acceptance shows only after the 409")

    let flow = WriteFlow(intent: intent, client: client, authenticator: NetworkingAuthStub(outcome: .cancelled))
    let report = try expectUnwrapped(try await flow.dryRun(), "DNS plan preview")
    try expect(report.lines.contains { $0.label == "Answers" && $0.value == "2 client networks" }, "the preview names the allowed client networks")
    let first = try netFinished(await flow.commit(choices: ConfirmChoices(), reviewed: report), "first DNS plan")
    guard case .refused(.conflict(let findings), _) = first else { throw CheckFailure.failed("a lockout plan stops on its findings, got \(first)") }
    try expect(findings.contains { $0.contains("cuts off SSH") }, "the blocking finding is listed")
    try expect(findings.count == 2, "warnings come with the blocker")
    let observed325 = await state.members(of: "approval.filed").isEmpty
    try expect(observed325, "nothing was filed before acceptance")

    let second = try netFinished(await WriteFlow(intent: intent, client: client, authenticator: NetworkingAuthStub(outcome: .cancelled))
        .commit(choices: ConfirmChoices(accepted: ["accept_lockout_risk"])), "accepted DNS plan")
    guard case .filed(let ids, let refused, let notes) = second else { throw CheckFailure.failed("an accepted plan files, got \(second)") }
    try expectEqual(ids.count, 1, "one approval")
    try expect(refused.isEmpty, "nothing refused")
    try expect(notes.contains { $0.hasPrefix("Accepted:") }, "the result restates the accepted finding")
    let filed = try await client.fetchApproval(id: ids[0])
    try expectEqual(filed.plugin, "selfdns", "filed plugin")
    try expect(filed.planHashMatchesServer, "the filed plan hashes to its plan_sha256")

    // A mesh deployment has no lockout risk and files at once.
    let mesh = try netFinished(await WriteFlow(intent: NetworkingIntents.planDNS(ObjectRef(kind: "DNS deployment", id: "dns_d01", name: "mesh resolver tyo"), node: node),
                                                client: client, authenticator: NetworkingAuthStub(outcome: .cancelled)).commit(choices: ConfirmChoices()), "mesh plan")
    guard case .filed = mesh else { throw CheckFailure.failed("a mesh plan files without findings") }
}

// MARK: - Group policy plan

private func checkNetworkingGroupPlan() async throws {
    let client = netDemo()
    let covered = DemoWorld.nodes.map { ObjectRef(kind: "node", id: $0.id, name: $0.name) }
    let intent = NetworkingIntents.planAllGroupPolicies(covered: covered)
    try expectEqual(intent.affected.count, covered.count, "covered nodes are listed as will try")
    try expect(intent.consequence.contains("whichever policy you start from"), "the sheet says every covered node is planned")
    let outcome = try netFinished(await WriteFlow(intent: intent, client: client, authenticator: NetworkingAuthStub(outcome: .cancelled)).commit(choices: ConfirmChoices()), "group plan")
    guard case .filed(let ids, let refused, let notes) = outcome else { throw CheckFailure.failed("group plan files, got \(outcome)") }
    try expectEqual(ids.count, DemoWorld.nodes.count - 4, "every covered node without a manual policy gets a plan")
    try expectEqual(Set(refused.map(\.object.name)), ["core-lon-1", "home-router", "lab-pi-1"], "two conflicts and one orphan are the refused half")
    try expect(refused.first { $0.object.name == "lab-pi-1" }?.reason == NetworkingGroupPlanResult.orphanReason, "orphan reason")
    try expectEqual(notes.first, "\(ids.count) plans filed, 2 conflicts, 1 orphaned node", "headline note")
    try expect(notes.contains { $0.contains("DNS nodes matches by selector") }, "selector impact note")
    try expect(!outcome.isCleanSuccess, "any conflict or orphan is never a clean success")
}

// MARK: - Convert

private func checkNetworkingConvert() async throws {
    let state = DemoState()
    let client = netDemo(state: state)
    let node = ObjectRef(kind: "node", id: DemoWorld.node("core-lon-1").id, name: "core-lon-1")
    let intent = NetworkingIntents.convertPolicy(node, name: "core egress", priority: 40)
    try expectEqual(intent.tier, .t3, "convert is T3 before the plan")
    try expect(intent.consequence.hasPrefix("Creates outbound policy \"core egress\" directly"), "the sheet says it creates the policy first")

    let cancelled = await WriteFlow(intent: intent, client: client, authenticator: NetworkingAuthStub(outcome: .cancelled)).commit(choices: ConfirmChoices())
    guard case .cancelled = cancelled else { throw CheckFailure.failed("a cancelled Face ID cancels the convert") }
    let observed373 = await state.members(of: "networking.converted").isEmpty
    try expect(observed373, "a cancelled convert sends nothing")

    let outcome = try netFinished(await WriteFlow(intent: intent, client: client, authenticator: NetworkingAuthStub(outcome: .confirmed)).commit(choices: ConfirmChoices()), "convert")
    guard case .filed(let ids, _, let notes) = outcome else { throw CheckFailure.failed("convert files the plan, got \(outcome)") }
    try expectEqual(ids.count, 1, "one plan")
    try expectEqual(notes.first, "Created outbound policy core egress and filed its plan for core-lon-1", "result names the policy and the plan")
    let observed379 = try await client.listNetPolicies().first { $0.targetNodeID == node.id }?.groupDerived ?? false
    try expect(observed379, "the node's document is now built from policies")
    let observed380 = try await client.networkingGroupPolicies().contains { $0.target.nodes == [node.id] }
    try expect(observed380, "the new policy is listed")

    let again = try netFinished(await WriteFlow(intent: intent, client: client, authenticator: NetworkingAuthStub(outcome: .confirmed)).commit(choices: ConfirmChoices()), "convert again")
    guard case .refused(.validation(let message), _) = again else { throw CheckFailure.failed("a second convert is refused, got \(again)") }
    try expect(message.contains("already built from outbound policies"), "the refusal says why")

    let disabled = try netFinished(await WriteFlow(intent: NetworkingIntents.convertPolicy(ObjectRef(kind: "node", id: DemoWorld.node("home-router").id, name: "home-router"), name: nil, priority: nil),
                                                    client: client, authenticator: NetworkingAuthStub(outcome: .confirmed)).commit(choices: ConfirmChoices()), "convert disabled")
    guard case .done(let done, _) = disabled else { throw CheckFailure.failed("a disabled document converts without a plan, got \(disabled)") }
    try expect(done.contains("no plan was filed"), "says no plan was filed")
}

// MARK: - Other writes

private func checkNetworkingWrites() async throws {
    let state = DemoState()
    let client = netDemo(state: state)
    let deployments = try await client.networkingDNSDeployments()
    let publicDNS = try expectUnwrapped(deployments.first { $0.id == "dns_d02" }, "public deployment")

    // Publish: the preview is computed on the phone and labelled as such.
    let publish = NetworkingIntents.publishDNS(publicDNS)
    try expectEqual(publish.tier, .t3, "publish is T3")
    let flow = WriteFlow(intent: publish, client: client, authenticator: NetworkingAuthStub(outcome: .confirmed))
    let report = try expectUnwrapped(try await flow.dryRun(), "publish preview")
    try expect(report.lines.allSatisfy { $0.group?.hasPrefix("Computed on this iPhone") ?? false }, "every preview line is labelled as computed on this iPhone")
    try expect(report.lines.contains { $0.label == "AAAA" && $0.value.contains("provider has 2001:db8:20::99") }, "the moved IPv6 address shows old and new")
    try expect(report.lines.contains { $0.label == "A" && $0.value.hasSuffix("unchanged") }, "the IPv4 address is unchanged")
    let published = try netFinished(await flow.commit(choices: ConfirmChoices(), reviewed: report), "publish")
    guard case .done(let message, _) = published else { throw CheckFailure.failed("publish is done, got \(published)") }
    try expect(message.hasPrefix("Published dns-fra.example.org"), "publish banner")
    let observed411 = try await client.networkingDNSDeployments().first { $0.id == "dns_d02" }?.lastIPv6 == DemoWorld.node("dns-fra-1").ipv6
    try expect(observed411, "the list now shows the published address")

    // A cancelled Face ID sends nothing: the mock answers nothing at all.
    let (silent, transport) = netMock([:])
    let cancelled = await WriteFlow(intent: NetworkingIntents.publishDNS(publicDNS), client: silent, authenticator: NetworkingAuthStub(outcome: .cancelled)).commit(choices: ConfirmChoices())
    guard case .cancelled = cancelled else { throw CheckFailure.failed("cancelled publish") }
    let observed417 = await transport.requestURLs.isEmpty
    try expect(observed417, "a cancelled publish sends no request")

    // Measure certificate is T2 with both scopes.
    let external = try expectUnwrapped(deployments.first { $0.id == "dns_d03" }, "external deployment")
    let measure = NetworkingIntents.measureCert(external, ports: external.portsToMeasure)
    try expectEqual(measure.tier, .t2, "measure is T2")
    try expectEqual(measure.scopes, ["dns:admin", "monitor:admin"], "measure scopes")
    try expect(measure.consequence.contains("doh.example.net:8443"), "names host and port")
    let measured = try netFinished(await WriteFlow(intent: measure, client: client, authenticator: NetworkingAuthStub(outcome: .cancelled)).commit(choices: ConfirmChoices()), "measure")
    guard case .done(let measuredText, _) = measured else { throw CheckFailure.failed("measure done") }
    try expectEqual(measuredText, "Created a TLS check for doh iad", "measure banner")
    let confinedMeasure = try netFinished(await WriteFlow(intent: measure, client: netDemo(.confinedToken), authenticator: NetworkingAuthStub(outcome: .cancelled)).commit(choices: ConfirmChoices()), "confined measure")
    guard case .refused(.forbidden, _) = confinedMeasure else { throw CheckFailure.failed("a confined token cannot measure") }

    // DDNS run: preview from the node, failure surfaces the provider's words.
    let profiles = try await client.listDDNS()
    let home = try expectUnwrapped(profiles.first { $0.id == "ddns_d03" }, "home profile")
    let run = NetworkingIntents.runDDNS(home)
    try expectEqual(run.tier, .t3, "DDNS run is T3")
    let runReport = try expectUnwrapped(try await WriteFlow(intent: run, client: client, authenticator: NetworkingAuthStub(outcome: .confirmed)).dryRun(), "run preview")
    try expect(runReport.lines.contains { $0.label == "home.example.net A" && $0.value == "\(DemoWorld.node("home-router").ipv4), was 192.0.2.10" }, "run preview names old and new")
    let ran = try netFinished(await WriteFlow(intent: run, client: client, authenticator: NetworkingAuthStub(outcome: .confirmed)).commit(choices: ConfirmChoices(), reviewed: runReport), "run")
    guard case .done(let ranText, _) = ran else { throw CheckFailure.failed("run done, got \(ran)") }
    try expect(ranText.hasPrefix("Ran home"), "run banner")
    let fra = try expectUnwrapped(profiles.first { $0.id == "ddns_d02" }, "failing profile")
    let failed = try netFinished(await WriteFlow(intent: NetworkingIntents.runDDNS(fra), client: client, authenticator: NetworkingAuthStub(outcome: .confirmed)).commit(choices: ConfirmChoices()), "failing run")
    guard case .refused(_, let failedText) = failed else { throw CheckFailure.failed("a provider refusal is refused") }
    try expect(failedText.contains("403"), "the provider's status is shown")

    // T4 deletes carry the typed name.
    let delete = NetworkingIntents.deleteDDNS(home)
    try expectEqual(delete.tier, .t4, "DDNS delete is T4")
    try expectEqual(delete.confirmPhrase, "home", "typed profile name")

    let routings = try await client.networkingGeoRoutings()
    let names = Dictionary(DemoWorld.nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let applied = try expectUnwrapped(routings.first { $0.id == "geo_g01" }, "applied routing")
    let geoDelete = NetworkingIntents.deleteGeo(applied, names: names, time: { _ in "Oct 23" })
    try expectEqual(geoDelete.confirmPhrase, "dns apex", "an applied routing asks for its name")
    let geoReport = try expectUnwrapped(try await WriteFlow(intent: geoDelete, client: client, authenticator: NetworkingAuthStub(outcome: .confirmed)).dryRun(), "geo dry run")
    try expectEqual(geoReport.lines.filter { $0.group == "What stays on nodes" }.map(\.label), ["dns-tyo-1", "dns-fra-1"], "each DNS node is named")
    let pending = try expectUnwrapped(routings.first { $0.id == "geo_g02" }, "pending routing")
    try expect(NetworkingIntents.deleteGeo(pending, names: names, time: { _ in "" }).confirmPhrase == nil, "a never-applied routing needs no typed name")
    let geoDone = try netFinished(await WriteFlow(intent: geoDelete, client: client, authenticator: NetworkingAuthStub(outcome: .confirmed)).commit(choices: ConfirmChoices(), reviewed: geoReport), "geo delete")
    guard case .done = geoDone else { throw CheckFailure.failed("geo delete done") }
    let observed462 = try await client.networkingGeoRoutings().contains { $0.id == "geo_g01" } == false
    try expect(observed462, "the row is gone after the server confirms")

    let tunnels = try await client.listTunnels()
    let grafana = try expectUnwrapped(tunnels.first { $0.id == "tunnel_t01" }, "tunnel")
    let tunnelPlan = try netFinished(await WriteFlow(intent: NetworkingIntents.planTunnel(grafana, node: ObjectRef(kind: "node", id: grafana.nodeID, name: "core-lon-1")),
                                                      client: client, authenticator: NetworkingAuthStub(outcome: .cancelled)).commit(choices: ConfirmChoices()), "tunnel plan")
    guard case .filed(let tunnelIDs, _, _) = tunnelPlan else { throw CheckFailure.failed("tunnel plan files") }
    let tunnelApproval = try await client.fetchApproval(id: tunnelIDs[0])
    try expect(tunnelApproval.plan.contains("grafana.example.org") && tunnelApproval.planHashMatchesServer, "tunnel plan body and hash")
    let tunnelDelete = NetworkingIntents.deleteTunnel(grafana, nodeName: "core-lon-1")
    try expectEqual(tunnelDelete.confirmPhrase, "grafana", "tunnel delete typed name")
    try expect(tunnelDelete.consequence.contains("cloudflared keeps running on core-lon-1"), "tunnel delete says what stays")
}

// MARK: - Pure previews

private func checkNetworkingPreviews() throws {
    let deployment = try JSONDecoder().decode(NetworkingDNSDeployment.self, from: json(#"""
    {"id":"d","name":"x","node_id":"n","engine":"coredns","hostname":"x.example.org","publish_ipv4":true,"publish_ipv6":true,"last_ipv4":"203.0.113.1","status":"running"}
    """#))
    let preview = NetworkingPublishPreview(deployment: deployment, publicIPv4: "203.0.113.2", publicIPv6: "")
    try expectEqual(preview.lines.map(\.type), ["A"], "no IPv6 address, no AAAA line")
    try expectEqual(preview.missing, ["IPv6"], "the missing family is named")
    try expectEqual(preview.sentences.first, "A: will publish the node's current address 203.0.113.2; the provider has 203.0.113.1.", "spec sentence")
    let blocked = NetworkingIntents.publishReport(deployment, publicIPv4: nil, publicIPv6: nil)
    try expect(blocked.blocking, "nothing to publish disables the button")

    let profile = try JSONDecoder().decode(DDNSProfile.self, from: json(#"""
    {"id":"p","name":"p","node_id":"n","provider":"cloudflare","domains":["a.example.org","b.example.org"],"enable_ipv4":true,"enable_ipv6":true,"last_ipv4":"192.0.2.1"}
    """#))
    let records = NetworkingDDNSPreview.records(profile, publicIPv4: "192.0.2.2", publicIPv6: nil)
    try expectEqual(records.map { "\($0.domain) \($0.type)" }, ["a.example.org A", "b.example.org A"], "every domain, enabled families with an address only")
    try expectEqual(records.first?.sentence, "a.example.org A 192.0.2.2 (was 192.0.2.1)", "record sentence")
    let cname = try JSONDecoder().decode(DDNSProfile.self, from: json(#"""
    {"id":"c","name":"c","node_id":"n","provider":"cloudflare","domains":["s.example.org"],"record_type":"cname","cname_target":"Edge.CDN.example.com.","last_target":"edge.cdn.example.com"}
    """#))
    try expectEqual(NetworkingDDNSPreview.records(cname, publicIPv4: "192.0.2.2", publicIPv6: nil).first?.sentence, "s.example.org CNAME edge.cdn.example.com (unchanged)", "CNAME preview normalizes the target")
    try expectEqual(NetworkingDDNSPreview.errorText(#"cloudflare: HTTP 403: [{"code":10000,"message":"Authentication error"}]"#),
                    "cloudflare: Cloudflare refused it, HTTP 403: Authentication error (code 10000)", "Cloudflare error list reads as a sentence")
    try expectEqual(NetworkingDDNSPreview.errorText("timeout"), "timeout", "other errors pass through")

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try expectEqual(NetworkingCertState.of(notAfter: now.addingTimeInterval(40 * 86_400), now: now, thresholdDays: 21), .ok(days: 40), "far expiry")
    try expectEqual(NetworkingCertState.of(notAfter: now.addingTimeInterval(3 * 86_400 + 60), now: now, thresholdDays: 0), .ok(days: 3), "unwatched expiry is never amber")
    try expectEqual(NetworkingCertState.of(notAfter: now.addingTimeInterval(-86_400 - 60), now: now, thresholdDays: 0), .expired(days: -2), "a lapsed expiry is still called out")
    try expectEqual(NetworkingCertState.expired(days: -2).words, "expired 2 days ago", "expired words")
}

// MARK: - Query fields

private func checkNetworkingQueries() throws {
    let rows = [
        NetworkingNodePolicyRow(nodeID: "n-1", nodeName: "edge-1", policy: nil),
        NetworkingNodePolicyRow(nodeID: "n-2", nodeName: "core-1", policy: NetPolicy(id: "n-2", targetNodeID: "n-2", enabled: true, lastError: "boom")),
    ]
    guard case .success(let failing) = NetworkingQuery.nodes("state:failing") else { throw CheckFailure.failed("state alias compiles") }
    try expectEqual(LatticeQueryEngine.apply(failing, to: rows, now: Date()).map(\.nodeName), ["core-1"], "state:failing finds the failed apply")
    guard case .success(let none) = NetworkingQuery.nodes("kind:none") else { throw CheckFailure.failed("kind compiles") }
    try expectEqual(LatticeQueryEngine.apply(none, to: rows, now: Date()).map(\.nodeName), ["edge-1"], "kind:none")
    guard case .failure(let error) = NetworkingQuery.dns("stauts:failed") else { throw CheckFailure.failed("unknown field is refused") }
    try expect(NetworkingQuery.message(error, noun: "Deployments").contains("Did you mean status?"), "typo suggests the field")
    guard case .success = NetworkingQuery.tunnels("host:grafana.example.org"), case .success = NetworkingQuery.geo("is:applied"),
          case .success = NetworkingQuery.policies("-is:enabled"), case .success = NetworkingQuery.guardNodes("state:failed"),
          case .success = NetworkingQuery.ddns("state:stale") else {
        throw CheckFailure.failed("every list's query compiles")
    }
}
