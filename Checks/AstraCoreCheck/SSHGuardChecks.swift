import Foundation
import AstraCore

public func checkSSHGuard() async throws {
    try checkSSHGuardDecoding()
    try checkSSHGuardFormAndSources()
    try checkSSHGuardArmBodies()
    try checkSSHGuardRotation()
    try await checkSSHGuardWriteFlows()
    try await checkSSHGuardDemoFlows()
    try await checkSSHGuardKnockReveal()
    try await checkSSHGuardBoard()
}

private let sgBase = "https://lattice.example.com"
private let sgClock = DemoClock(pinned: "2026-10-28T12:00:00Z")!

private func sgMock(_ responses: [String: (Int, Data)]) -> (LatticeClient, MockTransport) {
    let transport = MockTransport(responses: responses)
    let client = LatticeClient(baseURL: URL(string: sgBase)!, credential: LatticeCredential(bearerToken: "lat_check.notasecret"), transport: transport)
    return (client, transport)
}

private func sgDemo(_ identity: DemoIdentity = .pat, scenario: DemoScenario = .normal, state: DemoState = DemoState()) -> LatticeClient {
    let credential = identity == .pat
        ? LatticeCredential(bearerToken: DemoWorld.token)
        : LatticeCredential(sessionCookie: "sess_demo_notasecret", csrfToken: "csrf_demo_notasecret")
    return LatticeClient(baseURL: DemoWorld.baseURL, credential: credential,
                         transport: DemoTransport(identity: identity, scenario: scenario, clock: sgClock, state: state))
}

/// Sorted-key JSON, so goldens compare exactly.
private func sgCanonical(_ data: Data?) throws -> String {
    let data = try expectUnwrapped(data, "request body")
    let object = try JSONSerialization.jsonObject(with: data)
    return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

private func sgEncode(_ request: SSHGuardPlanRequest) throws -> String {
    try sgCanonical(try JSONEncoder().encode(request))
}

private struct SSHGuardAuthStub: WriteAuthenticator {
    let outcome: DeviceAuthOutcome
    func authenticate(reason: String) async -> DeviceAuthOutcome { outcome }
}

// MARK: - Decoding

private func checkSSHGuardDecoding() throws {
    let plan = try JSONDecoder().decode(SSHGuardPlanResponse.self, from: json(#"""
    {"approval":{"id":"approval_x","node_id":"n-a","plugin":"sshguard","action":"sshguard-arm:v1","plan":"stage: arm\n","plan_sha256":"ab","status":"pending","created_at":"2026-10-28T11:00:00Z"},
     "findings":[{"code":"single_way_in","severity":"warn","message":"one IP"}]}
    """#))
    try expectEqual(plan.filedApprovalIDs, ["approval_x"], "plan answer approval id")
    try expectEqual(plan.findings.first?.isBlocking, false, "warn finding is not blocking")
    let bare = try JSONDecoder().decode(SSHGuardPlanResponse.self, from: json(#"{"approval":{"id":"approval_y","plan_sha256":"cd","status":"pending"}}"#))
    try expect(bare.findings.isEmpty, "findings are optional")

    let confirm = try JSONDecoder().decode(SSHGuardConfirmResponse.self, from: json(#"{"approval":{"id":"approval_c","plan_sha256":"ef","status":"pending","action":"sshguard-confirm:v1"}}"#))
    try expectEqual(confirm.approval.id, "approval_c", "confirm answer")

    let installed = try JSONDecoder().decode(SSHGuardKnockState.self, from: json(#"""
    {"ok":true,"node_id":"n-a","knowledge":"installed","note":"known","gate_present":true,"revealable":true,"requires_step_up":true,
     "interactive_only":true,"approval_id":"arm-1","applied_at":"2026-10-28T11:49:00Z","confirmed":false,"port_count":3,
     "seq_timeout_sec":15,"open_for":"12h","ssh_port":3434,"previous_honoured":true}
    """#))
    try expectEqual(installed.knowledge, "installed", "knock knowledge")
    try expectEqual(installed.sshPort, 3434, "knock ssh port")
    try expectEqual(installed.previousHonoured, true, "previous honoured")
    try expectEqual(installed.gatePresent, true, "gate present")
    try expect(installed.appliedAt != nil, "applied at decodes")
    // An older server sends neither gate_present nor previous_honoured.
    let old = try JSONDecoder().decode(SSHGuardKnockState.self, from: json(#"{"ok":true,"node_id":"n-b","knowledge":"no_knock","note":"none","revealable":false,"requires_step_up":true,"interactive_only":true}"#))
    try expectEqual(old.gatePresent, nil, "gate_present absent")
    try expectEqual(old.previousHonoured, false, "previous_honoured absent")
    try expectEqual(old.sshPort, nil, "no ssh port")

    let reveal = try JSONDecoder().decode(SSHGuardKnockReveal.self, from: json(#"""
    {"ok":true,"node_id":"n-a","knowledge":"installed","approval_id":"arm-1","ports":[27431,45902,38117],"seq_timeout_sec":15,
     "open_for":"12h","ssh_port":22,"address":"203.0.113.12","note":"n","confirmed":true,"gate_present":true,
     "commands":[{"id":"knock","install":[{"platform":"macos","command":"brew install knock"}],"command":"knock 203.0.113.12 27431 45902 38117 && ssh 203.0.113.12"},{"id":"bash","command":"bash form"}],
     "sequence_sha256":"aa"}
    """#))
    try expectEqual(reveal.ports, [27431, 45902, 38117], "revealed ports")
    try expectEqual(reveal.shownValue, "knock 203.0.113.12 27431 45902 38117 && ssh 203.0.113.12", "the knock command is the shown value")
    try expectEqual(reveal.sequenceSHA256, "aa", "digest")
    try expectEqual(reveal.previousPorts, [], "previous ports absent")
    let noCommands = try JSONDecoder().decode(SSHGuardKnockReveal.self, from: json(#"{"ports":[1,2,3],"sequence_sha256":"bb"}"#))
    try expectEqual(noCommands.shownValue, "1 2 3", "ports when no command")
}

// MARK: - Form and sources (sshGuardModel.test.ts)

private func checkSSHGuardFormAndSources() throws {
    let parsed = SSHGuardRotation.parseMgmtSources("203.0.113.5, 198.51.100.0/24\n2001:db8::1  bad.host 10.0.0.1/33")
    try expectEqual(parsed.values, ["203.0.113.5", "198.51.100.0/24", "2001:db8::1"], "valid sources")
    try expectEqual(parsed.invalid, ["bad.host", "10.0.0.1/33"], "invalid sources")
    try expectEqual(SSHGuardRotation.parseMgmtSources("203.0.113.5").values, ["203.0.113.5"], "a bare address stays bare")
    try expectEqual(SSHGuardRotation.parseMgmtSources("10.0.0.1 10.0.0.1").values, ["10.0.0.1"], "duplicates collapse")

    func form(_ change: (inout SSHGuardRotation.Form) -> Void = { _ in }) -> SSHGuardRotation.Form {
        var form = SSHGuardRotation.Form(nodeID: "n-a", sshPort: 58394, keepLegacyPort: false, mgmtSources: "203.0.113.5",
                                         enableKnock: true, outOfBandFallback: false, confirmWindowSec: 900)
        change(&form)
        return form
    }
    try expect(SSHGuardRotation.validate(form { $0.mgmtSources = "" }).contains(.singleWayIn), "single way in")
    try expect(!SSHGuardRotation.validate(form { $0.mgmtSources = ""; $0.outOfBandFallback = true }).contains(.singleWayIn), "fallback answers single way in")
    try expect(!SSHGuardRotation.validate(form()).contains(.singleWayIn), "a source answers single way in")
    try expect(SSHGuardRotation.validate(form { $0.sshPort = 22 }).contains(.portIsLegacy), "22 is the legacy port")
    try expect(SSHGuardRotation.validate(form { $0.confirmWindowSec = 60 }).contains(.windowTooShort), "window too short")
    try expect(SSHGuardRotation.validate(form { $0.sshPort = 70000 }).contains(.portRange), "port range")
    try expect(SSHGuardRotation.validate(form { $0.mgmtSources = "nope" }).contains(.sourcesInvalid), "invalid source")
    try expectEqual(SSHGuardRotation.validate(.defaults(nodeID: "n-a")), [.singleWayIn], "the default form is refused until a way in is added")
    try expectEqual(SSHGuardRotation.validate(.defaults(nodeID: "")), [.nodeRequired, .singleWayIn], "no node")

    // Prefill from the node's last arm: knock, window, port and sources read back.
    let plan = "stage: arm\nssh_port: 3434\nkeep_legacy_port: true\nknock: true\nconfirm_window_sec: 1800\n\n## Management sources (reach SSH without knocking, no expiry)\n\n- 203.0.113.5/32\n- 198.51.100.0/24\n"
    let lastArm = try JSONDecoder().decode(SSHGuardApprovalRef.self, from: json(#"{"approval_id":"arm-1","status":"applied","outcome":"applied","knock":true,"confirm_window_sec":1800}"#))
    let prefilled = SSHGuardRotation.Form.prefilled(nodeID: "n-a", lastArm: lastArm, lastArmPlan: plan)
    try expectEqual(prefilled.sshPort, 3434, "prefilled port")
    try expectEqual(prefilled.confirmWindowSec, 1800, "prefilled window")
    try expectEqual(prefilled.mgmtSources, "203.0.113.5/32\n198.51.100.0/24", "prefilled sources")
    try expectEqual(prefilled.outOfBandFallback, false, "sources, not the fallback")
    let terminal = SSHGuardRotation.Form.prefilled(nodeID: "n-a", lastArm: lastArm, lastArmPlan: "stage: arm\nknock: true\n\n## Management sources (reach SSH without knocking, no expiry)\n\n- (none)\n")
    try expectEqual(terminal.outOfBandFallback, true, "a knock arm with no source stood on the terminal")
    try expectEqual(SSHGuardRotation.Form.prefilled(nodeID: "n-a", lastArm: nil, lastArmPlan: nil), .defaults(nodeID: "n-a"), "no last arm: defaults")
}

// MARK: - Arm request goldens

private func checkSSHGuardArmBodies() throws {
    try expectEqual(try sgEncode(SSHGuardRotation.planRequest(.defaults(nodeID: "n-edge-sin-1"))),
                    #"{"enable_knock":true,"keep_legacy_port":true,"node_id":"n-edge-sin-1"}"#, "default arm body")
    let omitted = SSHGuardRotation.Form(nodeID: "n-a", sshPort: 0, keepLegacyPort: false, mgmtSources: "", enableKnock: false, outOfBandFallback: true, confirmWindowSec: 900)
    try expectEqual(try sgEncode(SSHGuardRotation.planRequest(omitted)),
                    #"{"enable_knock":false,"node_id":"n-a","out_of_band_fallback":true}"#, "what the operator did not choose is omitted")
    let full = SSHGuardRotation.Form(nodeID: " n-a ", sshPort: 58394, keepLegacyPort: true, mgmtSources: "203.0.113.5, 198.51.100.0/24 bad", enableKnock: true, outOfBandFallback: false, confirmWindowSec: 300)
    try expectEqual(try sgEncode(SSHGuardRotation.planRequest(full)),
                    #"{"confirm_window_sec":300,"enable_knock":true,"keep_legacy_port":true,"mgmt_sources":["203.0.113.5","198.51.100.0\/24"],"node_id":"n-a","ssh_port":58394}"#,
                    "full arm body")
    let plainBody = try sgEncode(SSHGuardRotation.planRequest(full))
    try expect(!plainBody.contains("accept_findings"), "accept_findings absent until accepted")
    let acceptedBody = try sgEncode(SSHGuardRotation.planRequest(full, acceptFindings: true))
    try expect(acceptedBody.contains(#""accept_findings":true"#), "accept_findings when accepted")
    try expectEqual(SSHGuardRotation.planRequest(full).accepting(false).acceptFindings, nil, "unchecked leaves it out")
}

// MARK: - Rotation (sshGuardModel.test.ts)

private func checkSSHGuardRotation() throws {
    let previous = "27431 45902 38117"
    let governing = "stage: arm\nssh_port: 58394\nknock: true\n"
    typealias R = SSHGuardRotation
    try expectEqual(R.eligibility(selected: ["installed"], previousPorts: "", sshPort: 58394, governingPlan: governing), .digest, "installed by digest")
    try expectEqual(R.eligibility(selected: ["installed_superseded"], previousPorts: "", sshPort: 58394, governingPlan: governing), .digest, "superseded by digest")
    try expectEqual(R.eligibility(selected: ["installed"], previousPorts: previous, sshPort: 58394, governingPlan: governing), .digest, "digest ignores the advanced field")
    try expectEqual(R.eligibility(selected: [], previousPorts: "", sshPort: 58394, governingPlan: governing), .refused(.selectOne), "none selected")
    try expectEqual(R.eligibility(selected: ["installed", "installed"], previousPorts: "", sshPort: 58394, governingPlan: governing), .refused(.selectOne), "two selected")
    try expectEqual(R.eligibility(selected: ["planned"], previousPorts: previous, sshPort: 58394, governingPlan: governing), .refused(.planned), "planned")
    try expectEqual(R.eligibility(selected: ["no_knock"], previousPorts: previous, sshPort: 58394, governingPlan: governing), .refused(.noKnock), "no knock")
    try expectEqual(R.eligibility(selected: ["unknown"], previousPorts: "", sshPort: 3434, governingPlan: nil), .refused(.previousPortsRequired), "ports required")
    try expectEqual(R.eligibility(selected: ["unknown"], previousPorts: "   ", sshPort: 3434, governingPlan: nil), .refused(.previousPortsRequired), "blank is required")
    for bad in ["1 2 3", "27431 45902", "27431 45902 45902", "27431,45902,38117,20001", "27431 abc 38117"] {
        try expectEqual(R.eligibility(selected: ["unknown"], previousPorts: bad, sshPort: 3434, governingPlan: nil), .refused(.previousPortsInvalid), "invalid ports \(bad)")
    }
    try expectEqual(R.eligibility(selected: ["unknown"], previousPorts: "27431, 45902, 38117", sshPort: 3434, governingPlan: nil), .previousPorts([27431, 45902, 38117]), "previous ports")
    try expectEqual(R.eligibility(selected: ["installed"], previousPorts: "", sshPort: nil, governingPlan: governing), .refused(.portUnknown), "port unknown")
    try expectEqual(R.eligibility(selected: ["installed"], previousPorts: "", sshPort: 58394, governingPlan: nil), .refused(.armUnresolved), "arm unresolved")
    try expectEqual(R.eligibility(selected: ["installed_superseded"], previousPorts: "", sshPort: nil, governingPlan: nil), .refused(.armUnresolved), "arm before port")
    try expect(R.RotateEligibility.digest.isOpenable && R.RotateEligibility.refused(.previousPortsRequired).isOpenable && R.RotateEligibility.refused(.previousPortsInvalid).isOpenable, "openable")
    for code in [R.RotateRefusal.planned, .noKnock, .selectOne, .armUnresolved] {
        try expect(!R.RotateEligibility.refused(code).isOpenable, "not openable \(code)")
    }

    try expectEqual(R.rotationSSHPort(serverPort: 58394, governingPlan: "ssh_port: 4000\n", observed: [22]), 58394, "server port first")
    try expectEqual(R.rotationSSHPort(serverPort: nil, governingPlan: "stage: arm\nssh_port: 4000\nknock: true\n", observed: [22]), 4000, "then the plan")
    try expectEqual(R.rotationSSHPort(serverPort: nil, governingPlan: "stage: arm\n", observed: [3434, 22]), 3434, "then sshd")
    try expectEqual(R.rotationSSHPort(serverPort: nil, governingPlan: nil, observed: []), nil, "unknown")

    let digest = String(repeating: "ab", count: 32)
    try expectEqual(try sgEncode(R.rotationRequest(nodeID: "n-a", sshPort: 58394, from: .digest(digest), fallback: .terminal)),
                    #"{"confirm_window_sec":3600,"enable_knock":true,"node_id":"n-a","out_of_band_fallback":true,"rotate_from_sha256":"\#(digest)","ssh_port":58394}"#,
                    "rotation by digest")
    try expectEqual(try sgEncode(R.rotationRequest(nodeID: "n-a", sshPort: 3434, from: .previousPorts([27431, 45902, 38117]), fallback: .sources(["203.0.113.5/32", "2001:db8::/64"]))),
                    #"{"confirm_window_sec":3600,"enable_knock":true,"mgmt_sources":["203.0.113.5\/32","2001:db8::\/64"],"node_id":"n-a","previous_knock_ports":[27431,45902,38117],"ssh_port":3434}"#,
                    "rotation by previous ports")
    for port in [0, 22] {
        let body = try sgEncode(R.rotationRequest(nodeID: "n-a", sshPort: port, from: .digest("x"), fallback: .terminal))
        try expect(!body.contains("ssh_port"), "port \(port) keeps the current one")
    }

    let withSources = "stage: arm\n\n## Management sources (reach SSH without knocking, no expiry)\n\n- 203.0.113.5/32\n- 198.51.100.0/24\n\n## sshd drop-in: /etc/ssh/sshd_config.d/50-lattice-guard.conf\n\n- not a source\n"
    try expectEqual(R.parseArmMgmtSources(withSources), ["203.0.113.5/32", "198.51.100.0/24"], "sources from the plan")
    try expectEqual(R.fallback(forPlan: withSources), .sources(["203.0.113.5/32", "198.51.100.0/24"]), "sources fallback")
    let none = "stage: arm\n\n## Management sources (reach SSH without knocking, no expiry)\n\n- (none)\n\n## sshd drop-in\n"
    try expectEqual(R.parseArmMgmtSources(none), [], "no sources")
    try expectEqual(R.fallback(forPlan: none), .terminal, "terminal fallback")
    try expectEqual(R.parseArmMgmtSources("stage: arm\n"), nil, "no section")
    try expectEqual(R.fallback(forPlan: nil), .terminal, "no plan")

    // The governing arm is the one the server names, not the newest record.
    let knockPlan = "# Lattice SSH Guard plan\n\nstage: arm\nnode_id: n-a\nssh_port: 3434\nkeep_legacy_port: true\nknock: true\ngated_ports: 22, 3434\nconfirm_window_sec: 900\n\n## Management sources (reach SSH without knocking, no expiry)\n\n- 203.0.113.5/32\n- 198.51.100.0/24\n"
    let hardeningPlan = "# Lattice SSH Guard plan\n\nstage: arm\nnode_id: n-a\nssh_port: 0\nkeep_legacy_port: true\nknock: false\nconfirm_window_sec: 3600\n"
    let iso = ISO8601DateFormatter()
    let arms = [
        Approval(id: "arm-knock", nodeID: "n-a", plugin: "sshguard", action: "sshguard-arm:v1", plan: knockPlan, status: "applied", createdAt: iso.date(from: "2026-08-20T10:00:00Z"), updatedAt: iso.date(from: "2026-08-20T10:01:00Z")),
        Approval(id: "arm-hardening", nodeID: "n-a", plugin: "sshguard", action: "sshguard-arm:v1", plan: hardeningPlan, status: "applied", createdAt: iso.date(from: "2026-08-28T10:00:00Z"), updatedAt: iso.date(from: "2026-08-28T10:01:00Z")),
        Approval(id: "arm-rejected", nodeID: "n-a", plugin: "sshguard", action: "sshguard-arm:v1", plan: knockPlan.replacingOccurrences(of: "3434", with: "4000"), status: "rejected", createdAt: iso.date(from: "2026-08-29T10:00:00Z")),
    ]
    let named = try expectUnwrapped(R.governingArm(arms, nodeID: "n-a", serverApprovalID: "arm-knock"), "named governing arm")
    try expectEqual(named.id, "arm-knock", "the server's arm")
    try expectEqual(R.governingArm(arms, nodeID: "n-a", serverApprovalID: nil)?.id, "arm-knock", "newest applied knock arm")
    try expectEqual(R.governingArm(arms, nodeID: "n-a", serverApprovalID: "arm-elsewhere")?.id, nil, "never a stand-in")
    try expectEqual(R.governingArm(arms, nodeID: "n-b", serverApprovalID: "arm-knock")?.id, nil, "the id must be this node's")
    let request = R.rotationRequest(nodeID: "n-a", sshPort: R.rotationSSHPort(serverPort: nil, governingPlan: named.plan, observed: [22, 3434]) ?? 0,
                                    from: .digest(digest), fallback: R.fallback(forPlan: named.plan))
    try expectEqual(request.sshPort, 3434, "rotation keeps the governing port")
    try expectEqual(request.mgmtSources, ["203.0.113.5/32", "198.51.100.0/24"], "rotation keeps the governing sources")
    try expectEqual(request.outOfBandFallback, nil, "sources and the terminal are alternatives")

    try expectEqual(R.parseKnockDeclared("knock: true\n"), true, "knock declared")
    try expectEqual(R.parseKnockDeclared("knock: enabled\n"), nil, "unknown knock value")
    try expectEqual(R.parseConfirmWindow("confirm_window_sec: 900\n"), 900, "window parsed")
    try expectEqual(SSHGuardIntents.windowWords(900), "15 minutes", "window words")
    try expectEqual(SSHGuardIntents.windowWords(3600), "1 hour", "window words hour")
}

// MARK: - Intents through WriteFlow

private func checkSSHGuardWriteFlows() async throws {
    let node = ObjectRef(kind: "node", id: "n-a", name: "edge-a")
    let blocked = #"{"error":"plan blocked by lint findings","findings":[{"code":"overridden_by_guard","severity":"block","message":"open tcp/22 in netguard first"}]}"#
    let filed = #"{"approval":{"id":"approval_arm","node_id":"n-a","plugin":"sshguard","action":"sshguard-arm:v1","plan_sha256":"aa","status":"pending"},"findings":[{"code":"single_way_in","severity":"warn","message":"one IP"}]}"#
    let transport = MockTransport(responses: [:])
    _ = transport
    let (client, mock) = sgMock(["\(sgBase)/api/sshguard/plan": (409, json(blocked))])
    let intent = SSHGuardIntents.arm(node, form: SSHGuardRotation.Form(nodeID: "n-a", mgmtSources: "203.0.113.5"))
    try expectEqual(intent.tier, .plan, "arm is a plan filing")
    try expect(!WriteFlow.requiresAuthentication(intent.tier), "plan filing needs no Face ID")
    try expectEqual(intent.toggles.first?.revealedByConflict, true, "accept findings appears only after a conflict")
    let first = await WriteFlow(intent: intent, client: client, authenticator: SSHGuardAuthStub(outcome: .cancelled)).commit(choices: ConfirmChoices())
    guard case .finished(.refused(.conflict(let findings), _)) = first else { throw CheckFailure.failed("arm with blocking findings must refuse with findings, got \(first)") }
    try expectEqual(findings, ["open tcp/22 in netguard first"], "findings listed verbatim")
    let firstBody = try sgCanonical(await mock.lastBody)
    try expect(!firstBody.contains("accept_findings"), "first send carries no acceptance")

    let (accepting, acceptMock) = sgMock(["\(sgBase)/api/sshguard/plan": (200, json(filed))])
    let second = await WriteFlow(intent: intent, client: accepting, authenticator: SSHGuardAuthStub(outcome: .cancelled))
        .commit(choices: ConfirmChoices(accepted: [SSHGuardIntents.acceptFindingsID]))
    guard case .finished(.filed(let ids, let refused, let notes)) = second else { throw CheckFailure.failed("accepted arm files, got \(second)") }
    try expectEqual(ids, ["approval_arm"], "filed approval")
    try expect(refused.isEmpty, "nothing refused")
    try expectEqual(notes, ["Filed the arm plan for edge-a", "one IP"], "warnings travel as notes")
    try expectEqual(try sgCanonical(await acceptMock.lastBody),
                    #"{"accept_findings":true,"enable_knock":true,"keep_legacy_port":true,"mgmt_sources":["203.0.113.5"],"node_id":"n-a"}"#,
                    "accepted arm body")

    let (confirmClient, confirmMock) = sgMock(["\(sgBase)/api/sshguard/confirm": (200, json(#"{"approval":{"id":"approval_cfm","plan_sha256":"bb","status":"pending"}}"#))])
    let timed = SSHGuardIntents.confirm(node, deadlineText: "08:25")
    try expect(timed.consequence.contains("before 08:25, or edge-a undoes"), "the confirm sheet states the deadline itself")
    try expect(!timed.consequence.contains("shown above"), "the confirm sheet points at nothing it does not show")
    let confirm = await WriteFlow(intent: SSHGuardIntents.confirm(node, deadlineText: nil), client: confirmClient, authenticator: SSHGuardAuthStub(outcome: .cancelled)).commit(choices: ConfirmChoices())
    guard case .finished(.filed(let confirmIDs, _, _)) = confirm else { throw CheckFailure.failed("confirm files, got \(confirm)") }
    try expectEqual(confirmIDs, ["approval_cfm"], "confirm approval")
    try expectEqual(try sgCanonical(await confirmMock.lastBody), #"{"node_id":"n-a"}"#, "confirm body")

    let (excludeClient, excludeMock) = sgMock(["\(sgBase)/api/nodes/capabilities": (200, json(#"{"node_id":"n-a","capability":"sshguard","state":"excluded","reason":"r","enforced":true}"#))])
    let exclude = SSHGuardIntents.exclude(node, reason: "lab machine")
    try expectEqual(exclude.tier, .t3, "exclusion is T3")
    try expectEqual(exclude.title, "Stop SSH Guard plans for edge-a", "the title reads with the node as its object")
    try expect(exclude.consequence.contains("\"lab machine\""), "the consequence quotes the operator's reason")
    let cancelled = await WriteFlow(intent: exclude, client: excludeClient, authenticator: SSHGuardAuthStub(outcome: .cancelled)).commit(choices: ConfirmChoices())
    guard case .cancelled = cancelled else { throw CheckFailure.failed("cancelled Face ID must cancel") }
    try expectEqual(await excludeMock.requestURLs.count, 0, "cancelled exclusion sends nothing")
    _ = await WriteFlow(intent: exclude, client: excludeClient, authenticator: SSHGuardAuthStub(outcome: .confirmed)).commit(choices: ConfirmChoices())
    try expectEqual(try sgCanonical(await excludeMock.lastBody), #"{"capability":"sshguard","node_id":"n-a","reason":"lab machine","state":"excluded"}"#, "exclude body")

    let rotation = SSHGuardIntents.rotate(node, request: SSHGuardRotation.rotationRequest(nodeID: "n-a", sshPort: 22, from: .digest("cc"), fallback: .terminal))
    let (rotateClient, rotateMock) = sgMock(["\(sgBase)/api/sshguard/plan": (200, json(filed))])
    _ = await WriteFlow(intent: rotation, client: rotateClient, authenticator: SSHGuardAuthStub(outcome: .cancelled)).commit(choices: ConfirmChoices())
    try expectEqual(try sgCanonical(await rotateMock.lastBody),
                    #"{"confirm_window_sec":3600,"enable_knock":true,"node_id":"n-a","out_of_band_fallback":true,"rotate_from_sha256":"cc"}"#, "rotation body")
}

// MARK: - Demo: arm then confirm, findings, actionable approvals

private func checkSSHGuardDemoFlows() async throws {
    let state = DemoState()
    let client = sgDemo(state: state)
    let sin = DemoWorld.node("edge-sin-1")
    let arm = try await client.sshGuardPlan(SSHGuardRotation.planRequest(SSHGuardRotation.Form(nodeID: sin.id, mgmtSources: "198.51.100.0/28")))
    let confirm = try await client.sshGuardConfirm(nodeID: sin.id)
    try expect(arm.approval.id != confirm.approval.id, "arm then confirm files two approvals")
    let armRead = try await client.fetchApproval(id: arm.approval.id)
    let confirmRead = try await client.fetchApproval(id: confirm.approval.id)
    try expect(armRead.isSSHGuardArm && armRead.planHashMatchesServer, "the filed arm reads back by id with a matching hash")
    try expect(confirmRead.isSSHGuardConfirm && confirmRead.planHashMatchesServer, "the filed confirm reads back by id")
    try expect(confirmRead.plan.contains(arm.approval.id), "the confirm names the arm it confirms")

    // A node whose guard ruleset would override the gate refuses until accepted.
    let hkg = DemoWorld.node("edge-hkg-2")
    do {
        _ = try await client.sshGuardPlan(SSHGuardRotation.planRequest(SSHGuardRotation.Form(nodeID: hkg.id, outOfBandFallback: true)))
        throw CheckFailure.failed("edge-hkg-2 arm should be blocked by findings")
    } catch let error as LatticeAPIError {
        guard case .conflict(_, _, let findings) = error, findings.contains(where: { $0.contains("lattice_guard") }) else {
            throw CheckFailure.failed("expected lint findings, got \(error)")
        }
    }
    let accepted = try await client.sshGuardPlan(SSHGuardRotation.planRequest(SSHGuardRotation.Form(nodeID: hkg.id, outOfBandFallback: true), acceptFindings: true))
    try expect(accepted.approval.plan.contains("knock: true"), "accepted plan filed")

    // Not enrolled: the capability refuses the arm.
    do {
        _ = try await client.sshGuardPlan(SSHGuardRotation.planRequest(SSHGuardRotation.Form(nodeID: DemoWorld.node("dns-iad-1").id, outOfBandFallback: true)))
        throw CheckFailure.failed("dns-iad-1 is not enrolled")
    } catch let error as LatticeAPIError {
        guard case .forbidden = error else { throw CheckFailure.failed("expected forbidden, got \(error)") }
    }

    // edge-tyo-2 is reverting with a confirm waiting: Confirm opens it in Review.
    let statuses = try await client.fetchSSHGuardStatus()
    let tyo = try expectUnwrapped(statuses.first { $0.nodeName == "edge-tyo-2" }, "edge-tyo-2 status")
    try expectEqual(SSHGuardConfirmTarget.of(tyo), .review(approvalID: "approval_d1001"), "actionable approval opens Review")
    let iad = try expectUnwrapped(statuses.first { $0.nodeName == "edge-iad-1" }, "edge-iad-1 status")
    try expectEqual(SSHGuardConfirmTarget.of(iad), .file, "awaiting confirm with nothing filed files a confirm")
    let armPending = try expectUnwrapped(statuses.first { $0.stage == "arm_pending" }, "arm pending status")
    try expectEqual(SSHGuardConfirmTarget.of(armPending), .file, "an arm approval is not a confirm to open")

    // Knock state for every knowledge the demo carries.
    let installed = try await client.sshGuardKnockState(nodeID: tyo.nodeID)
    try expectEqual(installed.knowledge, "installed", "edge-tyo-2 knock installed")
    try expectEqual(installed.approvalID, "approval_d0904", "governing arm named")
    let planned = try await client.sshGuardKnockState(nodeID: DemoWorld.node("edge-sin-2").id)
    try expectEqual(planned.knowledge, "planned", "planned knock")
    let noKnock = try await client.sshGuardKnockState(nodeID: sin.id)
    try expectEqual(noKnock.knowledge, "no_knock", "no knock")
    try expectEqual(noKnock.revealable, false, "nothing to reveal")

    // The governing arm of a storied node reads back in the real plan form.
    let tyo1 = DemoWorld.node("relay-tyo-1")
    let tyo1Knock = try await client.sshGuardKnockState(nodeID: tyo1.id)
    let governing = try await client.fetchApproval(id: tyo1Knock.approvalID)
    let port = SSHGuardRotation.rotationSSHPort(serverPort: tyo1Knock.sshPort, governingPlan: governing.plan, observed: [])
    try expectEqual(port, 22, "relay-tyo-1 runs sshd on 22, as its status reports")
    try expectEqual(SSHGuardRotation.rotationRequest(nodeID: tyo1.id, sshPort: port ?? 0, from: .digest("d"), fallback: .terminal).sshPort, nil, "22 keeps the current port")
    try expectEqual(SSHGuardRotation.eligibility(selected: [tyo1Knock.knowledge], previousPorts: "", sshPort: port, governingPlan: governing.plan), .digest, "rotation by digest")
    try expectEqual(SSHGuardRotation.fallback(forPlan: governing.plan), .sources(["198.51.100.0/28", "2001:db8:22::/48"]), "governing sources")

    // A token without network:plan cannot read the board, and the server skips nothing silently into a count.
    let triage = sgDemo(scenario: .limitedToken)
    let hidden = try await triage.fetchSSHGuardStatus()
    try expect(hidden.isEmpty, "Triage sees no SSH Guard rows")
    let confined = try await sgDemo(scenario: .confinedToken).fetchSSHGuardStatus()
    try expect(!confined.isEmpty && confined.allSatisfy { DemoWorld.confinedNodeIDs.contains($0.nodeID) }, "confined rows only")
}

// MARK: - Knock reveal needs the session and a step-up

private func checkSSHGuardKnockReveal() async throws {
    let node = DemoWorld.node("edge-tyo-2")
    let grant = StepUpGrant(grant: "grant_demo_notasecret", expiresAt: Date().addingTimeInterval(60))
    do {
        _ = try await sgDemo(.pat).sshGuardRevealKnock(nodeID: node.id, grant: grant)
        throw CheckFailure.failed("a token must not reveal")
    } catch let error as LatticeAPIError {
        guard case .forbidden(code: "secret_reveal_scope_required", _) = error else { throw CheckFailure.failed("token reveal: \(error)") }
    }
    do {
        _ = try await sgDemo(.session).sshGuardRevealKnock(nodeID: node.id, grant: StepUpGrant(grant: "stale", expiresAt: Date()))
        throw CheckFailure.failed("a session without a fresh grant must not reveal")
    } catch let error as LatticeAPIError {
        try expect(error.isStepUpRequired, "stale grant asks for step-up again, got \(error)")
    }
    let reveal = try await sgDemo(.session).sshGuardRevealKnock(nodeID: node.id, grant: grant)
    try expectEqual(reveal.ports.count, 3, "three ports")
    try expect(!reveal.sequenceSHA256.isEmpty, "digest returned")

    // The reveal intent hands the digest to a rotation and shows the command once.
    final class Capture: @unchecked Sendable { var digest: String? }
    let capture = Capture()
    let intent = SSHGuardIntents.knockReveal(ObjectRef(kind: "node", id: node.id, name: node.name)) { capture.digest = $0 }
    try expectEqual(intent.purpose, .knockSequence, "reveal purpose")
    try expectEqual(intent.scopes, ["sshguard:read", "network:plan"], "reveal scopes on the session")
    let secret = try await intent.perform(sgDemo(.session), grant)
    try expectEqual(capture.digest, reveal.sequenceSHA256, "digest captured")
    try expect(secret.value.contains(reveal.ports.map(String.init).joined(separator: " ")), "the knock command carries the ports")
    try expect(!secret.description.contains(secret.value), "the secret's description is redacted")

    // The rotation the demo accepts names the revealed digest.
    let state = DemoState()
    let rotated = try await sgDemo(state: state).sshGuardPlan(SSHGuardRotation.rotationRequest(nodeID: node.id, sshPort: 22, from: .digest(reveal.sequenceSHA256), fallback: .terminal))
    try expect(rotated.approval.plan.contains("keeps opening it beside the new one"), "rotation plan filed")
    do {
        _ = try await sgDemo(state: state).sshGuardPlan(SSHGuardRotation.rotationRequest(nodeID: node.id, sshPort: 22, from: .digest("wrong"), fallback: .terminal))
        throw CheckFailure.failed("a wrong digest must be refused")
    } catch let error as LatticeAPIError {
        guard case .conflict = error else { throw CheckFailure.failed("wrong digest: \(error)") }
    }
}

// MARK: - Board derivation, filters and queries

private func checkSSHGuardBoard() async throws {
    let now = sgClock.anchor
    let statuses = try await sgDemo().fetchSSHGuardStatus()
    let nodes = try await sgDemo().fetchNodes()
    let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    // Scope is the explicit record, as on the console; the demo's record list is empty, so the check supplies one.
    let records = [DemoWorld.node("edge-sin-1").id: "enrolled", DemoWorld.node("edge-iad-1").id: "enrolled", DemoWorld.node("dns-iad-1").id: "excluded"]
    let rows = statuses.map { SSHGuardBoardRow(status: $0, node: byID[$0.nodeID], now: now, record: records[$0.nodeID]) }
    let undecided = statuses.compactMap { status -> SSHGuardBoardRow? in
        guard records[status.nodeID] == nil, status.enrolled, status.stage == "idle" else { return nil }
        return SSHGuardBoardRow(status: status, node: byID[status.nodeID], now: now)
    }
    try expect(!undecided.isEmpty, "the demo has admitted nodes nobody enrolled")
    try expect(undecided.allSatisfy { $0.scope == .undecided && !$0.isArmable }, "admitted without an enrolment is undecided and cannot arm")
    let gated = statuses.first { !$0.enrolled }.map { SSHGuardBoardRow(status: $0, node: byID[$0.nodeID], now: now) }
    try expect(gated.map { $0.scope == .undecided && $0.coverage != .excluded } ?? false, "a node the gate refuses is not called excluded without a record")
    let (recordClient, _) = sgMock(["\(sgBase)/api/nodes/capabilities": (200, json(#"""
    {"capabilities":[{"node_id":"n-a","capability":"sshguard","state":"enrolled","updated_at":"2026-10-01T00:00:00Z","enforced":true},
                     {"node_id":"n-b","capability":"sshguard","state":"excluded","reason":"NAT","updated_at":"2026-10-01T00:00:00Z","enforced":true},
                     {"node_id":"n-a","capability":"netguard","state":"excluded","reason":"lab","updated_at":"2026-10-01T00:00:00Z","enforced":false}],
     "known":[]}
    """#))])
    try expectEqual(try await recordClient.sshGuardCapabilityRecords(), ["n-a": "enrolled", "n-b": "excluded"], "only the sshguard records, by node")
    let sections = SSHGuardBoardLayout.sections(rows)
    try expectEqual(sections.first?.section, .confirmNeeded, "confirm needed leads")
    let confirmNeeded = sections.first?.rows.map(\.name) ?? []
    try expectEqual(confirmNeeded.prefix(2), ["edge-tyo-2", "relay-fra-1"], "soonest deadline first")
    try expect(sections.map(\.section).last == .excluded, "excluded sinks")
    try expect(sections.first { $0.section == .excluded }?.rows.map(\.name) == ["dns-iad-1"], "the not-enrolled node is excluded")
    let tyo = try expectUnwrapped(rows.first { $0.name == "edge-tyo-2" }, "edge-tyo-2 row")
    try expectEqual(SSHGuardBoardAction.primary(for: tyo), .confirm(.review(approvalID: "approval_d1001")), "reverting row confirms through Review")
    let sin = try expectUnwrapped(rows.first { $0.name == "edge-sin-1" }, "edge-sin-1 row")
    try expectEqual(SSHGuardBoardAction.primary(for: sin), .arm, "an open node arms")
    let excluded = try expectUnwrapped(rows.first { $0.name == "dns-iad-1" }, "dns-iad-1 row")
    try expectEqual(SSHGuardBoardAction.primary(for: excluded), .none, "excluded nodes offer nothing")
    let failed = try expectUnwrapped(rows.first { $0.name == "edge-iad-1" }, "edge-iad-1 row")
    try expectEqual(failed.coverage, .failed, "a closed window reads as failed")
    try expectEqual(SSHGuardBoardAction.primary(for: failed), .arm, "a reverted node arms again")

    try expect(rows.filter(SSHGuardPostureFilter.passwordOpen.matches).allSatisfy { $0.posture == .passwordOpen }, "posture filter")
    try expectEqual(rows.filter(SSHGuardCoverageFilter.reverting.matches).map(\.name).sorted(), ["edge-tyo-2", "relay-fra-1"], "reverting filter")
    try expectEqual(SSHGuardCoverageFilter(title: "Not armed"), .open, "filter from its menu title")
    for filter in SSHGuardCoverageFilter.allCases where filter != .all {
        try expect(rows.contains(where: filter.matches), "demo covers coverage \(filter)")
    }
    for filter in SSHGuardPostureFilter.allCases where filter != .all {
        try expect(rows.contains(where: filter.matches), "demo covers posture \(filter)")
    }

    func query(_ text: String) throws -> [String] {
        switch LatticeQueryEngine.compile(text, provider: SSHGuardBoardQueryFields.self) {
        case .success(let compiled): return LatticeQueryEngine.apply(compiled, to: rows, now: now).map(\.name)
        case .failure(let error): throw CheckFailure.failed("query \(text): \(error)")
        }
    }
    let passwordNames = try query("posture:password")
    try expect(passwordNames.allSatisfy { name in rows.first { $0.name == name }?.posture == .passwordOpen }, "posture alias")
    try expectEqual(try query("is:reverting").sorted(), ["edge-tyo-2", "relay-fra-1"], "is:reverting")
    try expectEqual(try query("knock:superseded"), ["edge-fra-3"], "knock alias")
    try expectEqual(try query("port:3434"), [], "no node reports 3434 in sshd facts")
    let failedNames = try query("state:failed")
    try expect(failedNames.contains("edge-hkg-2"), "state:failed")
    let armableNames = try query("tag:edge is:armable")
    try expect(armableNames.contains("edge-sin-1"), "tag and armable")
    if case .success = LatticeQueryEngine.compile("bogus:1", provider: SSHGuardBoardQueryFields.self) {
        throw CheckFailure.failed("an unknown field is an error, as in the console")
    }
}
