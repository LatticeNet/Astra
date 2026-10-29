import Foundation
import AstraCore

public func checkShared() async throws {
    try checkNodeDecoding()
    try checkURLAndRequests()
    try await checkLoginFlow()
    try checkNodeHonesty()
    try checkFormatters()
    try await checkIdentityAndAudit()
    try await checkApprovalListing()
    try await checkErrorMapping()
    try checkScopes()
    try checkPathKeysAndSeal()
    try checkDeepLinks()
    try await checkWriteFlowCancel()
    try checkIncidentFilters()
}

private func checkNodeDecoding() throws {
    let nodesJSON = """
    [
      {
        "id": "node-b",
        "name": "Tokyo Edge",
        "tags": ["edge", "jp"],
        "role": "edge",
        "wireguard_ip": "10.8.0.2",
        "public_ip": "203.0.113.10",
        "public_ipv6": "2001:db8::10",
        "agent_version": "0.2.0",
        "online": true,
        "last_seen": "2026-06-17T02:00:00Z",
        "metrics": {
          "cpu_percent": 12.5,
          "load1": 0.42,
          "load5": 0.38,
          "load15": 0.31,
          "memory_used": 1073741824,
          "memory_total": 4294967296,
          "disk_used": 53687091200,
          "disk_total": 107374182400,
          "net_rx_bytes": 123456,
          "net_tx_bytes": 654321,
          "net_rx_speed": 2048.5,
          "net_tx_speed": 1024.25,
          "uptime_seconds": 3600,
          "collected_at": "2026-06-17T01:59:50Z"
        },
        "host_facts": {
          "hostname": "tokyo-edge",
          "os": "linux",
          "platform": "debian",
          "platform_version": "12",
          "kernel_version": "6.1.0",
          "arch": "amd64",
          "cpu_cores": 4,
          "cpu_model": "AMD EPYC",
          "memory_total": 4294967296,
          "swap_total": 1073741824,
          "virtualization": "kvm",
          "reported_at": "2026-06-17T01:58:00Z"
        },
        "geo": {
          "country": "JP",
          "city": "Tokyo",
          "lat": 35.6762,
          "lon": 139.6503
        },
        "created_at": "2026-06-16T00:00:00Z"
      },
      {
        "id": "node-a",
        "name": "Disabled Node",
        "online": true,
        "disabled": true,
        "last_seen": "2026-06-17T02:00:00Z",
        "metrics": {},
        "host_facts": {},
        "created_at": "2026-06-16T00:00:00Z"
      }
    ]
    """.data(using: .utf8)!

    let nodes = try LatticeDecoder.decodeNodes(from: nodesJSON)
    try expectEqual(nodes.map(\.id), ["node-a", "node-b"], "nodes sort by id")
    let edge = try expectUnwrapped(nodes.first(where: { $0.id == "node-b" }), "edge node")
    try expectEqual(edge.name, "Tokyo Edge", "node name")
    try expectEqual(edge.hostFacts.hostname, "tokyo-edge", "host hostname")
    try expectEqual(edge.hostFacts.cpuCores, 4, "host cpu cores")
    try expectEqual(edge.metrics.cpuPercent, 12.5, "cpu")
    try expectEqual(edge.metrics.load5, 0.38, "load5")
    try expectEqual(edge.metrics.load15, 0.31, "load15")
    try expectEqual(edge.metrics.netRxSpeed, 2048.5, "net rx speed")
    try expectEqual(edge.metrics.netTxSpeed, 1024.25, "net tx speed")
    try expectEqual(edge.memoryUsedFraction, 0.25, "memory fraction")
    try expectEqual(edge.diskUsedFraction, 0.5, "disk fraction")
    try expectEqual(edge.geo?.country, "JP", "geo country")
    let referenceDate = ISO8601DateFormatter().date(from: "2026-06-17T02:01:00Z")!
    try expect(!edge.isOffline(referenceDate: referenceDate, timeout: 180), "online node should not be offline")
    let disabled = try expectUnwrapped(nodes.first(where: { $0.id == "node-a" }), "disabled node")
    try expect(disabled.isOffline(referenceDate: referenceDate, timeout: 180), "disabled node is treated as unavailable")

    do {
        _ = try LatticeDecoder.decodeNodes(from: #"{"error":{"code":"forbidden","message":"missing node:read","request_id":"req_1"}}"#.data(using: .utf8)!)
        throw CheckFailure.failed("expected API error")
    } catch LatticeAPIError.server(_, let code, let message) {
        try expectEqual(code, "forbidden", "api error code")
        try expectEqual(message, "missing node:read (request_id: req_1)", "api error message includes request id")
    }
}

private func checkURLAndRequests() throws {
    try expectEqual(
        AstraURLNormalizer.serviceURL(from: "lattice.example.com:8088")?.absoluteString,
        "https://lattice.example.com:8088",
        "service URL normalizes host and port without scheme"
    )
    try expectEqual(
        AstraURLNormalizer.serviceURL(from: " http://192.168.1.20:8088 ")?.absoluteString,
        "http://192.168.1.20:8088",
        "service URL trims and keeps explicit http scheme"
    )
    try expectEqual(
        AstraURLNormalizer.latticeDashboardURL(from: "https://lattice.example.com/api/nodes?x=1#top")?.absoluteString,
        "https://lattice.example.com",
        "dashboard URL strips API path"
    )
    try expectEqual(
        AstraURLNormalizer.latticeDashboardURL(from: "https://lattice.example.com/panel/api/nodes")?.absoluteString,
        "https://lattice.example.com/panel",
        "dashboard URL preserves reverse proxy prefix"
    )

    let bearerClient = LatticeClient(
        baseURL: URL(string: "https://lattice.example.com/panel/api")!,
        credential: LatticeCredential(bearerToken: " pat-token\n")
    )
    let bearerRequest = try bearerClient.buildRequest(path: "/api/nodes")
    try expectEqual(bearerRequest.url?.absoluteString, "https://lattice.example.com/panel/api/nodes", "nodes endpoint")
    try expectEqual(bearerRequest.value(forHTTPHeaderField: "Authorization"), "Bearer pat-token", "bearer auth header")
    try expectEqual(bearerRequest.value(forHTTPHeaderField: "Cookie"), nil, "bearer auth does not send session cookie")

    let sessionClient = LatticeClient(
        baseURL: URL(string: "https://lattice.example.com")!,
        credential: LatticeCredential(sessionCookie: "session-id", csrfToken: "csrf")
    )
    let sessionRequest = try sessionClient.buildRequest(path: "/api/nodes")
    try expectEqual(sessionRequest.url?.absoluteString, "https://lattice.example.com/api/nodes", "session endpoint")
    try expectEqual(sessionRequest.value(forHTTPHeaderField: "Cookie"), "lattice_session=session-id", "session cookie header")
    try expectEqual(sessionRequest.value(forHTTPHeaderField: "Authorization"), nil, "session auth does not send bearer")

    let loginRequest = try LatticeClient(baseURL: URL(string: "https://lattice.example.com/panel")!)
        .buildLoginRequest(username: "admin", password: "secret")
    try expectEqual(loginRequest.url?.absoluteString, "https://lattice.example.com/panel/api/login", "login endpoint")
    try expectEqual(loginRequest.httpMethod, "POST", "login method")
    try expectEqual(loginRequest.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8", "login content type")
    let body = try expectUnwrapped(loginRequest.httpBody, "login request body")
    let object = try expectUnwrapped(JSONSerialization.jsonObject(with: body) as? [String: Any], "login JSON object")
    try expectEqual(object["username"] as? String, "admin", "login username")
    try expectEqual(object["password"] as? String, "secret", "login password")
}

private func checkLoginFlow() async throws {
    let transport = MockTransport(responses: [
        "https://lattice.example.com/api/nodes": (
            200,
            """
            [
              {"id":"node-a","name":"A","online":true,"last_seen":"2026-06-17T02:00:00Z","metrics":{},"host_facts":{},"created_at":"2026-06-16T00:00:00Z"}
            ]
            """.data(using: .utf8)!
        ),
        "https://lattice.example.com/api/login": (
            200,
            #"{"csrf_token":"csrf-123","actor_id":"admin"}"#.data(using: .utf8)!
        ),
        "https://lattice.example.com/api/login/totp": (
            403,
            #"{"error":{"code":"forbidden","message":"missing auth:login","request_id":"req_totp"}}"#.data(using: .utf8)!
        )
    ], headers: [
        "https://lattice.example.com/api/login": [
            "Set-Cookie": "lattice_session=session-123; Path=/; HttpOnly; SameSite=Strict"
        ]
    ])

    let client = LatticeClient(
        baseURL: URL(string: "https://lattice.example.com")!,
        credential: LatticeCredential(bearerToken: "pat"),
        transport: transport
    )
    let nodes = try await client.fetchNodes()
    try expectEqual(nodes.map(\.name), ["A"], "fetch nodes")
    try expectEqual(await transport.authorizationHeaders, ["Bearer pat"], "fetch auth headers")

    let session = try await LatticeClient(
        baseURL: URL(string: "https://lattice.example.com")!,
        transport: transport
    ).login(username: "admin", password: "secret")
    try expectEqual(session.actorID, "admin", "login actor id")
    try expectEqual(session.csrfToken, "csrf-123", "login csrf")
    try expectEqual(session.sessionCookie, "session-123", "login cookie")

    do {
        _ = try await LatticeClient(
            baseURL: URL(string: "https://lattice.example.com")!,
            transport: transport
        ).loginTOTP(challengeID: "challenge", code: "000000")
        throw CheckFailure.failed("expected TOTP API error")
    } catch LatticeAPIError.forbidden(let code, let scope) {
        try expectEqual(code, "forbidden", "TOTP api error code")
        try expectEqual(scope, nil, "TOTP api error names no scope")
    }
}

private func checkNodeHonesty() throws {
    let json = """
    {"id":"node-b","name":"Tokyo Edge","online":true,"status":"degraded",
     "status_reason":"Reporting, but sing-box has been down.","reachability":"online",
     "last_seen":"2026-06-17T02:00:00Z","metrics":{},"host_facts":{},"created_at":"2026-06-16T00:00:00Z"}
    """.data(using: .utf8)!
    let node = try JSONDecoder().decode(LatticeNode.self, from: json)
    try expectEqual(node.honestyWord, "degraded", "status honesty prefers server status")
    try expect(node.needsAttention, "degraded needs attention")
    try expectEqual(node.statusReason.contains("sing-box"), true, "status reason decoded")
}

private func checkFormatters() throws {
    let now = ISO8601DateFormatter().date(from: "2026-06-17T02:00:00Z")!
    try expectEqual(UptimeFormatter.string(seconds: 90_061), "1d 1h", "uptime formats days+hours")
    try expectEqual(RelativeDateFormatter.shortDuration(3_600), "1h", "relative duration hours")
    try expectEqual(RelativeDateFormatter.string(from: now.addingTimeInterval(-120), now: now), "2m ago", "relative date ago")

    let nanGeo = NodeGeoView(id: "nan", geo: NodeGeoInfo(lat: .nan, lon: 10))
    try expect(!nanGeo.hasCoordinate, "NaN is not a map coordinate")
}

private func checkIdentityAndAudit() async throws {
    let transport = MockTransport(responses: [
        "https://lattice.example.com/api/me": (
            200,
            #"{"actor_id":"admin","username":"admin","token_id":"tok1","scopes":["node:read","node:admin","*"],"csrf_token":"c","totp_enabled":true,"server_allowlist":["node-a"]}"#.data(using: .utf8)!
        ),
        "https://lattice.example.com/api/audit?limit=200&offset=0&decision=deny": (
            200,
            #"{"events":[{"id":"a1","at":"2026-06-17T02:00:00Z","actor_id":"admin","action":"node.disable","decision":"deny","reason":"missing scope"}],"total":1,"limit":200,"offset":0}"#.data(using: .utf8)!
        ),
    ])
    let session = LatticeClient(baseURL: URL(string: "https://lattice.example.com")!, credential: LatticeCredential(sessionCookie: "sid", csrfToken: "csrf-token"), transport: transport)

    let me = try await session.fetchIdentity()
    try expectEqual(me.actorID, "admin", "me actor id")
    try expect(me.totpEnabled, "me totp enabled")
    try expect(me.hasScope("node:read"), "me has explicit scope")
    try expect(me.hasScope("inventory:read"), "me has wildcard scope via *")
    try expectEqual(me.serverAllowlist, ["node-a"], "me server allowlist")
    try expect(me.scopeSet.isConfined, "allowlist confines the scope set")

    let audit = try await session.fetchAudit(limit: 200, decision: "deny")
    try expectEqual(audit.total, 1, "audit total")
    try expect(audit.events.first?.isDeny ?? false, "audit deny decision parsed")
}

private func checkApprovalListing() async throws {
    // SHA-256 plan hash (known vectors), used for the approve TOCTOU defense.
    try expectEqual(PlanHasher.sha256Hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "sha256 of empty string")
    try expectEqual(PlanHasher.sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 of abc")

    let planBody = "table inet lattice_guard {}"
    let planHash = PlanHasher.sha256Hex(planBody)
    let transport = MockTransport(responses: [
        "https://lattice.example.com/api/network/approvals?status=pending": (200, ApprovalSamples.pendingList(planHash: planHash).data(using: .utf8)!),
        "https://lattice.example.com/api/network/approvals?count=1": (
            200, #"{"counts":{"pending":2,"approved":1,"stale":1,"applied":0,"rejected":0,"dismissed":0,"total":4}}"#.data(using: .utf8)!
        ),
        "https://lattice.example.com/api/network/approvals?id=ap1": (200, ApprovalSamples.byID(planBody: planBody, planHash: planHash).data(using: .utf8)!),
        "https://lattice.example.com/api/network/approvals?id=ap-wait": (200, ApprovalSamples.waiting(planBody: planBody, planHash: planHash).data(using: .utf8)!),
        "https://lattice.example.com/api/sshguard/status?node_id=node-a": (
            200,
            #"{"ok":true,"node":{"node_id":"node-a","node_name":"Edge","enrolled":true,"posture":{"state":"secured","key_access":true,"reason":"key only"},"knock_gate":true,"stage":"confirmed","knock":{"knowledge":"installed","revealable":true,"requires_step_up":true,"interactive_only":true,"note":"web only"}},"nodes":[]}"#.data(using: .utf8)!
        ),
    ])
    let client = LatticeClient(baseURL: URL(string: "https://lattice.example.com")!, credential: LatticeCredential(sessionCookie: "sid", csrfToken: "csrf-token"), transport: transport)

    let listed = try await client.listApprovals(status: "pending")
    try expectEqual(listed.count, 3, "pending listing count")
    let listRow = try expectUnwrapped(listed.first, "listing row")
    try expect(!listRow.hasPlanBody, "listing omits plan body")
    try expectEqual(listRow.planSHA256, planHash, "listing carries plan_sha256")
    try expectEqual(listRow.planHash, PlanHasher.sha256Hex(""), "hashing a listing row hashes empty plan")
    do {
        _ = try listRow.reviewedPlanSHA256()
        throw CheckFailure.failed("listing row must not be hash-bindable")
    } catch ApprovalReviewError.emptyPlan {
        // expected
    }
    try expect(listRow.isHumanPending, "human pending nft row")
    try expectEqual(listRow.displayState, .needsYou, "human pending row needs you")
    let linemeta = try expectUnwrapped(listed.first(where: { $0.id == "ap-linemeta" }), "linemeta row")
    try expect(linemeta.isAutoApprovedLineMeta, "system linemeta is auto-approved class")
    try expect(!linemeta.isHumanPending, "linemeta skipped from human inbox")
    let staleApproval = try expectUnwrapped(listed.first(where: { $0.id == "ap-stale" }), "stale approval decoded")
    try expect(staleApproval.isPending, "stale approval can remain pending until server cleanup")
    try expect(staleApproval.isStale, "stale approval exposes structured stale flag")
    try expect(!staleApproval.isApprovable, "stale approval is not approvable")
    try expect(staleApproval.reason.contains("re-plan"), "stale reason decoded")
    try expectEqual(staleApproval.displayState, .stale, "stale display state")

    let human = listed.filter(\.isHumanPending)
    try expectEqual(human.map(\.id), ["ap1", "ap-stale"], "human pending skips linemeta")

    let counts = try await client.countApprovals()
    try expectEqual(counts.pending, 2, "count pending")

    let loaded = try await client.fetchApproval(id: "ap1")
    try expect(loaded.hasPlanBody, "get-by-id carries plan")
    try expectEqual(try loaded.reviewedPlanSHA256(), planHash, "reviewed hash matches server")
    try expectEqual(loaded.pluginVersion, "1.2.3", "plugin version")
    try expectEqual(loaded.targets, ["node-a"], "targets")
    try expectEqual(loaded.proofLine, "plan \(planHash.prefix(4))… · 1 target", "proof line")

    let waiting = try await client.fetchApproval(id: "ap-wait")
    try expectEqual(waiting.waiting?.code, "node_offline", "waiting code")
    try expect(waiting.waiting?.blocked == true, "waiting blocked")
    try expect(waiting.proofLine.contains("waiting"), "waiting proof line")
    try expectEqual(waiting.displayState, .waiting, "blocked approved row reads waiting")

    let guardStatus = try await client.fetchSSHGuardStatus(nodeID: "node-a")
    try expectEqual(guardStatus.posture.state, "secured", "ssh guard posture")
    try expect(guardStatus.knockGate, "knock gate present")
    try expectEqual(SSHGuardBoard.coverage(for: guardStatus, scope: .enrolled, now: Date()), .confirmed, "confirmed stage covers the node")

    let badge = BadgeCount.compute(approvals: listed, incidents: [
        Incident(id: "i1", severity: "critical", state: "open"),
        Incident(id: "i2", severity: "info", state: "open"),
        Incident(id: "i3", severity: "warning", state: "acknowledged"),
    ])
    try expectEqual(badge, 3, "badge counts human pending approvals and open warning or critical incidents")
}

private func checkErrorMapping() async throws {
    let stepUp = json(#"{"error":{"code":"unauthorized","message":"invalid second factor"}}"#)
    try expectEqual(await LatticeErrorProbe.map(status: 401, body: stepUp), .unauthorized(message: "invalid second factor"), "401 keeps the step-up message")
    let findings = json(#"{"error":"plan blocked by lint findings","findings":[{"code":"lockout","severity":"block","message":"SSH would be closed"}]}"#)
    try expectEqual(await LatticeErrorProbe.map(status: 409, body: findings), .conflict(code: "conflict", findings: ["SSH would be closed"]), "409 carries findings")
    let stale = json(#"{"error":{"code":"approval_stale","message":"plan changed"}}"#)
    try expectEqual(await LatticeErrorProbe.map(status: 409, body: stale), .conflict(code: "approval_stale", findings: []), "409 keeps the envelope code")
    try expectEqual(await LatticeErrorProbe.map(status: 404, body: Data()), .notFound, "404 without a body")
    try expectEqual(await LatticeErrorProbe.map(status: 503, body: Data()), .server(status: 503, code: nil, message: ""), "503 without a body")
    try expectEqual(LatticeAPIError(URLError(.timedOut)), .transport(.timedOut), "URLError maps to transport")
}

private func checkScopes() throws {
    let triage = ScopeSet(scopes: TokenPresets.triage.scopes)
    try expect(triage.allows("monitor:admin"), "triage acknowledges incidents")
    try expect(!triage.allows("network:plan"), "triage cannot plan")
    try expect(ScopeSet(scopes: ["sshguard:admin"]).allows("sshguard:read"), "sshguard admin implies read")
    try expect(!ScopeSet(scopes: ["node:admin"]).allows("node:read"), "no other admin scope implies read")
    try expect(ScopeSet(scopes: ["proxy:read"]).allows("vpncore:read"), "proxy read satisfies vpncore read")
    try expect(!ScopeSet(scopes: ["*"]).allows("secrets:reveal"), "no wildcard satisfies secrets:reveal")
    try expect(ScopeSet(scopes: ["node:*"]).allows("node:admin"), "area wildcard")
    let confined = ScopeSet(scopes: ["*"], serverAllowlist: ["node-a"])
    try expect(!confined.allows("node:read", nodeID: "node-b"), "allowlist confines node checks")
    try expect(!confined.allows(ApprovalVisibility.readRequirement(plugin: "proxycore")), "proxy plans need an unconfined token")
    try expectEqual(ApprovalVisibility.hiddenPlugins(scopes: triage).contains("SSH Guard"), true, "triage cannot list SSH Guard approvals")
    try expectEqual(TokenPresets.operatorPlusRoot.scopes.contains("terminal:open"), true, "root preset carries terminal:open")
}

private func checkPathKeysAndSeal() throws {
    try expectEqual(encodePathKey(.pair(source: "tokyo-1", targetNode: "fra-2")), "tokyo-1~fra-2", "pair key")
    try expectEqual(encodePathKey(.check(source: "", monitorID: "m1")), "_~@m1", "control plane check key")
    try expectEqual(decodePathKey("_~@m1"), .check(source: "", monitorID: "m1"), "decode check key")
    try expectEqual(decodePathKey("~x"), nil, "empty source is not a key")
    try expectEqual(PlanSeal.short("3f9a00000000c210"), "3f9a…c210", "compact seal")
    try expectEqual(PlanSeal.groups("abcdefgh12"), ["abcd", "efgh", "12"], "seal groups")
    try expectEqual(PathReason.sentence(for: "node_offline"), "source offline", "path reason alias")
    try expectEqual(PathDisplayState(state: "degraded", reason: "degraded_loss", judgesDegraded: false), .unknown(PathReason(rawValue: "degraded_loss")), "degraded needs a judging server")
}

private func checkDeepLinks() throws {
    let approvalLink = try expectUnwrapped(LatticeDeepLink(url: URL(string: "lattice://approvals/ap1")!), "approval deep link")
    try expectEqual(approvalLink, LatticeDeepLink.approval(id: "ap1"), "custom scheme approval deep link")
    let console = URL(string: "https://lattice.example.org")!
    let nodeLink = try expectUnwrapped(LatticeDeepLink(url: URL(string: "https://lattice.example.org/nodes/node-a")!, console: console), "node deep link")
    try expectEqual(nodeLink, LatticeDeepLink.node(id: "node-a"), "https node path")
    try expectEqual(LatticeDeepLink(url: URL(string: "https://elsewhere.example.net/nodes/node-a")!, console: console), nil, "foreign host stays in the browser")
    for link: LatticeDeepLink in [
        .incident(id: "pending:node.offline/edge 1"),
        .path(key: "_~@m1"),
        .taskNode(taskID: "t1", nodeID: "n1"),
        .monitoring(segment: .paths, view: "chains", query: "source:tokyo-1"),
        .activity(scope: .approvals, view: .stuck, query: nil),
        .node(id: "n1", view: .settings),
        .settingsConnection,
    ] {
        let url = try expectUnwrapped(link.customURL, "custom URL for \(link)")
        try expectEqual(LatticeDeepLink(url: url), link, "round trip \(url.absoluteString)")
    }
    try expectEqual(
        LatticeConsolePath.check(id: "m1").url(console: console).absoluteString,
        "https://lattice.example.org/monitoring?view=checks&open=m1",
        "check console route"
    )
}

private struct CancellingAuthenticator: WriteAuthenticator {
    func authenticate(reason: String) async -> DeviceAuthOutcome { .cancelled }
}

private func checkWriteFlowCancel() async throws {
    let transport = MockTransport(responses: [:])
    let client = LatticeClient(baseURL: URL(string: "https://lattice.example.com")!, transport: transport)
    let intent = WriteIntent(
        tier: .t3,
        verb: "Disable node",
        object: ObjectRef(kind: "node", id: "n1", name: "edge-tyo-3"),
        scopes: ["node:admin"],
        consequence: "edge-tyo-3 can no longer authenticate.",
        changes: [.nodes],
        perform: { client, _ in
            try await client.setNodeDisabled(nodeID: "n1", disabled: true)
            return .done("Disabled edge-tyo-3")
        }
    )
    let result = await WriteFlow(intent: intent, client: client, authenticator: CancellingAuthenticator()).commit(choices: ConfirmChoices())
    guard case .cancelled = result else { throw CheckFailure.failed("cancelled authentication must end the flow") }
    try expectEqual(await transport.requestURLs.count, 0, "cancelled authentication sends nothing")
}

private func checkIncidentFilters() throws {
    let now = Date()
    let snoozed = {
        var incident = Incident(id: "i1", severity: "warning", state: "open")
        incident.snoozedUntil = now.addingTimeInterval(600)
        return incident
    }()
    try expect(IncidentFilter.snoozed.matches(snoozed, now: now), "snoozed into the future")
    try expect(!IncidentFilter.open.matches(snoozed, now: now), "open excludes snoozed")
    try expectEqual(snoozed.displayState(now: now), .snoozed(until: snoozed.snoozedUntil), "snoozed display state")
    try expectEqual(IncidentActions.of(Incident(id: "pending:k", state: "open"), now: now, canAdmin: true), .none, "derived pending accepts no writes")
    try expectEqual(IncidentServerState.allCases.map(\.rawValue), ["pending", "open", "acknowledged", "resolved"], "only the server's four states exist")
}
