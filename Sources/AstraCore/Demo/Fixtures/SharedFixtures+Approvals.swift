import Foundation

/// One invented approval. `planSHA256` is written out, not computed, so
/// `DemoChecks` can prove each body hashes to it (section 8.6); the one
/// deliberate mismatch is flagged.
public struct DemoApproval: Sendable, Hashable {
    public var id: String
    public var plugin: String
    public var action: String
    public var node: String
    public var status: String
    public var plan: String
    public var planSHA256: String
    public var createdAt: String
    public var updatedAt: String
    public var actorID: String = DemoWorld.actorID
    public var approvedBy: String = ""
    public var rejectedBy: String = ""
    public var reason: String = ""
    public var stale = false
    public var staleCode: String = ""
    public var targets: [String] = []
    public var waiting: DemoJSON?
    /// The fixture whose hash deliberately does not match, for the mismatch screenshot.
    public var isDeliberateMismatch = false

    public init(id: String, plugin: String, action: String, node: String, status: String, plan: String, planSHA256: String, createdAt: String, updatedAt: String) {
        self.id = id
        self.plugin = plugin
        self.action = action
        self.node = node
        self.status = status
        self.plan = plan
        self.planSHA256 = planSHA256
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var nodeID: String { DemoWorld.node(node).id }
}

// GET /api/network/approvals (list, ?id=, ?count=1) and the plan filing
// endpoints Shared owns. Decisions are M1's routes; they record their
// outcome in `approval.status.<id>` so these reads show it.
extension SharedFixtures {
    static var approvalRoutes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/network/approvals", body: listBody(approvals, query: [:])) { request, state in
                await approvalsAnswer(request, state: state)
            },
            DemoRoute(method: "POST", pathPattern: "/api/nodes/beacon/plan") { request, state in
                await planBeacon(request, state: state)
            },
            DemoRoute(method: "POST", pathPattern: "/api/nodes/agent-updates/plan") { request, state in
                await planAgentUpdate(request, state: state)
            },
        ]
    }

    public static let approvals: [DemoApproval] = needsYou + history

    /// The approvals in Inbox: pending and human.
    static let needsYou: [DemoApproval] = [
        {
            var approval = DemoApproval(
                id: "approval_d1001", plugin: "sshguard", action: "sshguard-confirm:v1", node: "edge-tyo-2", status: "pending",
                plan: DemoPlans.sshGuardConfirm, planSHA256: "61510c846fb59f37cc19a682cbc0c9d36d54e7c52d2e18ac77326eace64485c5", createdAt: "-6m", updatedAt: "-6m"
            )
            approval.reason = "Confirm before the automatic revert"
            return approval
        }(),
        DemoApproval(
            id: "approval_d1002", plugin: "agentupdate", action: "update-agent", node: "edge-sin-1", status: "pending",
            plan: DemoPlans.agentUpdate(node: "edge-sin-1", arch: "amd64"), planSHA256: "3b66b82a6e69797a3c78c7707e1be26cc6f756aaade1b7fd339c0d790ccbef0c", createdAt: "-2h", updatedAt: "-2h"
        ),
        DemoApproval(
            id: "approval_d1003", plugin: "agentupdate", action: "update-agent", node: "edge-sin-2", status: "pending",
            plan: DemoPlans.agentUpdate(node: "edge-sin-2", arch: "amd64"), planSHA256: "252b2f41fec110cbf5e98cdc4095de3d20dae3684fd5fb0bad846f1029b65314", createdAt: "-2h", updatedAt: "-2h"
        ),
        DemoApproval(
            id: "approval_d1004", plugin: "agentupdate", action: "update-agent", node: "edge-ams-1", status: "pending",
            plan: DemoPlans.agentUpdate(node: "edge-ams-1", arch: "amd64"), planSHA256: "0f57f057dcf21ee53e94d19ba2fea2657acf987cf5815358f2d0d3a1272d94c0", createdAt: "-2h", updatedAt: "-2h"
        ),
        DemoApproval(
            id: "approval_d1005", plugin: "nftpolicy", action: "apply-ruleset", node: "relay-fra-1", status: "pending",
            plan: DemoPlans.outboundPolicy(node: "relay-fra-1"), planSHA256: "a0001fbebbdfcd3477999904fa71fb550f110cca657f45277d3905a1f66ca440", createdAt: "-35m", updatedAt: "-35m"
        ),
        DemoApproval(
            id: "approval_d1006", plugin: "beacon", action: "node.beacon", node: "dns-iad-1", status: "pending",
            plan: DemoPlans.beaconEnable, planSHA256: "2e06355febb81186954cebe5b77736245f7f778bd08c5ba8b8ab7ced6bdae485", createdAt: "-20m", updatedAt: "-20m"
        ),
        DemoApproval(
            id: "approval_d1007", plugin: "selfdns", action: "apply-config", node: "dns-tyo-1", status: "pending",
            plan: DemoPlans.selfDNS, planSHA256: "332828b47aff2ef7a6a06f4630a9503149e30cc7a06e0babdc612baa16d5ede5", createdAt: "-1h", updatedAt: "-1h"
        ),
        {
            var approval = DemoApproval(
                id: "approval_d1008", plugin: "agentupdate", action: "update-agent", node: "edge-lon-1", status: "rejected",
                plan: DemoPlans.agentUpdate(node: "edge-lon-1", arch: "amd64", mode: "auto"), planSHA256: "76f120e166fa98f2041593797a6874a063a19de651dc09b8d0cfb415ce400ab5", createdAt: "-3d", updatedAt: "-1d"
            )
            approval.actorID = "lattice-server"
            approval.stale = true
            approval.staleCode = "agent_update_policy_changed"
            approval.reason = "agent update policy changed since this approval was planned; current_version planned=0.3.9 current=0.3.10; re-plan before approving"
            return approval
        }(),
        {
            var approval = DemoApproval(
                id: "approval_d1009", plugin: "nftpolicy", action: "apply-ruleset", node: "relay-iad-3", status: "pending",
                plan: DemoPlans.outboundPolicy(node: "relay-iad-3"),
                planSHA256: "0000000000000000000000000000000000000000000000000000000000000000",
                createdAt: "-15m", updatedAt: "-15m"
            )
            approval.isDeliberateMismatch = true
            return approval
        }(),
    ]

    /// Decided approvals, one per display state of section 4.2.
    static let history: [DemoApproval] = [
        {
            var approval = DemoApproval(
                id: "approval_d0901", plugin: "agentupdate", action: "update-agent", node: "edge-tyo-1", status: "applied",
                plan: DemoPlans.agentUpdate(node: "edge-tyo-1", arch: "amd64"), planSHA256: "ba499e8a5070628df7d963d0c8b9f75c29dcf1951f52d4d6d22cb873d4076463", createdAt: "-1d", updatedAt: "-23h"
            )
            approval.approvedBy = DemoWorld.actorID
            return approval
        }(),
        {
            var approval = DemoApproval(
                id: "approval_d0902", plugin: "selfdns", action: "apply-config", node: "dns-fra-1", status: "rejected",
                plan: DemoPlans.selfDNSFrankfurt, planSHA256: "a2c30874fd0794a60a4ed01d1bb592749f15e452602a374fd00c7d2cea506af4", createdAt: "-2d", updatedAt: "-2d"
            )
            approval.rejectedBy = DemoWorld.actorID
            return approval
        }(),
        {
            var approval = DemoApproval(
                id: "approval_d0903", plugin: "nftpolicy", action: "apply-ruleset", node: "edge-hkg-2", status: "rejected",
                plan: DemoPlans.outboundPolicy(node: "edge-hkg-2"), planSHA256: "63910bd06612dfdb8401e69fdd86d8ac2576cf878674e68d78c16a5785924b9c", createdAt: "-5h", updatedAt: "-5h"
            )
            // A failed apply: the server rejects the row with the failure as
            // its reason and keeps approved_by, with no rejected_by.
            approval.approvedBy = DemoWorld.actorID
            approval.reason = "apply task failed: nft exited 1"
            return approval
        }(),
        {
            var approval = DemoApproval(
                id: "approval_d0904", plugin: "sshguard", action: "sshguard-arm:v1", node: "edge-tyo-2", status: "applied",
                plan: DemoPlans.sshGuardArm, planSHA256: "9b94b776ebc8b9ad68632db8b6e9684fc8189b306f30c5ea42ada702bd2188a3", createdAt: "-40m", updatedAt: "-11m"
            )
            approval.approvedBy = DemoWorld.actorID
            return approval
        }(),
        {
            var approval = DemoApproval(
                id: "approval_d0905", plugin: "agentupdate", action: "update-agent", node: "relay-fra-2", status: "approved",
                plan: DemoPlans.agentUpdate(node: "relay-fra-2", arch: "amd64"), planSHA256: "fc9450aacd7ffa51f1fe1b6d3df61a64a4d98c149979de1a33d003e78b98acf2", createdAt: "-4h", updatedAt: "-3h"
            )
            approval.approvedBy = DemoWorld.actorID
            approval.waiting = .object([
                "code": "node_offline",
                "reason": "relay-fra-2 has been offline since 3 h ago; the apply task waits for it",
                "blocked": true,
                "node_id": .string(DemoWorld.node("relay-fra-2").id),
                "node_name": "relay-fra-2",
                "node_status": "offline",
                "node_status_since": .time("-3h"),
                "node_status_reason": .string(DemoWorld.offlineReason(lastSeen: "-3h")),
                "task_id": "task_d0905apply",
                "task_status": "queued",
            ])
            return approval
        }(),
        {
            // Approved without queueing, then replaced by approval_d1002: the
            // server's plan_superseded wait, which it marks dismissible.
            var approval = DemoApproval(
                id: "approval_d0906", plugin: "agentupdate", action: "update-agent", node: "edge-sin-1", status: "approved",
                plan: DemoPlans.agentUpdate(node: "edge-sin-1", arch: "amd64", current: "0.3.8"), planSHA256: "f53f9e8ed3b5dc2ebfb8c7d59fc29ee2666f20e3afa14687e69139f317fd2f6a", createdAt: "-3d", updatedAt: "-3d"
            )
            approval.approvedBy = DemoWorld.actorID
            approval.waiting = .object([
                "code": "plan_superseded",
                "reason": "A newer plan for the same change on edge-sin-1 replaced this one (approval_d1002); this approval will not be dispatched.",
                "blocked": true,
                "superseded_by": "approval_d1002",
                "dismissible": true,
            ])
            return approval
        }(),
        {
            var approval = DemoApproval(
                id: "approval_d0907", plugin: "agentupdate", action: "update-agent", node: "lab-pi-2", status: "dismissed",
                plan: DemoPlans.agentUpdate(node: "lab-pi-2", arch: "arm64", current: "0.3.7"), planSHA256: "c48ef9c2007a906e45e6d5e97060c9d3394e62d77a8855f555e774f6429c622c", createdAt: "-8d", updatedAt: "-5d"
            )
            approval.stale = true
            approval.staleCode = "node_offline"
            approval.reason = "No longer needed"
            return approval
        }(),
        {
            var approval = DemoApproval(
                id: "approval_d0908", plugin: "singbox-linemeta", action: "sync-linemeta", node: "relay-hkg-1", status: "applied",
                plan: DemoPlans.lineMeta, planSHA256: "608313ec2a921bc93af01b7a261ff709e30d7c1e3ae4cea2eca544aa518d9cbe", createdAt: "-30m", updatedAt: "-29m"
            )
            approval.actorID = "lattice-server"
            approval.approvedBy = "lattice-server"
            return approval
        }(),
    ]

    // MARK: Answers

    static func approvalsAnswer(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        var rows: [DemoApproval] = []
        for approval in approvals {
            rows.append(await current(approval, state: state, scenario: request.scenario))
        }
        if request.scenario == .quiet {
            rows = rows.filter { $0.status != "pending" }
        }
        if request.identity == .pat {
            // The server lists only what this token may read (approvalPrimaryScopeAllows).
            let scopes = DemoTransport.scopes(for: request.identity, scenario: request.scenario)
            rows = rows.filter { ApprovalVisibility.canList(plugin: $0.plugin, nodeID: $0.nodeID, scopes: scopes) }
        }
        if let id = request.query["id"] {
            guard let row = rows.first(where: { $0.id == id }) else {
                return .error(status: 404, code: "not_found", message: "approval not found")
            }
            return .json(DemoJSON.object([("approval", approvalJSON(row, includePlan: true))]).text)
        }
        if request.query["count"] != nil {
            return .json(countsBody(rows))
        }
        return .json(listBody(rows, query: request.query))
    }

    /// The approval with this session's decision applied.
    static func current(_ approval: DemoApproval, state: DemoState, scenario: DemoScenario) async -> DemoApproval {
        var approval = approval
        if let status = await state.value(for: "approval.status.\(approval.id)") {
            approval.status = status
            approval.updatedAt = ""
            let by = await state.value(for: "approval.by.\(approval.id)") ?? DemoWorld.actorID
            switch status {
            case "rejected": approval.rejectedBy = by
            case "approved", "applied": approval.approvedBy = by
            default: break
            }
        }
        if approval.status == "approved", approval.waiting == nil {
            approval.waiting = .object([
                "code": "task_running",
                "reason": .string("the apply task is running on \(approval.node)"),
                "blocked": false,
                "task_status": "leased",
            ])
        }
        return approval
    }

    static func listBody(_ rows: [DemoApproval], query: [String: String]) -> String {
        var rows = rows
        if query["include_dismissed"] == nil { rows = rows.filter { $0.status != "dismissed" } }
        if let status = query["status"], !status.isEmpty {
            let wanted = Set(status.split(separator: ",").map(String.init))
            rows = rows.filter { wanted.contains($0.status) }
        }
        if let plugin = query["plugin"], !plugin.isEmpty { rows = rows.filter { $0.plugin == plugin } }
        if let node = query["node_id"], !node.isEmpty { rows = rows.filter { $0.nodeID == node } }
        let includePlan = query["include"] == "plan"
        let items = rows.map { approvalJSON($0, includePlan: includePlan) }
        let filtered = query.keys.contains { ["status", "plugin", "node_id", "since", "limit", "offset", "include_dismissed"].contains($0) }
        guard filtered else { return DemoJSON.array(items).text }
        return page("approvals", items, limit: intQuery(query, "limit") ?? 50, offset: intQuery(query, "offset")).text
    }

    private static func intQuery(_ query: [String: String], _ name: String) -> Int? {
        query[name].flatMap { Int($0) }
    }

    static func countsBody(_ rows: [DemoApproval]) -> String {
        func count(_ status: String) -> Double { Double(rows.filter { $0.status == status }.count) }
        return DemoJSON.object([
            ("counts", .object([
                ("pending", .number(count("pending"))),
                ("approved", .number(count("approved"))),
                ("stale", .number(Double(rows.filter { $0.status == "pending" && $0.stale }.count))),
                ("applied", .number(count("applied"))),
                ("rejected", .number(count("rejected"))),
                ("dismissed", .number(count("dismissed"))),
                ("total", .number(Double(rows.count))),
            ])),
        ]).text
    }

    /// One `ApprovalView`. The listing leaves `plan` out unless asked.
    static func approvalJSON(_ approval: DemoApproval, includePlan: Bool) -> DemoJSON {
        .object([
            "id": .string(approval.id),
            "node_id": .string(approval.nodeID),
            "plugin": .string(approval.plugin),
            "action": .string(approval.action),
            "plan": includePlan ? .string(approval.plan) : nil,
            "plan_sha256": .string(approval.planSHA256),
            "status": .string(approval.status),
            "reason": approval.reason.isEmpty ? nil : .string(approval.reason),
            "stale": approval.stale ? true : nil,
            "stale_code": approval.staleCode.isEmpty ? nil : .string(approval.staleCode),
            "actor_id": .string(approval.actorID),
            "approved_by": approval.approvedBy.isEmpty ? nil : .string(approval.approvedBy),
            "rejected_by": approval.rejectedBy.isEmpty ? nil : .string(approval.rejectedBy),
            "rejected_at": approval.rejectedBy.isEmpty ? nil : .time(approval.updatedAt),
            "created_at": .time(approval.createdAt),
            "updated_at": .time(approval.updatedAt),
            "targets": approval.targets.isEmpty ? nil : .strings(approval.targets),
            // The server sends a waiting record only for approved rows.
            "waiting": approval.status == "approved" ? approval.waiting : nil,
        ])
    }

    // MARK: Plan filing

    static func planBeacon(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        let body = request.bodyStrings
        guard let nodeID = body["node_id"], let node = DemoWorld.node(id: nodeID) else {
            return .error(status: 400, code: "bad_request", message: "node_id is required")
        }
        let action = body["action"] ?? "change"
        let plan = DemoPlans.beacon(node: node.name, action: action, port: body["port"] ?? "7443")
        let id = "approval_filed\(await state.recordHit("filed.approval"))"
        await state.insert(id, into: "approval.filed")
        let approval = DemoApproval(
            id: id, plugin: "beacon", action: "node.beacon", node: node.name, status: "pending",
            plan: plan, planSHA256: PlanHasher.sha256Hex(plan), createdAt: "", updatedAt: ""
        )
        return .json(DemoJSON.object([
            ("approval", approvalJSON(approval, includePlan: true)),
            ("plan", .object(["node_id": .string(node.id), "action": .string(action)])),
            ("findings", []),
        ]).text)
    }

    static func planAgentUpdate(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        guard let nodeID = request.bodyStrings["node_id"], let node = DemoWorld.node(id: nodeID) else {
            return .error(status: 400, code: "bad_request", message: "node_id is required")
        }
        if node.agentVersion == "0.3.10" && request.bodyStrings["force"] != "1" && request.bodyStrings["force"] != "true" {
            return .error(status: 409, code: "conflict", message: "\(node.name) already runs 0.3.10")
        }
        let plan = DemoPlans.agentUpdate(node: node.name, arch: node.arch, current: node.agentVersion.isEmpty ? "unknown" : node.agentVersion)
        let id = "approval_filed\(await state.recordHit("filed.approval"))"
        await state.insert(id, into: "approval.filed")
        let approval = DemoApproval(
            id: id, plugin: "agentupdate", action: "update-agent", node: node.name, status: "pending",
            plan: plan, planSHA256: PlanHasher.sha256Hex(plan), createdAt: "", updatedAt: ""
        )
        return .json(approvalJSON(approval, includePlan: true).text)
    }
}

/// Plan bodies. They hold no times and no clock tokens: the hash covers
/// every byte, and the transport substitutes tokens in whole bodies.
enum DemoPlans {
    static func agentUpdate(node name: String, arch: String, current: String = "0.3.9", mode: String = "manual") -> String {
        let node = DemoWorld.node(name)
        return """
        plugin: agentupdate
        mode: \(mode)
        node_id: \(node.id)
        node_name: \(node.name)
        current_version: \(current)
        target_version: 0.3.10
        binary_source: control_plane
        binary_url: https://demo.lattice.invalid/api/nodes/agent-updates/artifacts/lattice-agent-linux-\(arch)-0.3.10
        sha256: \(arch == "arm64" ? "5d0e3b7c9a41f2e8b6c3d9a0f1e2b4c6d8e0a2c4e6f8a0b2d4f6a8c0e2b4d6f8" : "9f2c4e6a8b0d2f4a6c8e0b2d4f6a8c0e2b4d6f8a0c2e4b6d8f0a2c4e6b8d0f2a")
        install_path: /usr/local/bin/lattice-agent
        service_name: lattice-agent

        Safety:
        - the binary comes from this control plane, so the node needs no third-party egress
        - the control plane re-verifies the stored bytes against this digest before serving them
        - the node holds the download to sha256 before replacing the running agent
        - if the new agent does not report within 120 s, the old binary is restored
        """
    }

    static let sshGuardArm = """
    plugin: sshguard
    action: sshguard-arm:v1
    node_id: n-edge-tyo-2
    node_name: edge-tyo-2
    ssh_port: 22
    confirm_window_sec: 900
    knock: enabled

    sshd (drop-in /etc/ssh/sshd_config.d/50-lattice-sshguard.conf):
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      PermitRootLogin prohibit-password

    gate (nft table inet lattice_sshguard):
      allow tcp/22 from 198.51.100.0/28
      allow tcp/22 from 2001:db8:22::/48
      allow tcp/22 after the knock sequence below
      drop tcp/22 from everyone else

    How to knock:
      knock edge-tyo-2.example.net 7000 8000 9000 && ssh ops@edge-tyo-2.example.net

    Revert: unless a confirm plan applies within 900 s, the node restores
    the previous sshd configuration and removes the gate by itself.
    """

    static let sshGuardConfirm = """
    plugin: sshguard
    action: sshguard-confirm:v1
    node_id: n-edge-tyo-2
    node_name: edge-tyo-2
    arm_approval_id: approval_d0904

    Confirm cancels the automatic revert the arm plan armed.
    After it applies, the hardened sshd profile and the SSH gate stay in force:
      PasswordAuthentication no
      PermitRootLogin prohibit-password
      tcp/22 open to 198.51.100.0/28, 2001:db8:22::/48 and the knock sequence

    Check before approving: you can still log in to edge-tyo-2 with a key.
    """

    static func outboundPolicy(node name: String) -> String {
        let node = DemoWorld.node(name)
        return """
        plugin: nftpolicy
        action: apply-ruleset
        node_id: \(node.id)
        node_name: \(node.name)
        policy: edge-egress (group policy, priority 100)

        table inet lattice_policy {
          chain output {
            type filter hook output priority 0; policy accept;
            ip daddr 198.51.100.0/24 tcp dport { 443, 8443 } accept comment "europe relays"
            ip daddr 203.0.113.31 tcp dport 443 accept comment "relay-hkg-1"
            tcp dport 25 drop comment "no outbound mail"
          }
        }
        """
    }

    static let beaconEnable = beacon(node: "dns-iad-1", action: "enable", port: "7443")


    static func beacon(node name: String, action: String, port: String) -> String {
        let node = DemoWorld.node(name)
        let sources = DemoWorld.nodes.filter { $0.region == node.region && $0.id != node.id && $0.isReporting }.prefix(3)
        return """
        plugin: beacon
        kind: node.beacon
        action: \(action)
        node_id: \(node.id)
        node_name: \(node.name)
        port: \(port)
        bind: 0.0.0.0

        Approved sources:
        \(sources.map { "- \($0.name) (\($0.id)) \($0.ipv4)/32" }.joined(separator: "\n"))
        """
    }

    static let selfDNS = """
    plugin: selfdns
    action: apply-config
    node_id: n-dns-tyo-1
    node_name: dns-tyo-1
    deployment: tyo-authoritative
    zone: example.org
    listen: 203.0.113.15:53, [2001:db8:10::15]:53

    records:
      example.org.          300 IN A     203.0.113.11
      example.org.          300 IN AAAA  2001:db8:10::11
      www.example.org.      300 IN CNAME example.org.
      api.example.org.      60  IN A     203.0.113.12
    """

    static let selfDNSFrankfurt = """
    plugin: selfdns
    action: apply-config
    node_id: n-dns-fra-1
    node_name: dns-fra-1
    deployment: fra-authoritative
    zone: example.org
    listen: 198.51.100.44:53

    records:
      example.org.          300 IN A     198.51.100.41
      status.example.org.   60  IN A     198.51.100.43
    """

    static let lineMeta = """
    plugin: singbox-linemeta
    action: sync-linemeta
    node_id: n-relay-hkg-1
    node_name: relay-hkg-1

    lines:
      line-hkg-a  inbound vless-reality  port 443   users 12
      line-hkg-b  inbound hysteria2      port 8443  users 7
    """
}
