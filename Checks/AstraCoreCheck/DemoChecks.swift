import Foundation
import AstraCore

public func checkDemo() async throws {
    try checkFixtureRegistry()
    try checkClockTokens()
    try await checkUnmatchedRoute()
    try checkApprovalHashes()
    try await checkNoLiteralTimestamps()
    try checkWorldCoverage()
    try await checkSharedFixturesDecode()
    try await checkScenarios()
    try await checkSessionWrites()
}

private let pinned = DemoClock(pinned: "2026-10-28T12:00:00Z")!

private func demoClient(_ identity: DemoIdentity = .pat, scenario: DemoScenario = .normal, state: DemoState = DemoState()) -> LatticeClient {
    let transport = DemoTransport(identity: identity, scenario: scenario, clock: pinned, state: state)
    return LatticeClient(baseURL: DemoWorld.baseURL, credential: LatticeCredential(bearerToken: DemoWorld.token), transport: transport)
}

/// The uniqueness key has no duplicates, and every GET route whose body is
/// a JSON object names what the Empty scenario serves (section 8.6).
private func checkFixtureRegistry() throws {
    let routes = DemoFixtures.all
    let keys = routes.map(\.uniquenessKey)
    try expectEqual(Set(keys).count, keys.count, "demo routes are unique by method, path, query and body match")
    for route in routes where route.method == "GET" && route.body.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
        try expect(route.emptyBody != nil, "GET \(route.pathPattern) has an object body and must set emptyBody")
    }
}

private func checkClockTokens() throws {
    try expectEqual(
        pinned.substitute(#"{"a":"{{now}}","b":"{{now-12s}}","c":"{{now+3d}}"}"#),
        #"{"a":"2026-10-28T12:00:00Z","b":"2026-10-28T11:59:48Z","c":"2026-10-31T12:00:00Z"}"#,
        "time tokens are served relative to the demo clock"
    )
    try expectEqual(DemoScenario(argument: "failing:/api/monitors"), .failing(prefix: "/api/monitors"), "scenario argument with a prefix")
    for scenario in DemoScenario.allCases {
        try expectEqual(DemoScenario(argument: scenario.argument), scenario, "scenario \(scenario.title) round-trips its argument")
    }
}

private func checkUnmatchedRoute() async throws {
    let transport = DemoTransport(identity: .pat, clock: DemoClock(anchor: Date(), isPinned: true), routes: [])
    let client = LatticeClient(baseURL: DemoWorld.baseURL, credential: LatticeCredential(bearerToken: DemoWorld.token), transport: transport)
    do {
        _ = try await client.fetchHealth()
        throw CheckFailure.failed("an unmatched demo route must not succeed")
    } catch LatticeAPIError.notFound {
        // expected: a missing fixture looks like a missing endpoint
    }
}

/// Every approval fixture carries the real SHA-256 of its plan, except the
/// one flagged mismatch the mismatch screenshot needs.
private func checkApprovalHashes() throws {
    var wrong: [String] = []
    for approval in SharedFixtures.approvals {
        let computed = PlanHasher.sha256Hex(approval.plan)
        if approval.isDeliberateMismatch {
            try expect(computed != approval.planSHA256, "\(approval.id) is the flagged mismatch")
        } else if computed != approval.planSHA256 {
            wrong.append("\(approval.id) \(computed)")
        }
    }
    try expect(wrong.isEmpty, "approval fixtures hash to their plan_sha256:\n" + wrong.joined(separator: "\n"))
    try expectEqual(SharedFixtures.approvals.filter(\.isDeliberateMismatch).count, 1, "exactly one deliberate mismatch")
}

/// Fixture bodies hold `{{now}}` tokens, never literal timestamps. The
/// server's version strings are allowed to look like dates.
private func checkNoLiteralTimestamps() async throws {
    let literal = try NSRegularExpression(pattern: #"20\d\d-\d\d-\d\d"#)
    let allowlist: [String] = []
    func scan(_ text: String, _ label: String) throws {
        let range = NSRange(location: 0, length: (text as NSString).length)
        for match in literal.matches(in: text, range: range) {
            let found = (text as NSString).substring(with: match.range)
            try expect(allowlist.contains(found), "\(label) holds a literal timestamp \(found)")
        }
    }
    let transport = DemoTransport(identity: .pat, clock: pinned)
    for route in DemoFixtures.all {
        try scan(route.body, "\(route.method) \(route.pathPattern) body")
        try scan(route.emptyBody ?? "", "\(route.method) \(route.pathPattern) emptyBody")
        guard route.method == "GET", !route.pathPattern.contains("*") else { continue }
        let answer = try await transport.answer(DemoRequest(identity: .pat, method: "GET", path: route.pathPattern, query: route.query))
        try scan(answer.body, "GET \(route.pathPattern) answer")
    }
}

/// The states section 8.6 requires the screenshots to find.
private func checkWorldCoverage() throws {
    try expectEqual(DemoWorld.nodes.count, 35, "35 invented nodes")
    try expectEqual(Set(DemoWorld.nodes.map(\.id)).count, 35, "node ids are unique")
    try expectEqual(Set(DemoWorld.nodes.map(\.status)), ["online", "degraded", "offline", "never_reported", "disabled"], "nodes in all five honesty states")
    for node in DemoWorld.nodes {
        try expect(node.ipv4.hasPrefix("192.0.2.") || node.ipv4.hasPrefix("198.51.100.") || node.ipv4.hasPrefix("203.0.113."), "\(node.name) uses a documentation IPv4 range")
        try expect(node.ipv6.isEmpty || node.ipv6.hasPrefix("2001:db8:"), "\(node.name) uses the documentation IPv6 range")
    }
    let incidents = SharedFixtures.incidents
    try expect(incidents.contains { $0.state == "open" && $0.severity == "critical" && $0.maintenance.isEmpty && $0.snoozedUntil.isEmpty }, "an open critical incident")
    try expect(incidents.contains { $0.state == "open" && $0.severity == "warning" && !$0.flapping }, "an open warning incident")
    try expect(incidents.contains { $0.state == "open" && $0.severity == "info" }, "an open info incident")
    try expect(incidents.contains { $0.state == "acknowledged" }, "an acknowledged incident")
    try expect(incidents.contains { !$0.snoozedUntil.isEmpty }, "a snoozed incident")
    try expect(incidents.contains { !$0.maintenance.isEmpty }, "a held incident")
    try expect(incidents.contains { $0.id.hasPrefix("pending:") && $0.state == "pending" }, "a derived pending incident")
    try expect(incidents.contains { $0.flapping }, "a flapping incident")
    try expect(incidents.contains { $0.state == "resolved" }, "a resolved incident")
    try expect(incidents.contains { $0.kind == "path.degraded" && $0.state == "open" }, "a path-kind incident")
    let taskStates = Set(SharedFixtures.tasks.map { TaskRunState(serverValue: $0.status) })
    try expectEqual(taskStates, Set(TaskRunState.allCases), "tasks in every run state")
}

/// Every Shared read decodes from the fixtures through a real client.
private func checkSharedFixturesDecode() async throws {
    let client = demoClient()
    let now = pinned.anchor

    let me = try await client.fetchIdentity()
    try expectEqual(Set(me.scopes), Set(TokenPresets.operator.scopes), "the demo token holds the Operator preset")
    try expectEqual(try await client.fetchServerVersion().version, "alpha-0.9.4a2", "demo server version")
    try expectTrue(try await client.fetchHealth().isOK, "demo health")
    try expectTrue(try await client.fetchPluginTrust().warns, "demo plugin trust names a non-official publisher")

    let nodes = try await client.fetchNodes()
    try expectEqual(nodes.count, 35, "demo nodes decode")
    try expectEqual(Set(nodes.map(\.honesty)), Set(NodeHonesty.allCases), "decoded nodes cover every honesty state")
    try expect(nodes.first { $0.name == "relay-fra-2" }?.lastSeen != nil, "an offline node keeps its last report")
    let geo = try await client.fetchNodeGeo()
    try expectEqual(geo.filter(\.hasCoordinate).count, 30, "home lab nodes have no map location")

    let pending = try await client.listHumanPendingApprovals()
    try expectEqual(pending.count, 8, "pending approvals visible to the Operator preset")
    // The listing retires a stale agent update before it answers, so the stale
    // row is rejected with neither decider and reads stale, never failed.
    let retired = try await client.fetchApproval(id: "approval_d1008")
    try expectEqual(retired.status, "rejected", "the stale agent update is served retired")
    try expectEqual(retired.displayState, .stale, "a retired stale agent update reads stale")
    let counts = try await client.countApprovals()
    try expectEqual(counts.pending, 8, "approval counts")
    for approval in pending {
        let loaded = try await client.fetchApproval(id: approval.id)
        let verified = (try? loaded.reviewedPlanSHA256()) != nil
        try expectEqual(verified, approval.id != "approval_d1009", "\(approval.id) verifies on the phone unless it is the mismatch")
    }
    let page = try await client.listApprovals(query: ApprovalQuery(status: "applied", limit: 10))
    try expect(page.approvals.contains { $0.isAutoApprovedLineMeta }, "history holds an automatic line-metadata approval")
    try expectEqual(BadgeCount.compute(approvals: pending, incidents: try await client.listIncidents().incidents, now: now), 8 + 3, "badge: eight approvals and three open warning or critical incidents")

    let incidents = try await client.listIncidents()
    try expectEqual(incidents.incidents.count, SharedFixtures.incidents.count, "every incident decodes")
    try expectEqual(Set(incidents.incidents.map { $0.displayState(now: now) }).count >= 7, true, "incidents cover the display states")
    let resolved = try await client.listIncidents(states: [.resolved], limit: 1)
    try expectEqual(resolved.incidents.first?.id, "inc_d09", "the newest resolution comes first")
    try expectEqual(try await client.listMaintenanceWindows().windows.count, 2, "maintenance windows decode")

    let paths = try await client.fetchPaths(window: .oneHour)
    try expect(paths.judgesDegraded, "the demo server judges degraded")
    try expectEqual(paths.beaconReplans.first?.request?.action, .change, "beacon replans decode with their request")
    let measures = Set(paths.paths.map { $0.displayState(judgesDegraded: true).measure })
    try expectEqual(measures, [.measured, .skipped, .paused], "paths cover measured, skipped and paused")

    let tasks = try await client.listTasks()
    try expectEqual(Set(tasks.map { $0.runState(now: now) }), Set(TaskRunState.allCases), "decoded tasks cover every run state")
    let running = try expectUnwrapped(tasks.first { $0.id == "task_d03" }, "the running task")
    try expectEqual(running.targetStates.values.filter { $0.status == "leased" }.count, 2, "fan-out target records decode")
    let stalled = try expectUnwrapped(tasks.first { $0.id == "task_d04" }?.leaseProgress(), "stalled lease progress")
    try expectEqual(stalled.label, "stopped re-leasing after 3 attempts (the agent restarted during each run), attempt 3 of 3", "stalled label")
    let failed = try await client.listTasks(query: TaskQuery(statuses: ["failed"]))
    try expectEqual(failed.tasks.map(\.id), ["task_d02"], "task status filter")
    try expectEqual(try await client.fetchTaskCounts().running, 1, "task counts")
    try expectEqual(try await client.listTaskResults(taskID: "task_d03").count, 10, "task results by task")

    let audit = try await client.fetchAudit(query: AuditQuery(correlationID: "corr_sshguard", limit: 100))
    try expectEqual(audit.events.count, 4, "audit by correlation")
    try expect(audit.events.allSatisfy { $0.rawJSON.hasPrefix("{\"id\":") }, "audit events keep their raw JSON")

    let expiring = try await client.fetchExpiring(within: 7)
    try expectEqual(expiring.items.map(\.state), ["overdue", "due", "due", "due"], "expiring within a week")

    let ddns = try await client.listDDNS()
    let byNode = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, DDNSNodeAddresses(publicIPv4: $0.publicIP ?? "", publicIPv6: $0.publicIPv6 ?? "", down: $0.honesty != .online && $0.honesty != .degraded)) })
    try expectEqual(ddns.map { $0.health(now: now, node: byNode[$0.nodeID]) }, [.current, .failing, .stale, .current], "DDNS profiles current, failing, stale and a current CNAME")

    let guardRows = try await client.fetchSSHGuardStatus()
    try expectEqual(Set(guardRows.map(\.stage)), Set(SSHGuardBoardStage.allCases.map(\.rawValue)), "SSH Guard rows in every server stage")
    let reverting = SSHGuardBoard.revertingNodes(guardRows, now: now)
    try expect(reverting.contains { $0.nodeName == "edge-tyo-2" && $0.actionableApprovalID == "approval_d1001" }, "one node reverting with an approval to open")
    try expect(guardRows.contains { $0.revertArmed && SSHGuardBoard.revertWindowPassed($0, now: now) }, "one node whose window already closed")
    let one = try await client.fetchSSHGuardStatus(nodeID: DemoWorld.node("edge-tyo-2").id)
    try expectEqual(one.lastArm?.approvalID, "approval_d0904", "one SSH Guard row with its arm history")

    let deliveries = try await client.fetchDeliveries()
    try expect(deliveries.deliveries.contains { $0.outcome == "sent" } && deliveries.deliveries.contains { $0.outcome == "failed" }, "deliveries sent and failed")
}

private func checkScenarios() async throws {
    let refused = try await DemoTransport(identity: .pat, clock: pinned)
        .answer(DemoRequest(identity: .pat, method: "GET", path: "/api/incidents", query: ["state": "active"]))
    try expectEqual(refused.status, 400, "unknown incident state is a 400")
    try expect(refused.body.contains(#"unknown state \"active\""#), "with the server's message")

    let confined = demoClient(scenario: .confinedToken)
    let confinedIdentity = try await confined.fetchIdentity()
    try expectEqual(confinedIdentity.serverAllowlist.count, 12, "Confined token reports its node allowlist")
    try expect(confinedIdentity.scopeSet.isConfined, "Confined token reads as confined")
    try expectEqual(Set(try await confined.fetchNodes().map(\.id)), Set(DemoWorld.confinedNodeIDs), "Confined token lists only its nodes")

    let limited = demoClient(scenario: .limitedToken)
    try expectEqual(Set(try await limited.fetchIdentity().scopes), Set(TokenPresets.triage.scopes), "Limited token reports Triage")
    try expectEqual(try await limited.listHumanPendingApprovals().count, 0, "Triage lists no approvals")
    try expectEqual(try await limited.fetchSSHGuardStatus().count, 0, "Triage reads no SSH Guard rows")
    do {
        _ = try await limited.listDDNS()
        throw CheckFailure.failed("Triage must not read DDNS")
    } catch LatticeAPIError.forbidden {}

    do {
        _ = try await demoClient(scenario: .failing(prefix: nil)).listIncidents()
        throw CheckFailure.failed("Failing must fail incidents")
    } catch LatticeAPIError.server(let status, _, _) {
        try expectEqual(status, 503, "Failing answers 503")
    }

    let stale = demoClient(scenario: .stale)
    _ = try await stale.fetchNodes()
    do {
        _ = try await stale.fetchNodes()
        throw CheckFailure.failed("Stale must fail the second read")
    } catch LatticeAPIError.transport(let code) {
        try expectEqual(code, .timedOut, "Stale times out")
    }

    let forbidden = demoClient(scenario: .forbidden(prefix: nil))
    _ = try await forbidden.listIncidents()
    do {
        _ = try await forbidden.listIncidents()
        throw CheckFailure.failed("Forbidden must refuse after the first load")
    } catch LatticeAPIError.forbidden(let code, _) {
        try expectEqual(code, "forbidden", "Forbidden answers the forbidden code")
    }

    try expectEqual(try await demoClient(scenario: .empty).fetchNodes().count, 0, "Empty serves no nodes")
    try expectEqual(try await demoClient(scenario: .empty).listIncidents().incidents.count, 0, "Empty serves no incidents")
    let empty = demoClient(scenario: .empty)
    try expectEqual(try await empty.countApprovals().pending, 0, "Empty counts no pending approvals")
    try expectEqual(try await empty.listApprovals(query: ApprovalQuery(status: "pending")).approvals.count, 0, "Empty answers a filtered approvals query with an empty envelope")
    try expectEqual(try await empty.listTasks(query: TaskQuery(statuses: ["failed"])).tasks.count, 0, "Empty answers a filtered tasks query with an empty envelope")
    try expectEqual(try await empty.listHumanPendingApprovals().count, 0, "Empty serves no pending approvals")

    do {
        _ = try await demoClient(scenario: .companionBehind(prefix: nil)).fetchApproval(id: "approval_d1001")
        throw CheckFailure.failed("Companion behind must not decode the approval")
    } catch LatticeAPIError.invalidResponse {}

    do {
        _ = try await demoClient(.session, scenario: .noSession).stepUp(code: "123456")
        throw CheckFailure.failed("No session must refuse the session client")
    } catch LatticeAPIError.unauthorized {}

    do {
        _ = try await demoClient(scenario: .offline).fetchHealth()
        throw CheckFailure.failed("Offline must not answer")
    } catch LatticeAPIError.transport(let code) {
        try expectEqual(code, .notConnectedToInternet, "Offline has no network path")
    }

    let quiet = demoClient(scenario: .quiet)
    try expectEqual(try await quiet.listHumanPendingApprovals().count, 0, "Quiet has nothing pending")
    try expectTrue(try await quiet.fetchNodes().allSatisfy { $0.honesty == .online }, "Quiet has every node online")
    try expectTrue(try await quiet.listIncidents().incidents.allSatisfy { $0.state == "resolved" }, "Quiet has only resolved incidents")
}

/// Writes change what later reads show, for the session.
private func checkSessionWrites() async throws {
    let state = DemoState()
    let client = demoClient(state: state)

    // The waiting record follows what the approval asked for, as the server's does.
    let reviewed = try await client.fetchApproval(id: "approval_d1005")
    let approvedOnly = try await client.approveReviewed(reviewed, queueApply: false)
    try expectEqual(approvedOnly.waiting?.code, "not_queued", "approve without queueing waits as not queued")
    try expectEqual(approvedOnly.waiting?.blocked, true, "a not queued approval is blocked")
    let applying = try await client.approveReviewed(try await client.fetchApproval(id: "approval_d1004"), queueApply: true)
    try expectEqual(applying.waiting?.code, "task_running", "approve and apply on a reporting node runs the task")
    let acked = try await client.acknowledgeIncident(id: "inc_d01")
    try expectEqual(acked.state, "acknowledged", "acknowledging answers the acknowledged incident")
    let reread = try await client.listIncidents().incidents.first { $0.id == "inc_d01" }
    try expectEqual(reread?.state, "acknowledged", "the acknowledgment holds for the session")
    let snoozed = try await client.snoozeIncident(id: "inc_d02", minutes: 60)
    try expect(snoozed.snoozedUntil != nil, "snoozing sets snoozed_until")
    let ended = try await client.snoozeIncident(id: "inc_d02", minutes: 0)
    try expectEqual(ended.snoozedUntil, nil, "minutes 0 ends the snooze")

    await state.setValue("approved", for: "approval.status.approval_d1005")
    let decided = try await client.fetchApproval(id: "approval_d1005")
    try expectEqual(decided.status, "approved", "a decision recorded by a route shows on reload")
    try expectEqual(decided.approvedBy, DemoWorld.actorID, "with this actor as the decider")

    let filed = try await client.planAgentUpdate(nodeID: DemoWorld.node("lab-pi-1").id, force: true)
    try expect((try? filed.reviewedPlanSHA256()) != nil, "a filed plan carries the hash of its body")

    let session = demoClient(.session)
    do {
        _ = try await session.stepUp(code: "000000")
        throw CheckFailure.failed("000000 is the demo's wrong code")
    } catch LatticeAPIError.unauthorized(let message) {
        try expect(message.hasPrefix("invalid second factor"), "a wrong code keeps the server's message: \(message)")
    }
    let grant = try await session.stepUp(code: "123456")
    try expect(grant.isUsable(now: pinned.anchor), "a demo grant is usable for a minute")

    let login = LatticeClient(baseURL: DemoWorld.baseURL, transport: DemoTransport(identity: .session, clock: pinned))
    do {
        _ = try await login.login(username: "ops", password: "demo")
        throw CheckFailure.failed("demo sign-in asks for a code")
    } catch LatticeAPIError.totpRequired(let challenge) {
        let signedIn = try await login.loginTOTP(challengeID: challenge, code: "123456")
        try expectEqual(signedIn.sessionCookie, "sess_demo_notasecret", "the demo session cookie")
        try expect(signedIn.expiresAt != nil, "the cookie's Max-Age gives the session an expiry")
    }
}

/// `expect` for a value computed with `await`, which an autoclosure cannot hold.
private func expectTrue(_ condition: Bool, _ message: String) throws {
    try expect(condition, message)
}
