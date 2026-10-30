import Foundation
import AstraCore

public func checkAgentUpdates() async throws {
    try checkAgentUpdatesDecoding()
    try checkAgentUpdatesVersions()
    try await checkAgentUpdatesDemo()
    try await checkAgentUpdatesPlanAllBehind()
    try await checkAgentUpdatesLostAnswers()
    try checkAgentUpdatesForceWords()
}

private let auClock = DemoClock(pinned: "2026-10-28T12:00:00Z")!

private func auDemo(_ scenario: DemoScenario = .normal, state: DemoState = DemoState()) -> LatticeClient {
    LatticeClient(baseURL: DemoWorld.baseURL, credential: LatticeCredential(bearerToken: DemoWorld.token),
                  transport: DemoTransport(identity: .pat, scenario: scenario, clock: auClock, state: state))
}

private struct AgentUpdatesAuthStub: WriteAuthenticator {
    func authenticate(reason: String) async -> DeviceAuthOutcome { .cancelled }
}

// MARK: - Decoding

private func checkAgentUpdatesDecoding() throws {
    let policies = try JSONDecoder().decode(AgentUpdatesPolicyList.self, from: json(#"""
    {"policies":[
      {"node_id":"n-a","enabled":true,"auto_plan":false,"target_version":"latest","binary_url":"","sha256":"","install_path":"/usr/local/bin/lattice-agent",
       "service_name":"lattice-agent","last_planned_version":"0.3.10","last_planned_at":"2026-10-28T10:00:00Z","last_error":"boom",
       "last_fetch":{"approval_id":"approval_a","target_version":"0.3.10","at":"2026-10-28T10:05:00Z",
                     "fetches":[{"source":1,"kind":"m.r2","exit_code":28,"bytes":4194304,"seconds":30,"bad_chunks":1},{"source":2,"kind":"cp","exit_code":0,"bytes":7618048,"seconds":6.2}],
                     "exit_code":0,"stage":"done"},
       "created_at":"2026-09-01T00:00:00Z","updated_at":"2026-10-28T10:00:00Z"},
      {"node_id":"n-b","enabled":false,"auto_plan":true,"target_version":"0.3.9","binary_url":"https://downloads.example.com/lattice-agent-linux-amd64",
       "sha256":"ab","install_path":"","service_name":"","last_fetch":null,"created_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-01T00:00:00Z"}
    ]}
    """#)).policies
    try expectEqual(policies.count, 2, "two policies")
    let first = policies[0]
    try expectEqual(first.state, .manual, "enabled without auto is manual")
    try expectEqual(policies[1].state, .disabled, "a disabled policy reads off whatever auto says")
    try expectEqual(AgentUpdatesPolicyState.of(nil), .none, "no policy")
    try expectEqual(first.resolvedTarget(latest: "v0.3.10"), "0.3.10", "latest resolves to the release")
    try expectEqual(policies[1].resolvedTarget(latest: "0.3.10"), "0.3.9", "a pinned target stays")
    let fetch = try expectUnwrapped(first.lastFetch, "last fetch")
    try expectEqual(fetch.outcome, .installed, "done with fetches is installed")
    try expectEqual(fetch.sources.map(\.kind), ["cp", "m.r2"], "finished sources first")
    try expectEqual(fetch.sources.last?.badChunks, 1, "bad chunks counted")
    try expectEqual(fetch.sources.last?.label, "mirror r2", "mirror label")
    try expect(policies[1].lastFetch == nil, "null last_fetch")

    let failed = try JSONDecoder().decode(AgentUpdatesFetch.self, from: json(#"{"approval_id":"a","exit_code":22,"stage":"fetch","fetches":[{"kind":"up","exit_code":22,"bytes":0}]}"#))
    try expectEqual(failed.outcome, .failed, "a non-zero exit failed")
    let kept = try JSONDecoder().decode(AgentUpdatesFetch.self, from: json(#"{"approval_id":"a","exit_code":0,"stage":"done"}"#))
    try expectEqual(kept.outcome, .kept, "nothing fetched kept the binary")
    try expectEqual(kept.sources.first?.seconds, nil, "no sources")

    let release = try JSONDecoder().decode(AgentUpdatesReleaseInfo.self, from: json(#"""
    {"repo":"LatticeNet/lattice-node-agent","channel":"stable","latest_tag":"v0.3.10","latest_version":"0.3.10",
     "release_url":"https://github.com/LatticeNet/lattice-node-agent/releases/tag/v0.3.10","artifacts":["lattice-agent-linux-amd64"],
     "sha256":{"lattice-agent-linux-amd64":"9f2c"},"fetched_at":"2026-10-28T11:53:00Z"}
    """#))
    try expectEqual(release.latestVersion, "0.3.10", "latest version")
    try expectEqual(release.sha256["lattice-agent-linux-amd64"], "9f2c", "digest by file")
    try expect(release.candidates.isEmpty, "candidates are optional")

    let artifacts = try JSONDecoder().decode(AgentUpdatesArtifactListing.self, from: json(#"""
    {"artifacts":[{"version":"0.3.10","os":"linux","arch":"amd64","sha256":"9f2c","size_bytes":11812352,"stored_bytes":11812352,"updated_at":"2026-10-22T12:00:00Z"}],
     "stored_bytes":11812352,"limit_bytes":536870912,"serving_enabled":false}
    """#))
    try expectEqual(artifacts.artifacts.first?.platform, "linux/amd64", "artifact platform")
    try expectEqual(artifacts.servingEnabled, false, "serving disabled")

    let mirrors = try JSONDecoder().decode(AgentUpdatesMirrorsView.self, from: json(#"""
    {"mirrors":[{"id":"r2","name":"","base_url":"https://m.example.org","prefer_for":["g-a"],"priority":10,"enabled":true}],
     "revision":3,"order":[{"node_id":"n-a","name":"a","sources":["mirror:r2","control-plane","upstream"]}],"pending":["approval_m"],
     "health":[{"mirror":"r2","fetches":4,"chunk_failures":1}]}
    """#))
    try expectEqual(mirrors.mirrors.first?.displayName, "r2", "mirror falls back to its id")
    try expectEqual(mirrors.order.first?.sentence(mirrorNames: ["r2": "Object store"]), "Object store, control plane, release host", "order sentence")
    try expectEqual(mirrors.health.first?.chunkFailures, 1, "chunk failures")

    try expectEqual(AgentUpdatesArtifactName.platform("lattice-agent-linux-amd64"), "linux/amd64", "release file platform")
    try expectEqual(AgentUpdatesArtifactName.platform("lattice-agent-darwin-arm64.tar.gz"), "darwin/arm64", "archive platform")
    try expectEqual(AgentUpdatesArtifactName.platform("SHA256SUMS"), nil, "not an agent binary")
}

// MARK: - Versions (agentUpdatesModel.test.ts)

private func checkAgentUpdatesVersions() throws {
    typealias V = AgentUpdatesVersion
    try expect(V.compare("0.3.10", "0.3.9") > 0, "10 is newer than 9")
    try expect(V.compare("v0.3.8", "0.3.9") < 0, "v prefix")
    try expectEqual(V.compare("0.3.9", "v0.3.9"), 0, "equal across v")
    try expect(V.compare("0.3.9-alpha.1", "0.3.9") < 0, "prerelease is older")
    try expect(V.compare("0.3.9-alpha.10", "0.3.9-alpha.2") > 0, "numeric prerelease")
    try expectEqual(V.compare("0.3.9+abc123", "0.3.9"), 0, "build metadata ignored")
    try expect(V.compare("0.3.9-rc.1+abc123", "0.3.9") < 0, "still a prerelease")
    try expectEqual(V.compare("0.3.9-rc.1+abc123", "0.3.9-rc.1+def456"), 0, "metadata ignored on prereleases")
    try expect(V.compare("0.3.9-alpha-2", "0.3.9-alpha-10") < 0, "the tag after the first hyphen is compared whole")
    typealias S = AgentUpdatesStanding
    try expectEqual(S.of(running: "v0.3.9+abc123", latest: "0.3.9"), .current, "current with metadata")
    try expectEqual(S.of(running: "0.3.9", latest: "v0.3.9"), .current, "current")
    try expectEqual(S.of(running: "0.3.3", latest: "0.3.9"), .behind, "behind")
    try expectEqual(S.of(running: "0.4.0-alpha.1", latest: "0.3.9"), .ahead, "ahead")
    try expectEqual(S.of(running: nil, latest: "0.3.9"), .unknown, "no running version")
    try expectEqual(S.of(running: "0.3.9", latest: nil), .unknown, "no latest")

    let slices = AgentUpdatesBulk.distribution(["0.3.9", "0.3.8", "0.3.9", nil, "0.3.3", "0.3.8", "0.3.9"], latest: "0.3.9")
    try expectEqual(slices.map(\.version), ["0.3.9", "0.3.8", "0.3.3", ""], "newest first, unreported last")
    try expectEqual(slices.map(\.count), [3, 2, 1, 1], "counts")
    try expectEqual(slices.map(\.standing), [.current, .behind, .behind, .unknown], "standings")
}

// MARK: - Demo reads and the Nodes view

private func checkAgentUpdatesDemo() async throws {
    let client = auDemo()
    let policies = try await client.agentUpdatesPolicies()
    let release = try await client.agentUpdatesReleaseInfo()
    let artifacts = try await client.agentUpdatesArtifacts()
    let mirrors = try await client.agentUpdatesMirrors()
    let nodes = try await client.fetchNodes()
    try expectEqual(release.latestVersion, AgentUpdatesFixtures.latest, "demo latest")
    try expect(release.artifacts.allSatisfy { AgentUpdatesArtifactName.platform($0) != nil && release.sha256[$0] != nil }, "every release file has a platform and digest")
    try expect(!artifacts.artifacts.isEmpty && artifacts.servingEnabled, "stored artifacts")
    try expectEqual(mirrors.order.count, nodes.count, "an order per readable node")

    let byNode = Dictionary(policies.map { ($0.nodeID, $0) }, uniquingKeysWith: { a, _ in a })
    let rows = nodes.map { AgentUpdatesNodeRow(node: $0, policy: byNode[$0.id], latest: release.latestVersion) }
    let behind = rows.filter { $0.standing == .behind }.map(\.name).sorted()
    try expectEqual(behind, ["edge-ams-1", "edge-lon-1", "edge-sin-1", "edge-sin-2", "lab-pi-2"], "behind nodes")
    let bulk = AgentUpdatesBulk.plan(rows)
    try expectEqual(bulk.plan.map(\.name).sorted(), behind, "every behind node has a policy")
    try expect(bulk.skipped.isEmpty, "none skipped")
    try expect(rows.contains { $0.standing == .unknown }, "never-reported nodes are unknown")
    try expect(rows.contains { $0.policyState == .none } && rows.contains { $0.policyState == .auto } && rows.contains { $0.policyState == .disabled }, "policy states covered")

    func query(_ text: String) throws -> [String] {
        switch LatticeQueryEngine.compile(text, provider: AgentUpdatesQueryFields.self) {
        case .success(let compiled): return LatticeQueryEngine.apply(compiled, to: rows, now: auClock.anchor).map(\.name)
        case .failure(let error): throw CheckFailure.failed("query \(text): \(error)")
        }
    }
    try expectEqual(try query("is:behind").sorted(), behind, "is:behind")
    try expectEqual(try query("policy:off"), ["lab-pi-2"], "policy alias")
    let failedNames = try query("is:failed")
    try expect(failedNames.contains("edge-lon-1"), "is:failed")
    try expectEqual(try query("is:behind -policy:auto sort:name"), behind, "console example")

    // A confined token reads only its nodes' policies and orders.
    let confined = auDemo(.confinedToken)
    let confinedPolicies = try await confined.agentUpdatesPolicies()
    try expect(confinedPolicies.allSatisfy { DemoWorld.confinedNodeIDs.contains($0.nodeID) }, "confined policies")
    let confinedOrder = try await confined.agentUpdatesMirrors().order
    try expect(confinedOrder.allSatisfy { DemoWorld.confinedNodeIDs.contains($0.nodeID) }, "confined orders")
}

// MARK: - Plan all behind: sequential, with the refused half

private func checkAgentUpdatesPlanAllBehind() async throws {
    let targets = ["edge-sin-1", "edge-sin-2", "edge-ams-1", "edge-lon-1", "lab-pi-2"].map {
        ObjectRef(kind: "node", id: DemoWorld.node($0).id, name: $0)
    }
    let intent = AgentUpdatesPlanning.planAllBehind(targets)
    try expectEqual(intent.tier, .plan, "plan all behind is a plan filing")
    try expectEqual(intent.affected.map(\.name), targets.map(\.name), "the sheet lists every node it will try")
    try expectEqual(intent.scopes, ["node:admin", "network:plan"], "scopes")
    let state = DemoState()
    let client = auDemo(state: state)
    let result = await WriteFlow(intent: intent, client: client, authenticator: AgentUpdatesAuthStub()).commit(choices: ConfirmChoices())
    guard case .finished(.filed(let ids, let refused, _)) = result else { throw CheckFailure.failed("plan all behind files, got \(result)") }
    try expectEqual(ids, ["approval_d1002", "approval_d1003", "approval_d1004", "approval_au_\(DemoWorld.node("edge-lon-1").id)"], "open plans answered, one new plan filed")
    try expectEqual(refused.map(\.object.name), ["lab-pi-2"], "the disabled policy is the refused half")
    try expect(refused.first?.reason.contains("not enabled") == true, "the server's reason is kept")
    for id in ids {
        let approval = try await client.fetchApproval(id: id)
        try expect(approval.planHashMatchesServer && approval.isHumanPending, "\(id) reads back by id for BatchReview")
    }
    let events = ApprovalEvents.group(try await ids.asyncMap { try await client.fetchApproval(id: $0) })
    try expectEqual(events.count, 1, "the filed plans are one event group for BatchReview")

    // Single node, and a node already on the target answers 409.
    let one = await WriteFlow(intent: AgentUpdatesPlanning.planOne(targets[3]), client: auDemo(state: state), authenticator: AgentUpdatesAuthStub()).commit(choices: ConfirmChoices())
    guard case .finished(.filed(let single, _, _)) = one else { throw CheckFailure.failed("single plan files, got \(one)") }
    try expectEqual(single.count, 1, "one approval")
    let current = ObjectRef(kind: "node", id: DemoWorld.node("edge-tyo-1").id, name: "edge-tyo-1")
    let noop = await AgentUpdatesPlanning.planSequentially([current], client: auDemo())
    guard case .refused = noop else { throw CheckFailure.failed("a node on the target refuses, got \(noop)") }
}

/// Answers plan posts by node: a timeout for the nodes in `lost`, a 400 for
/// the nodes in `refused`, a filed approval otherwise; and approval listings
/// from `pending`, keyed by node id.
private actor PlanLossTransport: HTTPTransport {
    let lost: Set<String>
    let refused: Set<String>
    let pending: [String: String]
    private(set) var posts = 0

    init(lost: Set<String>, refused: Set<String> = [], pending: [String: String] = [:]) {
        self.lost = lost
        self.refused = refused
        self.pending = pending
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func answer(_ status: Int, _ body: String) -> (Data, URLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
        }
        if request.httpMethod == "POST" {
            posts += 1
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let node = body?["node_id"] as? String ?? ""
            if lost.contains(node) { throw URLError(.timedOut) }
            if refused.contains(node) { return answer(400, #"{"error":"agent update policy is not enabled for this node"}"#) }
            return answer(200, #"{"id":"approval_\#(node)","node_id":"\#(node)","plugin":"agentupdate","action":"agent-update:v1","plan_sha256":"aa","status":"pending"}"#)
        }
        let node = components?.queryItems?.first { $0.name == "node_id" }?.value ?? ""
        let rows = pending[node].map { #"[{"id":"\#($0)","node_id":"\#(node)","plugin":"agentupdate","action":"agent-update:v1","plan_sha256":"aa","status":"pending"}]"# } ?? "[]"
        return answer(200, #"{"approvals":\#(rows),"total":0,"limit":5,"offset":0}"#)
    }
}

private func checkAgentUpdatesLostAnswers() async throws {
    let nodes = ["n-a", "n-b", "n-c"].map { ObjectRef(kind: "node", id: $0, name: "edge-\($0.dropFirst(2))") }
    func client(_ transport: PlanLossTransport) -> LatticeClient {
        LatticeClient(baseURL: URL(string: "https://lattice.example.com")!, credential: LatticeCredential(bearerToken: "lat_check.notasecret"), transport: transport)
    }

    // One answer lost, its plan found on the read back: it counts as filed.
    let found = PlanLossTransport(lost: ["n-b"], pending: ["n-b": "approval_found"])
    let first = await AgentUpdatesPlanning.planSequentially(nodes, client: client(found))
    guard case .filed(let ids, let refused, let notes) = first else { throw CheckFailure.failed("a lost answer with a plan found files, got \(first)") }
    try expectEqual(ids, ["approval_n-a", "approval_n-c", "approval_found"], "the plan found on the read back is filed")
    try expect(refused.isEmpty, "a lost answer is never a refusal")
    try expectEqual(notes.first, "3 plans filed", "summary")
    try expectEqual(await found.posts, 3, "nothing is retried")

    // Lost with no plan found: counted as not confirmed, listed beside the
    // refusals so the Result step names it and the run is never clean.
    let missing = PlanLossTransport(lost: ["n-b"], refused: ["n-c"])
    let second = await AgentUpdatesPlanning.planSequentially(nodes, client: client(missing))
    guard case .filed(_, let refusedHalf, let secondNotes) = second else { throw CheckFailure.failed("one filed plan still files, got \(second)") }
    try expectEqual(refusedHalf.map(\.object.id), ["n-c", "n-b"], "the refusal, then the unconfirmed node")
    try expect(refusedHalf.last?.reason.hasPrefix("Could not confirm") == true, "the unconfirmed node says why")
    try expectEqual(secondNotes.first, "1 plan filed, 1 refused, 1 not confirmed", "summary counts the unconfirmed node apart")
    try expect(!second.isCleanSuccess, "an unconfirmed node is never a clean success")

    let onlyLost = PlanLossTransport(lost: ["n-b"])
    let fourth = await AgentUpdatesPlanning.planSequentially(Array(nodes.prefix(2)), client: client(onlyLost))
    guard case .filed(let fourthIDs, let fourthRefused, _) = fourth else { throw CheckFailure.failed("one filed plan still files, got \(fourth)") }
    try expectEqual(fourthIDs, ["approval_n-a"], "one plan filed")
    try expectEqual(fourthRefused.map(\.object.id), ["n-b"], "a lone unconfirmed node keeps the Result step")
    try expect(!fourth.isCleanSuccess, "one filed and one unconfirmed is partial")

    // Every answer lost: unknown, never "No plan was filed".
    let allLost = PlanLossTransport(lost: ["n-a", "n-b", "n-c"])
    let third = await AgentUpdatesPlanning.planSequentially(nodes, client: client(allLost))
    guard case .unknown(let message) = third else { throw CheckFailure.failed("all answers lost is unknown, got \(third)") }
    try expect(!message.contains("No plan was filed"), "a lost answer never reads as nothing filed")
}

private func checkAgentUpdatesForceWords() throws {
    let node = ObjectRef(kind: "node", id: "n-a", name: "edge-a")
    let down = AgentUpdatesPlanning.planOne(node, force: true, running: "0.4.0-alpha.3", target: "0.3.10")
    try expectEqual(down.title, "Plan agent downgrade for edge-a", "a forced plan on an ahead node says downgrade")
    try expect(down.consequence.contains("downgrade of edge-a from 0.4.0-alpha.3 to 0.3.10"), "downgrade versions named")
    try expect(AgentUpdatesPlanning.planOne(node, force: true, running: "0.3.10", target: "v0.3.10").consequence.contains("reinstalls 0.3.10"), "same version is a reinstall")
    try expect(AgentUpdatesPlanning.planOne(node, force: true, running: "", target: "0.3.10").consequence.contains("cannot be compared"), "unreported version")
    try expect(!AgentUpdatesPlanning.planOne(node).consequence.contains("already runs"), "a plain plan claims nothing about the version")
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for element in self { out.append(try await transform(element)) }
        return out
    }
}
