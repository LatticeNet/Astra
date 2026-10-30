import Foundation
import AstraCore

public func checkShared() async throws {
    try checkIdentifierText()
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
    try checkAuthorityNote()
    try await checkRefusalMapping()
    try await checkGatewayTimeoutIsUnknown()
    try checkForbiddenClassification()
    try await checkQueryEncodingAndWindowEnd()
    try checkIncidentFilters()
    try checkQueryVectors()
    try checkScopeGoldens()
    try checkApprovalVisibilityGoldens()
    try checkTokenPresetCoverage()
    try checkIncidentOrdering()
    try await checkIncidentStatesNeverSent()
    try checkSSHGuardBoard()
    try checkPathDerivation()
    try checkBadgeAndDDNS()
    try checkTaskLease()
    try checkVerdicts()
    try checkDeepLinkGoldens()
    try checkRawJSONSlices()
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
    // The PAT rides every request, so cleartext is for local servers only.
    for local in ["http://localhost:8088", "http://10.0.0.5", "http://172.20.1.1:80", "http://nas.local", "http://[fd00::5]:8088", "http://127.0.0.1"] {
        try expect(AstraURLNormalizer.serviceURL(from: local) != nil, "\(local) is a local server and may use http")
    }
    for remote in ["http://lattice.example.com", "http://203.0.113.10", "http://172.32.0.1", "http://192.169.0.1", "ftp://lattice.example.com"] {
        try expectEqual(AstraURLNormalizer.serviceURL(from: remote), nil, "\(remote) is refused in cleartext")
    }
    try expect(AstraURLNormalizer.serviceURL(from: "https://203.0.113.10") != nil, "https is allowed anywhere")
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
    } catch LatticeAPIError.forbidden(let code, let message) {
        try expectEqual(code, "forbidden", "TOTP api error code")
        try expect(!message.isEmpty, "TOTP api error keeps the server's message")
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
    let posix = Locale(identifier: "en_US_POSIX")
    let stamped = "No report since 2026-10-29T03:20:00Z; the control plane stops trusting a node after 1m30s of silence."
    let local = TimeDisplay.localizingStamps(in: stamped, mode: .utc, locale: posix)
    try expect(!local.contains("2026-10-29T03:20:00Z") && local.contains(TimeDisplay.dateTime(ISO8601DateFormatter().date(from: "2026-10-29T03:20:00Z")!, mode: .utc, locale: posix)), "reason stamps show in the chosen zone")
    try expect(local.hasSuffix("after 1m30s of silence."), "the rest of the reason is kept")
    try expectEqual(TimeDisplay.localizingStamps(in: "disk 94% full", mode: .utc, locale: posix), "disk 94% full", "text without a stamp is unchanged")
    let english = Locale(identifier: "en_US")
    try expectEqual(RelativeDateFormatter.shortDuration(3_600, locale: english), "1h", "relative duration hours")
    try expectEqual(RelativeDateFormatter.shortDuration(6_600, locale: english), "1h", "relative duration counts whole hours")
    try expectEqual(RelativeDateFormatter.shortDuration(45, locale: english), "45s", "relative duration seconds")
    try expectEqual(RelativeDateFormatter.string(from: now.addingTimeInterval(-120), now: now, locale: english), TimeDisplay.relative(now.addingTimeInterval(-120), now: now, locale: english), "relative date uses the one formatter")

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
    let failedApply = Approval(id: "ap-f", status: "rejected", reason: "apply task failed: nft exited 1", approvedBy: "u1")
    try expectEqual(failedApply.displayState, .failed, "a rejected row without rejected_by is a failed apply")
    try expectEqual(Approval(id: "ap-r", status: "rejected", approvedBy: "", rejectedBy: "u1").displayState, .rejected, "a rejected row with rejected_by was rejected by someone")

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
    try expectEqual(await LatticeErrorProbe.map(status: 409, body: findings), .conflict(code: "conflict", message: "plan blocked by lint findings", findings: ["SSH would be closed"]), "409 carries findings")
    let stale = json(#"{"error":{"code":"approval_stale","message":"plan changed"}}"#)
    try expectEqual(await LatticeErrorProbe.map(status: 409, body: stale), .conflict(code: "approval_stale", message: "plan changed", findings: []), "409 keeps the envelope code")
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

/// A session write with no scope names the session, not an empty scope list.
private func checkAuthorityNote() throws {
    func intent(_ scopes: [String], client: ClientKind) -> WriteIntent {
        WriteIntent(
            tier: .t2, client: client, verb: "Rename passkey", object: ObjectRef(kind: "passkey", id: "pk1", name: "MacBook"),
            scopes: scopes, consequence: "The passkey keeps working.", changes: [], perform: { _, _ in .done("Renamed") }
        )
    }
    try expectEqual(intent([], client: .session).authorityNote, "Uses your signed-in session", "session write without scopes names the session")
    try expectEqual(intent([], client: .session).dialogMessage, "The passkey keeps working. Uses your signed-in session.", "T2 dialog ends with the session, not a bare period")
    try expect(intent([], client: .primary).authorityNote == nil, "a token write without scopes names nothing")
    try expectEqual(intent([], client: .primary).dialogMessage, "The passkey keeps working.", "no dangling scope clause")
    try expectEqual(intent(["log:admin"], client: .primary).authorityNote, "Uses scope log:admin", "one scope")
    try expectEqual(intent(["a:b", "c:d"], client: .primary).dialogMessage, "The passkey keeps working. a:b, c:d.", "scopes follow the consequence")
}

/// Server refusals keep their message and reach the refusal code spec 6.4 and 6.7 name.
private func checkRefusalMapping() async throws {
    let plainStepUp = try expectUnwrapped(await LatticeErrorProbe.map(status: 403, body: json(#"{"error":{"code":"forbidden","message":"second-factor step-up required","request_id":"req_1"}}"#)), "plain step-up 403")
    try expect(plainStepUp.isStepUpRequired, "requireStepUpGrant's plain 403 reads as step-up required")
    guard case .refused(.stepUpRequired, _)? = WriteFlow.refusal(for: plainStepUp) else {
        throw CheckFailure.failed("plain step-up 403 must map to stepUpRequired")
    }

    let noTOTP = try expectUnwrapped(await LatticeErrorProbe.map(status: 403, body: json(#"{"error":{"code":"forbidden","message":"an authenticator passcode must be enabled before passcode step-up"}}"#)), "no TOTP 403")
    try expectEqual(noTOTP.localizedDescription, "an authenticator passcode must be enabled before passcode step-up", "403 keeps the server's message")
    try expect(!noTOTP.isStepUpRequired, "the no-TOTP refusal is not a step-up retry")

    let version = try expectUnwrapped(await LatticeErrorProbe.map(status: 409, body: json(#"{"error":{"code":"version_conflict","message":"someone saved in between"}}"#)), "version conflict 409")
    guard case .refused(.versionConflict, let message)? = WriteFlow.refusal(for: version) else {
        throw CheckFailure.failed("version_conflict must map to versionConflict")
    }
    try expectEqual(message, "someone saved in between", "409 keeps the server's message")

    let stale = try expectUnwrapped(await LatticeErrorProbe.map(status: 409, body: json(#"{"error":{"code":"approval_stale","message":"plan changed since review; re-review before approving"}}"#)), "stale 409")
    guard case .refused(.approvalStale, let staleMessage)? = WriteFlow.refusal(for: stale) else {
        throw CheckFailure.failed("approval_stale must map to approvalStale")
    }
    try expectEqual(staleMessage, "plan changed since review; re-review before approving", "approval_stale keeps the server's message")
}

private struct ConfirmingAuthenticator: WriteAuthenticator {
    func authenticate(reason: String) async -> DeviceAuthOutcome { .confirmed }
}

/// A proxy timeout after the request was sent may hide an applied write, so
/// the runner verifies instead of reporting a refusal (6.7). A 502 that
/// carries a Lattice envelope is the server's own refusal.
private func checkGatewayTimeoutIsUnknown() async throws {
    let client = LatticeClient(baseURL: URL(string: "https://lattice.example.com")!, transport: MockTransport(responses: [:]))
    func intent(throwing error: LatticeAPIError) -> WriteIntent {
        WriteIntent(
            tier: .t2,
            verb: "Enable node",
            object: ObjectRef(kind: "node", id: "n1", name: "edge-tyo-3"),
            scopes: ["node:admin"],
            consequence: "edge-tyo-3 can authenticate again.",
            verify: { _ in "edge-tyo-3 is now enabled." },
            changes: [.nodes],
            perform: { _, _ in throw error }
        )
    }
    for status in [504, 524] {
        let result = await WriteFlow(intent: intent(throwing: .server(status: status, code: nil, message: "")), client: client, authenticator: ConfirmingAuthenticator()).commit(choices: ConfirmChoices())
        guard case .finished(.unknown(let message)) = result else {
            throw CheckFailure.failed("HTTP \(status) after sending must be unknown")
        }
        try expectEqual(message, "Could not confirm. edge-tyo-3 is now enabled.", "HTTP \(status) runs verify")
    }
    let refusal = await WriteFlow(intent: intent(throwing: .server(status: 502, code: "bad_gateway", message: "agent artifact upstream failed")), client: client, authenticator: ConfirmingAuthenticator()).commit(choices: ConfirmChoices())
    guard case .finished(.refused) = refusal else {
        throw CheckFailure.failed("a Lattice 502 envelope is a refusal")
    }
}

/// Only scope refusals turn a screen into the denied state; the scope comes
/// from the caller because the envelope never names one.
private func checkForbiddenClassification() throws {
    let state = ResourceState<Int>.loaded(1, at: Date())
    guard case .denied(let scope) = state.failing(.forbidden(code: "forbidden", message: "missing node:read"), surface: "Nodes", missingScope: "node:read") else {
        throw CheckFailure.failed("a plain 403 is a scope denial")
    }
    try expectEqual(scope, "node:read", "denied names the caller's missing scope")
    for error in [
        LatticeAPIError.forbidden(code: "forbidden", message: "invalid csrf token"),
        .forbidden(code: "mfa_required", message: "two-factor enrollment required"),
        .forbidden(code: "step_up_required", message: "second-factor step-up required"),
        .forbidden(code: "forbidden", message: "second-factor step-up required"),
    ] {
        guard case .failed(let failure, let last, _) = state.failing(error, surface: "Nodes", missingScope: "node:read") else {
            throw CheckFailure.failed("\(error) is not a missing scope")
        }
        try expectEqual(failure, error, "the refusal keeps its message")
        try expect(last == nil, "a 403 drops the stale value")
    }
}

/// Go reads a literal "+" in a query as a space, and the server refuses a
/// maintenance end that is not after its start.
private func checkQueryEncodingAndWindowEnd() async throws {
    let transport = MockTransport(responses: [:])
    let client = LatticeClient(baseURL: URL(string: "https://lattice.example.com")!, transport: transport)
    _ = try? await client.fetchAudit(action: "c++ a+b=c&d")
    let sent = try expectUnwrapped(await transport.requestURLs.first, "audit request sent")
    try expect(sent.contains("action=c%2B%2B%20a%2Bb%3Dc%26d"), "query values escape +, = and &: \(sent)")

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let scheduled = MaintenanceWindow(id: "w1", name: "Kernel", startsAt: start, endsAt: start.addingTimeInterval(3600))
    try expectEqual(MaintenanceWindowInput(ending: scheduled, at: start.addingTimeInterval(-600)).endsAt, start.addingTimeInterval(1), "ending a scheduled window ends it a second after its start")
    try expectEqual(MaintenanceWindowInput(ending: scheduled, at: start.addingTimeInterval(60)).endsAt, start.addingTimeInterval(60), "ending a running window ends it now")
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

// MARK: - Query vectors

/// Runs the console's portable query vectors (`src/lib/query/vectors.json`,
/// copied byte for byte) against the port, as the console's `vectors.ts`
/// runner does, except the autocomplete cases.
private func checkQueryVectors() throws {
    let root = try expectUnwrapped(try JSONSerialization.jsonObject(with: fixture("query-vectors.json")) as? [String: Any], "query vectors object")
    let schema = try expectUnwrapped(root["schema"] as? [String: Any], "vector schema")
    let textPaths = try expectUnwrapped(schema["text"] as? [String], "vector text paths")
    let fieldSpecs = try expectUnwrapped(schema["fields"] as? [[String: Any]], "vector fields")
    let fields = fieldSpecs.map(vectorField)
    let text: @Sendable (VectorRow) -> [String] = { row in textPaths.flatMap { vectorTexts(row.values[$0]) } }
    let now = try expectUnwrapped(AstraTestDates.parse(root["now"] as? String ?? ""), "vector now")
    let sharedRows = (root["rows"] as? [[String: Any]] ?? []).map(VectorRow.init)
    var failures: [String] = []

    for vector in root["parse"] as? [[String: Any]] ?? [] {
        let query = vector["query"] as? String ?? ""
        let parsed = LatticeQuery.parse(query)
        if let error = vector["error"] as? [Any] {
            let got: String
            switch parsed {
            case .success: got = "ok"
            case .failure(let failure): got = vectorRender([failure.code.rawValue, failure.start, failure.end])
            }
            if got != vectorRender(error) { failures.append("parse \(query): want \(vectorRender(error)), got \(got)") }
            continue
        }
        guard case .success(let result) = parsed else {
            failures.append("parse \(query): refused")
            continue
        }
        if vector.keys.contains("tree") {
            let want = vectorRender(vector["tree"] ?? NSNull())
            let got = vectorRender(result.tree.map(vectorShape) ?? NSNull())
            if want != got { failures.append("parse \(query): want \(want), got \(got)") }
        }
        if let sorts = vector["sorts"] as? [[Any]] {
            let got = vectorRender(result.sorts.map { [$0.field, $0.descending] as [Any] })
            if got != vectorRender(sorts) { failures.append("parse \(query) sorts: want \(vectorRender(sorts)), got \(got)") }
        }
    }

    for pair in root["withoutSorts"] as? [[String]] ?? [] {
        let got = LatticeQuery.withoutSorts(pair[0])
        if got != pair[1] { failures.append("withoutSorts \(pair[0]): want \(pair[1]), got \(got)") }
    }

    for vector in root["run"] as? [[String: Any]] ?? [] {
        let query = vector["query"] as? String ?? ""
        let compiled = LatticeQueryEngine.compile(query, fields: fields, text: text)
        if let want = vector["error"] as? [String: Any] {
            switch compiled {
            case .success:
                failures.append("run \(query): want \(want["code"] ?? ""), got a query")
            case .failure(let error):
                var mismatch = error.code.rawValue != want["code"] as? String
                if let start = want["start"] as? Int, start != error.start { mismatch = true }
                if let end = want["end"] as? Int, end != error.end { mismatch = true }
                for (key, value) in want["params"] as? [String: String] ?? [:] where error.params[key] ?? "" != value { mismatch = true }
                if mismatch { failures.append("run \(query): want \(want), got \(error)") }
            }
            continue
        }
        guard case .success(let compiledQuery) = compiled else {
            if case .failure(let error) = compiled { failures.append("run \(query): refused with \(error)") }
            continue
        }
        let rows = (vector["rows"] as? [[String: Any]]).map { $0.map(VectorRow.init) } ?? sharedRows
        let kept = LatticeQueryEngine.apply(compiledQuery, to: rows, now: now).map(\.id)
        if let ids = vector["ids"] as? [String], kept != ids { failures.append("run \(query): want \(ids), got \(kept)") }
        if let set = vector["set"] as? [String], kept.sorted() != set.sorted() { failures.append("run \(query) (any order): want \(set), got \(kept)") }
    }

    let values = root["values"] as? [String: Any] ?? [:]
    for entry in values["number"] as? [[Any]] ?? [] {
        let unit = LatticeQueryNumberUnit(rawValue: entry[1] as? String ?? "plain") ?? .plain
        let got = LatticeQueryValues.parseNumber(entry[0] as? String ?? "", unit: unit)
        if got != (entry[2] as? Double) { failures.append("parseNumber \(entry[0]) \(unit): want \(entry[2]), got \(String(describing: got))") }
    }
    for entry in values["duration"] as? [[Any]] ?? [] {
        let got = LatticeQueryValues.parseDuration(entry[0] as? String ?? "")
        if got != (entry[1] as? Double) { failures.append("parseDuration \(entry[0]): want \(entry[1]), got \(String(describing: got))") }
    }
    for entry in values["time"] as? [[Any]] ?? [] {
        var expected: Double?
        if let want = entry[1] as? [String: Any] {
            if let utc = want["utc"] as? Double {
                expected = utc
            } else if let local = want["local"] as? [Int] {
                var parts = local + Array(repeating: 0, count: max(0, 7 - local.count))
                if local.count < 3 { parts[2] = 1 }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .current
                let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1] + 1, day: parts[2], hour: parts[3], minute: parts[4], second: parts[5]))
                expected = date.map { ($0.timeIntervalSince1970 * 1_000).rounded() + Double(parts[6]) }
            }
        }
        let got = LatticeQueryValues.parseTime(entry[0] as? String ?? "")
        if got != expected { failures.append("parseTime \(entry[0]): want \(String(describing: expected)), got \(String(describing: got))") }
    }
    for entry in values["versions"] as? [[Any]] ?? [] {
        let got = LatticeQueryValues.compareVersions(entry[0] as? String ?? "", entry[1] as? String ?? "")
        if got != entry[2] as? Int { failures.append("compareVersions \(entry[0]) \(entry[1]): want \(entry[2]), got \(got)") }
    }

    if !failures.isEmpty {
        throw CheckFailure.failed("query vectors: \(failures.count) failed\n" + failures.joined(separator: "\n"))
    }
}

/// One row of the vector file; the values are plain JSON.
private struct VectorRow: @unchecked Sendable {
    let values: [String: Any]
    init(_ values: [String: Any]) { self.values = values }
    var id: String { values["id"].map { "\($0)" } ?? "" }
}

private enum AstraTestDates {
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

private func vectorField(_ spec: [String: Any]) -> LatticeQueryField<VectorRow> {
    let path = spec["path"] as? String ?? ""
    return LatticeQueryField(
        key: spec["key"] as? String ?? "",
        aliases: spec["aliases"] as? [String] ?? [],
        type: LatticeQueryFieldType(rawValue: spec["type"] as? String ?? "string") ?? .string,
        unit: LatticeQueryNumberUnit(rawValue: spec["unit"] as? String ?? "plain") ?? .plain,
        values: spec["values"] as? [String] ?? [],
        valueAliases: spec["valueAliases"] as? [String: String] ?? [:],
        flag: spec["flag"] as? Bool ?? false,
        sortable: (spec["sort"] as? Bool) != false,
        get: { row in vectorValue(row.values[path]) }
    )
}

private func isJSONBool(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
}

private func vectorValue(_ value: Any?) -> LatticeQueryFieldValue {
    switch value {
    case let text as String: return .string(text)
    case let number as NSNumber where isJSONBool(number): return .bool(number.boolValue)
    case let number as NSNumber: return .number(number.doubleValue)
    case let list as [Any]:
        if list.allSatisfy({ $0 is NSNumber && !isJSONBool($0) }) { return .numbers(list.compactMap { ($0 as? NSNumber)?.doubleValue }) }
        return .strings(list.map { "\($0)" })
    default: return .none
    }
}

private func vectorTexts(_ value: Any?) -> [String] {
    switch value {
    case nil, is NSNull: return []
    case let list as [Any]: return list.flatMap { vectorTexts($0) }
    case let text as String: return text.isEmpty ? [] : [text]
    case let number as NSNumber: return [number.stringValue]
    default: return []
    }
}

/// The tree without offsets, as nested arrays, as the console's tests print it.
private func vectorShape(_ node: LatticeQueryNode) -> Any {
    switch node {
    case .and(let items): return ["and"] + items.map(vectorShape)
    case .or(let items): return ["or"] + items.map(vectorShape)
    case .not(let item): return ["not", vectorShape(item)]
    case .text(let value, let quoted): return quoted ? "\"\(value)\"" : value
    case .term(let term): return term.compact
    }
}

private func vectorRender(_ value: Any) -> String {
    switch value {
    case is NSNull: return "null"
    case let number as Int where type(of: value) == Int.self: return String(number)
    case let flag as Bool where type(of: value) == Bool.self: return flag ? "true" : "false"
    case let text as String: return "\"\(text)\""
    case let number as NSNumber where isJSONBool(number): return number.boolValue ? "true" : "false"
    case let number as NSNumber: return number.stringValue
    case let list as [Any]: return "[" + list.map(vectorRender).joined(separator: ",") + "]"
    default: return "\(value)"
    }
}

// MARK: - Scopes, from internal/rbac/rbac_test.go

private func checkScopeGoldens() throws {
    let confined = ScopeSet(scopes: ["node:read", "task:*"], serverAllowlist: ["node-a"])
    try expect(confined.allows("task:run", nodeID: "node-a"), "wildcard task scope on an allowed node")
    try expect(!confined.allows("task:run", nodeID: "node-b"), "server allowlist denial")
    try expect(!confined.allows("network:apply", nodeID: "node-a"), "missing scope denial")

    let migration: [(granted: String, required: String, want: Bool)] = [
        ("proxy:read", "vpncore:read", true), ("proxy:admin", "vpncore:admin", true),
        ("proxy:read", "substore:read", true), ("proxy:admin", "substore:admin", true),
        ("vpncore:read", "proxy:read", true), ("vpncore:admin", "proxy:admin", true),
        ("vpncore:*", "proxy:admin", true), ("proxy:*", "substore:admin", true),
        ("substore:read", "proxy:read", false), ("substore:admin", "vpncore:admin", false),
        ("vpncore:read", "substore:read", false), ("proxy:read", "vpncore:admin", false),
    ]
    for row in migration {
        try expectEqual(ScopeSet(scopes: [row.granted]).allows(row.required), row.want, "\(row.granted) allows \(row.required)")
    }
    for (scopes, want) in [(["secrets:reveal"], true), (["*"], false), (["secrets:*"], false), (["proxy:admin", "vpncore:admin", "substore:admin", "token:admin", "user:admin"], false)] {
        try expectEqual(ScopeSet(scopes: scopes).allows("secrets:reveal"), want, "secrets:reveal held by \(scopes)")
    }
    try expect(ScopeSet(scopes: ["*"]).allows("proxy:admin"), "* still allows every ordinary scope")

    // Every grantable scope the server knows has a description.
    let known = [
        "audit:read", "ddns:admin", "dns:admin", "geo:admin", "geo:read", "group:admin", "group:read", "inventory:admin",
        "inventory:read", "kv:admin", "kv:read", "kv:write", "log:admin", "log:read", "log:write", "monitor:admin",
        "monitor:read", "netguard:admin", "netguard:read", "netpolicy:admin", "netpolicy:read", "network:apply",
        "network:plan", "node:admin", "node:read", "notify:admin", "notify:send", "oidc:admin", "plugin:admin",
        "plugin:verify", "proxy:admin", "proxy:read", "secrets:reveal", "sshguard:admin", "sshguard:read",
        "substore:admin", "substore:read", "static:admin", "static:read", "static:write", "task:read", "task:run",
        "terminal:open", "token:admin", "tunnel:admin", "user:admin", "vpn:probe", "vpncore:admin", "vpncore:read",
        "wireguard:admin", "wireguard:read",
    ]
    let described = Set(ScopeCatalogue.entries.map(\.scope))
    try expectEqual(described.count, ScopeCatalogue.entries.count, "the catalogue names each scope once")
    let undescribed = known.filter { !described.contains($0) }
    // The console's catalogue leaves out the scopes it never offers in the token form.
    try expect(undescribed.allSatisfy { ["kv:admin", "static:admin", "secrets:reveal"].contains($0) }, "every offered scope is described: missing \(undescribed)")
    try expectEqual(ScopeCatalogue.entry(for: "network:apply")?.sensitive, true, "network:apply is marked sensitive")
}

// MARK: - Approval visibility, from server_approval_scope_test.go

private func checkApprovalVisibilityGoldens() throws {
    let planOnly = ScopeSet(scopes: ["network:plan"], serverAllowlist: ["node-a"])
    try expect(!ApprovalVisibility.canList(plugin: "agentupdate", nodeID: "node-a", scopes: planOnly), "network:plan alone cannot list an agent update")
    let nodeAdmin = ScopeSet(scopes: ["network:plan", "node:admin"], serverAllowlist: ["node-a"])
    try expect(ApprovalVisibility.canList(plugin: "agentupdate", nodeID: "node-a", scopes: nodeAdmin), "node:admin and network:plan list an agent update")
    try expect(ApprovalVisibility.canList(plugin: "nftpolicy", nodeID: "node-a", scopes: ScopeSet(scopes: ["netpolicy:admin"])), "netpolicy:admin lists its own approvals without network:plan")
    try expect(ApprovalVisibility.canList(plugin: "sshguard", nodeID: "n", scopes: ScopeSet(scopes: ["sshguard:admin", "network:plan"])), "sshguard:admin implies the read")
    try expect(!ApprovalVisibility.canList(plugin: "sshguard", nodeID: "n", scopes: ScopeSet(scopes: ["network:plan"])), "SSH Guard plans hold a knock sequence")

    let decisions: [(plugin: String, action: String, want: String?)] = [
        ("nft", "apply-ruleset:netguard-v1", "netguard:admin"), ("nft", "apply-ruleset", nil),
        ("agentupdate", "", "node:admin"), ("selfdns", "", "dns:admin"), ("proxycore", "", "proxy:admin"),
        ("singbox-lineuser", "", "vpncore:admin"), ("singbox-linemeta", "", "vpncore:admin"),
        ("singbox-managedline", "", "vpncore:admin"), ("cftunnel", "", "tunnel:admin"),
        ("nftpolicy", "", "netpolicy:admin"), ("wireguard", "", nil), ("singbox-linechain", "", nil),
        ("sshguard", "sshguard-future:v9", "sshguard:admin"), ("beacon", "node.beacon", "monitor:admin"),
        ("controlplane-witness", "", "notify:admin"), ("substore-plan", "", "proxy:admin"), ("agent.mirrors", "", "node:admin"),
    ]
    for row in decisions {
        try expectEqual(ApprovalVisibility.decisionScope(plugin: row.plugin, action: row.action), row.want, "decision scope of \(row.plugin) \(row.action)")
    }

    let multi = Approval(id: "a", nodeID: "node-a", plugin: "nft", action: "apply-ruleset", status: "pending", targets: ["node-a", "node-b"])
    try expect(!ApprovalVisibility.canList(multi, scopes: ScopeSet(scopes: ["network:plan"], serverAllowlist: ["node-a"])), "every other target needs network:plan too")
    try expect(ApprovalVisibility.canList(multi, scopes: ScopeSet(scopes: ["network:plan"], serverAllowlist: ["node-a", "node-b"])), "a token on both targets lists it")
}

// MARK: - Token presets

private func checkTokenPresetCoverage() throws {
    try expect(ParityMatrix.rows.count > 100, "the parity matrix holds section 3.2 row by row")
    try expectEqual(TokenPresets.uncoveredScopes(), [], "every native parity row's scopes are in a preset or deliberately excluded")
    for preset in TokenPresets.all {
        try expect(Set(preset.scopes).isDisjoint(with: TokenPresets.deliberatelyExcluded), "\(preset.title) carries no excluded scope")
    }
    try expect(!TokenPresets.operator.scopes.contains("task:run") && !TokenPresets.operator.scopes.contains("terminal:open"), "root scopes sit only in Operator plus root")
    let sentinel = ParityMatrixRow(page: "Test", action: "Needs an odd scope", endpoint: "POST /api/x", scopes: ["wireguard:admin"], modes: [.nativeT2])
    try expectEqual(TokenPresets.uncoveredScopes(rows: [sentinel]), ["wireguard:admin"], "an uncovered native scope is reported")
    let web = ParityMatrixRow(page: "Test", action: "Desk only", endpoint: "POST /api/x", scopes: ["wireguard:admin"], modes: [.web])
    try expectEqual(TokenPresets.uncoveredScopes(rows: [web].filter(\.isNative)), [], "web rows need no preset")
}

// MARK: - Incidents

private func checkIncidentOrdering() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func incident(_ id: String, _ state: String, _ severity: String, since: Double, held: Bool = false) -> Incident {
        var incident = Incident(id: id, severity: severity, state: state)
        incident.since = now.addingTimeInterval(since)
        if held { incident.maintenance = "window" }
        if state == "resolved" { incident.resolvedAt = now.addingTimeInterval(since + 60) }
        return incident
    }
    let rows = [
        incident("resolved-old", "resolved", "critical", since: -9_000),
        incident("resolved-new", "resolved", "warning", since: -600),
        incident("pending", "pending", "warning", since: -60),
        incident("acked", "acknowledged", "critical", since: -300),
        incident("held", "open", "critical", since: -400, held: true),
        incident("warn-old", "open", "warning", since: -800),
        incident("crit-new", "open", "critical", since: -100),
        incident("crit-old", "open", "critical", since: -500),
    ]
    let sorted = rows.sorted { IncidentFilter.areInIncreasingOrder($0, $1, now: now) }.map(\.id)
    try expectEqual(sorted, ["crit-old", "crit-new", "warn-old", "held", "acked", "pending", "resolved-new", "resolved-old"], "compareIncidents order")
    try expect(IncidentFilter.active.matches(rows[3], now: now) && !IncidentFilter.active.matches(rows[2], now: now), "active is open and acknowledged")
}

/// No Shared call can ask the server for a console-only incident filter.
private func checkIncidentStatesNeverSent() async throws {
    let transport = MockTransport(responses: [
        "https://lattice.example.com/api/incidents": (200, json(#"{"incidents":[],"windows":[],"durable":true}"#)),
        "https://lattice.example.com/api/incidents?state=pending,open,acknowledged,resolved": (200, json(#"{"incidents":[],"windows":[],"durable":true}"#)),
        "https://lattice.example.com/api/incidents?state=open,acknowledged": (200, json(#"{"incidents":[],"windows":[],"durable":true}"#)),
    ])
    let client = LatticeClient(baseURL: URL(string: "https://lattice.example.com")!, transport: transport)
    _ = try await client.listIncidents()
    _ = try await client.listIncidents(states: IncidentServerState.allCases)
    _ = try await client.listIncidents(states: [.open, .acknowledged])
    for url in await transport.requestURLs {
        let state = URLComponents(string: url)?.queryItems?.first { $0.name == "state" }?.value ?? ""
        for word in state.split(separator: ",") {
            try expect(IncidentServerState(rawValue: String(word)) != nil, "only the server's four states are sent, saw \(word) in \(url)")
        }
    }
}

// MARK: - SSH Guard, from __tests__/sshGuardBoardModel.test.ts

private func checkSSHGuardBoard() throws {
    let cases: [(SSHGuardBoardStage, SSHGuardScopeState, SSHGuardCoverage)] = [
        (.idle, .enrolled, .open), (.armPending, .enrolled, .armPending), (.armApproved, .enrolled, .armPending),
        (.awaitingConfirm, .enrolled, .reverting(deadline: nil)), (.confirmPending, .enrolled, .reverting(deadline: nil)),
        (.confirmApproved, .enrolled, .reverting(deadline: nil)), (.reverted, .enrolled, .failed),
        (.idle, .excluded, .excluded), (.armFailed, .excluded, .excluded), (.reverted, .excluded, .excluded),
        (.confirmed, .excluded, .confirmed), (.awaitingConfirm, .excluded, .reverting(deadline: nil)),
        (.hardened, .enrolled, .confirmed), (.inForce, .excluded, .confirmed), (.armFailed, .enrolled, .failed),
    ]
    for (stage, scope, want) in cases {
        try expectEqual(SSHGuardBoard.coverageBucket(stage, scope: scope), want, "coverage of \(stage) \(scope)")
    }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let later = now.addingTimeInterval(3_600)
    let reverting = try JSONDecoder().decode(SSHGuardNodeStatus.self, from: json(#"{"node_id":"reverting","stage":"awaiting_confirm","revert_armed":true,"revert_deadline":"\#(AstraTestDates.string(now.addingTimeInterval(600)))","posture":{"state":"secured"},"knock_gate":true,"stage_is_history":false,"enrolled":true,"knock":{}}"#))
    try expectEqual(SSHGuardBoard.boardStage(reverting, now: now), .awaitingConfirm, "the timer is still running")
    try expectEqual(SSHGuardBoard.boardStage(reverting, now: later), .reverted, "past the deadline the box reverted")
    try expectEqual(SSHGuardBoard.revertingNodes([reverting], now: now).map(\.nodeID), ["reverting"], "the urgent card lists it")
    try expectEqual(SSHGuardBoard.revertingNodes([reverting], now: later).count, 0, "the urgent card empties: there is no timer left to beat")
    try expectEqual(SSHGuardBoard.coverage(for: reverting, scope: .enrolled, now: later), .failed, "a reverted arm counts as failed")
    try expectEqual(SSHGuardBoard.coverage(for: reverting, scope: .enrolled, now: now), .reverting(deadline: reverting.revertDeadline), "the countdown carries the server's deadline")
}

// MARK: - Paths

private func checkPathDerivation() throws {
    try expectEqual(PathDisplayState(state: "up", reason: nil, judgesDegraded: false), .up, "up")
    try expectEqual(PathDisplayState(state: "degraded", reason: "degraded_loss", judgesDegraded: true), .degraded(PathReason(rawValue: "degraded_loss")), "degraded from a judging server")
    try expectEqual(PathDisplayState(state: "weird", reason: nil, judgesDegraded: true), .unknown(nil), "an unknown word is unknown, never up")
    try expectEqual(PathDisplayState(state: "unknown", reason: "pair_off", judgesDegraded: true), .paused(PathReason(rawValue: "path_paused")), "aliases resolve to a pause")
    try expectEqual(PathReason(rawValue: "Node - Offline").rawValue, "agent_offline", "runs of spaces and hyphens become one underscore")
    try expectEqual(PathReason.sentence(for: "something_new"), "something_new", "an unknown reason is shown as sent")
    try expectEqual(PathDisplayState(state: "unknown", reason: "udp_only", judgesDegraded: true).measure, .skipped, "a check skips a UDP-only pair")
    try expectEqual(PathDisplayState(state: "unknown", reason: "packet_budget", judgesDegraded: true), .paused(PathReason(rawValue: "packet_budget")), "section 4.2 reads packet_budget as paused")
    try expectEqual(PathDisplayState(state: "unknown", reason: "packet_budget", judgesDegraded: true).measure, .skipped, "and the console counts it as skipped")
    try expectEqual(PathDisplayState(state: "unknown", reason: "check_paused", judgesDegraded: true).measure, .paused, "a paused check is the operator's choice")
    try expectEqual(PathDisplayState(state: "unknown", reason: "no_data", judgesDegraded: true).measure, .measured, "no data yet is still a measured path")
    try expectEqual(PathDisplayState(state: "down", reason: "path_paused", judgesDegraded: true).measure, .measured, "only unknown paths are skipped or paused")

    // Two definitions measuring the same pair are two cells with one key.
    let pair = try JSONDecoder().decode(PathsResponse.self, from: json(#"""
    {"paths":[
     {"source":"n1","target_node":"n2","target":"192.0.2.2:443","monitor_id":"m1","check_definition_id":"d1","state":"up"},
     {"source":"n1","target_node":"n2","target":"192.0.2.2:7443","monitor_id":"m2","check_definition_id":"d2","state":"down"}
    ]}
    """#))
    try expectEqual(pair.paths.count, 2, "both cells decode")
    try expectEqual(pair.paths[0].key, pair.paths[1].key, "both cells share the pair key")
    try expectEqual(Set(pair.paths.map(\.id)).count, 2, "ids stay unique in the matrix")
    try expectEqual(pair.path(key: pair.paths[1].key)?.monitorID, "m1", "a pair key opens the first cell, as the console does")

    // Go writes RFC 3339 with fractional seconds only when they are not zero.
    func degradedAt(_ text: String) throws -> Date? {
        try JSONDecoder().decode(PathsResponse.self, from: json(#"{"paths":[],"degraded_at":"\#(text)"}"#)).degradedAt
    }
    let whole = Date(timeIntervalSince1970: 1_800_000_000)
    try expectEqual(try degradedAt("2027-01-15T08:00:00Z"), whole, "whole seconds")
    try expectEqual(try degradedAt("2027-01-15T16:00:00+08:00"), whole, "an offset")
    let nanos = try expectUnwrapped(try degradedAt("2027-01-15T08:00:00.123456789Z"), "nanosecond fraction")
    try expect(abs(nanos.timeIntervalSince(whole) - 0.123456789) < 0.001, "fractional seconds keep their value")
    try expectEqual(try degradedAt("0001-01-01T00:00:00Z"), nil, "Go's zero time is no date")
}

// MARK: - Badge, DDNS, tasks

private func checkBadgeAndDDNS() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var snoozed = Incident(id: "s", severity: "critical", state: "open")
    snoozed.snoozedUntil = now.addingTimeInterval(60)
    var held = Incident(id: "h", severity: "warning", state: "open")
    held.maintenance = "window"
    let incidents = [
        Incident(id: "c", severity: "critical", state: "open"), Incident(id: "w", severity: "warning", state: "open"),
        Incident(id: "i", severity: "info", state: "open"), Incident(id: "a", severity: "critical", state: "acknowledged"),
        snoozed, held, Incident(id: "pending:x", severity: "warning", state: "pending"),
    ]
    let approvals = [
        Approval(id: "p", nodeID: "n", plugin: "agentupdate", action: "update-agent", status: "pending"),
        Approval(id: "m", nodeID: "n", plugin: "singbox-linemeta", action: "sync", status: "pending", actorID: "lattice-server"),
        Approval(id: "d", nodeID: "n", plugin: "agentupdate", action: "update-agent", status: "applied"),
    ]
    try expectEqual(BadgeCount.compute(approvals: approvals, incidents: incidents, now: now), 3, "badge: one human approval, one critical and one warning")

    func profile(_ fields: String) throws -> DDNSProfile {
        try JSONDecoder().decode(DDNSProfile.self, from: json(#"{"id":"d","node_id":"n","enable_ipv4":true,"enable_ipv6":false,"interval_seconds":300,"created_at":"2026-01-01T00:00:00Z",\#(fields)}"#))
    }
    let node = DDNSNodeAddresses(publicIPv4: "192.0.2.9", publicIPv6: "", down: false)
    let lastRun = AstraTestDates.string(now.addingTimeInterval(-3_600))
    try expectEqual(try profile(#""last_ipv4":"192.0.2.9","last_run_at":"\#(lastRun)""#).health(now: now, node: node), .current, "an address that holds still is current however old the run")
    try expectEqual(try profile(#""last_ipv4":"192.0.2.1","last_run_at":"\#(lastRun)""#).health(now: now, node: node), .stale, "moved and overdue is stale")
    try expectEqual(try profile(#""last_ipv4":"192.0.2.1","last_run_at":"\#(AstraTestDates.string(now.addingTimeInterval(-200)))""#).assess(node: node, now: now).state, .waiting, "moved within two intervals is waiting")
    try expectEqual(try profile(#""last_ipv4":"192.0.2.9","last_error":"403""#).health(now: now, node: node), .failing, "a last error is failing")
    try expectEqual(try profile(#""last_ipv4":"192.0.2.9","last_run_at":"\#(lastRun)""#).assess(node: nil, now: now).state, .unchecked, "without node data an address profile is unchecked")
    try expectEqual(try profile(#""record_type":"cname","cname_target":"Edge.Example.com.","last_target":"edge.example.com","last_run_at":"\#(lastRun)""#).health(now: now), .current, "a confirmed CNAME is current")
    try expectEqual(try profile(#""interval_seconds":0,"record_type":"cname","cname_target":"edge.example.com""#).effectiveIntervalSeconds, 300, "the server's default interval")
}

private func checkTaskLease() throws {
    try expectEqual(TaskLeaseProgress.formatLeaseAge(30), "30 s", "seconds")
    try expectEqual(TaskLeaseProgress.formatLeaseAge(41 * 60 + 5), "41 min", "minutes")
    try expectEqual(TaskLeaseProgress.formatLeaseAge(2 * 3_600 + 5 * 60), "2 h 5 min", "hours and minutes")
    try expectEqual(TaskLeaseProgress.formatLeaseAge(6 * 86_400 + 2 * 3_600 + 59), "6 d 2 h", "two units at most")
    try expectEqual(TaskLeaseProgress(attempts: 2, maxAttempts: 3, leaseAgeSeconds: 2_460).label, "leased 41 min, attempt 2 of 3", "a held lease")
    try expectEqual(TaskLeaseProgress(attempts: 3, maxAttempts: 3, leaseAgeSeconds: 10, stalledReason: "stopped after 3 attempts (x).").label, "stopped after 3 attempts (x), attempt 3 of 3", "the reason wins and loses its full stop")
    let fanOut = try JSONDecoder().decode(LatticeTask.self, from: json(#"{"id":"t","targets":["a","b"],"status":"leased","attempts":1,"target_states":{"a":{"status":"leased","attempts":2,"max_attempts":3,"lease_age_seconds":60}}}"#))
    try expectEqual(fanOut.leaseProgress(nodeID: "a")?.label, "leased 1 min, attempt 2 of 3", "a target record")
    try expectEqual(fanOut.leaseProgress(nodeID: "b"), nil, "no task-level fallback for one node of a fan-out")
    try expectEqual(fanOut.runState(nodeID: "a", now: Date()), .leased, "a target's own state")
    try expectEqual(TaskRunState(serverValue: "running"), .leased, "running reads as leased")
    try expectEqual(TaskRunState(serverValue: "brand_new"), .queued, "an unknown word reads as queued")
}

// MARK: - Verdict, section 4.8

private func checkVerdicts() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let locale = Locale(identifier: "en_US_POSIX")
    let fresh = SectionCoverage.fresh(at: now)
    func verdict(_ snapshot: InboxSnapshot) -> Verdict {
        VerdictBuilder.verdict(for: snapshot, now: now, mode: .utc, locale: locale)
    }
    func allFresh(except overrides: [InboxSection: SectionCoverage] = [:]) -> [InboxSection: SectionCoverage] {
        var coverage = Dictionary(uniqueKeysWithValues: InboxSection.allCases.map { ($0, fresh) })
        coverage.merge(overrides) { _, new in new }
        return coverage
    }
    let since = now.addingTimeInterval(-1_800)
    let clock = TimeDisplay.clock(since, mode: .utc, locale: locale)

    try expectEqual(verdict(InboxSnapshot()).sentence, "Checking the fleet.", "rule 1: nothing loaded")
    try expectEqual(verdict(InboxSnapshot(coverage: allFresh(except: [.tasks: .notLoaded]))).sentence, "Checking the fleet.", "rule 1: a section still loading")

    let failed = InboxSnapshot(coverage: allFresh(except: [.incidents: .failed(lastGoodAt: now.addingTimeInterval(-720))]), approvalsNeedingYou: 2)
    try expectEqual(verdict(failed).sentence, "2 need you. Cannot confirm the rest: incidents did not load.", "rule 2 with approvals")
    var noApprovals = failed
    noApprovals.approvalsNeedingYou = 0
    try expectEqual(verdict(noApprovals).sentence, "Cannot confirm. Last good refresh 12 minutes ago.", "rule 2: the oldest good refresh")
    let offline = InboxSnapshot(coverage: allFresh(except: [.nodes: .offline(lastGoodAt: since)]))
    try expectEqual(verdict(offline).sentence, "Cannot confirm. Offline since \(clock).", "rule 2 offline")

    let operatorSnapshot = InboxSnapshot(
        coverage: allFresh(),
        approvalsNeedingYou: 2,
        approvalsWaiting: 3,
        problems: [
            VerdictProblem(kind: .offlineNode, summary: "fra-2 offline", since: now.addingTimeInterval(-7_200)),
            VerdictProblem(kind: .degradedPath, summary: "Path tokyo-1 to fra-2 degraded", since: since),
        ],
        nodeCount: 35, onlineCount: 33, failedTasks: 1, dueCount: 3
    )
    let operatorVerdict = verdict(operatorSnapshot)
    let offlineSince = TimeDisplay.clock(now.addingTimeInterval(-7_200), mode: .utc, locale: locale)
    try expectEqual(operatorVerdict.sentence, "2 need you. fra-2 offline since \(offlineSince).", "rule 3: the worst problem by precedence")
    try expectEqual(operatorVerdict.segments.map(\.text), ["33 of 35 online", "3 waiting", "1 failed task", "3 due"], "the four count segments")
    try expectEqual(operatorVerdict.segments.first?.query, "-status:online", "the node segment filters to the rest")
    if case .failure(let error) = LatticeQuery.parse(operatorVerdict.segments.first?.query ?? "") {
        throw CheckFailure.failed("the node segment query must parse: \(error)")
    }

    var critical = operatorSnapshot
    critical.approvalsNeedingYou = 0
    critical.problems.append(VerdictProblem(kind: .sshGuardReverting, summary: "edge-tyo-2 reverts unless confirmed", since: nil))
    critical.problems.append(VerdictProblem(kind: .criticalIncident, summary: "relay-fra-2 offline", since: since))
    try expectEqual(verdict(critical).sentence, "relay-fra-2 offline since \(clock).", "a critical incident leads")

    let quiet = InboxSnapshot(coverage: allFresh(), nodeCount: 35, onlineCount: 35, newestResolvedAt: since)
    try expectEqual(verdict(quiet).sentence, "Quiet since \(clock).", "rule 4")
    try expectEqual(verdict(quiet).segments.first?.query, nil, "all online needs no filter")
    try expectEqual(verdict(InboxSnapshot(coverage: allFresh())).sentence, "Quiet. Nothing needs you.", "rule 4 without a resolution")

    let triage = InboxSnapshot(coverage: allFresh(except: [
        .approvals: .denied(scope: "network:plan"), .ddns: .denied(scope: "ddns:admin"), .sshGuard: .denied(scope: "sshguard:read"),
    ]), nodeCount: 35, onlineCount: 35, newestResolvedAt: since)
    let triageVerdict = verdict(triage)
    try expectEqual(triageVerdict.sentence, "Quiet for what this token can see. Not covered: approvals, DDNS, SSH Guard.", "the Triage golden")
    try expect(!triageVerdict.segments.contains { $0.target == .approvals }, "a denied section has no segment, never a zero")

    let confined = InboxSnapshot(coverage: allFresh(), nodeCount: 12, onlineCount: 12, confinedTo: 12)
    try expectEqual(verdict(confined).sentence, "Quiet for what this token can see.", "a confined token qualifies quiet")
    try expectEqual(verdict(confined).segments.first?.text, "12 of 12 visible nodes online", "and its node clause")

    let partial = InboxSnapshot(coverage: allFresh(except: [.approvals: .partial(hiddenPlugins: ["Self-host DNS"], at: now)]), newestResolvedAt: since)
    try expectEqual(verdict(partial).sentence, "Quiet since \(clock). Hidden from this token: Self-host DNS approvals.", "hidden plugins qualify the sentence")
}

// MARK: - Deep links, section 2.5

private func checkDeepLinkGoldens() throws {
    let tricky = ["ap1", "pending:node.offline/edge 1", "a~b@c:d", "_~@m1", "x/y z"]
    var links: [LatticeDeepLink] = [.inbox, .upcoming, .settingsConnection]
    for id in tricky {
        links += [
            .approval(id: id), .node(id: id, view: nil), .node(id: id, view: .activity), .monitor(id: id), .check(id: id),
            .definition(id: id), .path(key: id), .incident(id: id), .maintenanceWindow(id: id), .task(id: id),
            .taskNode(taskID: id, nodeID: id), .auditEvent(id: id), .trace(correlationID: id), .machine(id: id),
            .group(id: id), .policy(id: id), .dnsDeployment(id: id), .ddnsProfile(id: id), .geoRoute(id: id),
            .tunnel(id: id), .sshGuardNode(nodeID: id), .agentUpdateNode(nodeID: id), .plugin(id: id), .share(id: id),
            .notifyChannel(id: id), .notifyDelivery(id: id), .webhook(id: id), .token(id: id), .user(id: id),
            .terminalSession(id: id), .vpnUser(id: id), .connection(id: id),
        ]
    }
    links += [
        .fleet(scope: .machines, query: "region:tyo"), .fleet(scope: nil, query: nil),
        .monitoring(segment: .incidents, view: "all", query: nil), .activity(scope: .tasks, view: nil, query: "status:failed"),
    ]
    for link in links {
        let url = try expectUnwrapped(link.customURL, "custom URL for \(link)")
        try expectEqual(LatticeDeepLink(url: url), link, "round trip \(url.absoluteString)")
        try expectEqual(LatticeDeepLink(url: url)?.customURL, url, "build after parse returns the input for \(url.absoluteString)")
    }

    let console = URL(string: "https://lattice.example.org")!
    let builders: [(LatticeConsolePath, String)] = [
        (.inbox, "/"), (.approval(id: "a1"), "/approvals?open=a1"), (.node(id: "n1", view: .settings), "/nodes/n1?view=settings"),
        (.check(id: "m1"), "/monitoring?view=checks&open=m1"), (.definition(id: "d1"), "/monitoring?view=checks&open=d1"),
        (.path(key: "_~@m1"), "/monitoring?view=topology&path=_~@m1"),
        (.incident(id: "i1", query: "relay-fra-2"), "/monitoring?view=incidents&state=all&q=relay-fra-2"),
        (.maintenance, "/monitoring?view=incidents&state=all"), (.task(id: "t1"), "/tasks?open=t1"),
        (.taskNode(taskID: "t1", nodeID: "n1"), "/tasks?open=t1"), (.auditEvent(id: "e1"), "/audit?open=e1"),
        (.trace(correlationID: "c1"), "/audit?view=all&q=trace:c1"), (.machine(id: "m1"), "/inventory?machine=m1"),
        (.upcoming, "/upcoming"), (.group(id: "g1"), "/node-groups?open=g1"), (.policy(id: "p1"), "/network/outbound?policy=p1"),
        (.dnsDeployment(id: "d1"), "/network/dns?open=d1"), (.ddnsProfile(id: "d1"), "/network/ddns?open=d1"),
        (.geoRoute(id: "g1"), "/network/geo-routing?open=g1"), (.tunnel(id: "t1"), "/network/tunnels?open=t1"),
        (.sshGuardNode(nodeID: "n1"), "/network/ssh-guard?node_id=n1"), (.agentUpdates(nodeName: "edge-tyo-3"), "/platform/agent-updates?view=nodes&q=edge-tyo-3"),
        (.plugin(id: "p1"), "/platform/plugins?open=p1"), (.share(id: "s1"), "/platform/publishing?view=routes&origin=share&open=s1"),
        (.notifyChannel(id: "c1"), "/platform/notifications?view=routing&channel=c1"), (.notifyDelivery(id: "d1"), "/platform/notifications?view=sent&open=d1"),
        (.webhook(id: "w1"), "/platform/webhooks?open=w1"), (.tokens, "/settings/access?view=tokens"), (.users, "/settings/access?view=users"),
        (.terminalSession(id: "s1"), "/terminal?session_id=s1"), (.vpnUsers, "/plugins/latticenet.vpn-core/users"),
        (.connection(id: "c1"), "/platform/evidence?view=explore&lens=connections&conn=c1"), (.settingsSecurity, "/settings/security"),
    ]
    for (path, want) in builders {
        try expectEqual(path.url(console: console).absoluteString, "https://lattice.example.org" + want, "console route \(want)")
    }

    let parsed: [(String, LatticeDeepLink)] = [
        ("/approvals?open=a1", .approval(id: "a1")), ("/monitoring/m1", .check(id: "m1")),
        ("/monitoring?view=checks&open=m1", .check(id: "m1")), ("/monitoring?view=topology&path=_~@m1", .path(key: "_~@m1")),
        ("/nodes/n1", .node(id: "n1")), ("/nodes/n1?view=activity", .node(id: "n1", view: .activity)),
        ("/tasks?open=t1", .task(id: "t1")), ("/audit?open=e1", .auditEvent(id: "e1")), ("/inventory?machine=m1", .machine(id: "m1")),
        ("/node-groups?open=g1", .group(id: "g1")), ("/network/ssh-guard?node_id=n1", .sshGuardNode(nodeID: "n1")),
        ("/platform/plugins?open=p1", .plugin(id: "p1")),
    ]
    for (path, want) in parsed {
        try expectEqual(LatticeDeepLink(url: URL(string: "https://lattice.example.org" + path)!, console: console), want, "console link \(path)")
    }
    try expectEqual(LatticeDeepLink(url: URL(string: "https://lattice.example.org:8443/nodes/n1")!, console: console), nil, "another port is another host")
    try expectEqual(LatticeDeepLink(url: URL(string: "https://lattice.example.org/settings/about")!, console: console), nil, "an unmapped console route opens in the browser")
}

// MARK: - Raw JSON

private func checkRawJSONSlices() throws {
    let text = #"{"total":2,"events":[{"id":"a","metadata":{"k":"v]}"}} , {"id":"b","n":[1,{"x":"\""}]}],"limit":2}"#
    let slices = try expectUnwrapped(JSONArraySlicer.elements(of: json(text), key: "events"), "events slices")
    try expectEqual(slices.map { String(decoding: $0, as: UTF8.self) }, [#"{"id":"a","metadata":{"k":"v]}"}}"#, #"{"id":"b","n":[1,{"x":"\""}]}"#], "elements keep their exact bytes")
    try expectEqual(JSONArraySlicer.elements(of: json(#"[1,"two",{"three":3}]"#))?.count, 3, "a top-level array")
    try expectEqual(JSONArraySlicer.elements(of: json(#"{"other":[]}"#), key: "events") == nil, true, "a missing key is nil")
}

extension AstraTestDates {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// A break opportunity after each separator, and nothing else changes.
private func checkIdentifierText() throws {
    try expectEqual(IdentifierText.breakable("relay-fra-1.example.org"), "relay-\u{200B}fra-\u{200B}1.\u{200B}example.\u{200B}org", "breaks after hyphens and dots")
    try expectEqual(IdentifierText.breakable("expiring_within_14d").replacingOccurrences(of: "\u{200B}", with: ""), "expiring_within_14d", "removing the breaks gives the identifier back")
}
