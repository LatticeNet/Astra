import Foundation

// GET /api/ddns and GET (or POST) /api/sshguard/status.
extension SharedFixtures {
    static var networkingRoutes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/ddns", body: DemoJSON.array(ddnsProfiles).text) { request, _ in
                .json(DemoJSON.array(request.scenario == .quiet ? quietDDNSProfiles : ddnsProfiles).text)
            }.requiring("ddns:admin"),
            DemoRoute(pathPattern: "/api/sshguard/status", body: sshGuardBody(request: nil), emptyBody: #"{"ok":true,"nodes":[]}"#) { request, _ in
                .json(sshGuardBody(request: request))
            },
            DemoRoute(method: "POST", pathPattern: "/api/sshguard/status") { request, _ in
                .json(sshGuardBody(request: request))
            },
        ]
    }

    // MARK: DDNS

    /// Current, failing, stale (the node moved and the profile is overdue)
    /// and a current CNAME profile.
    static let ddnsProfiles: [DemoJSON] = [
        ddns(id: "ddns_d01", name: "tyo apex", node: "edge-tyo-1", domains: ["edge.example.org"], lastIPv4: DemoWorld.node("edge-tyo-1").ipv4, lastRun: "-3d"),
        ddns(id: "ddns_d02", name: "fra relay", node: "relay-fra-1", domains: ["relay.example.org", "relay-eu.example.org"], lastIPv4: DemoWorld.node("relay-fra-1").ipv4, lastRun: "-4m", error: "cloudflare: 403 invalid API token"),
        ddns(id: "ddns_d03", name: "home", node: "home-router", domains: ["home.example.net"], lastIPv4: "192.0.2.10", lastRun: "-2h"),
        ddns(id: "ddns_d04", name: "status page", node: "edge-fra-3", domains: ["status.example.org"], lastIPv4: "", lastRun: "-5m", cname: "status-example.cdn.example.com"),
    ]

    /// The same profiles, all current.
    static let quietDDNSProfiles: [DemoJSON] = [
        ddns(id: "ddns_d01", name: "tyo apex", node: "edge-tyo-1", domains: ["edge.example.org"], lastIPv4: DemoWorld.node("edge-tyo-1").ipv4, lastRun: "-3d"),
        ddns(id: "ddns_d02", name: "fra relay", node: "relay-fra-1", domains: ["relay.example.org", "relay-eu.example.org"], lastIPv4: DemoWorld.node("relay-fra-1").ipv4, lastRun: "-4m"),
        ddns(id: "ddns_d03", name: "home", node: "home-router", domains: ["home.example.net"], lastIPv4: DemoWorld.node("home-router").ipv4, lastRun: "-2h"),
        ddns(id: "ddns_d04", name: "status page", node: "edge-fra-3", domains: ["status.example.org"], lastIPv4: "", lastRun: "-5m", cname: "status-example.cdn.example.com"),
    ]

    private static func ddns(id: String, name: String, node nodeName: String, domains: [String], lastIPv4: String, lastRun: String, error: String = "", cname: String = "") -> DemoJSON {
        let node = DemoWorld.node(nodeName)
        return .object([
            "id": .string(id),
            "name": .string(name),
            "node_id": .string(node.id),
            "provider": "cloudflare",
            "domains": .strings(domains),
            "enable_ipv4": .bool(cname.isEmpty),
            "enable_ipv6": .bool(cname.isEmpty && !node.ipv6.isEmpty),
            "max_retries": 3,
            "ttl": 120,
            "interval_seconds": 300,
            "record_type": cname.isEmpty ? "address" : "cname",
            "cname_target": cname.isEmpty ? nil : .string(cname),
            "has_credential": true,
            "last_ipv4": lastIPv4.isEmpty ? nil : .string(lastIPv4),
            "last_ipv6": cname.isEmpty && !node.ipv6.isEmpty ? .string(node.ipv6) : nil,
            "last_target": cname.isEmpty ? nil : .string(cname),
            "last_run_at": .time(lastRun),
            "last_error": error.isEmpty ? nil : .string(error),
            "created_at": "{{now-60d}}",
            "updated_at": .time(lastRun),
        ])
    }

    // MARK: SSH Guard

    private struct GuardRow {
        var node: String
        var stage: String
        var posture: String
        var enrolled = true
        var revertDeadline: String?
        var actionable: String = ""
        var knock = "installed"
    }

    /// Every server stage once, one node reverting minutes ahead with an
    /// approval to open, and one whose window already closed.
    private static let guardRows: [GuardRow] = [
        GuardRow(node: "edge-tyo-2", stage: "confirm_pending", posture: "secured", revertDeadline: "+4m", actionable: "approval_d1001"),
        GuardRow(node: "edge-tyo-1", stage: "hardened", posture: "secured"),
        GuardRow(node: "relay-tyo-1", stage: "confirmed", posture: "secured"),
        GuardRow(node: "edge-sin-1", stage: "idle", posture: "password_open", knock: "no_knock"),
        GuardRow(node: "edge-sin-2", stage: "arm_pending", posture: "partial", knock: "planned"),
        GuardRow(node: "relay-hkg-1", stage: "arm_approved", posture: "partial", knock: "planned"),
        GuardRow(node: "edge-hkg-2", stage: "arm_failed", posture: "password_open", knock: "no_knock"),
        GuardRow(node: "relay-fra-1", stage: "confirm_approved", posture: "secured", revertDeadline: "+11m"),
        GuardRow(node: "edge-fra-3", stage: "reverted", posture: "password_open", knock: "installed_superseded"),
        GuardRow(node: "edge-ams-2", stage: "in_force", posture: "secured"),
        GuardRow(node: "core-lon-1", stage: "idle", posture: "unknown", knock: "unknown"),
        GuardRow(node: "edge-iad-1", stage: "awaiting_confirm", posture: "secured", revertDeadline: "-2m"),
        GuardRow(node: "dns-iad-1", stage: "idle", posture: "partial", enrolled: false, knock: "no_knock"),
    ]

    static func sshGuardBody(request: DemoRequest?) -> String {
        let quiet = request?.scenario == .quiet
        var rows = guardRows.map { row -> GuardRow in
            guard quiet else { return row }
            var calm = row
            calm.stage = row.enrolled ? "hardened" : "idle"
            calm.posture = row.enrolled ? "secured" : row.posture
            calm.revertDeadline = nil
            calm.actionable = ""
            return calm
        }
        if let request {
            // The server skips nodes the caller lacks sshguard:read and network:plan on.
            let scopes = DemoTransport.scopes(for: request.identity, scenario: request.scenario)
            rows = rows.filter {
                let id = DemoWorld.node($0.node).id
                return scopes.allows("sshguard:read", nodeID: id) && scopes.allows("network:plan", nodeID: id)
            }
        }
        var wanted: String?
        if let request {
            wanted = request.query["node_id"] ?? request.bodyStrings["node_id"]
        }
        let nodes = rows.map(guardJSON)
        if let wanted, let one = rows.first(where: { DemoWorld.node($0.node).id == wanted }) {
            return DemoJSON.object([("ok", true), ("node", guardJSON(one)), ("nodes", [guardJSON(one)])]).text
        }
        return DemoJSON.object([("ok", true), ("nodes", .array(nodes))]).text
    }

    private static func guardJSON(_ row: GuardRow) -> DemoJSON {
        let node = DemoWorld.node(row.node)
        let password = row.posture == "password_open"
        let reported = row.posture != "unknown"
        let reason: String = switch row.posture {
        case "secured": "password login is off and a key is authorized"
        case "password_open": "PasswordAuthentication yes in the effective sshd configuration"
        case "partial": "password login is off but root may log in with a password"
        default: "the node has not reported its sshd configuration"
        }
        let armed = row.revertDeadline != nil
        return .object([
            "node_id": .string(node.id),
            "node_name": .string(node.name),
            "enrolled": .bool(row.enrolled),
            "posture": .object([
                "state": .string(row.posture),
                "key_access": .bool(row.posture == "secured"),
                "key_evidence": row.posture == "secured" ? "authorized_keys for ops" : nil,
                "reason": .string(reason),
            ]),
            "sshd": reported ? .object([
                "password_authentication": .bool(password),
                "pubkey_authentication": true,
                "permit_root_login": row.posture == "partial" ? "yes" : "prohibit-password",
                "ports": [22],
                "observed_at": "{{now-2m}}",
            ]) : nil,
            "reality_collected_at": reported ? "{{now-2m}}" : nil,
            "knock_gate": .bool(["hardened", "confirmed", "in_force", "confirm_pending", "confirm_approved", "awaiting_confirm"].contains(row.stage)),
            "stage": .string(row.stage),
            "stage_is_history": .bool(row.stage == "reverted" && row.posture == "secured"),
            "revert_armed": .bool(armed),
            "revert_deadline": row.revertDeadline.map { .time($0) },
            "actionable_approval_id": row.actionable.isEmpty ? nil : .string(row.actionable),
            "last_arm": row.stage == "idle" ? nil : .object([
                "approval_id": .string(row.node == "edge-tyo-2" ? "approval_d0904" : "approval_arm_\(node.name)"),
                "status": .string(["arm_pending"].contains(row.stage) ? "pending" : (row.stage == "arm_failed" ? "failed" : "applied")),
                "outcome": .string(["arm_pending"].contains(row.stage) ? "pending" : (row.stage == "arm_failed" ? "rejected" : "applied")),
                "created_at": "{{now-40m}}",
                "updated_at": "{{now-11m}}",
                "gates_firewall": true,
                "knock": .bool(row.knock != "no_knock"),
                "confirm_window_sec": 900,
            ]),
            "knock": .object([
                "knowledge": .string(row.knock),
                "revealable": .bool(row.knock == "installed"),
                "requires_step_up": true,
                "interactive_only": true,
                "note": .string(row.knock == "installed" ? "Reveal needs a signed-in session and a fresh code." : ""),
                "approval_id": row.knock == "installed" && row.node == "edge-tyo-2" ? "approval_d0904" : nil,
            ]),
        ])
    }
}
