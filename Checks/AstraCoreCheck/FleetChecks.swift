import Foundation
import AstraCore

public func checkFleet() async throws {
    try await checkNodeWrites()
    try checkFleetSummaries()
    try await checkFleetDecoding()
    try await checkFleetDemoReads()
    try await checkFleetWriteBodies()
    try await checkFleetIntentFlows()
    try checkFleetQueryFields()
    try checkFleetQueries()
    try checkFleetLogic()
    try checkFleetMapClusters()
}

private let base = "https://lattice.example.com"
private let pinnedClock = DemoClock(pinned: "2026-10-28T12:00:00Z")!

private func mockClient(_ responses: [String: (Int, Data)]) -> (LatticeClient, MockTransport) {
    let transport = MockTransport(responses: responses)
    let client = LatticeClient(baseURL: URL(string: base)!, credential: LatticeCredential(bearerToken: "lat_check.notasecret"), transport: transport)
    return (client, transport)
}

private func fleetDemoClient(_ scenario: DemoScenario = .normal, state: DemoState = DemoState()) -> LatticeClient {
    LatticeClient(baseURL: DemoWorld.baseURL, credential: LatticeCredential(bearerToken: DemoWorld.token),
                  transport: DemoTransport(identity: .pat, scenario: scenario, clock: pinnedClock, state: state))
}

/// The body as sorted-key JSON, so goldens compare exactly.
private func canonical(_ data: Data?) throws -> String {
    let data = try expectUnwrapped(data, "request body")
    let object = try JSONSerialization.jsonObject(with: data)
    let sorted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: sorted, as: UTF8.self)
}

private struct FleetAuthStub: WriteAuthenticator {
    let outcome: DeviceAuthOutcome
    func authenticate(reason: String) async -> DeviceAuthOutcome { outcome }
}

// MARK: - Moved from M0 (kept)

private func checkNodeWrites() async throws {
    let transport = MockTransport(responses: [
        "https://lattice.example.com/api/nodes/disable?node_id=node-a": (200, #"{"ok":true,"disabled":true}"#.data(using: .utf8)!),
        "https://lattice.example.com/api/nodes/rotate-token?node_id=node-a": (200, #"{"node_id":"node-a","token":"tok.secret"}"#.data(using: .utf8)!),
        "https://lattice.example.com/api/nodes/capabilities?node_id=node-a": (
            200,
            #"{"node_id":"node-a","effective":[{"capability":"sshguard","enforced":true,"mutates":true,"allowed":true,"source":"record","state":"enrolled","record_reason":"hardening wave 2","actor_id":"u-1","updated_at":"2026-10-20T08:00:00Z"}]}"#.data(using: .utf8)!
        ),
    ])
    let session = LatticeClient(baseURL: URL(string: "https://lattice.example.com")!, credential: LatticeCredential(sessionCookie: "sid", csrfToken: "csrf-token"), transport: transport)

    try await session.setNodeDisabled(nodeID: "node-a", disabled: true)
    let disableBody = try await bodyObject(transport.bodies.last ?? nil)
    try expectEqual(disableBody["node_id"] as? String, "node-a", "disable node id body")
    try expectEqual(disableBody["disabled"] as? Bool, true, "disable flag body")

    let rotate = try await session.rotateNodeToken(nodeID: "node-a")
    try expectEqual(rotate.token, "tok.secret", "rotate returns one-time token")

    let caps = try await session.fetchNodeCapabilities(nodeID: "node-a")
    try expectEqual(caps.first?.capability, "sshguard", "capability id")
    try expect(caps.first?.allowed == true, "capability allowed")
    try expectEqual(caps.first?.recordReason, "hardening wave 2", "capability record reason")
    try expect(caps.first?.updatedAt != nil, "capability record time")
}

private func checkFleetSummaries() throws {
    let now = ISO8601DateFormatter().date(from: "2026-06-17T02:00:00Z")!
    let healthy = LatticeNode(id: "n1", name: "h", online: true, lastSeen: now, metrics: LatticeMetrics(cpuPercent: 20, memoryUsed: 20, memoryTotal: 100), hostFacts: LatticeHostFacts())
    let hot = LatticeNode(id: "n2", name: "hot", online: true, lastSeen: now, metrics: LatticeMetrics(cpuPercent: 95, memoryUsed: 50, memoryTotal: 100), hostFacts: LatticeHostFacts())
    let down = LatticeNode(id: "n3", name: "down", online: false, lastSeen: now.addingTimeInterval(-9999), metrics: LatticeMetrics(), hostFacts: LatticeHostFacts())

    let summary = FleetSummary(nodes: [healthy, hot, down], thresholds: FleetThresholds(), now: now)
    try expectEqual(summary.total, 3, "fleet total")
    try expectEqual(summary.online, 2, "fleet online")
    try expectEqual(summary.offline, 1, "fleet offline")
    try expectEqual(summary.critical, 2, "fleet critical counts hot cpu + offline")
    try expect(abs(summary.averageCPU - 57.5) < 0.001, "fleet average cpu over online nodes")

    var history = MetricsHistory(capacity: 2)
    history.record(nodes: [healthy, hot], at: now)
    history.record(nodes: [healthy, hot], at: now.addingTimeInterval(30))
    history.record(nodes: [healthy], at: now.addingTimeInterval(60))
    try expectEqual(history.samples(for: "n1").count, 2, "history respects capacity")
    try expectEqual(history.samples(for: "n2").count, 0, "history prunes missing nodes")
    try expectEqual(history.samples(for: "n1").last?.cpu, 20, "history records latest cpu")

    let worldwide = try expectUnwrapped(
        FleetMapRegion.fitting(latitudes: [37.77, 35.68], longitudes: [-122.4, 139.7]),
        "worldwide pair fits"
    )
    try expect(worldwide.longitudeDelta <= 360, "worldwide longitude span stays inside MapKit's 360 cap")
    try expect(worldwide.latitudeDelta <= 180, "latitude span stays inside MapKit's 180 cap")
    try expect(FleetMapRegion.fitting(latitudes: [.nan], longitudes: [1]) == nil, "NaN pair is rejected")
}

// MARK: - Decoding edge cases (server-shaped JSON)

private func checkFleetDecoding() async throws {
    let history = try JSONDecoder().decode(FleetMetricsQuery.self, from: fixture("fleet-node-history.json"))
    try expectEqual(history.stepSeconds, 600, "metrics step")
    let cpu = try expectUnwrapped(history.series(named: "cpu"), "cpu series")
    try expectEqual(cpu.avg.count, 3, "null averages decode as gaps, not failures")
    try expectEqual(cpu.points.map(\.value), [12.5, 14], "points skip the null bucket")
    try expectEqual(history.series(named: "beat_gap")?.points.count, 0, "an empty event series decodes")

    let network = try JSONDecoder().decode(FleetNodeNetworkView.self, from: fixture("fleet-node-network-refused.json"))
    try expect(network.inbound?.section.isRefused == true, "refused inbound section")
    try expectEqual(network.inbound?.section.scope, "netguard:read", "refused section names its scope")
    try expectEqual(network.inbound?.zones, [], "null zones decode empty")
    try expectEqual(network.outbound?.effectiveTitle, "Manual node policy", "manual document blocks every policy")
    try expectEqual(network.outbound?.ruleCount, 9, "manual rule count")
    try expectEqual(network.outboundRules, ["tcp dport 443 accept"], "rules list strips braces and chain headers")
    try expectEqual(network.tables.last?.rulesWithheld, "knock", "knock rules are withheld")
    try expectEqual(network.mesh?.peersRefused, "wireguard:read", "mesh peers refusal")

    let summary = try JSONDecoder().decode(FleetNodeDeleteSummary.self, from: fixture("fleet-delete-summary.json"))
    try expectEqual(summary.logStorePurgeErrors, 2, "purge errors decode")
    try expectEqual(summary["future_counter"], 4, "an unknown counter is kept")
    let lines = FleetDeleteReport.lines(summary)
    try expect(lines.contains { $0.label == "future counter" && $0.group == "Other" }, "an unknown counter is still shown")
    try expect(!lines.contains { $0.label.contains("log store") }, "delete-only counters stay out of the dry run")
    try expect(FleetDeleteReport.requiresTypedName(summary), "a DNS deployment needs the typed name")
    let outcome = FleetDeleteReport.outcome(summary, node: ObjectRef(kind: "node", id: "n-a", name: "edge-a"))
    guard case .partial(let done, let failed, let message) = outcome else { throw CheckFailure.failed("purge errors must be partial") }
    try expectEqual(done.map(\.id), ["n-a"], "the node itself is deleted")
    try expectEqual(failed.count, 1, "one failure line for the log stores")
    try expectEqual(message, "Node deleted; 2 log stores could not be purged", "partial delete copy")
}

// MARK: - Every demo response decodes

private func checkFleetDemoReads() async throws {
    let demo = fleetDemoClient()
    let arcs = MapClusters.arcs(try await demo.fetchPaths(window: .oneHour), nodes: try await demo.fetchNodeGeo(), all: false)
    let tokyoFrankfurt = arcs.filter { $0.id.contains("35.5,139.5") && $0.id.contains("50.0,8.5") }
    try expectEqual(tokyoFrankfurt.count, 1, "paths between the same two cells share one arc: \(arcs.map(\.id))")
    try expectEqual(tokyoFrankfurt.first?.state, .down, "the shared arc keeps the worst state")

    let client = fleetDemoClient()
    let records = try await client.fleetFetchNodeRecords()
    try expectEqual(records.count, DemoWorld.nodes.count, "node records cover the fleet")
    try expect(records.contains { $0.facts.provider == "Northwind Cloud" }, "provider comes from the node geo record")

    let tokyo = DemoWorld.node("edge-tyo-1").id
    let fra2 = DemoWorld.node("relay-fra-2").id
    let probe = DemoWorld.node("probe-sin-3").id

    let all = try await client.fleetStatusHistory(days: 7)
    try expectEqual(all.nodes.count, DemoWorld.nodes.count, "status history for every node")
    let offline = try expectUnwrapped(try await client.fleetStatusHistory(nodeID: fra2, days: 7).nodes[fra2], "offline node history")
    try expectEqual(offline.events.last?.to, "offline", "offline node ends offline")
    try expect(offline.offlineSeconds > 0, "offline seconds counted")
    try expectEqual(try await client.fleetStatusHistory(nodeID: probe, days: 1).nodes[probe]?.initial, "unknown", "never reported is unknown")

    for range in FleetMetricsRange.allCases {
        let metrics = try await client.fleetNodeHistory(nodeID: tokyo, range: range)
        try expect(!(metrics.series(named: "cpu")?.points.isEmpty ?? true), "cpu history for \(range.rawValue)")
        try expectEqual(metrics.series.count, 6, "six node series for \(range.rawValue)")
    }
    try expectEqual(try await client.fleetNodeHistory(nodeID: probe, range: .oneDay).series.count, 0, "a node that never reported has no series")
    let syd = try await client.fleetNodeHistory(nodeID: DemoWorld.node("relay-syd-2").id, range: .oneDay)
    let times = try expectUnwrapped(syd.series(named: "cpu"), "syd cpu").points.map(\.date)
    let gaps = zip(times, times.dropFirst()).filter { $1.timeIntervalSince($0) > 600 * 2.5 }
    try expect(!gaps.isEmpty, "relay-syd-2 history has a gap to draw")

    let network = try await client.fleetNodeNetwork(nodeID: tokyo)
    try expectEqual(network.inbound?.firewallTitle, "NetGuard", "Tokyo edge is under NetGuard")
    try expect(!network.outboundRules.isEmpty, "rules=1 returns the ruleset")
    try expect(!network.outboundRules.contains { $0.hasPrefix("type ") }, "the chain hook line is not a rule")
    try expectEqual(network.outbound?.applying.count, 2, "baseline and group policy apply")
    let home = try await client.fleetNodeNetwork(nodeID: DemoWorld.node("home-nas").id)
    try expectEqual(home.outbound?.effectiveTitle, "No outbound policy", "home node has no outbound policy")

    let duplicates = try await client.fleetDuplicates()
    try expectEqual(FleetHeader.duplicates(duplicates.nodeCount), "2 possible duplicate nodes", "duplicate banner copy")

    let listening = try await client.fleetBeacon(nodeID: DemoWorld.node("relay-tyo-1").id)
    try expect(listening.isEnabled && listening.state == "listening", "relay beacon listens")
    try expectEqual(listening.planRequest.action, .change, "an enabled beacon replans as change")
    try expect(listening.carriesNetGuard, "NetGuard exposure needs netguard:admin")
    let off = try await client.fleetBeacon(nodeID: DemoWorld.node("dns-iad-1").id)
    try expectEqual(off.planRequest.action, .enable, "an off beacon plans enable")
    try expectEqual(off.pendingApprovalID, "approval_d1006", "pending enable plan is linked")
    let broken = try await client.fleetBeacon(nodeID: DemoWorld.node("relay-syd-2").id)
    try expectEqual(broken.stateWord, "not listening", "not listening state word")

    let caps = try await client.fetchNodeCapabilities(nodeID: DemoWorld.node("lab-pi-2").id)
    let sshguard = try expectUnwrapped(caps.first { $0.capability == "sshguard" }, "sshguard capability")
    try expectEqual(FleetCapabilityState.word(sshguard), "Excluded", "standing exclusion")
    try expect(FleetCapabilityState.detail(sshguard).contains("port forwarding"), "exclusion reason shown")

    let gates = try await client.fleetCapabilityGates()
    let gate = try expectUnwrapped(gates.first { $0.capability == "sshguard" }, "sshguard gate")
    try expect(gate.enforced && gate.refuseCount > 0 && gate.refused.count <= 10, "would-refuse sample of at most ten")

    let groups = try await client.fleetGroups()
    try expectEqual(groups.groups.count, DemoWorld.groups.count, "every group listed")
    let homeLab = try expectUnwrapped(groups.groups.first { $0.id == "g-home-lab" }, "home lab group")
    try expectEqual(homeLab.kind, .staticMembers, "home lab is static")
    try expectEqual(groups.groups.first { $0.id == "g-asia-edge" }?.kind, .selector, "Asia edge is a selector")
    try expect(homeLab.rollup.offline >= 1, "home lab rollup counts lab-pi-2 offline")
    let usedBy = try await client.fleetGroupUsedBy(groupID: "g-asia-edge")
    try expect(usedBy.blocksDelete && usedBy.usedBy.count == 2, "Asia edge is used twice")

    let plan = try await client.fleetPlanNodeDelete(nodeID: DemoWorld.node("dns-tyo-1").id)
    try expect(FleetDeleteReport.requiresTypedName(plan), "a DNS node needs the typed name")
    let plain = try await client.fleetPlanNodeDelete(nodeID: DemoWorld.node("edge-iad-2").id)
    try expect(!FleetDeleteReport.requiresTypedName(plain), "a plain edge node does not")
    try expect(FleetDeleteReport.lines(plain).allSatisfy { $0.value != "0" }, "the dry run lists only non-zero counters")

    // The Empty scenario still decodes every object route.
    let empty = fleetDemoClient(.empty)
    try expectEqual(try await empty.fleetDuplicates().groups.count, 0, "empty duplicates")
    try expectEqual(try await empty.fleetGroups().groups.count, 0, "empty groups")
    try expectEqual(try await empty.fleetCapabilityGates().count, 0, "empty gates")
    try expectEqual(try await empty.fleetNodeHistory(nodeID: tokyo, range: .oneHour).series.count, 0, "empty history")

    // A Triage token reads Fleet but cannot write it.
    let triage = fleetDemoClient(.limitedToken)
    do {
        try await triage.setNodeDisabled(nodeID: tokyo, disabled: true)
        throw CheckFailure.failed("Triage must not disable a node")
    } catch let error as LatticeAPIError {
        guard case .forbidden = error else { throw CheckFailure.failed("Triage disable maps to forbidden, got \(error)") }
    }
}

// MARK: - Request-body goldens for every write

private func checkFleetWriteBodies() async throws {
    let ok = json(#"{"ok":true}"#)
    let summary = json(#"{"node_id":"n-a","node_name":"edge-a","found":true,"mutated":false,"tasks_stripped":1}"#)
    let group = json(#"{"id":"g1","name":"Lab","members":["n-a","n-b"],"resolved_members":["n-a","n-b"],"rollup":{"total":2,"online":2,"offline":0,"disabled":0}}"#)
    let (client, transport) = mockClient([
        "\(base)/api/nodes/disable?node_id=n-a": (200, json(#"{"ok":true,"disabled":false}"#)),
        "\(base)/api/nodes/rotate-token?node_id=n-a": (200, json(#"{"node_id":"n-a","token":"lat_new.notasecret"}"#)),
        "\(base)/api/nodes/update": (200, json(#"{"ok":true,"name":"edge-b","role":"edge","comment":"","tags":["asia","edge"]}"#)),
        "\(base)/api/nodes/delete/plan": (200, summary),
        "\(base)/api/nodes/delete": (200, summary),
        "\(base)/api/nodes/debug": (200, json(#"{"id":"n-a","agent_debug":{"enabled":true,"collect":true}}"#)),
        "\(base)/api/nodes/geo": (200, json(#"{"id":"n-a","name":"edge-a"}"#)),
        "\(base)/api/nodes/geo/resolve": (200, json(#"{"results":[{"node_id":"n-a","ip":"203.0.113.11","status":"updated","geo":{"city":"Tokyo","country":"JP"}}]}"#)),
        "\(base)/api/nodes/beacon/rotate": (200, json(#"{"node_id":"n-a","epoch":5}"#)),
        "\(base)/api/nodes/capabilities": (200, json(#"{"node_id":"n-a","capability":"sshguard","state":"excluded","reason":"no port","enforced":true,"updated_at":"0001-01-01T00:00:00Z"}"#)),
        "\(base)/api/capabilities": (200, json(#"{"capability":"sshguard","enforced":true,"mutates":true,"derived":false,"allow_count":1,"refuse_count":2}"#)),
        "\(base)/api/groups/delete": (200, ok),
        "\(base)/api/groups/members": (200, group),
    ])
    func last() async throws -> String { try canonical(await transport.lastBody) }

    try await client.setNodeDisabled(nodeID: "n-a", disabled: false)
    try expectEqual(try await last(), #"{"disabled":false,"node_id":"n-a"}"#, "enable body")
    _ = try await client.rotateNodeToken(nodeID: "n-a")
    try expectEqual(try await last(), #"{"node_id":"n-a"}"#, "rotate token body")
    let updated = try await client.fleetUpdateNode(FleetNodeUpdateRequest(nodeID: "n-a", name: "edge-b", role: "edge", comment: "", tags: ["edge", "asia"]))
    try expectEqual(try await last(), #"{"comment":"","name":"edge-b","node_id":"n-a","role":"edge","tags":["edge","asia"]}"#, "identity body sends every replaced field")
    try expectEqual(updated.tags, ["asia", "edge"], "identity answer decodes")
    _ = try await client.fleetPlanNodeDelete(nodeID: "n-a")
    try expectEqual(try await last(), #"{"node_id":"n-a"}"#, "delete plan body")
    _ = try await client.fleetDeleteNode(nodeID: "n-a")
    try expectEqual(try await last(), #"{"node_id":"n-a"}"#, "delete body")
    let facts = try await client.fleetSetAgentDebug(nodeID: "n-a", enabled: true, collect: true)
    try expectEqual(try await last(), #"{"collect":true,"enabled":true,"node_id":"n-a"}"#, "debug on body")
    try expect(facts.agentDebug.enabled, "debug answer decodes the node view")
    let (offClient, offTransport) = mockClient(["\(base)/api/nodes/debug": (200, json(#"{"id":"n-a","agent_debug":{"enabled":false,"collect":false}}"#))])
    _ = try await offClient.fleetSetAgentDebug(nodeID: "n-a", enabled: false, collect: true)
    try expectEqual(try canonical(await offTransport.lastBody), #"{"collect":false,"enabled":false,"node_id":"n-a"}"#, "debug off never collects")
    _ = try await client.fleetClearNodeGeo(nodeID: "n-a")
    try expectEqual(try await last(), #"{"clear":true,"node_id":"n-a"}"#, "geo clear body")
    _ = try await client.resolveNodeGeo(nodeID: "n-a", all: false, missingOnly: false, overwrite: true)
    try expectEqual(try await last(), #"{"all":false,"missing_only":false,"node_id":"n-a","overwrite":true}"#, "geo resolve one body")
    let (allClient, allTransport) = mockClient(["\(base)/api/nodes/geo/resolve": (200, json(#"{"results":[]}"#))])
    _ = try await allClient.resolveNodeGeo(nodeID: nil, all: true, missingOnly: true, overwrite: false)
    try expectEqual(try canonical(await allTransport.lastBody), #"{"all":true,"missing_only":true,"overwrite":false}"#, "locate all body")
    _ = try await client.fleetRotateBeacon(nodeID: "n-a")
    try expectEqual(try await last(), #"{"node_id":"n-a"}"#, "beacon rotate body")
    let record = try await client.fleetDecideCapability(FleetCapabilityDecisionRequest(nodeID: "n-a", capability: "sshguard", state: "excluded", reason: "no port"))
    try expectEqual(try await last(), #"{"capability":"sshguard","node_id":"n-a","reason":"no port","state":"excluded"}"#, "capability body")
    try expectEqual(record.state, "excluded", "capability answer decodes")
    let impact = try await client.fleetSetGateEnforced(capability: "sshguard", enforced: true)
    try expectEqual(try await last(), #"{"capability":"sshguard","enforced":true}"#, "gate body")
    try expectEqual(impact.refuseCount, 2, "gate answer decodes")
    try await client.fleetDeleteGroup(groupID: "g1")
    try expectEqual(try await last(), #"{"id":"g1"}"#, "group delete body")
    let view = try await client.fleetSetGroupMembers(FleetGroupMembersRequest(groupID: "g1", add: ["n-b"]))
    try expectEqual(try await last(), #"{"add":["n-b"],"group_id":"g1","remove":[]}"#, "group members body")
    try expectEqual(view.members, ["n-a", "n-b"], "members answer decodes")

    // Beacon plan bodies the Fleet screens build (Shared posts them).
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let change = BeaconPlanRequest(nodeID: "n-a", action: .change, port: 7411, bind: "203.0.113.11", endpoint: "203.0.113.11:7411")
    try expectEqual(String(decoding: try encoder.encode(change), as: UTF8.self),
                    #"{"action":"change","bind":"203.0.113.11","endpoint":"203.0.113.11:7411","node_id":"n-a","port":7411}"#, "beacon change body")
    try expectEqual(String(decoding: try encoder.encode(BeaconPlanRequest(nodeID: "n-a", action: .enable)), as: UTF8.self),
                    #"{"action":"enable","node_id":"n-a"}"#, "beacon enable body takes the server defaults")
}

// MARK: - Intents end to end against the demo server

private func checkFleetIntentFlows() async throws {
    let state = DemoState()
    let client = fleetDemoClient(state: state)
    let node = ObjectRef(kind: "node", id: DemoWorld.node("edge-tyo-3").id, name: "edge-tyo-3")

    // A cancelled Face ID sends nothing.
    let (mock, transport) = mockClient([:])
    let cancelled = await WriteFlow(intent: FleetIntents.disable(node), client: mock, authenticator: FleetAuthStub(outcome: .cancelled)).commit(choices: ConfirmChoices())
    guard case .cancelled = cancelled else { throw CheckFailure.failed("cancelled disable must report cancelled") }
    try expectEqual(await transport.requestURLs.count, 0, "cancelled disable sends no request")

    // Disable then its inverse, through the Shared node list.
    let pass = FleetAuthStub(outcome: .confirmed)
    let disable = FleetIntents.disable(node)
    try expectEqual(disable.tier, .t3, "disable is T3")
    guard case .finished(.done) = await WriteFlow(intent: disable, client: client, authenticator: pass).commit(choices: ConfirmChoices()) else {
        throw CheckFailure.failed("disable lands")
    }
    try expectEqual(try await client.fetchNodes().first { $0.id == node.id }?.honesty, .disabled, "the list shows the node disabled")
    let enable = try expectUnwrapped(disable.inverse?(), "disable has a verified inverse")
    try expectEqual(enable.tier, .t2, "the inverse is the T2 enable")
    _ = await WriteFlow(intent: enable, client: client, authenticator: pass).commit(choices: ConfirmChoices())
    let restored = try await client.fetchNodes().first { $0.id == node.id }?.honesty != .disabled
    try expect(restored, "enable restores it")

    // Bulk disable reports per node.
    let missing = ObjectRef(kind: "node", id: "n-gone", name: "gone")
    let bulk = await WriteFlow(intent: FleetIntents.bulkDisable([node, missing]), client: client, authenticator: pass).commit(choices: ConfirmChoices())
    guard case .finished(.partial(let succeeded, let failed, _)) = bulk else { throw CheckFailure.failed("bulk with a missing node is partial") }
    try expectEqual(succeeded.map(\.id), [node.id], "bulk keeps the node that worked")
    try expectEqual(failed.map(\.object.id), ["n-gone"], "bulk names the node that failed")

    // A lost answer is checked against the server, not reported as not done.
    let a = ObjectRef(kind: "node", id: "n-a", name: "edge-a")
    let b = ObjectRef(kind: "node", id: "n-b", name: "edge-b")
    let (lostClient, _) = mockClient([
        "\(base)/api/nodes/disable?node_id=n-a": (504, Data()),
        "\(base)/api/nodes/disable?node_id=n-b": (504, Data()),
        "\(base)/api/nodes": (200, json(#"[{"id":"n-a","name":"edge-a","status":"disabled"},{"id":"n-b","name":"edge-b","status":"online"}]"#)),
    ])
    let lost = await WriteFlow(intent: FleetIntents.bulkDisable([a, b]), client: lostClient, authenticator: pass).commit(choices: ConfirmChoices())
    guard case .finished(.partial(let landed, let unclear, let lostMessage)) = lost else { throw CheckFailure.failed("bulk with lost answers is partial: \(lost)") }
    try expectEqual(landed.map(\.id), ["n-a"], "a lost answer the server shows landed counts as done")
    try expectEqual(unclear.first?.reason, "Could not confirm. edge-b is not disabled.", "a lost answer names what the server says")
    try expectEqual(lostMessage, "1 disabled, 1 not done", "lost answer message")


    guard case .finished(.done(_, let secret?)) = await WriteFlow(intent: FleetIntents.rotateToken(node), client: client, authenticator: pass).commit(choices: ConfirmChoices()) else {
        throw CheckFailure.failed("rotate returns a secret")
    }
    try expect(secret.value.hasPrefix("lat_demo_node_") && !secret.description.contains(secret.value), "rotated token is shown once and redacted in descriptions")

    // Delete: the dry run runs again before sending; a change stops the write.
    let planA = json(#"{"node_id":"n-a","node_name":"edge-a","found":true,"mutated":false,"dns_deployments":1,"tasks_stripped":2}"#)
    let planB = json(#"{"node_id":"n-a","node_name":"edge-a","found":true,"mutated":false,"dns_deployments":1,"tasks_stripped":3}"#)
    let shifting = MockTransport(responses: ["\(base)/api/nodes/delete/plan": (200, planA)])
    let shiftingClient = LatticeClient(baseURL: URL(string: base)!, credential: LatticeCredential(bearerToken: "t"), transport: shifting)
    let edge = ObjectRef(kind: "node", id: "n-a", name: "edge-a")
    let deleteIntent = FleetIntents.delete(edge, typedName: true)
    try expectEqual(deleteIntent.confirmPhrase, "edge-a", "typed name is the node name")
    let flow = WriteFlow(intent: deleteIntent, client: shiftingClient, authenticator: pass)
    let reviewed = try expectUnwrapped(try await flow.dryRun(), "delete dry run")
    try expect(reviewed.lines.contains { $0.label == "DNS deployments" && $0.group == "Services" }, "dry run groups DNS under services")
    let changedTransport = MockTransport(responses: ["\(base)/api/nodes/delete/plan": (200, planB)])
    let changedFlow = WriteFlow(intent: deleteIntent, client: LatticeClient(baseURL: URL(string: base)!, credential: LatticeCredential(bearerToken: "t"), transport: changedTransport), authenticator: pass)
    guard case .dryRunChanged = await changedFlow.commit(choices: ConfirmChoices(), reviewed: reviewed) else {
        throw CheckFailure.failed("a changed plan stops the delete")
    }
    let onlyPlans = await changedTransport.requestURLs.allSatisfy { $0.hasSuffix("/delete/plan") }
    try expect(onlyPlans, "no delete is sent after the plan changed")

    // The demo delete of lab-pi-2 purges with errors: partial, never green.
    let lab = ObjectRef(kind: "node", id: DemoWorld.node("lab-pi-2").id, name: "lab-pi-2")
    let labFlow = WriteFlow(intent: FleetIntents.delete(lab, typedName: false), client: client, authenticator: pass)
    let labPlan = try await labFlow.dryRun()
    guard case .finished(.partial(_, _, let message)) = await labFlow.commit(choices: ConfirmChoices(), reviewed: labPlan) else {
        throw CheckFailure.failed("lab-pi-2 delete is partial")
    }
    try expectEqual(message, "Node deleted; 2 log stores could not be purged", "partial delete banner")

    // A line-chain conflict maps to its message.
    let hkg = ObjectRef(kind: "node", id: DemoWorld.node("relay-hkg-1").id, name: "relay-hkg-1")
    guard case .finished(.refused(_, let refusal)) = await WriteFlow(intent: FleetIntents.delete(hkg, typedName: true), client: client, authenticator: pass).commit(choices: ConfirmChoices()) else {
        throw CheckFailure.failed("line-chain conflict refuses")
    }
    try expect(refusal.contains("line chain"), "line-chain conflict message is kept: \(refusal)")

    // Plans file approvals; the beacon plan on a NetGuard node needs netguard:admin.
    let relay = ObjectRef(kind: "node", id: DemoWorld.node("relay-tyo-1").id, name: "relay-tyo-1")
    let beacon = try await client.fleetBeacon(nodeID: relay.id)
    let beaconPlan = FleetIntents.planBeacon(relay, request: beacon.planRequest, netGuard: beacon.carriesNetGuard)
    try expect(beaconPlan.scopes.contains("netguard:admin"), "NetGuard companion adds netguard:admin")
    guard case .finished(.filed(let ids, _, _)) = await WriteFlow(intent: beaconPlan, client: client, authenticator: pass).commit(choices: ConfirmChoices()) else {
        throw CheckFailure.failed("beacon plan files")
    }
    try expectEqual(ids.count, 1, "one beacon approval")
    let sin = ObjectRef(kind: "node", id: DemoWorld.node("edge-sin-1").id, name: "edge-sin-1")
    guard case .finished(.filed) = await WriteFlow(intent: FleetIntents.planAgentUpdate(sin, force: false), client: client, authenticator: pass).commit(choices: ConfirmChoices()) else {
        throw CheckFailure.failed("agent update plan files")
    }

    // Exclude without a reason is refused by the server; with one it lands.
    guard case .finished(.refused) = await WriteFlow(intent: FleetIntents.decideCapability(node, capability: "sshguard", state: "excluded"), client: client, authenticator: pass).commit(choices: ConfirmChoices()) else {
        throw CheckFailure.failed("exclude without a reason is refused")
    }
    _ = await WriteFlow(intent: FleetIntents.decideCapability(node, capability: "sshguard", state: "enrolled"), client: client, authenticator: pass).commit(choices: ConfirmChoices())
    let enrolled = try await client.fetchNodeCapabilities(nodeID: node.id).first { $0.capability == "sshguard" }
    try expectEqual(enrolled.map(FleetCapabilityState.word), "Enrolled", "enrolment shows on the next read")

    // Group delete is blocked while anything names the group.
    let used = try expectUnwrapped(try await WriteFlow(intent: FleetIntents.deleteGroup(ObjectRef(kind: "group", id: "g-asia-edge", name: "Asia edge")), client: client, authenticator: pass).dryRun(), "group dry run")
    try expect(used.blocking, "a used group cannot be deleted")
    let free = try expectUnwrapped(try await WriteFlow(intent: FleetIntents.deleteGroup(ObjectRef(kind: "group", id: "g-us-edge", name: "US edge")), client: client, authenticator: pass).dryRun(), "free group dry run")
    try expect(!free.blocking, "an unused group can be deleted")

    // Static members: add then remove.
    let lab1 = ObjectRef(kind: "node", id: DemoWorld.node("edge-fra-3").id, name: "edge-fra-3")
    let homeLab = ObjectRef(kind: "group", id: "g-home-lab", name: "Home lab")
    _ = await WriteFlow(intent: FleetIntents.setGroupMembers(homeLab, add: [lab1]), client: client, authenticator: pass).commit(choices: ConfirmChoices())
    let added = try await client.fleetGroups().groups.first { $0.id == "g-home-lab" }?.members.contains(lab1.id) == true
    try expect(added, "member added")
    _ = await WriteFlow(intent: FleetIntents.setGroupMembers(homeLab, remove: [lab1]), client: client, authenticator: pass).commit(choices: ConfirmChoices())
    let removed = try await client.fleetGroups().groups.first { $0.id == "g-home-lab" }?.members.contains(lab1.id) == false
    try expect(removed, "member removed")

    // Gate enforcement round trip.
    let gates = try await client.fleetCapabilityGates()
    let singbox = try expectUnwrapped(gates.first { $0.capability == "singbox" }, "singbox gate")
    let on = FleetIntents.setGate(singbox, enforced: true)
    try expectEqual(on.affected.count, singbox.refused.count, "the sheet lists the would-refuse sample")
    _ = await WriteFlow(intent: on, client: client, authenticator: pass).commit(choices: ConfirmChoices())
    let enforcedNow = try await client.fleetCapabilityGates().first { $0.capability == "singbox" }?.enforced == true
    try expect(enforcedNow, "gate enforced")

    // Tiers match the parity matrix.
    try expectEqual(FleetIntents.bulkEnable([node]).tier, .t2, "bulk enable T2")
    try expectEqual(FleetIntents.bulkDisable([node]).tier, .t3, "bulk disable T3")
    try expectEqual(FleetIntents.rotateToken(node).tier, .t3, "rotate token T3")
    try expectEqual(FleetIntents.delete(node, typedName: false).tier, .t4, "delete T4")
    try expectEqual(FleetIntents.clearGeo(node).tier, .t2, "geo clear T2")
    try expectEqual(FleetIntents.resolveGeo(node, ip: "").tier, .t2, "geo resolve T2")
    try expectEqual(FleetIntents.locateAll([node]).tier, .t2, "locate all T2")
    try expectEqual(FleetIntents.agentDebug(node, enabled: true).tier, .t2, "agent debug T2")
    try expectEqual(FleetIntents.rotateBeacon(node).tier, .t3, "beacon rotate T3")
    try expectEqual(FleetIntents.decideCapability(node, capability: "nft", state: "enrolled").tier, .t3, "capability T3")
    try expectEqual(FleetIntents.planAgentUpdate(node, force: true).tier, .plan, "agent update P")
    try expectEqual(FleetIntents.deleteGroup(homeLab).tier, .t4, "group delete T4")
    try expectEqual(FleetIntents.setGroupMembers(homeLab, add: [node]).tier, .t2, "members T2")
    try expectEqual(FleetIntents.setGate(singbox, enforced: false).tier, .t3, "gate T3")
    try expectEqual(FleetIntents.updateIdentity(node, request: FleetNodeUpdateRequest(nodeID: node.id, name: "x", role: "", comment: "", tags: []), changed: ["name"]).tier, .t2, "identity T2")
}

// MARK: - Query fields match nodeFields.ts

private func checkFleetQueryFields() throws {
    // key, aliases, type, unit, flag, sortable: copied from lib/query/nodeFields.ts.
    let expected: [(String, [String], LatticeQueryFieldType, LatticeQueryNumberUnit, Bool, Bool)] = [
        ("name", [], .string, .plain, false, true),
        ("id", [], .string, .plain, false, true),
        ("ip", ["address", "addr"], .list, .plain, false, true),
        ("tag", ["tags", "role"], .list, .plain, false, true),
        ("group", ["groups"], .list, .plain, false, true),
        ("provider", ["isp", "asn"], .list, .plain, false, true),
        ("country", ["cc"], .string, .plain, false, true),
        ("region", ["city", "geo"], .list, .plain, false, true),
        ("os", ["platform"], .list, .plain, false, true),
        ("arch", [], .string, .plain, false, true),
        ("agent", ["version"], .version, .plain, false, true),
        ("cap", ["caps", "capability", "config"], .enumeration, .plain, false, true),
        ("status", [], .enumeration, .plain, false, true),
        ("online", [], .bool, .plain, true, false),
        ("offline", [], .bool, .plain, true, false),
        ("degraded", [], .bool, .plain, true, false),
        ("disabled", [], .bool, .plain, true, false),
        ("never", ["never_reported", "unreported"], .bool, .plain, true, false),
        ("reporting", [], .bool, .plain, true, false),
        ("drift", [], .bool, .plain, true, false),
        ("cpu", [], .number, .percent, false, true),
        ("mem", ["memory"], .number, .percent, false, true),
        ("disk", [], .number, .percent, false, true),
        ("load", ["load1"], .number, .plain, false, true),
        ("rx", [], .number, .rate, false, true),
        ("tx", [], .number, .rate, false, true),
        ("last_seen", ["seen", "lastseen"], .time, .plain, false, true),
        ("uptime", [], .duration, .plain, false, true),
    ]
    let fields = FleetNodeQuery.fields()
    try expectEqual(fields.map(\.key), expected.map(\.0), "node fields in console order")
    for (field, want) in zip(fields, expected) {
        try expectEqual(field.aliases, want.1, "\(field.key) aliases")
        try expectEqual(field.type, want.2, "\(field.key) type")
        try expectEqual(field.unit, want.3, "\(field.key) unit")
        try expectEqual(field.flag, want.4, "\(field.key) flag")
        try expectEqual(field.sortable, want.5, "\(field.key) sortable")
    }
    try expectEqual(FleetNodeQuery.capabilities, ["exec", "root", "terminal", "stream", "poll", "singbox", "singbox-drift", "no-source"], "NODE_CAPABILITIES")
    try expectEqual(FleetNodeQuery.statusOrder, ["never_reported", "offline", "degraded", "disabled", "online"], "attention order")
    try expectEqual(FleetNodeQuery.capabilityWord("Sing-Box"), "singbox", "capability alias")
    try expectEqual(FleetNodeQuery.capabilityWord("drift"), "singbox-drift", "drift alias")
    try expect(FleetNodeQuery.capabilityWord("ssh") == nil, "unknown capability word")
}

private func record(_ id: String, name: String, status: String, cpu: Double = 10, tags: [String] = [], role: String = "edge",
                    groups: [String] = [], city: String? = nil, country: String? = nil, provider: String = "", agent: String? = "0.3.10",
                    runtime: FleetAgentRuntime? = nil, launchSingBox: Bool? = nil, allowlist: [String] = ["0.0.0.0/0"]) -> FleetNodeRecord {
    let node = LatticeNode(
        id: id, name: name, tags: tags, role: role, publicIP: "203.0.113.\(id.count)", agentVersion: agent,
        online: status == "online" || status == "degraded", status: status, lastSeen: Date(timeIntervalSince1970: 1_800_000_000),
        groupIDs: groups, metrics: LatticeMetrics(cpuPercent: cpu, memoryUsed: 50, memoryTotal: 100, diskUsed: 9, diskTotal: 10),
        geo: LatticeGeo(country: country, city: city)
    )
    return FleetNodeRecord(node: node, facts: FleetNodeFacts(id: id, agentRuntime: runtime, launchSingBoxDiscover: launchSingBox,
                                                             agentSourceAllowlist: allowlist, provider: provider, asn: provider.isEmpty ? 0 : 64_501))
}

private func checkFleetQueries() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_060)
    let rows = [
        record("n1", name: "edge-tyo-1", status: "online", cpu: 92, tags: ["edge", "asia"], groups: ["g-asia"], city: "Tokyo", country: "JP",
               provider: "Northwind Cloud", runtime: FleetAgentRuntime(allowExec: true, allowTerminal: true, terminalTransport: "stream", singBoxDiscover: true), launchSingBox: false),
        record("n2", name: "relay-fra-2", status: "offline", cpu: 99, tags: ["relay"], role: "relay", city: "Frankfurt", country: "DE", agent: "0.3.9"),
        record("n3", name: "lab-pi-2", status: "never_reported", tags: ["home", "lab"], role: "lab", agent: nil, allowlist: []),
        record("n4", name: "edge-sjc-1", status: "degraded", cpu: 40, tags: ["edge", "us"], city: "San Jose", country: "US"),
    ]
    let groupName: @Sendable (String) -> String? = { $0 == "g-asia" ? "Asia edge" : nil }
    func names(_ query: String) throws -> [String] {
        guard case .success(let compiled) = FleetNodeQuery.compile(query, groupName: groupName) else {
            throw CheckFailure.failed("query \(query) must compile")
        }
        return LatticeQueryEngine.apply(compiled, to: rows, now: now).map(\.node.name)
    }
    try expectEqual(try names("status:offline"), ["relay-fra-2"], "status filter")
    try expectEqual(try names("status:never"), ["lab-pi-2"], "status alias never")
    try expectEqual(try names("cpu>80"), ["edge-tyo-1"], "cpu reads reporting nodes only, never the offline node's last number")
    try expectEqual(try names("tag:edge -tag:us"), ["edge-tyo-1"], "tag with negation")
    try expectEqual(try names("role:relay"), ["relay-fra-2"], "role is a tag alias")
    try expectEqual(try names(#"group:"Asia edge""#), ["edge-tyo-1"], "group by name")
    try expectEqual(try names("region:tokyo"), ["edge-tyo-1"], "region matches city")
    try expectEqual(try names("country:DE"), ["relay-fra-2"], "country")
    try expectEqual(try names("provider:AS64501"), ["edge-tyo-1"], "provider by ASN")
    try expectEqual(try names("cap:exec"), ["edge-tyo-1"], "capability from the agent runtime")
    try expectEqual(try names("exec"), ["edge-tyo-1"], "bare capability word")
    try expectEqual(try names("is:drift"), ["edge-tyo-1"], "sing-box drift flag")
    try expectEqual(try names("cap:no-source"), ["lab-pi-2"], "no agent source allowlist")
    try expectEqual(try names("agent<0.3.10"), ["relay-fra-2"], "agent version compare")
    try expectEqual(try names("is:reporting sort:-cpu"), ["edge-tyo-1", "edge-sjc-1"], "reporting flag and sort")
    try expectEqual(try names("fra"), ["relay-fra-2"], "bare text search")
    if case .success = FleetNodeQuery.compile("stauts:offline") { throw CheckFailure.failed("a misspelt field is an error") }
    try expectEqual(FleetNodeQuery.apply("stauts:offline", to: rows, now: now).count, rows.count, "an invalid query keeps the list")
}

// MARK: - Pure derivations

private func checkFleetLogic() throws {
    let rows = [
        record("n1", name: "b-online", status: "online", tags: ["edge"], groups: ["g1"], city: "Tokyo", provider: "Northwind Cloud"),
        record("n2", name: "a-online", status: "online", tags: ["edge", "asia"], city: "Tokyo"),
        record("n3", name: "c-offline", status: "offline"),
        record("n4", name: "d-disabled", status: "disabled", groups: ["g1"]),
        record("n5", name: "e-degraded", status: "degraded", city: "Frankfurt"),
        record("n6", name: "f-never", status: "never_reported"),
    ]
    let status = FleetNodeGrouping.sections(rows, by: .status)
    try expectEqual(status.map(\.title), ["Offline", "Degraded", "Never reported", "Online", "Disabled"], "status sections worst first")
    try expectEqual(status[3].records.map(\.node.name), ["a-online", "b-online"], "names sort inside a section")
    let byRegion = FleetNodeGrouping.sections(rows, by: .region)
    try expectEqual(byRegion.map(\.title), ["Frankfurt", "Tokyo", "No location"], "region sections, missing last")
    let byTag = FleetNodeGrouping.sections(rows, by: .tag)
    try expectEqual(byTag.first { $0.title == "edge" }?.records.count, 2, "a node appears under each tag")
    let byGroup = FleetNodeGrouping.sections(rows, by: .group) { $0 == "g1" ? "Lab" : nil }
    try expectEqual(byGroup.first?.title, "Lab", "group names resolve")
    try expectEqual(FleetNodeGrouping.sections(rows, by: .provider).first?.title, "Northwind Cloud", "provider sections")
    try expectEqual(FleetNodeGrouping.sections([], by: .none).count, 0, "no rows, no sections")

    let nodes = rows.map(\.node)
    try expectEqual(FleetHeader.sentence(nodes, allowlist: []), "6 nodes, 2 online", "header")
    try expectEqual(FleetHeader.sentence(nodes, allowlist: Array(repeating: "n", count: 12)), "Confined to 12 nodes. 2 of 6 visible nodes online", "confined header")
    try expectEqual(FleetHeader.duplicates(1), "1 possible duplicate node", "duplicate singular")
    try expectEqual(FleetHeader.sentence(nodes, allowlist: ["*"]), "6 nodes, 2 online", "a star allowlist is unconfined")

    func capability(_ json: String) throws -> NodeCapabilityEffective {
        try JSONDecoder().decode(NodeCapabilityEffective.self, from: Data(json.utf8))
    }
    let excludedOpen = try capability(#"{"capability":"sshguard","enforced":false,"allowed":false,"source":"record","state":"excluded","record_reason":"no port forwarding yet"}"#)
    try expect(!FleetCapabilityState.detail(excludedOpen).contains("not gated"), "an exclusion on an open gate is not called ungated")
    try expect(FleetCapabilityState.detail(excludedOpen).contains("no port forwarding yet"), "the exclusion reason leads")
    try expect(FleetCapabilityState.detail(excludedOpen).contains("Refused even while the gate is off"), "an exclusion refuses on an open gate")
    try expect(!FleetCapabilityState.isDormant(excludedOpen), "an exclusion is not dormant")
    let undecidedOpen = try capability(#"{"capability":"wireguard","enforced":false,"allowed":true,"source":"not-enforced","state":""}"#)
    try expect(FleetCapabilityState.isDormant(undecidedOpen), "undecided on an open gate is dormant")
    try expectEqual(FleetCapabilityState.word(undecidedOpen), "Not decided", "allowed by an open gate is not in scope")
    let derived = try capability(#"{"capability":"vpn","enforced":true,"allowed":true,"source":"derived","state":""}"#)
    try expectEqual(FleetCapabilityState.word(derived), "In scope", "derived allowance reads in scope")

    let renews = Date().addingTimeInterval(12 * 86_400 + 3_600)
    let machine = MachineProfile(id: "m1", nodeID: "n1", vendor: "Northwind Cloud", priceCents: 900, currency: "EUR", renewalCycleRaw: "monthly", nextRenewal: renews)
    let line = FleetMachineLine.detail(machine)
    try expect(line.hasPrefix("Northwind Cloud, ") && line.contains("a month") && line.hasSuffix("renews in 12 days"), "machine row line: \(line)")

    try expectEqual(FleetAgentVersion.newer(than: "0.3.8", in: ["0.3.10", "0.3.9", "0.3.9", "0.3.8", nil]), 2, "two newer versions")
    try expectEqual(FleetAgentVersion.newer(than: "0.3.10", in: ["0.3.10", "0.3.9"]), 0, "newest is not behind")
    try expectEqual(FleetAgentVersion.newest(in: ["0.3.9", "0.3.10", "0.3.7"]), "0.3.10", "semantic newest, not lexical")

    let summary = FleetNodeDeleteSummary(nodeID: "n", nodeName: "x", counters: ["managed_lines": 2, "monitors_stripped": 1, "tasks_deleted": 0])
    let report = FleetDeleteReport.report(summary)
    try expectEqual(report.lines.map(\.group), ["Services", "Configuration", "History"], "grouped by consequence")
    try expectEqual(report.lines.first?.label, "Managed lines", "services first")
    try expect(FleetDeleteReport.requiresTypedName(summary), "managed lines need the typed name")
    try expect(!FleetDeleteReport.requiresTypedName(FleetNodeDeleteSummary(nodeID: "n", nodeName: "x", counters: ["monitors_stripped": 3])), "monitors alone do not")
    try expectEqual(report.fingerprint, "managed_lines=2,monitors_stripped=1,tasks_deleted=0", "fingerprint is every counter in key order")
    try expect(FleetDeleteReport.report(FleetNodeDeleteSummary(nodeID: "n", nodeName: "x", found: false, counters: [:])).blocking, "a missing node blocks")
    guard case .done(let done, nil) = FleetDeleteReport.outcome(summary, node: ObjectRef(kind: "node", id: "n", name: "x")) else {
        throw CheckFailure.failed("a clean delete is done")
    }
    try expectEqual(done, "Deleted node x", "clean delete copy")

    let since = Date(timeIntervalSince1970: 0)
    let until = since.addingTimeInterval(4 * 3_600)
    let history = FleetNodeStatusHistory(initial: "online", events: [
        FleetStatusEvent(at: since.addingTimeInterval(3_700), to: "offline"),
        FleetStatusEvent(at: since.addingTimeInterval(3_800), to: "online"),
        FleetStatusEvent(at: since.addingTimeInterval(3 * 3_600), to: "unknown"),
    ])
    try expectEqual(FleetStatusStrip.cells(history, since: since, until: until, count: 4), [.online, .offline, .online, .unknown], "a short outage keeps its cell")
    try expectEqual(FleetStatusStrip.cells(FleetNodeStatusHistory(initial: "unknown", events: []), since: since, until: until, count: 2), [.unknown, .unknown], "never observed is unknown")
    try expectEqual(FleetNodeStatusHistory(initial: "online", events: [], onlineSeconds: 75, offlineSeconds: 25).onlineShare, 0.75, "online share")

    let selector = FleetGroupSelector(matchTagsAny: ["asia"], matchRoles: ["edge"])
    try expectEqual(selector.sentence, "tag asia, and role edge", "selector sentence")
    let mixed = FleetGroupView(id: "g", name: "G", members: ["n1"], selector: selector)
    try expectEqual(mixed.kind, .mixed, "selector plus members is mixed")
    try expect(mixed.acceptsStaticMembers, "mixed groups take static members")
    try expect(!FleetGroupView(id: "g", name: "G", selector: selector).acceptsStaticMembers, "selector groups do not")
    try expectEqual(FleetGroupRollup(total: 12, online: 11, offline: 1).sentence, "12 nodes, 1 offline", "rollup sentence")
    let candidates = FleetGroupHealth.candidates(FleetGroupView(id: "g", name: "G", members: ["n1"]), nodes: nodes)
    try expect(!candidates.contains { $0.id == "n1" } && candidates.count == 5, "candidates leave out static members")
}

private func geo(_ id: String, _ name: String, status: String, lat: Double, lon: Double, city: String) -> NodeGeoView {
    NodeGeoView(id: id, name: name, status: status, geo: NodeGeoInfo(city: city, lat: lat, lon: lon))
}

private func checkFleetMapClusters() throws {
    let nodes = [
        geo("a", "edge-tyo-1", status: "online", lat: 35.68, lon: 139.69, city: "Tokyo"),
        geo("b", "edge-tyo-2", status: "offline", lat: 35.70, lon: 139.71, city: "Tokyo"),
        geo("c", "edge-tyo-3", status: "degraded", lat: 35.74, lon: 139.73, city: "Tokyo"),
        geo("d", "relay-fra-1", status: "online", lat: 50.11, lon: 8.68, city: "Frankfurt"),
        NodeGeoView(id: "e", name: "home-nas", status: "online"),
        geo("f", "null-island", status: "online", lat: 0, lon: 0, city: ""),
    ]
    let clusters = MapClusters.clusters(nodes)
    try expectEqual(clusters.count, 2, "Tokyo nodes share one half-degree cell")
    let tokyo = try expectUnwrapped(clusters.first, "worst cluster first")
    try expectEqual(tokyo.worst, .offline, "worst member decides the glyph")
    try expectEqual(tokyo.label, "Tokyo, 3 nodes, 1 offline, 1 degraded", "cluster label")
    try expectEqual(tokyo.members.map(\.name), ["edge-tyo-2", "edge-tyo-3", "edge-tyo-1"], "members worst first")
    try expectEqual(MapClusters.unlocated(nodes).map(\.name), ["home-nas", "null-island"], "no geo and the 0,0 sentinel are unlocated")
    try expectEqual(MapClusters.rounded(35.74), 35.5, "rounds to half degrees")
    try expectEqual(MapClusters.rounded(35.76), 36.0, "rounds up past the quarter")

    let europe = MapClusters.clusters([
        geo("g", "relay-ams-1", status: "online", lat: 52.37, lon: 4.90, city: "Amsterdam"),
        geo("h", "relay-fra-2", status: "offline", lat: 50.11, lon: 8.68, city: "Frankfurt"),
        geo("i", "edge-tyo-9", status: "online", lat: 35.68, lon: 139.69, city: "Tokyo"),
    ])
    let zoomedOut = MapClusters.merged(europe, latitudeGap: 6, longitudeGap: 8)
    try expectEqual(zoomedOut.count, 2, "overlapping European pins merge at a world zoom")
    try expectEqual(zoomedOut.first?.worst, .offline, "the merged pin carries the worst glyph")
    try expectEqual(zoomedOut.first?.members.count, 2, "the merged pin sums its members")
    try expectEqual(zoomedOut.first?.place, "Frankfurt and 1 more place", "merged pin place")
    try expectEqual(MapClusters.merged(europe, latitudeGap: 0.5, longitudeGap: 0.5).count, 3, "zoomed in, pins stay apart")

    let world = MapClusters.clusters([
        geo("j", "edge-ams-1", status: "online", lat: 52.37, lon: 4.90, city: "Amsterdam"),
        geo("k", "edge-ams-2", status: "online", lat: 52.37, lon: 4.90, city: "Amsterdam"),
        geo("l", "edge-ams-3", status: "online", lat: 52.37, lon: 4.90, city: "Amsterdam"),
        geo("m", "edge-tyo-1", status: "degraded", lat: 35.68, lon: 139.69, city: "Tokyo"),
        geo("n", "relay-syd-1", status: "degraded", lat: -33.87, lon: 151.21, city: "Sydney"),
        geo("o", "edge-sjc-1", status: "offline", lat: 37.34, lon: -121.89, city: "San Jose"),
    ])
    let opening = try expectUnwrapped(FleetMapFrame.opening(world), "an opening region")
    func inside(_ lat: Double, _ lon: Double, _ latDelta: Double, _ lonDelta: Double) -> (FleetMapCluster) -> Bool {
        { abs($0.latitude - lat) <= latDelta / 2 && abs(FleetMapFrame.wrapped($0.longitude - lon)) <= lonDelta / 2 }
    }
    let hidden = FleetMapFrame.hiddenProblems(world, isShown: inside(opening.centerLatitude, opening.centerLongitude, opening.latitudeDelta, opening.longitudeDelta))
    try expect(hidden.count <= 1, "the map opens over the most problem places, not the most nodes: \(hidden.map(\.place))")
    try expect(!hidden.contains { $0.place == "Tokyo" || $0.place == "Sydney" }, "Asia-Pacific problems open on screen")
    let europeOnly = FleetMapFrame.hiddenProblems(world, isShown: inside(50, 8, 40, 60))
    let view = FleetMapRegion.Result(centerLatitude: 0, centerLongitude: 170, latitudeDelta: 100, longitudeDelta: 100)
    let fiji = FleetMapFrame.screenFraction(latitude: 0, longitude: -170, region: view)
    try expect(abs(fiji.x - 0.7) < 0.001 && abs(fiji.y - 0.5) < 0.001, "screen fraction wraps the antimeridian: \(fiji)")
    try expect(FleetMapFrame.screenFraction(latitude: 60, longitude: 170, region: view).y < 0, "north of the view is above the screen")
    try expectEqual(europeOnly.map(\.place), ["San Jose", "Sydney", "Tokyo"], "problem places outside the view are named, worst first")
}
