import Foundation

/// Demo routes for the SSHGuard domain, owned by the SSHGuard module (section 8.6).
///
/// The status rows are Shared's (`SharedFixtures.sshGuardBody`); these routes
/// read them, so a node's stage, posture and knock read the same everywhere.
/// Filed plans get a fixed id per node and stage (`approval_sga_<node id>`,
/// `approval_sgc_<node id>`), with a `?id=` route each, so Review can load
/// what the phone filed. Session state: `sshguard.plan.<approval id>` holds a
/// filed plan body, `sshguard.filed` the filed ids.
public enum SSHGuardFixtures {
    public static var routes: [DemoRoute] {
        [
            DemoRoute(method: "POST", pathPattern: "/api/sshguard/plan") { request, state in
                await plan(request, state: state)
            }.requiring("sshguard:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/sshguard/confirm") { request, state in
                await confirm(request, state: state)
            }.requiring("sshguard:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/sshguard/knock") { request, _ in
                knockState(request)
            },
            DemoRoute(method: "POST", pathPattern: "/api/sshguard/knock/reveal") { request, _ in
                reveal(request)
            },
        ] + approvalRoutes
    }

    // MARK: Status rows

    /// The Shared status row of one node, as JSON objects.
    static func statusRow(_ nodeID: String) -> [String: Any]? {
        let body = SharedFixtures.sshGuardBody(request: nil)
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let nodes = object["nodes"] as? [[String: Any]] else { return nil }
        return nodes.first { $0["node_id"] as? String == nodeID }
    }

    private static func string(_ row: [String: Any]?, _ path: String...) -> String {
        var value: Any? = row
        for key in path { value = (value as? [String: Any])?[key] }
        return value as? String ?? ""
    }

    /// The port sshd listens on per node: most run on 22, a few were moved.
    static func sshPort(_ name: String) -> Int {
        switch name {
        case "relay-tyo-1": 3434
        case "edge-ams-2": 2222
        default: 22
        }
    }

    /// An invented, stable knock sequence per node, in the knock range.
    static func knockPorts(_ node: DemoWorldNode) -> [Int] {
        let host = Int(node.ipv4.split(separator: ".").last ?? "1") ?? 1
        return [20000 + (host * 977) % 13000, 33000 + (host * 613) % 13000, 46000 + (host * 389) % 13000]
    }

    static func knockDigest(_ node: DemoWorldNode) -> String {
        PlanHasher.sha256Hex(knockPorts(node).map(String.init).joined(separator: ","))
    }

    static func approvalNodeIDs() -> [DemoWorldNode] { DemoWorld.nodes }

    // MARK: Plan text, in the server's RenderArmPlan header form

    static func armPlan(node: DemoWorldNode, sshPort: Int, keepLegacy: Bool, knock: Bool, sources: [String], window: Int, rotating: Bool = false) -> String {
        let gated = knock || !sources.isEmpty
        var lines = [
            "# Lattice SSH Guard plan",
            "",
            "stage: arm",
            "node_id: \(node.id)",
            "node_name: \(node.name)",
            "ssh_port: \(sshPort)",
            "keep_legacy_port: \(keepLegacy)",
            "knock: \(knock)",
        ]
        if gated { lines.append("gated_ports: \(sshPort > 0 && sshPort != 22 && keepLegacy ? "22, \(sshPort)" : String(sshPort > 0 ? sshPort : 22))") }
        lines.append("confirm_window_sec: \(window)")
        lines += [
            "",
            "## What this does, and why it cannot strand you",
            "",
            gated
                ? "The apply hardens sshd and narrows who may reach it. It arms a systemd timer that undoes all of it in \(window) seconds unless a second, separate confirm plan is approved and applied first."
                : "The apply changes no port and installs no firewall: it edits sshd's configuration and nothing else. It arms a systemd timer that undoes all of it in \(window) seconds unless a confirm plan applies first.",
        ]
        if rotating {
            lines += ["", "The knock sequence the node runs today keeps opening it beside the new one until the confirm applies."]
        }
        if gated {
            lines += ["", knock ? "## Management sources (reach SSH without knocking, no expiry)" : "## Management sources (the only sources that may reach SSH)", ""]
            lines += sources.isEmpty ? ["- (none)"] : sources.map { "- \($0)" }
        }
        lines += [
            "",
            "## sshd drop-in: /etc/ssh/sshd_config.d/50-lattice-guard.conf",
            "",
            "PasswordAuthentication no",
            "KbdInteractiveAuthentication no",
            "PermitRootLogin prohibit-password",
            "LoginGraceTime 20",
            "MaxAuthTries 3",
            "MaxStartups 100:30:200",
        ]
        if knock {
            lines += ["", "## Knock", "", "A sequence of three ports, drawn on the control plane, opens tcp/\(sshPort > 0 ? sshPort : 22) for 12h after it arrives within 15 s.", "Reveal it from the SSH Guard page with a fresh second factor."]
        }
        return lines.joined(separator: "\n")
    }

    static func confirmPlan(node: DemoWorldNode, armID: String) -> String {
        """
        # Lattice SSH Guard plan

        stage: confirm
        node_id: \(node.id)
        node_name: \(node.name)
        arm_approval_id: \(armID)

        Confirm cancels the automatic revert the arm plan armed. After it
        applies, the hardened sshd profile and the SSH gate stay in force.

        Check before approving: you opened a new connection to \(node.name)
        over the new path and got a shell.
        """
    }

    /// The arm each storied node's status names as `last_arm`, in the real
    /// plan form, so rotation can read its port and sources.
    static func historicArmPlan(_ node: DemoWorldNode) -> String {
        let row = statusRow(node.id)
        let knock = ((row?["last_arm"] as? [String: Any])?["knock"] as? Bool) ?? false
        let sources: [String] = switch node.region {
        case "tyo", "sin", "hkg": ["198.51.100.0/28", "2001:db8:22::/48"]
        case "fra", "ams", "lon": ["203.0.113.64/27"]
        default: []
        }
        return armPlan(node: node, sshPort: sshPort(node.name), keepLegacy: true, knock: knock, sources: sources, window: 900)
    }

    // MARK: Approvals by id

    static var approvalRoutes: [DemoRoute] {
        approvalNodeIDs().flatMap { node -> [DemoRoute] in
            [
                DemoRoute(pathPattern: "/api/network/approvals", query: ["id": "approval_arm_\(node.name)"]) { request, state in
                    await historicArm(node, request: request, state: state)
                },
                DemoRoute(pathPattern: "/api/network/approvals", query: ["id": "approval_sga_\(node.id)"]) { request, state in
                    await filed("approval_sga_\(node.id)", action: "sshguard-arm:v1", node: node, request: request, state: state)
                },
                DemoRoute(pathPattern: "/api/network/approvals", query: ["id": "approval_sgc_\(node.id)"]) { request, state in
                    await filed("approval_sgc_\(node.id)", action: "sshguard-confirm:v1", node: node, request: request, state: state)
                },
            ]
        }
    }

    private static func historicArm(_ node: DemoWorldNode, request: DemoRequest, state: DemoState) async -> DemoResponse {
        let row = statusRow(node.id)
        let arm = row?["last_arm"] as? [String: Any]
        guard let arm, arm["approval_id"] as? String == "approval_arm_\(node.name)" else {
            return .error(status: 404, code: "not_found", message: "approval not found")
        }
        let plan = historicArmPlan(node)
        var approval = DemoApproval(
            id: "approval_arm_\(node.name)", plugin: "sshguard", action: "sshguard-arm:v1", node: node.name,
            status: arm["status"] as? String == "failed" ? "rejected" : (arm["status"] as? String ?? "applied"),
            plan: plan, planSHA256: PlanHasher.sha256Hex(plan), createdAt: "-40m", updatedAt: "-11m"
        )
        if approval.status == "applied" { approval.approvedBy = DemoWorld.actorID }
        approval = await SharedFixtures.current(approval, state: state, scenario: request.scenario)
        return .json(DemoJSON.object([("approval", SharedFixtures.approvalJSON(approval, includePlan: true))]).text)
    }

    private static func filed(_ id: String, action: String, node: DemoWorldNode, request: DemoRequest, state: DemoState) async -> DemoResponse {
        guard await state.contains(id, in: "sshguard.filed"), let plan = await state.value(for: "sshguard.plan.\(id)") else {
            return .error(status: 404, code: "not_found", message: "approval not found")
        }
        var approval = DemoApproval(id: id, plugin: "sshguard", action: action, node: node.name, status: "pending",
                                    plan: plan, planSHA256: PlanHasher.sha256Hex(plan), createdAt: "", updatedAt: "")
        approval = await SharedFixtures.current(approval, state: state, scenario: request.scenario)
        return .json(DemoJSON.object([("approval", SharedFixtures.approvalJSON(approval, includePlan: true))]).text)
    }

    // MARK: Plan and confirm

    private struct Finding {
        var code: String
        var severity: String
        var message: String

        var json: DemoJSON {
            .object(["code": .string(code), "severity": .string(severity), "message": .string(message)])
        }
    }

    /// Who may plan for a node: the route wrapper checked sshguard:admin;
    /// the handler checks both scopes on the node.
    private static func nodeScopeRefusal(_ request: DemoRequest, nodeID: String, scopes needed: [String]) -> DemoResponse? {
        let scopes = DemoTransport.scopes(for: request.identity, scenario: request.scenario)
        for scope in needed where !scopes.allows(scope, nodeID: nodeID) {
            return .error(status: 403, code: "forbidden", message: "missing scope \(scope) for node \(nodeID)")
        }
        return nil
    }

    static func plan(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        let body = request.bodyObject() ?? [:]
        guard let nodeID = body["node_id"] as? String, !nodeID.isEmpty else {
            return .error(status: 400, code: "bad_request", message: "node_id is required")
        }
        if let refusal = nodeScopeRefusal(request, nodeID: nodeID, scopes: ["sshguard:admin", "network:plan"]) { return refusal }
        guard let node = DemoWorld.node(id: nodeID) else {
            return .error(status: 404, code: "not_found", message: "node not found")
        }
        let row = statusRow(nodeID)
        if row?["enrolled"] as? Bool == false {
            return .error(status: 403, code: "capability_denied", message: "\(node.name) is not enrolled for sshguard; enroll it under Capability Gates before planning")
        }
        let sshPortValue = body["ssh_port"] as? Int ?? 0
        let knock = body["enable_knock"] as? Bool ?? (sshPortValue != 0)
        let sources = body["mgmt_sources"] as? [String] ?? []
        let fallback = body["out_of_band_fallback"] as? Bool ?? false
        let window = body["confirm_window_sec"] as? Int ?? 900
        let keepLegacy = body["keep_legacy_port"] as? Bool ?? true
        let accept = body["accept_findings"] as? Bool ?? false
        let rotateFrom = body["rotate_from_sha256"] as? String
        let previous = body["previous_knock_ports"] as? [Int]
        if window != 0, window < 120 || window > 3600 {
            return .error(status: 400, code: "bad_request", message: "confirm_window_sec must be between 120 and 3600")
        }
        if sshPortValue == 22 {
            return .error(status: 400, code: "bad_request", message: "ssh_port 22 is the legacy port; omit ssh_port to keep the current one")
        }
        if rotateFrom != nil || previous != nil {
            guard knock else {
                return .error(status: 400, code: "bad_request", message: "a rotation keeps the previous sequence alive beside a new one, so it needs knocking on")
            }
            if let rotateFrom {
                let knowledge = string(row, "knock", "knowledge")
                guard ["installed", "installed_superseded"].contains(knowledge) else {
                    return .error(status: 409, code: "conflict", message: "the control plane holds no installed knock sequence for this node to rotate from; if the node knocks on a sequence Lattice never installed, pass previous_knock_ports")
                }
                guard rotateFrom == knockDigest(node) else {
                    return .error(status: 409, code: "conflict", message: "rotate_from_sha256 does not name the sequence the control plane holds as installed; reveal it again, or pass previous_knock_ports if the node runs something else")
                }
            }
        }

        var findings: [Finding] = []
        if !node.isReporting && node.status == "never_reported" {
            findings.append(Finding(code: "no_reality", severity: "warn", message: "this node has never reported its listeners, so the port-conflict and firewall-override checks could not run. The apply verifies the port is listening before it gates anything, but that is a later and more expensive place to find out."))
        }
        let gatedPort = sshPortValue > 0 ? sshPortValue : sshPort(node.name)
        if node.name == "edge-hkg-2" && (knock || !sources.isEmpty) {
            findings.append(Finding(code: "overridden_by_guard", severity: "block", message: "this node's lattice_guard ruleset is policy drop and does not accept tcp/\(gatedPort). An accept in the knock table does not let a packet skip lattice_guard, so knocking would appear to succeed and the connection would still never open. Open tcp/\(gatedPort) in netguard first."))
        }
        if fallback, !node.isReporting {
            findings.append(Finding(code: "fallback_unavailable", severity: "block", message: "this profile gates SSH on the grounds that the node's Lattice terminal is the fallback, and that node is either offline or not reporting the terminal capability. Gating SSH now would leave no way in that does not depend on knocking working."))
        }
        if !knock, sources.isEmpty {
            findings.append(Finding(code: "hardening_only", severity: "warn", message: "this profile has no management source and no knock sequence, so it installs no firewall: it changes sshd's settings and leaves who can reach the port exactly as it is. Password login stops, the brute force does not. Add a management source if the intent was to narrow access."))
        }
        if !sources.isEmpty, sources.allSatisfy({ !$0.contains("/") || $0.hasSuffix("/32") || $0.hasSuffix("/128") }) {
            findings.append(Finding(code: "single_way_in", severity: "warn", message: "every management source is a single host address, so the fallback that does not depend on knocking is one IP. That is often intended, but it should be a decision: if that address changes, the only way back in is the knock sequence."))
        }
        let blocking = findings.contains { $0.severity == "block" }
        if blocking, !accept {
            let sorted = findings.sorted { ($0.severity == "block" ? 0 : 1, $0.code) < ($1.severity == "block" ? 0 : 1, $1.code) }
            return DemoResponse(status: 409, body: DemoJSON.object([
                ("error", "plan blocked by lint findings"),
                ("findings", .array(sorted.map(\.json))),
            ]).text)
        }

        let planText = armPlan(node: node, sshPort: sshPortValue, keepLegacy: keepLegacy, knock: knock, sources: sources, window: window,
                               rotating: rotateFrom != nil || previous != nil)
        let id = "approval_sga_\(node.id)"
        await state.insert(id, into: "sshguard.filed")
        await state.setValue(planText, for: "sshguard.plan.\(id)")
        await state.setValue(nil, for: "approval.status.\(id)")
        let approval = DemoApproval(id: id, plugin: "sshguard", action: "sshguard-arm:v1", node: node.name, status: "pending",
                                    plan: planText, planSHA256: PlanHasher.sha256Hex(planText), createdAt: "", updatedAt: "")
        return .json(DemoJSON.object([
            ("approval", SharedFixtures.approvalJSON(approval, includePlan: true)),
            ("findings", .array(findings.filter { $0.severity != "block" }.map(\.json))),
        ]).text)
    }

    static func confirm(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        guard let nodeID = request.bodyStrings["node_id"], !nodeID.isEmpty else {
            return .error(status: 400, code: "bad_request", message: "node_id is required")
        }
        if let refusal = nodeScopeRefusal(request, nodeID: nodeID, scopes: ["sshguard:admin", "network:plan"]) { return refusal }
        guard let node = DemoWorld.node(id: nodeID) else {
            return .error(status: 404, code: "not_found", message: "node not found")
        }
        let row = statusRow(nodeID)
        if string(row, "stage") == "hardened" {
            return .error(status: 409, code: "conflict", message: "this node's last arm was durable: it installed no firewall and the node already had a key path in, so no revert timer was armed and there is nothing to confirm")
        }
        let armID = await state.contains("approval_sga_\(node.id)", in: "sshguard.filed")
            ? "approval_sga_\(node.id)"
            : (string(row, "last_arm", "approval_id").isEmpty ? "approval_arm_\(node.name)" : string(row, "last_arm", "approval_id"))
        let planText = confirmPlan(node: node, armID: armID)
        let id = "approval_sgc_\(node.id)"
        await state.insert(id, into: "sshguard.filed")
        await state.setValue(planText, for: "sshguard.plan.\(id)")
        await state.setValue(nil, for: "approval.status.\(id)")
        let approval = DemoApproval(id: id, plugin: "sshguard", action: "sshguard-confirm:v1", node: node.name, status: "pending",
                                    plan: planText, planSHA256: PlanHasher.sha256Hex(planText), createdAt: "", updatedAt: "")
        return .json(DemoJSON.object([("approval", SharedFixtures.approvalJSON(approval, includePlan: true))]).text)
    }

    // MARK: Knock

    static func knockNote(knowledge: String, confirmed: Bool) -> String {
        switch knowledge {
        case "installed":
            confirmed
                ? "The control plane knows this node's knock sequence. It was applied and confirmed, so it is the sequence the node is running."
                : "The control plane knows the knock sequence from the arm that was applied. That arm was never confirmed, so its automatic revert may have removed it from the node since."
        case "installed_superseded":
            "The control plane knows this node's knock sequence from an arm record that was later dismissed as superseded. The dismissal retired the record, not the change: the arm was approved and dispatched, its confirm applied, and no later plan has replaced the knock since. This is the sequence the node was last told to run."
        case "planned":
            "An SSH Guard plan for this node carries a knock sequence, but it has not been applied. The node is not knocking on it yet."
        case "no_knock":
            "SSH Guard is set up on this node without port knocking. There is no sequence to show; reach SSH from a management source."
        default:
            "The control plane has no SSH Guard plan for this node, so it does not know a knock sequence. If this node knocks, it was configured outside Lattice and the sequence is only wherever that was recorded."
        }
    }

    static func knockState(_ request: DemoRequest) -> DemoResponse {
        guard let nodeID = request.bodyStrings["node_id"], !nodeID.isEmpty else {
            return .error(status: 400, code: "bad_request", message: "node_id is required")
        }
        if let refusal = nodeScopeRefusal(request, nodeID: nodeID, scopes: ["sshguard:read", "network:plan"]) { return refusal }
        guard let node = DemoWorld.node(id: nodeID) else {
            return .error(status: 404, code: "not_found", message: "node not found")
        }
        let row = statusRow(nodeID)
        let stage = string(row, "stage")
        let knowledge = string(row, "knock", "knowledge").isEmpty ? "unknown" : string(row, "knock", "knowledge")
        let installed = knowledge == "installed" || knowledge == "installed_superseded"
        let confirmed = ["hardened", "confirmed", "in_force"].contains(stage)
        let armID = string(row, "last_arm", "approval_id")
        let hasSequence = installed || knowledge == "planned"
        return .json(DemoJSON.object([
            "ok": true,
            "node_id": .string(nodeID),
            "knowledge": .string(knowledge),
            "note": .string(knockNote(knowledge: knowledge, confirmed: confirmed)),
            "gate_present": .bool(row?["knock_gate"] as? Bool ?? false),
            "revealable": .bool(hasSequence),
            "requires_step_up": true,
            "interactive_only": true,
            "approval_id": armID.isEmpty || !hasSequence ? nil : .string(armID),
            "applied_at": knowledge == "installed" ? "{{now-11m}}" : nil,
            "confirmed": installed ? .bool(confirmed) : nil,
            "port_count": hasSequence ? 3 : nil,
            "seq_timeout_sec": hasSequence ? 15 : nil,
            "open_for": hasSequence ? "12h" : nil,
            "ssh_port": hasSequence ? .number(Double(sshPort(node.name))) : nil,
            "previous_honoured": node.name == "relay-fra-1" ? true : nil,
        ]).text)
    }

    static func reveal(_ request: DemoRequest) -> DemoResponse {
        guard let nodeID = request.bodyStrings["node_id"], !nodeID.isEmpty else {
            return .error(status: 400, code: "bad_request", message: "node_id is required")
        }
        if let refusal = nodeScopeRefusal(request, nodeID: nodeID, scopes: ["sshguard:read", "network:plan"]) { return refusal }
        guard request.identity == .session else {
            return .error(status: 403, code: "secret_reveal_scope_required", message: "revealing a secret needs a signed-in session with a fresh second factor, or a token with secrets:reveal; use /api/sshguard/knock to learn whether a sequence exists and /api/network/approvals to read the plan that installed it")
        }
        guard request.bodyStrings["step_up_grant"] == "grant_demo_notasecret" else {
            return .error(status: 403, code: "step_up_required", message: "a fresh second factor is required")
        }
        guard let node = DemoWorld.node(id: nodeID) else {
            return .error(status: 404, code: "not_found", message: "node not found")
        }
        let row = statusRow(nodeID)
        let knowledge = string(row, "knock", "knowledge")
        switch knowledge {
        case "installed", "installed_superseded", "planned": break
        case "no_knock":
            return .error(status: 404, code: "not_found", message: "SSH Guard is applied on this node without port knocking, so there is no sequence")
        default:
            return .error(status: 404, code: "not_found", message: "the control plane has no SSH Guard plan for this node and does not know a knock sequence")
        }
        let ports = knockPorts(node)
        let port = sshPort(node.name)
        let confirmed = ["hardened", "confirmed", "in_force"].contains(string(row, "stage"))
        let knockLine = "knock \(node.ipv4) \(ports.map(String.init).joined(separator: " ")) && ssh -p \(port) ops@\(node.ipv4)"
        let bashLine = ports.map { "timeout 1 bash -c '</dev/tcp/\(node.ipv4)/\($0)'" }.joined(separator: "; ") + "; ssh -p \(port) ops@\(node.ipv4)"
        return .json(DemoJSON.object([
            "ok": true,
            "node_id": .string(nodeID),
            "knowledge": .string(knowledge),
            "approval_id": .string(string(row, "last_arm", "approval_id")),
            "note": .string(knockNote(knowledge: knowledge, confirmed: confirmed)),
            "gate_present": .bool(row?["knock_gate"] as? Bool ?? false),
            "confirmed": .bool(confirmed),
            "ports": .array(ports.map { .number(Double($0)) }),
            "seq_timeout_sec": 15,
            "open_for": "12h",
            "ssh_port": .number(Double(port)),
            "address": .string(node.ipv4),
            "commands": .array([
                .object(["id": "knock", "install": .array([.object(["platform": "macos", "command": "brew install knock"])]), "command": .string(knockLine)]),
                .object(["id": "bash", "command": .string(bashLine)]),
            ]),
            "sequence_sha256": .string(knockDigest(node)),
            "previous_ports": node.name == "relay-fra-1" ? .array(ports.reversed().map { .number(Double($0)) }) : nil,
        ]).text)
    }
}
