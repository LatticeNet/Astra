import Foundation
import AstraCore

public func checkApprovals() async throws {
    try await checkDecisionBodies()
    try await checkApprovalDecoding()
    try checkApprovalGrouping()
    try checkApprovalTitles()
    try checkDecisionEligibility()
    try checkTransitionVerification()
    try await checkDecisionFlowCancel()
    try await checkDecisionFlowOutcomes()
    try await checkBatchDecisions()
    try await checkPendingPlanHydration()
    try await checkApprovalsDemoRoutes()
}

/// Approval JSON shared by the Shared listing checks and the decision checks.
enum ApprovalSamples {
    static func pendingList(planHash: String) -> String {
        """
        {"approvals":[
          {"id":"ap1","node_id":"node-a","plugin":"nftpolicy","action":"apply nft",
           "plan_sha256":"\(planHash)","status":"pending","actor_id":"admin",
           "targets":["node-a"],"created_at":"2026-06-17T02:00:00Z"},
          {"id":"ap-linemeta","node_id":"node-a","plugin":"singbox-linemeta","action":"apply-metadata",
           "plan_sha256":"\(planHash)","status":"pending","actor_id":"lattice-server",
           "created_at":"2026-06-17T02:00:01Z"},
          {"id":"ap-stale","node_id":"node-a","plugin":"agentupdate","action":"agent.update",
           "plan_sha256":"deadbeef","status":"pending","actor_id":"admin",
           "reason":"agent update policy changed since this approval was planned; re-plan before approving",
           "stale":true,"stale_code":"agent_update_policy_changed",
           "created_at":"2026-06-17T02:01:00Z"}
        ],"total":3,"limit":100,"offset":0}
        """
    }

    static func byID(planBody: String, planHash: String) -> String {
        """
        {"approval":{"id":"ap1","node_id":"node-a","plugin":"nftpolicy","action":"apply nft",
         "plan":"\(planBody)","plan_sha256":"\(planHash)","status":"pending","actor_id":"admin",
         "plugin_version":"1.2.3","artifact_digest":"sha256:abc","targets":["node-a"],
         "created_at":"2026-06-17T02:00:00Z"}}
        """
    }

    static func waiting(planBody: String, planHash: String) -> String {
        """
        {"approval":{"id":"ap-wait","node_id":"node-a","plugin":"nftpolicy","action":"apply nft",
         "plan":"\(planBody)","plan_sha256":"\(planHash)","status":"approved","actor_id":"admin",
         "approved_by":"admin","targets":["node-a"],
         "waiting":{"code":"node_offline","reason":"node-a has not reported","blocked":true,
                    "node_id":"node-a","node_status":"offline","dismissible":true}}}
        """
    }
}

private let checkBase = URL(string: "https://lattice.example.com")!

/// One `approvalView` as the server writes it, for the decision checks.
private func approvalView(
    id: String = "ap1",
    plugin: String = "nftpolicy",
    action: String = "apply-ruleset",
    node: String = "node-a",
    plan: String = "table inet lattice_policy {}",
    hash: String? = nil,
    status: String = "pending",
    approvedBy: String? = nil,
    rejectedBy: String? = nil,
    stale: Bool = false,
    waiting: String? = nil,
    updatedAt: String = "2026-06-17T02:05:00Z"
) -> String {
    var fields = [
        #""id":"\#(id)""#, #""node_id":"\#(node)""#, #""plugin":"\#(plugin)""#, #""action":"\#(action)""#,
        #""plan":"\#(plan)""#, #""plan_sha256":"\#(hash ?? PlanHasher.sha256Hex(plan))""#, #""status":"\#(status)""#,
        #""actor_id":"admin""#, #""created_at":"2026-06-17T02:00:00Z""#, #""updated_at":"\#(updatedAt)""#,
    ]
    if let approvedBy { fields.append(#""approved_by":"\#(approvedBy)""#) }
    if let rejectedBy { fields.append(contentsOf: [#""rejected_by":"\#(rejectedBy)""#, #""rejected_at":"\#(updatedAt)""#]) }
    if stale { fields.append(#""stale":true,"stale_code":"agent_update_policy_changed""#) }
    if let waiting { fields.append(#""waiting":\#(waiting)"#) }
    return "{" + fields.joined(separator: ",") + "}"
}

/// `expect` with an eagerly evaluated condition, so it may contain `try`.
private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure.failed(message) }
}

private func checkDate(_ text: String) -> Date? {
    ISO8601DateFormatter().date(from: text)
}

private func decoded(_ json: String) throws -> Approval {
    try JSONDecoder().decode(Approval.self, from: Data(json.utf8))
}

/// A scripted transport: answers by "METHOD path?query" in order, and can
/// throw a URLError to stand for a timeout after send.
private actor ScriptedTransport: HTTPTransport {
    enum Answer {
        case json(Int, String)
        case fail(URLError.Code)
    }

    private var script: [String: [Answer]]
    private(set) var requests: [String] = []
    private(set) var bodies: [String: [[String: String]]] = [:]

    init(_ script: [String: [Answer]]) {
        self.script = script
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try expectUnwrapped(request.url, "request URL")
        let query = url.query.map { "?\($0)" } ?? ""
        let key = "\(request.httpMethod ?? "GET") \(url.path)\(query)"
        requests.append(key)
        if let body = request.httpBody, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            bodies[key, default: []].append(object.compactMapValues { value in (value as? String) ?? (value as? Bool).map { $0 ? "true" : "false" } })
        }
        guard var answers = script[key], !answers.isEmpty else {
            throw CheckFailure.failed("unscripted request \(key); seen \(requests)")
        }
        let answer = answers.removeFirst()
        script[key] = answers
        switch answer {
        case .fail(let code):
            throw URLError(code)
        case .json(let status, let text):
            let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            return (Data(text.utf8), http)
        }
    }

    func bodiesFor(_ key: String) -> [[String: String]] { bodies[key] ?? [] }
    var count: Int { requests.count }
}

/// Counts authentications and answers with a fixed outcome.
private actor CountingAuth: DecisionAuthenticator {
    let outcome: DeviceAuthOutcome
    private(set) var reasons: [String] = []

    init(_ outcome: DeviceAuthOutcome) {
        self.outcome = outcome
    }

    func authenticate(reason: String) async -> DeviceAuthOutcome {
        reasons.append(reason)
        return outcome
    }
}

private func errorEnvelope(_ code: String, _ message: String) -> String {
    #"{"error":{"code":"\#(code)","message":"\#(message)","request_id":"req_check"}}"#
}

// MARK: Request bodies

private func checkDecisionBodies() async throws {
    let planBody = "table inet lattice_guard {}"
    let planHash = PlanHasher.sha256Hex(planBody)
    let rejectJSON = """
    {"id":"ap1","node_id":"node-a","plugin":"nftpolicy","action":"apply nft",
     "plan":"\(planBody)","plan_sha256":"\(planHash)","status":"rejected","actor_id":"admin",
     "rejected_by":"admin","created_at":"2026-06-17T02:00:00Z"}
    """
    let dismissJSON = """
    {"id":"ap-stale","node_id":"node-a","plugin":"agentupdate","action":"agent.update",
     "plan":"target_version: 0.2.7","plan_sha256":"deadbeef","status":"dismissed","actor_id":"admin"}
    """
    let transport = MockTransport(responses: [
        "https://lattice.example.com/api/network/approvals?id=ap1": (200, ApprovalSamples.byID(planBody: planBody, planHash: planHash).data(using: .utf8)!),
        "https://lattice.example.com/api/network/approvals/approve": (
            200,
            """
            {"id":"ap1","node_id":"node-a","plugin":"nftpolicy","action":"apply nft","plan":"\(planBody)","plan_sha256":"\(planHash)","status":"approved","actor_id":"admin","approved_by":"admin"}
            """.data(using: .utf8)!
        ),
        "https://lattice.example.com/api/network/approvals/reject": (200, rejectJSON.data(using: .utf8)!),
        "https://lattice.example.com/api/network/approvals/dismiss": (200, dismissJSON.data(using: .utf8)!),
    ])
    let client = LatticeClient(baseURL: checkBase, credential: LatticeCredential(sessionCookie: "sid", csrfToken: "csrf-token"), transport: transport)

    let loaded = try await client.fetchApproval(id: "ap1")
    let approved = try await client.approveReviewed(loaded, queueApply: true)
    try expectEqual(approved.status, "approved", "approve returns approved status")
    let approveBody = try await bodyObject(transport.bodies.last ?? nil)
    try expectEqual(Set(approveBody.keys), ["approval_id", "queue_apply", "plan_sha256"], "approve sends exactly the server fields")
    try expectEqual(approveBody["approval_id"] as? String, "ap1", "approve approval_id")
    try expectEqual(approveBody["queue_apply"] as? Bool, true, "approve queue_apply")
    try expectEqual(approveBody["plan_sha256"] as? String, planHash, "approve plan_sha256 matches plan hash")
    try expectEqual(await transport.csrfHeaders.last ?? nil, "csrf-token", "approve carries CSRF header")
    try expectEqual(await transport.methods.last ?? nil, "POST", "approve is a POST")
    try expectEqual(await transport.requestURLs.last, "https://lattice.example.com/api/network/approvals/approve", "approve path")

    let rejected = try await client.rejectApproval(approvalID: "ap1")
    try expectEqual(rejected.status, "rejected", "reject status")
    try expectEqual(rejected.rejectedBy, "admin", "rejected_by")
    let rejectBody = try await bodyObject(transport.bodies.last ?? nil)
    try expectEqual(Set(rejectBody.keys), ["approval_id"], "reject sends only approval_id")
    try expectEqual(rejectBody["approval_id"] as? String, "ap1", "reject approval_id")

    let dismissed = try await client.dismissApproval(approvalID: "ap-stale", note: "superseded")
    try expectEqual(dismissed.status, "dismissed", "dismiss status")
    let dismissBody = try await bodyObject(transport.bodies.last ?? nil)
    try expectEqual(Set(dismissBody.keys), ["approval_id", "note"], "dismiss sends approval_id and note")
    try expectEqual(dismissBody["approval_id"] as? String, "ap-stale", "dismiss approval_id")
    try expectEqual(dismissBody["note"] as? String, "superseded", "dismiss note")

    // A listing row has no body: approving from it must never send.
    let listingRow = Approval(id: "ap1", plugin: "nftpolicy", planSHA256: planHash, status: "pending")
    do {
        _ = try await client.approveReviewed(listingRow, queueApply: true)
        throw CheckFailure.failed("approving a listing row must refuse")
    } catch ApprovalReviewError.emptyPlan {}
}

// MARK: Decoding

private func checkApprovalDecoding() async throws {
    let waiting = #"{"code":"task_queued","reason":"queued for node-a","blocked":false,"node_id":"node-a","node_name":"node-a","node_status":"online","node_status_since":"2026-06-17T01:00:00Z","task_id":"task-1","task_status":"queued","superseded_by":"","dismissible":false}"#
    let view = try decoded(approvalView(status: "approved", approvedBy: "admin", waiting: waiting))
    try expectEqual(view.waiting?.code, "task_queued", "waiting code decodes")
    try expectEqual(view.waiting?.taskID, "task-1", "waiting task decodes")
    try check(view.waiting?.nodeStatusSince != nil, "waiting node_status_since decodes")
    try expectEqual(view.displayState, .applying, "approved and moving reads applying")

    let rejected = try decoded(approvalView(status: "rejected", rejectedBy: "u-2"))
    try check(rejected.rejectedAt != nil, "rejected_at decodes")
    try expectEqual(rejected.displayState, .rejected, "rejected with rejected_by reads rejected")
    let failed = try decoded(approvalView(status: "rejected", approvedBy: "admin"))
    try expectEqual(failed.displayState, .failed, "rejected without rejected_by reads failed")

    // Every response shape the module reads.
    let rows = [approvalView(id: "a"), approvalView(id: "b", status: "approved", approvedBy: "admin")]
    let transport = MockTransport(responses: [
        "https://lattice.example.com/api/network/approvals": (200, json("[\(rows.joined(separator: ","))]")),
        "https://lattice.example.com/api/network/approvals?status=pending&include=plan&limit=100&offset=0": (200, json(#"{"approvals":[\#(rows[0])],"total":120,"limit":100,"offset":0}"#)),
        "https://lattice.example.com/api/network/approvals?count=1": (200, json(#"{"counts":{"pending":2,"approved":1,"stale":1,"applied":4,"rejected":1,"dismissed":0,"total":9}}"#)),
        "https://lattice.example.com/api/network/approvals?id=missing": (404, json(errorEnvelope("not_found", "approval not found"))),
        "https://lattice.example.com/api/network/approvals?id=html": (200, json("<!doctype html><title>Lattice</title>")),
        "https://lattice.example.com/api/network/approvals?id=nohash": (200, json(#"{"approval":{"id":"nohash","status":"pending","plan":"x"}}"#)),
    ])
    let client = LatticeClient(baseURL: checkBase, transport: transport)
    let bare = try await client.listApprovals()
    try expectEqual(bare.map(\.id), ["a", "b"], "bare listing decodes")
    let page = try await client.approvalsListPage(query: ApprovalQuery(status: "pending", limit: 100), includePlan: true)
    try expectEqual(page.total, 120, "envelope total decodes, for Showing 100 of N")
    try expectEqual(page.approvals.first?.hasPlanBody, true, "include=plan carries bodies")
    let counts = try await client.countApprovals()
    try expectEqual(counts.pending, 2, "counts decode")
    do {
        _ = try await client.fetchApproval(id: "missing")
        throw CheckFailure.failed("a 404 by id must throw")
    } catch LatticeAPIError.notFound {}
    do {
        _ = try await client.fetchApproval(id: "html")
        throw CheckFailure.failed("an undecodable body must throw")
    } catch LatticeAPIError.invalidResponse {}
    do {
        _ = try await client.fetchApproval(id: "nohash")
        throw CheckFailure.failed("a body without plan_sha256 must fail closed")
    } catch LatticeAPIError.invalidResponse {}
}

// MARK: Grouping (console approvalsModel.test.ts)

private func item(_ id: String, plugin: String = "agentupdate", action: String = "update-agent", node: String? = nil, plan: String = "", status: String = "pending", actor: String = ApprovalEvents.systemWriter, created: String = "2026-08-06T10:00:00Z") throws -> Approval {
    var approval = try decoded(approvalView(id: id, plugin: plugin, action: action, node: node ?? "node-\(id)", plan: "", status: status))
    approval.plan = plan
    approval.actorID = actor
    approval.createdAt = checkDate(created)
    return approval
}

private func agentPlan(_ current: String, _ target: String, _ node: String = "edge-1") -> String {
    ["# lattice agent update plan", "node_name: \(node)", "current_version: \(current)", "target_version: \(target)", "artifact_url: https://dl.example.invalid/agent"].joined(separator: "\n")
}

private func checkApprovalGrouping() throws {
    for status in ["pending", "approved"] {
        try check(ApprovalEvents.isGroupable(try item("s-\(status)", status: status)), "\(status) is groupable")
    }
    for status in ["applied", "rejected", "dismissed", "failed"] {
        try check(!ApprovalEvents.isGroupable(try item("s-\(status)", status: status)), "\(status) is not groupable")
    }

    let byWriter = ApprovalEvents.group([
        try item("w1", plugin: "selfdns", action: "apply-zone:a", actor: "lattice-server"),
        try item("w2", plugin: "selfdns", action: "apply-zone:b", actor: "lattice-server"),
        try item("w3", plugin: "selfdns", action: "apply-zone:a", actor: "operator-7"),
        try item("w4", plugin: "nftpolicy", action: "apply-zone:a", actor: "lattice-server"),
    ])
    try expectEqual(byWriter.count, 3, "writer + plugin + prefix make three events")
    try expectEqual(byWriter.map(\.approvals.count).sorted(), [1, 1, 2], "event sizes")
    let pair = try expectUnwrapped(byWriter.first { $0.approvals.count == 2 }, "the pair")
    try expectEqual(pair.writer, "lattice-server", "pair writer")
    try expectEqual(pair.actionPrefix, "apply-zone", "pair prefix")

    let transitions = ApprovalEvents.group([
        try item("t1", plan: agentPlan("0.3.0", "0.3.3", "edge-1")),
        try item("t2", plan: agentPlan("0.3.0", "0.3.3", "edge-2")),
        try item("t3", plan: agentPlan("0.3.3-alpha.2", "0.3.3", "edge-3")),
    ])
    try expectEqual(transitions.count, 2, "agent updates group by transition")
    let main = try expectUnwrapped(transitions.first { $0.approvals.count == 2 }, "main transition")
    try expectEqual(main.transition, ApprovalsVersionTransition(current: "0.3.0", target: "0.3.3"), "main transition parsed")
    try expectEqual(main.approvals.map { ApprovalEvents.nodeLabel($0) }, ["edge-1", "edge-2"], "items sorted by node label")
    try expectEqual(ApprovalEvents.summary(main), "Agent update to 0.3.3 on 2 nodes", "group row title")
    try expectEqual(ApprovalEvents.batchTitle(main), "Agent update to 0.3.3, 2 plans", "batch sheet title")

    let parsed = ApprovalEvents.parseAgentUpdatePlan("node_name: \"edge 9\"\ncurrent_version: 0.3.0\ntarget_version: 0.3.3\n")
    try expectEqual(parsed.transition, ApprovalsVersionTransition(current: "0.3.0", target: "0.3.3"), "parse versions")
    try expectEqual(parsed.nodeName, "edge 9", "parse quoted node name")
    let partial = ApprovalEvents.parseAgentUpdatePlan("target_version: 0.3.3\nunrelated: line")
    try check(partial.transition == nil && partial.nodeName == nil, "partial plan has no transition")

    let linemeta = ApprovalEvents.group(try (0..<24).map { index in
        try item("lm\(index)", plugin: "singbox-linemeta", action: "apply-metadata:\(String(format: "%064d", index))", plan: "{\"lines\":\(index + 1)}")
    })
    try expectEqual(linemeta.count, 1, "linemeta collapses into one event")
    try expectEqual(linemeta.first?.approvals.count, 24, "24 linemeta items")
    try expectEqual(linemeta.first?.title, "Line metadata sync", "linemeta title")
    try expectEqual(linemeta.first?.isSystem, true, "system writer")

    var production = try (0..<20).map { try item("p\($0)", plan: agentPlan("0.3.0", "0.3.3", "edge-\($0)")) }
    production.append(try item("p99", plan: agentPlan("0.3.3-alpha.2", "0.3.3", "edge-99")))
    production += try (0..<24).map { try item("pm\($0)", plugin: "singbox-linemeta", action: "apply-metadata:\(String(format: "%064d", $0))", plan: "{}") }
    let titles = ApprovalEvents.group(production).map { "\($0.title) (\($0.approvals.count))" }.sorted()
    try expectEqual(titles, ["Fleet upgrade 0.3.0 → 0.3.3 (20)", "Fleet upgrade 0.3.3-alpha.2 → 0.3.3 (1)", "Line metadata sync (24)"], "production batch events")

    let unknown = ApprovalEvents.group([try item("u1", actor: ""), try item("u2", actor: "   ")])
    try expectEqual(unknown.count, 1, "blank writers collapse")
    try expectEqual(unknown.first?.writer, ApprovalEvents.unknownWriter, "unknown writer")
    try expectEqual(unknown.first?.isSystem, false, "unknown is not system")
    try expectEqual(ApprovalEvents.writer(try item("u3", actor: "  ops-bot ")), "ops-bot", "writer trims")

    try expectEqual(ApprovalEvents.eventTitle(plugin: "agentupdate", actionPrefix: "update-agent", transition: nil), "Fleet upgrade", "fleet upgrade without transition")
    try expectEqual(ApprovalEvents.eventTitle(plugin: "selfdns", actionPrefix: "apply-zone", transition: nil), "Apply Zone", "generic title")
    try expectEqual(ApprovalEvents.humanizeActionPrefix("apply-metadata"), "Apply Metadata", "humanize")
    try expectEqual(ApprovalEvents.actionPrefix("apply-metadata:deadbeef"), "apply-metadata", "prefix before colon")
    try expectEqual(ApprovalEvents.actionPrefix("update-agent"), "update-agent", "prefix without colon")

    let older = try item("o1", plugin: "selfdns", action: "apply-zone", created: "2026-08-06T09:00:00Z")
    var newer = try (0..<8).map { try item("n\($0)", plugin: "nftpolicy", action: "sync-rules", node: "node-0\($0)", created: "2026-08-06T11:00:00Z") }
    newer.append(try item("n-dup", plugin: "nftpolicy", action: "sync-rules", node: "node-00", created: "2026-08-06T11:00:00Z"))
    let sorted = ApprovalEvents.group([older] + newer)
    try expectEqual(sorted.first?.plugin, "nftpolicy", "newest event first")
    let preview = ApprovalEvents.nodePreview(try expectUnwrapped(sorted.first, "newest"))
    try expectEqual(preview.nodes, ["node-00", "node-01", "node-02", "node-03", "node-04", "node-05"], "preview dedupes and caps")
    try expectEqual(preview.extra, 2, "8 distinct nodes minus 6")

    // Firewall and NetGuard share plugin and prefix; the kind keeps them apart.
    let rulesets = ApprovalEvents.group([
        try item("f1", plugin: "nft", action: "apply-ruleset", actor: "admin"),
        try item("f2", plugin: "nft", action: "apply-ruleset:netguard-v1", actor: "admin"),
    ])
    try expectEqual(rulesets.count, 2, "firewall and NetGuard are two events")
    try check(ApprovalEvents.key(for: try item("f3", plugin: "nft", action: "apply-ruleset", actor: "admin")) == rulesets.first { $0.approvals.first?.id == "f1" }?.key, "key(for:) matches the group key")
}

private func checkApprovalTitles() throws {
    let cases: [(String, String, String, String)] = [
        ("agentupdate", "update-agent", "", "Update the node agent"),
        ("sshguard", "sshguard-confirm:v1", "", "Confirm the SSH Guard arm"),
        ("sshguard", "sshguard-arm:v1", "", "Arm SSH Guard"),
        ("nft", "apply-ruleset:netguard-v1", "", "Apply NetGuard security groups"),
        ("nft", "apply-ruleset", "", "Apply the firewall ruleset"),
        ("singbox-lineuser", "apply-line-user:abc", "apply_remove", "Remove a VPN user from a line"),
        ("beacon", "node.beacon", "", "Open, change or close a node's beacon"),
        ("example.plugin", "example.plugin/reference/plan", "", "Reference plan (plugin)"),
    ]
    for (plugin, action, method, title) in cases {
        let approval = Approval(id: "t", plugin: plugin, action: action, method: method)
        try expectEqual(ApprovalEvents.title(for: approval), title, "title for \(plugin) \(action)")
    }
    try expectEqual(ApprovalEvents.rawLabel(Approval(id: "t", plugin: "sshguard", action: "sshguard-arm:v1")), "sshguard · sshguard-arm", "raw label")
    try expectEqual(ApprovalEvents.pluginSymbol("sshguard"), "lock.shield", "plugin glyph")
    try expectEqual(ApprovalEvents.pluginSymbol("someone.else"), "puzzlepiece.extension", "unknown plugin glyph")
}

// MARK: Eligibility

private func checkDecisionEligibility() throws {
    let plan = "table inet lattice_policy {}"
    let pending = try decoded(approvalView(plugin: "sshguard", action: "sshguard-confirm:v1", plan: plan))
    let operatorScopes = ScopeSet(scopes: TokenPresets.operator.scopes)
    let readOnly = ScopeSet(scopes: ["network:plan", "sshguard:read"])

    try expectEqual(ApprovalsDecisionGate.approveBlock(pending, hashVerified: true, companionBehind: false, scopes: operatorScopes), nil, "Operator may approve a verified pending plan")
    try expectEqual(ApprovalsDecisionGate.approveBlock(pending, hashVerified: true, companionBehind: false, scopes: nil), nil, "unknown scopes do not block")
    try expectEqual(ApprovalsDecisionGate.approveBlock(pending, hashVerified: true, companionBehind: true, scopes: operatorScopes), "This app is behind the server", "companion behind blocks")
    try expectEqual(ApprovalsDecisionGate.approveBlock(pending, hashVerified: false, companionBehind: false, scopes: operatorScopes), "Plan does not match its hash", "mismatch blocks approve")
    try expectEqual(ApprovalsDecisionGate.approveBlock(pending, hashVerified: true, companionBehind: false, scopes: readOnly), "Deciding needs network:apply and sshguard:admin", "read-only names both missing scopes")
    try expectEqual(ApprovalsDecisionGate.approveBlock(pending, hashVerified: true, companionBehind: false, scopes: operatorScopes, inFlight: true), "A decision is in progress", "in flight blocks")
    try expectEqual(ApprovalsDecisionGate.rejectBlock(pending, companionBehind: false, scopes: operatorScopes), nil, "reject allowed on mismatch")

    let stale = try decoded(approvalView(plugin: "agentupdate", action: "update-agent", plan: plan, stale: true))
    try expectEqual(ApprovalsDecisionGate.approveBlock(stale, hashVerified: true, companionBehind: false, scopes: operatorScopes), "Stale: inspect only", "stale blocks approve")
    try expectEqual(ApprovalsDecisionGate.rejectBlock(stale, companionBehind: false, scopes: operatorScopes), "Stale: inspect only", "stale blocks reject")
    try check(ApprovalsDecisionGate.canReplan(stale), "stale agent update can be replanned")
    try check(!ApprovalsDecisionGate.canReplan(pending), "fresh rows are not replanned")
    try expectEqual(ApprovalsDecisionGate.approveBlock(pending, hashVerified: true, companionBehind: false, scopes: operatorScopes, identityLoaded: false), "Identity not loaded", "no actor id blocks approve")
    try expectEqual(ApprovalsDecisionGate.rejectBlock(pending, companionBehind: false, scopes: operatorScopes, identityLoaded: false), "Identity not loaded", "no actor id blocks reject")

    // The server retires a stale agent update on its next listing read:
    // rejected, the stale reason, and no approved_by or rejected_by. That is
    // the only stale agent update a client ever receives.
    let retired = try decoded(approvalView(plugin: "agentupdate", action: "update-agent", plan: plan, status: "rejected", stale: true))
    try check(ApprovalsTransition.isStaleRetirement(retired), "a rejected stale row with no decider is a stale retirement")
    try check(ApprovalsDecisionGate.canReplan(retired), "a retired stale agent update can be replanned")
    try check(ApprovalsDecisionGate.canDismiss(retired), "a retired stale agent update can be dismissed")
    try expectEqual(ApprovalsDecisionGate.approveBlock(retired, hashVerified: true, companionBehind: false, scopes: operatorScopes), "Stale: inspect only", "a retired stale row reads as stale")
    try check(!ApprovalsDecisionGate.canReplan(try decoded(approvalView(plugin: "agentupdate", action: "update-agent", node: "", plan: plan, status: "rejected", stale: true))), "a stale row without a node is not replanned")

    let approved = try decoded(approvalView(plan: plan, status: "approved", approvedBy: "admin"))
    try expectEqual(ApprovalsDecisionGate.approveBlock(approved, hashVerified: true, companionBehind: false, scopes: operatorScopes), "No longer pending", "decided rows are not pending")

    let netguard = try decoded(approvalView(plugin: "nft", action: "apply-ruleset:netguard-v1", plan: plan))
    try expectEqual(ApprovalsDecisionGate.missingScopes(netguard, scopes: operatorScopes), ["netguard:admin"], "Operator lacks netguard:admin")

    // canDismiss: the server's waiting.dismissible first, then the fallback.
    let dismissibleWait = #"{"code":"plan_superseded","reason":"replaced","blocked":true,"dismissible":true}"#
    let stuckWait = #"{"code":"node_offline","reason":"offline","blocked":true,"dismissible":false}"#
    try check(ApprovalsDecisionGate.canDismiss(try decoded(approvalView(plugin: "nftpolicy", status: "approved", approvedBy: "a", waiting: dismissibleWait))), "waiting.dismissible true wins")
    try check(!ApprovalsDecisionGate.canDismiss(try decoded(approvalView(plugin: "agentupdate", status: "approved", approvedBy: "a", waiting: stuckWait))), "waiting.dismissible false wins over the plugin fallback")
    try check(ApprovalsDecisionGate.canDismiss(stale), "a stale agent update falls back to dismissible")
    try check(!ApprovalsDecisionGate.canDismiss(pending), "a fresh pending SSH Guard row is not dismissible")
    try check(!ApprovalsDecisionGate.canDismiss(try decoded(approvalView(plugin: "agentupdate", action: "update-agent"))), "a fresh pending agent update is not dismissible")
    try check(!ApprovalsDecisionGate.canDismiss(try decoded(approvalView(plugin: "sshguard", action: "sshguard-arm:v1", stale: true))), "only agent updates are dismissible by staleness")
    try check(!ApprovalsDecisionGate.canDismiss(try decoded(approvalView(plugin: "nftpolicy"))), "a fresh nftpolicy row is not dismissible")
    try check(!ApprovalsDecisionGate.canDismiss(try decoded(approvalView(plugin: "agentupdate", status: "dismissed"))), "a dismissed row is not dismissible again")

    try expectEqual(
        ApprovalsDecisionGate.authReason(.approve(queueApply: true), approval: pending, nodeName: "edge-tyo-2"),
        "Approve Confirm the SSH Guard arm on edge-tyo-2, plan \(PlanSeal.short(pending.planSHA256))",
        "approve reason names action, node and seal"
    )
    try expectEqual(ApprovalsDecisionGate.authReason(.reject, approval: pending, nodeName: "edge-tyo-2"), "Reject Confirm the SSH Guard arm on edge-tyo-2", "reject reason")
    try expectEqual(ApprovalsDecisionGate.batchAuthReason(.approve(queueApply: true), count: 13, title: "Agent update to 0.4.2"), "Approve 13 plans: Agent update to 0.4.2", "batch reason says the count once")
}

private func checkTransitionVerification() throws {
    let before = try decoded(approvalView())
    let mine = try decoded(approvalView(status: "approved", approvedBy: "u-me"))
    let theirs = try decoded(approvalView(status: "approved", approvedBy: "u-other"))
    try check(ApprovalsTransition.verified(.approve(queueApply: true), before: before, after: mine, actorID: "u-me"), "my approval verifies")
    try check(!ApprovalsTransition.verified(.approve(queueApply: true), before: before, after: theirs, actorID: "u-me"), "an approval by someone else does not")
    try check(ApprovalsTransition.verified(.approve(queueApply: true), before: before, after: try decoded(approvalView(status: "applied", approvedBy: "u-me")), actorID: "u-me"), "an apply that already ran still verifies")
    try check(!ApprovalsTransition.verified(.reject, before: before, after: theirs, actorID: "u-me"), "reject answered with an unchanged approved view does not verify")
    try check(ApprovalsTransition.verified(.reject, before: before, after: try decoded(approvalView(status: "rejected", rejectedBy: "u-me")), actorID: "u-me"), "my rejection verifies")
    try check(!ApprovalsTransition.verified(.reject, before: before, after: try decoded(approvalView(status: "rejected", approvedBy: "u-me")), actorID: "u-me"), "a failed apply is not a rejection")
    try check(ApprovalsTransition.verified(.dismiss(note: "x"), before: before, after: try decoded(approvalView(status: "dismissed")), actorID: "u-me"), "dismissal verifies by status")
    try check(!ApprovalsTransition.verified(.dismiss(note: "x"), before: try decoded(approvalView(status: "dismissed")), after: try decoded(approvalView(status: "dismissed")), actorID: "u-me"), "an already dismissed row does not")
    try check(!ApprovalsTransition.verified(.approve(queueApply: true), before: before, after: theirs, actorID: ""), "without an actor id, someone else's approval does not verify")
    try check(!ApprovalsTransition.verified(.reject, before: before, after: try decoded(approvalView(status: "rejected", rejectedBy: "u-other")), actorID: ""), "without an actor id, a rejection does not verify")
    let retired = try decoded(approvalView(plugin: "agentupdate", status: "rejected", stale: true))
    try check(!ApprovalsTransition.verified(.approve(queueApply: true), before: before, after: retired, actorID: "u-me"), "a stale retirement is not an approval")
    try expectEqual(ApprovalsTransition.decider(retired), "Lattice", "a stale retirement was decided by Lattice")
    try expectEqual(ApprovalsTransition.statusWord(try decoded(approvalView(status: "rejected", approvedBy: "u-me"))), "approved, then failed to apply,", "a failed apply keeps its wording")
}

// MARK: DecisionFlow

private func checkDecisionFlowCancel() async throws {
    let approval = try decoded(approvalView())
    for decision in [ApprovalsDecision.approve(queueApply: true), .reject, .dismiss(note: "No longer needed")] {
        for outcome in [DeviceAuthOutcome.cancelled, .failed("Biometry is locked out.")] {
            let transport = ScriptedTransport([:])
            let flow = DecisionFlow(client: LatticeClient(baseURL: checkBase, transport: transport), authenticator: CountingAuth(outcome))
            let result = await flow.decide(decision, on: approval, actorID: "u-me", reason: "check")
            try expectEqual(await transport.count, 0, "\(decision.verb) with authentication \(outcome) sends zero requests")
            switch (result, outcome) {
            case (.cancelled, .cancelled), (.authenticationFailed, .failed): break
            default: throw CheckFailure.failed("\(decision.verb) after \(outcome) returned \(result)")
            }
        }
    }
    // A body that does not hash is refused before Face ID and before any request.
    let mismatch = try decoded(approvalView(hash: String(repeating: "0", count: 64)))
    let auth = CountingAuth(.confirmed)
    let transport = ScriptedTransport([:])
    let result = await DecisionFlow(client: LatticeClient(baseURL: checkBase, transport: transport), authenticator: auth).decide(.approve(queueApply: true), on: mismatch, actorID: "u-me", reason: "check")
    try expectEqual(await transport.count, 0, "a mismatched plan sends nothing")
    try expectEqual(await auth.reasons.count, 0, "a mismatched plan never asks for Face ID")
    guard case .finished(.refused(.validation, _), _) = result else { throw CheckFailure.failed("mismatch refuses: \(result)") }
    let emptyNote = await DecisionFlow(client: LatticeClient(baseURL: checkBase, transport: transport), authenticator: auth).decide(.dismiss(note: "   "), on: approval, actorID: "u-me", reason: "check")
    guard case .finished(.refused(.validation, _), _) = emptyNote else { throw CheckFailure.failed("an empty note refuses: \(emptyNote)") }
    try expectEqual(await transport.count, 0, "an empty dismiss note sends nothing")
}

private func checkDecisionFlowOutcomes() async throws {
    let plan = "table inet lattice_policy {}"
    let approval = try decoded(approvalView(plan: plan))
    let get = "GET /api/network/approvals?id=ap1"
    let approve = "POST /api/network/approvals/approve"
    let mode = TimeZoneMode.utc
    let locale = Locale(identifier: "en_GB")

    func run(_ decision: ApprovalsDecision, _ script: [String: [ScriptedTransport.Answer]], on target: Approval = approval) async -> (DecisionFlow.Result, ScriptedTransport) {
        let transport = ScriptedTransport(script)
        let flow = DecisionFlow(client: LatticeClient(baseURL: checkBase, transport: transport), authenticator: CountingAuth(.confirmed), mode: mode, locale: locale)
        return (await flow.decide(decision, on: target, actorID: "u-me", reason: "check"), transport)
    }

    // Approve lands, the reload shows a waiting record.
    let moving = #"{"code":"task_running","reason":"the apply task is running on node-a","blocked":false}"#
    let landed = approvalView(plan: plan, status: "approved", approvedBy: "u-me", waiting: moving)
    var (result, transport) = await run(.approve(queueApply: true), [approve: [.json(200, approvalView(plan: plan, status: "approved", approvedBy: "u-me"))], get: [.json(200, #"{"approval":\#(landed)}"#)]])
    guard case .finished(.done(let message, _), let reloaded) = result else { throw CheckFailure.failed("approve lands: \(result)") }
    try expectEqual(message, "Approved, apply in progress: the apply task is running on node-a", "approve waiting sentence")
    try expectEqual(reloaded?.waiting?.code, "task_running", "the reloaded view carries waiting")
    try expectEqual(await transport.requests, [approve, get], "approve then reload by id")
    try expectEqual(await transport.bodiesFor(approve).first?["plan_sha256"], PlanHasher.sha256Hex(plan), "approve sends the hash of the body on screen")

    let blocked = #"{"code":"node_offline","reason":"node-a has been offline for 3 h","blocked":true}"#
    (result, _) = await run(.approve(queueApply: true), [approve: [.json(200, "{}")], get: [.json(200, #"{"approval":\#(approvalView(plan: plan, status: "approved", approvedBy: "u-me", waiting: blocked))}"#)]])
    guard case .finished(.done("Approved, waiting: node-a has been offline for 3 h", _), _) = result else { throw CheckFailure.failed("blocked waiting sentence: \(result)") }
    (result, transport) = await run(.approve(queueApply: false), [approve: [.json(200, "{}")], get: [.json(200, #"{"approval":\#(approvalView(plan: plan, status: "approved", approvedBy: "u-me"))}"#)]])
    guard case .finished(.done("Approved; apply not queued.", _), _) = result else { throw CheckFailure.failed("approve only sentence: \(result)") }
    try expectEqual(await transport.bodiesFor(approve).first?["queue_apply"], "false", "Approve only sends queue_apply false")

    // Idempotent 200: someone else approved first; the answer is the unchanged view.
    let theirs = approvalView(plan: plan, status: "approved", approvedBy: "u-other", updatedAt: "2026-06-17T02:04:00Z")
    (result, _) = await run(.approve(queueApply: true), [approve: [.json(200, theirs)], get: [.json(200, #"{"approval":\#(theirs)}"#)]])
    guard case .finished(.refused(.alreadyDecided(let status, let by, _), let refusal), _) = result else { throw CheckFailure.failed("already approved: \(result)") }
    try expectEqual(status, "approved", "already decided status")
    try expectEqual(by, "u-other", "already decided by")
    try expectEqual(refusal, "Not recorded: this plan was already approved by u-other at \(TimeDisplay.clock(checkDate("2026-06-17T02:04:00Z")!, mode: mode, locale: locale)).", "already decided sentence")

    // A stale agent update the server retired while Review was open: approve
    // answers 200 with the unchanged rejected view. Nobody approved it.
    let retiredView = approvalView(plugin: "agentupdate", action: "update-agent", plan: plan, status: "rejected", stale: true, updatedAt: "2026-06-17T02:04:00Z")
    (result, _) = await run(.approve(queueApply: true), [approve: [.json(200, retiredView)], get: [.json(200, #"{"approval":\#(retiredView)}"#)]], on: try decoded(approvalView(plugin: "agentupdate", action: "update-agent", plan: plan)))
    guard case .finished(.refused(.alreadyDecided(_, let retiredBy, _), let retiredRefusal), _) = result else { throw CheckFailure.failed("stale retirement: \(result)") }
    try expectEqual(retiredBy, "Lattice", "a stale retirement names Lattice")
    try expectEqual(retiredRefusal, "Not recorded: this plan was already retired as stale (the agent update policy changed) by Lattice at \(TimeDisplay.clock(checkDate("2026-06-17T02:04:00Z")!, mode: mode, locale: locale)).", "stale retirement sentence")

    // Without an actor id a decision someone else made is never green.
    do {
        let transport = ScriptedTransport([approve: [.json(200, theirs)], get: [.json(200, #"{"approval":\#(theirs)}"#)]])
        let flow = DecisionFlow(client: LatticeClient(baseURL: checkBase, transport: transport), authenticator: CountingAuth(.confirmed), mode: mode, locale: locale)
        let anonymous = await flow.decide(.approve(queueApply: true), on: approval, actorID: "", reason: "check")
        guard case .finished(.unknown(let note), _) = anonymous else { throw CheckFailure.failed("no actor id is not done: \(anonymous)") }
        try check(note.hasPrefix("Sent; this app could not confirm who decided it"), "no actor id says it could not confirm the decider")
    }

    // Reject on an approval that is no longer pending also answers 200 unchanged.
    let reject = "POST /api/network/approvals/reject"
    (result, _) = await run(.reject, [reject: [.json(200, theirs)], get: [.json(200, #"{"approval":\#(theirs)}"#)]])
    guard case .finished(.refused(.alreadyDecided, _), _) = result else { throw CheckFailure.failed("reject after approval elsewhere: \(result)") }
    (result, _) = await run(.reject, [reject: [.json(200, "{}")], get: [.json(200, #"{"approval":\#(approvalView(plan: plan, status: "rejected", rejectedBy: "u-me"))}"#)]])
    guard case .finished(.done("Rejected.", _), _) = result else { throw CheckFailure.failed("reject lands: \(result)") }

    // 409 approval_stale on approve: re-review, never retry.
    (result, transport) = await run(.approve(queueApply: true), [
        approve: [.json(409, errorEnvelope("approval_stale", "plan changed since review; re-review before approving"))],
        get: [.json(200, #"{"approval":\#(approvalView(plan: "table inet lattice_policy { changed }"))}"#)],
    ])
    guard case .finished(.refused(.approvalStale, "This plan changed since you opened it."), let fresh) = result else { throw CheckFailure.failed("approve stale: \(result)") }
    try expectEqual(fresh?.plan, "table inet lattice_policy { changed }", "the stale answer reloads the new body")
    try expectEqual(await transport.requests.filter { $0 == approve }.count, 1, "a stale approve is never retried")

    // 409 approval_stale on dismiss means not dismissible.
    let dismiss = "POST /api/network/approvals/dismiss"
    (result, _) = await run(.dismiss(note: "No longer needed"), [dismiss: [.json(409, errorEnvelope("approval_stale", "approval is not stale; reject or approve it explicitly"))], get: [.json(200, #"{"approval":\#(approvalView(plan: plan))}"#)]])
    guard case .finished(.refused(.notDismissible, "Not dismissible: approve or reject it."), _) = result else { throw CheckFailure.failed("dismiss not dismissible: \(result)") }
    (result, transport) = await run(.dismiss(note: "  No longer needed "), [dismiss: [.json(200, "{}")], get: [.json(200, #"{"approval":\#(approvalView(plan: plan, status: "dismissed"))}"#)]])
    guard case .finished(.done("Dismissed.", _), _) = result else { throw CheckFailure.failed("dismiss lands: \(result)") }
    try expectEqual(await transport.bodiesFor(dismiss).first?["note"], "No longer needed", "the note is sent trimmed")

    // A timeout after send is read back, never retried.
    (result, transport) = await run(.approve(queueApply: true), [approve: [.fail(.timedOut)], get: [.json(200, #"{"approval":\#(approvalView(plan: plan, status: "approved", approvedBy: "u-me"))}"#)]])
    guard case .finished(.done, _) = result else { throw CheckFailure.failed("timeout then verified: \(result)") }
    try expectEqual(await transport.requests, [approve, get], "a timeout reloads once and does not resend")
    (result, _) = await run(.approve(queueApply: true), [approve: [.fail(.timedOut)], get: [.json(200, #"{"approval":\#(approvalView(plan: plan))}"#)]])
    guard case .finished(.unknown("Could not confirm. The plan is now pending."), _) = result else { throw CheckFailure.failed("timeout then unconfirmed: \(result)") }

    // No connection: nothing left the phone.
    (result, transport) = await run(.reject, [reject: [.fail(.notConnectedToInternet)]])
    guard case .finished(.refused(.notSent, _), _) = result else { throw CheckFailure.failed("offline reject: \(result)") }
    try expectEqual(await transport.count, 1, "an unsent request is not reloaded")

    // 403 and 404.
    (result, _) = await run(.reject, [reject: [.json(404, errorEnvelope("not_found", "approval not found"))]])
    guard case .finished(.refused(.notFound, _), _) = result else { throw CheckFailure.failed("reject 404: \(result)") }
    (result, _) = await run(.reject, [reject: [.json(403, errorEnvelope("forbidden", "missing scope sshguard:admin"))]])
    guard case .finished(.refused(.forbidden, _), _) = result else { throw CheckFailure.failed("reject 403: \(result)") }
}

private func checkBatchDecisions() async throws {
    let plans = ["table a {}", "table b {}", "table c {}"]
    let approvals = try plans.enumerated().map { index, plan in try decoded(approvalView(id: "b\(index)", node: "node-\(index)", plan: plan)) }
    var script: [String: [ScriptedTransport.Answer]] = ["POST /api/network/approvals/approve": Array(repeating: .json(200, "{}"), count: 3)]
    for (index, plan) in plans.enumerated() {
        let by = index == 2 ? "u-other" : "u-me"
        script["GET /api/network/approvals?id=b\(index)"] = [.json(200, #"{"approval":\#(approvalView(id: "b\(index)", node: "node-\(index)", plan: plan, status: "approved", approvedBy: by))}"#)]
    }
    let transport = ScriptedTransport(script)
    let auth = CountingAuth(.confirmed)
    let flow = DecisionFlow(client: LatticeClient(baseURL: checkBase, transport: transport), authenticator: auth)
    let result = await flow.decideBatch(.approve(queueApply: true), on: approvals, actorID: "u-me", reason: "Approve 3 plans")
    try expectEqual(await auth.reasons, ["Approve 3 plans"], "one Face ID for the batch")
    guard case .finished(let rows, let reloaded, let summary) = result else { throw CheckFailure.failed("batch finished: \(result)") }
    guard case .partial(let succeeded, let failed, let message) = summary else { throw CheckFailure.failed("mixed batch is partial: \(summary)") }
    try expectEqual(message, "2 approved, 1 not recorded", "batch banner")
    try expectEqual(succeeded.count, 2, "two landed")
    try expectEqual(failed.first?.object.id, "b2", "the row decided elsewhere failed")
    if case .refused(.alreadyDecided, _)? = rows["b2"] {} else { throw CheckFailure.failed("b2 already decided: \(String(describing: rows["b2"]))") }
    try expectEqual(reloaded.count, 3, "every row reloaded by id")
    let hashes = Set(await transport.bodiesFor("POST /api/network/approvals/approve").compactMap { $0["plan_sha256"] })
    try expectEqual(hashes, Set(plans.map(PlanHasher.sha256Hex)), "each row sends its own plan_sha256")

    let cancelTransport = ScriptedTransport([:])
    let cancelled = await DecisionFlow(client: LatticeClient(baseURL: checkBase, transport: cancelTransport), authenticator: CountingAuth(.cancelled)).decideBatch(.reject, on: approvals, actorID: "u-me", reason: "Reject 3 plans")
    guard case .cancelled = cancelled else { throw CheckFailure.failed("cancelled batch: \(cancelled)") }
    try expectEqual(await cancelTransport.count, 0, "a cancelled batch sends nothing")

    let allDone = DecisionFlow.batchSummary(.reject, approvals: Array(approvals.prefix(2)), rows: ["b0": .done("Rejected."), "b1": .done("Rejected.")])
    guard case .done("2 plans rejected", _) = allDone else { throw CheckFailure.failed("clean batch summary: \(allDone)") }
    let unconfirmed = DecisionFlow.batchSummary(.approve(queueApply: true), approvals: Array(approvals.prefix(2)), rows: ["b0": .done("Approved."), "b1": .unknown("Could not confirm.")])
    guard case .partial(_, _, "1 approved, 1 could not be confirmed") = unconfirmed else { throw CheckFailure.failed("an unconfirmed row is not called unrecorded: \(unconfirmed)") }

    let fetchTransport = ScriptedTransport([
        "GET /api/network/approvals?id=b0": [.json(200, #"{"approval":\#(approvalView(id: "b0", plan: plans[0]))}"#)],
        "GET /api/network/approvals?id=b1": [.json(404, errorEnvelope("not_found", "approval not found"))],
    ])
    let loaded = await LatticeClient(baseURL: checkBase, transport: fetchTransport).approvalsFetchAll(ids: ["b0", "b1"])
    if case .success(let first)? = loaded["b0"] { try expectEqual(first.id, "b0", "batch load by id") } else { throw CheckFailure.failed("b0 loads") }
    if case .failure(.notFound)? = loaded["b1"] {} else { throw CheckFailure.failed("b1 fails with notFound") }
}

// MARK: Pending listing

/// The pending page carries no bodies; agent-update bodies come from one
/// narrow read, and only while a row's body is not cached for its hash.
private func checkPendingPlanHydration() async throws {
    let agentPlan = "plugin: agentupdate\ncurrent_version: 0.3.9\ntarget_version: 0.3.10\nnode_name: edge-a"
    let agentHash = PlanHasher.sha256Hex(agentPlan)
    let rows = #"[{"id":"au1","node_id":"node-a","plugin":"agentupdate","action":"update-agent","plan_sha256":"\#(agentHash)","status":"pending"},{"id":"np1","node_id":"node-b","plugin":"nftpolicy","action":"apply-ruleset","plan_sha256":"abc","status":"pending"}]"#
    let bodies = #"[{"id":"au1","node_id":"node-a","plugin":"agentupdate","action":"update-agent","plan":"\#(agentPlan.replacingOccurrences(of: "\n", with: "\\n"))","plan_sha256":"\#(agentHash)","status":"pending"}]"#
    let list = "GET /api/network/approvals?status=pending&limit=100&offset=0"
    let narrow = "GET /api/network/approvals?status=pending&include=plan&plugin=agentupdate&limit=100&offset=0"
    let page = #"{"approvals":\#(rows),"total":2,"limit":100,"offset":0}"#
    let transport = ScriptedTransport([
        list: [.json(200, page), .json(200, page)],
        narrow: [.json(200, #"{"approvals":\#(bodies),"total":1,"limit":100,"offset":0}"#)],
    ])
    let client = LatticeClient(baseURL: checkBase, transport: transport)
    let (first, cache) = try await client.approvalsPendingPage(cache: ApprovalsPlanCache())
    try expectEqual(await transport.requests, [list, narrow], "the first read fetches agent-update bodies once, narrowly")
    try expectEqual(first.approvals.first { $0.id == "au1" }?.plan, agentPlan, "the agent-update row carries its body")
    try check(first.approvals.first { $0.id == "np1" }?.hasPlanBody == false, "other rows stay without bodies")
    try expectEqual(ApprovalEvents.group(first.approvals).first { $0.plugin == "agentupdate" }?.transition?.target, "0.3.10", "grouping reads the hydrated body")
    let (second, _) = try await client.approvalsPendingPage(cache: cache)
    try expectEqual(await transport.requests, [list, narrow, list], "a cached body is not fetched again")
    try expectEqual(second.approvals.first { $0.id == "au1" }?.plan, agentPlan, "the cached body is filled in")
}

// MARK: Demo routes

private func checkApprovalsDemoRoutes() async throws {
    for extra in ApprovalsFixtures.extras {
        try expectEqual(PlanHasher.sha256Hex(extra.plan), extra.planSHA256, "\(extra.id) hashes to its plan_sha256")
    }
    let state = DemoState()
    func client(_ scenario: DemoScenario = .normal) -> LatticeClient {
        LatticeClient(baseURL: DemoWorld.baseURL, credential: LatticeCredential(bearerToken: DemoWorld.token), transport: DemoTransport(identity: .pat, scenario: scenario, clock: DemoClock(pinned: "2026-10-28T09:00:00Z")!, state: state))
    }
    let demo = client()

    let pendingQuery = ApprovalQuery(status: "pending", limit: 100)
    let pending = try await demo.approvalsListPage(query: pendingQuery, includePlan: true)
    try check(pending.approvals.contains { $0.id == "approval_m1_netguard" }, "the pending listing carries the module's extras")
    try check(pending.approvals.allSatisfy(\.hasPlanBody), "include=plan carries bodies")
    let events = ApprovalEvents.group(pending.approvals.filter(\.isHumanPending))
    let firewall = try expectUnwrapped(events.first { $0.plugin == "nft" && $0.approvals.count == 3 }, "the firewall group")
    try expectEqual(Set(firewall.approvals.map(\.planSHA256)).count, 1, "the firewall group shares one body")
    let agents = try expectUnwrapped(events.first { $0.plugin == "agentupdate" && $0.approvals.count == 3 }, "the agent-update group")
    try expectEqual(Set(agents.approvals.map(\.planSHA256)).count, 3, "the agent-update group has three bodies")

    let triage = try await client(.limitedToken).approvalsListPage(query: pendingQuery, includePlan: true)
    try expectEqual(triage.approvals.count, 0, "Triage lists no approvals")

    // Approve lands and reads back approved by this actor.
    let beacon = try await demo.fetchApproval(id: "approval_d1006")
    let approved = try await demo.approveReviewed(beacon, queueApply: true)
    try expectEqual(approved.approvedBy, DemoWorld.actorID, "demo approve records the actor")
    let reread = try await demo.fetchApproval(id: "approval_d1006")
    try expectEqual(reread.status, "approved", "demo ?id= shows the decision")
    try check(reread.waiting != nil, "an approved row carries waiting")

    // The raced approval comes back decided by another operator.
    let raced = try await demo.fetchApproval(id: ApprovalsFixtures.racedApprovalID)
    let raceAnswer = try await demo.approveReviewed(raced, queueApply: true)
    try expectEqual(raceAnswer.approvedBy, ApprovalsFixtures.otherOperator, "the race is won elsewhere")

    // Hash mismatch and stale answer 409 approval_stale.
    do {
        _ = try await demo.approveApproval(approvalID: "approval_d1005", queueApply: true, planSHA256: String(repeating: "a", count: 64))
        throw CheckFailure.failed("a wrong hash must be refused")
    } catch LatticeAPIError.conflict(let code, _, _) {
        try expectEqual(code, "approval_stale", "wrong hash is approval_stale")
    }
    let stale = try await demo.fetchApproval(id: "approval_d1008")
    if stale.isPending {
        do {
            _ = try await demo.approveReviewed(stale, queueApply: true)
            throw CheckFailure.failed("a stale approval must be refused")
        } catch LatticeAPIError.conflict(let code, _, _) {
            try expectEqual(code, "approval_stale", "stale is approval_stale")
        }
    } else {
        try check(ApprovalsTransition.isStaleRetirement(stale), "approval_d1008 is served as the server retires it")
    }

    // The module's retired stale agent update has the server's shape, and
    // Review offers both of its exits.
    let retired = try await demo.fetchApproval(id: ApprovalsFixtures.retiredAgentUpdateID)
    try check(ApprovalsTransition.isStaleRetirement(retired), "the retired agent update is rejected, stale, with no decider")
    try check(ApprovalsDecisionGate.canReplan(retired), "replan is offered on the retired stale row")
    try check(ApprovalsDecisionGate.canDismiss(retired), "dismiss is offered on the retired stale row")
    let history = try await demo.listApprovals(query: ApprovalQuery(status: "approved,applied,rejected,dismissed", includeDismissed: true))
    try check(history.approvals.contains { $0.id == ApprovalsFixtures.retiredAgentUpdateID }, "History lists the retired agent update")

    // Dismiss: only agent updates and SSH Guard, only when dismissible.
    do {
        _ = try await demo.dismissApproval(approvalID: "approval_d1005", note: "x")
        throw CheckFailure.failed("dismissing an outbound policy must be refused")
    } catch LatticeAPIError.server(let status, _, _) {
        try expectEqual(status, 400, "non-dismissible plugin answers 400")
    }
    do {
        _ = try await demo.dismissApproval(approvalID: "approval_d1002", note: "x")
        throw CheckFailure.failed("dismissing a fresh agent update must be refused")
    } catch LatticeAPIError.conflict(let code, _, _) {
        try expectEqual(code, "approval_stale", "not dismissible is approval_stale")
    }
    let dismissed = try await demo.dismissApproval(approvalID: "approval_d0906", note: "Superseded by approval_d1002")
    try expectEqual(dismissed.status, "dismissed", "a dismissible wait is dismissed")
    let retiredDismissed = try await demo.dismissApproval(approvalID: ApprovalsFixtures.retiredAgentUpdateID, note: "Replanned")
    try expectEqual(retiredDismissed.status, "dismissed", "a retired stale agent update is dismissed")

    // The NetGuard plan reads, but the Operator token cannot decide it.
    let netguard = try await demo.fetchApproval(id: "approval_m1_netguard")
    try check(netguard.planHashMatchesServer, "the NetGuard body hashes")
    do {
        _ = try await demo.rejectApproval(approvalID: netguard.id)
        throw CheckFailure.failed("deciding without netguard:admin must be refused")
    } catch LatticeAPIError.forbidden {}
}
