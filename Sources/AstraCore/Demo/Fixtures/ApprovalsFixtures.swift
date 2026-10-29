import Foundation

/// Demo routes for the Approvals domain, owned by the Approvals module (section 8.6).
///
/// The decisions (`approve`, `reject`, `dismiss`) behave as the server does
/// (`handleApprove`, `handleRejectApproval`, `handleDismissApproval` in
/// server.go): 404 for an approval the token cannot read, 403 without the
/// decision scopes, 200 with the unchanged view for an approval that is no
/// longer pending, 409 `approval_stale` for a plan hash that does not match
/// or a row that is not dismissible. They record the outcome in
/// `approval.status.<id>` and `approval.by.<id>`, which the Shared listing
/// and `?id=` reads apply.
///
/// Two stories are built in. `approval_d1007` (the Tokyo DNS change) is
/// decided by another operator, ops-oncall, a moment before this phone's
/// request lands, so its decision comes back "already approved". The extra
/// approvals below add a group of identical firewall plans (one distinct body
/// in BatchReview) and a NetGuard plan the Operator token can read but not
/// decide (it lacks `netguard:admin`), for the read-only Review.
public enum ApprovalsFixtures {
    public static var routes: [DemoRoute] {
        var routes = [
            DemoRoute(method: "POST", pathPattern: "/api/network/approvals/approve") { request, state in
                await decide(.approve, request: request, state: state)
            },
            DemoRoute(method: "POST", pathPattern: "/api/network/approvals/reject") { request, state in
                await decide(.reject, request: request, state: state)
            },
            DemoRoute(method: "POST", pathPattern: "/api/network/approvals/dismiss") { request, state in
                await decide(.dismiss, request: request, state: state)
            },
            // The pending listing Inbox and Approvals read, with the extras added.
            DemoRoute(pathPattern: "/api/network/approvals", query: ["status": "pending", "include": "plan"]) { request, state in
                await pendingList(request, state: state)
            },
        ]
        for extra in extras {
            routes.append(DemoRoute(pathPattern: "/api/network/approvals", query: ["id": extra.id]) { request, state in
                await byID(extra, request: request, state: state)
            })
        }
        return routes
    }

    /// The approval another operator decides first.
    public static let racedApprovalID = "approval_d1007"
    /// The operator who wins that race.
    public static let otherOperator = "u-demo-oncall"

    /// The identical firewall ruleset filed for three relays in one group.
    static let relayFirewallPlan = """
    plugin: nft
    action: apply-ruleset
    security_group: relays-inbound (applies to every node tagged relay)

    table inet lattice_guard {
      chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iif lo accept
        tcp dport 22 ip saddr 198.51.100.0/28 accept comment "ops bastion"
        tcp dport { 443, 8443 } accept comment "relay ingress"
        udp dport 8443 accept comment "hysteria2"
        icmp type echo-request limit rate 10/second accept
      }
    }
    """

    static let netGuardPlan = """
    plugin: nft
    action: apply-ruleset:netguard-v1
    node_id: n-edge-tyo-1
    node_name: edge-tyo-1
    zones: public, ops

    security groups:
      web-public   tcp/443 from 0.0.0.0/0, ::/0
      ops-ssh      tcp/22 from 198.51.100.0/28 (zone ops)

    table inet lattice_netguard {
      chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        tcp dport 443 accept comment "web-public"
        tcp dport 22 ip saddr 198.51.100.0/28 accept comment "ops-ssh"
      }
    }
    """

    /// Approvals this module adds to the demo fleet. Their hashes are
    /// computed, so they always match their bodies.
    public static let extras: [DemoApproval] = {
        let firewall = ["relay-fra-2", "relay-hkg-1", "relay-tyo-1"].map { node in
            DemoApproval(
                id: "approval_m1_fw_\(node.replacingOccurrences(of: "-", with: "_"))", plugin: "nft", action: "apply-ruleset",
                node: node, status: "pending", plan: relayFirewallPlan, planSHA256: PlanHasher.sha256Hex(relayFirewallPlan),
                createdAt: "-12m", updatedAt: "-12m"
            )
        }
        var netGuard = DemoApproval(
            id: "approval_m1_netguard", plugin: "nft", action: "apply-ruleset:netguard-v1",
            node: "edge-tyo-1", status: "pending", plan: netGuardPlan, planSHA256: PlanHasher.sha256Hex(netGuardPlan),
            createdAt: "-50m", updatedAt: "-50m"
        )
        netGuard.reason = "Adopts edge-tyo-1 into NetGuard zones public and ops"
        return firewall + [netGuard]
    }()

    static var all: [DemoApproval] { SharedFixtures.approvals + extras }

    // MARK: Reads

    static func pendingList(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        let rows = await visibleRows(request, state: state)
        return .json(SharedFixtures.listBody(rows, query: request.query))
    }

    static func byID(_ extra: DemoApproval, request: DemoRequest, state: DemoState) async -> DemoResponse {
        let rows = await visibleRows(request, state: state)
        guard let row = rows.first(where: { $0.id == extra.id }) else {
            return .error(status: 404, code: "not_found", message: "approval not found")
        }
        return .json(DemoJSON.object([("approval", SharedFixtures.approvalJSON(row, includePlan: true))]).text)
    }

    /// Every approval with this session's decisions applied, as this token may list them.
    static func visibleRows(_ request: DemoRequest, state: DemoState) async -> [DemoApproval] {
        var rows: [DemoApproval] = []
        for approval in all {
            rows.append(await SharedFixtures.current(approval, state: state, scenario: request.scenario))
        }
        if request.scenario == .quiet {
            rows = rows.filter { $0.status != "pending" }
        }
        if request.identity == .pat {
            let scopes = DemoTransport.scopes(for: request.identity, scenario: request.scenario)
            rows = rows.filter { ApprovalVisibility.canList(plugin: $0.plugin, nodeID: $0.nodeID, scopes: scopes) }
        }
        return rows
    }

    // MARK: Decisions

    enum Decision { case approve, reject, dismiss }

    static func decide(_ decision: Decision, request: DemoRequest, state: DemoState) async -> DemoResponse {
        guard let id = request.bodyStrings["approval_id"]?.trimmingCharacters(in: .whitespaces),
              let base = all.first(where: { $0.id == id }) else {
            return .error(status: 404, code: "not_found", message: "approval not found")
        }
        if request.identity == .pat {
            let scopes = DemoTransport.scopes(for: request.identity, scenario: request.scenario)
            guard ApprovalVisibility.canList(plugin: base.plugin, nodeID: base.nodeID, scopes: scopes) else {
                return .error(status: 404, code: "not_found", message: "approval not found")
            }
            let view = Approval(id: base.id, nodeID: base.nodeID, plugin: base.plugin, action: base.action)
            let missing = scopes.missing(ApprovalVisibility.decisionRequirement(for: view), nodeID: base.nodeID)
            if !missing.isEmpty {
                return .error(status: 403, code: "forbidden", message: "missing scope \(missing.joined(separator: ", "))")
            }
        }
        var approval = await SharedFixtures.current(base, state: state, scenario: request.scenario)
        if approval.status == "pending", base.id == racedApprovalID {
            // Another operator's approval lands first; this request then
            // finds a decided row and gets it back unchanged.
            await state.setValue("approved", for: "approval.status.\(base.id)")
            await state.setValue(otherOperator, for: "approval.by.\(base.id)")
            approval = await SharedFixtures.current(base, state: state, scenario: request.scenario)
        }
        let actor = DemoWorld.actorID
        switch decision {
        case .approve:
            guard approval.status == "pending" else { return view(approval) }
            if approval.stale {
                return .error(status: 409, code: "approval_stale", message: approval.reason.isEmpty ? "approval is stale; re-plan before approving" : approval.reason)
            }
            let sent = request.bodyStrings["plan_sha256"]?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !sent.isEmpty else {
                return .error(status: 400, code: "bad_request", message: "plan_sha256 is required for this approval")
            }
            guard sent.lowercased() == PlanHasher.sha256Hex(approval.plan) else {
                return .error(status: 409, code: "approval_stale", message: "plan changed since review; re-review before approving")
            }
            await record("approved", by: actor, id: base.id, state: state)
        case .reject:
            guard approval.status == "pending" else { return view(approval) }
            await record("rejected", by: actor, id: base.id, state: state)
        case .dismiss:
            if approval.status == "dismissed" { return view(approval) }
            guard approval.plugin == "agentupdate" || approval.plugin == "sshguard" else {
                return .error(status: 400, code: "bad_request", message: "only stale agent update or SSH Guard approvals can be dismissed")
            }
            let dismissible = approval.stale || approval.waiting.map(isDismissible) == true
            guard dismissible else {
                return .error(status: 409, code: "approval_stale", message: "approval is not stale; reject or approve it explicitly")
            }
            await record("dismissed", by: actor, id: base.id, state: state)
        }
        return view(await SharedFixtures.current(base, state: state, scenario: request.scenario))
    }

    private static func record(_ status: String, by actor: String, id: String, state: DemoState) async {
        await state.setValue(status, for: "approval.status.\(id)")
        await state.setValue(actor, for: "approval.by.\(id)")
    }

    private static func view(_ approval: DemoApproval) -> DemoResponse {
        .json(SharedFixtures.approvalJSON(approval, includePlan: true).text)
    }

    private static func isDismissible(_ waiting: DemoJSON) -> Bool {
        guard let data = waiting.text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["dismissible"] as? Bool == true
    }
}
