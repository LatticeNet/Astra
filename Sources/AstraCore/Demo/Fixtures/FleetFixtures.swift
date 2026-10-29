import Foundation

/// Demo routes for the Fleet domain, owned by the Fleet module (section 8.6).
/// Every body is built from `DemoWorld`, so a node reads the same here as in
/// the Shared node list.
///
/// Session state these routes keep in `DemoState`:
///
/// - `node.disabled` and `node.enabled` (sets, documented by Shared): the
///   disable and enable writes record here, and the Shared node list reads it.
/// - `fleet.cap.<nodeID>.<capability>`: `enrolled|<reason>` or `excluded|<reason>`.
/// - `fleet.gate.<capability>`: `true` or `false`, a gate's enforcement.
/// - `fleet.debug.<nodeID>`: `on` or `off`.
/// - `fleet.identity.<nodeID>`: the last identity written, as JSON.
/// - `fleet.beacon.epoch.<nodeID>`: the key epoch after a rotation.
/// - `fleet.group.members.<groupID>`: static members, comma separated.
/// - `fleet.group.deleted` and `fleet.node.deleted` (sets of ids).
public enum FleetFixtures {
    public static var routes: [DemoRoute] {
        nodeReadRoutes + nodeWriteRoutes + capabilityRoutes + groupRoutes
    }

    // MARK: - Node reads

    static var nodeReadRoutes: [DemoRoute] {
        let sample = DemoWorld.node("edge-tyo-1")
        return [
            DemoRoute(pathPattern: "/api/nodes/status-history", body: statusHistoryBody(nodes: DemoWorld.nodes, days: 7),
                      emptyBody: #"{"since":"{{now-7d}}","until":"{{now}}","now":"{{now}}","server_started_at":"{{now-4d}}","nodes":{}}"#) { request, _ in
                let days = min(max(Int(request.query["days"] ?? "") ?? 7, 1), 30)
                if let id = request.query["node_id"], !id.isEmpty {
                    guard let node = DemoWorld.node(id: id) else { return .error(status: 404, code: "not_found", message: "node not found") }
                    return .json(statusHistoryBody(nodes: [node], days: days))
                }
                return .json(statusHistoryBody(nodes: DemoWorld.nodes, days: days))
            }.requiring("node:read"),
            DemoRoute(pathPattern: "/api/nodes/history", body: historyBody(sample, range: "24h", now: Date()),
                      emptyBody: #"{"owner":"node/","tier":"raw","resolution_seconds":10,"step_seconds":600,"from":"{{now-24h}}","to":"{{now}}","retained_from":"{{now-90d}}","series":[]}"#) { request, _ in
                guard let id = request.query["node_id"], let node = DemoWorld.node(id: id) else {
                    return .error(status: 404, code: "not_found", message: "node not found")
                }
                let range = request.query["range"] ?? "24h"
                guard ["1h", "6h", "24h", "7d", "30d", "90d", "1y", "5y"].contains(range) else {
                    return .error(status: 400, code: "bad_request", message: "range must be one of 1h, 6h, 24h, 7d, 30d, 90d, 1y, 5y")
                }
                return .json(historyBody(node, range: range, now: Date()))
            }.requiring("node:read"),
            DemoRoute(pathPattern: "/api/nodes/network", body: networkBody(sample).text,
                      emptyBody: #"{"node_id":"","generated_at":"{{now}}","inbound":{"state":"ok","zones":[],"security_groups":[],"derived_security_groups":[],"extra_ports":[]},"outbound":{"state":"ok","source":"none","default_drop":false,"policies":[]},"access":{"state":"ok","enrolled":false,"knock_required":false,"stage_is_history":false,"revert_armed":false},"mesh":{"state":"ok","public_key":false,"ready":false,"missing":[],"peers":0,"not_reported":[]},"groups":{"state":"ok","items":[]},"tables":[]}"#) { request, _ in
                guard let id = request.query["node_id"], let node = DemoWorld.node(id: id) else {
                    return .error(status: 404, code: "not_found", message: "node not found")
                }
                return .json(networkBody(node, rules: request.query["rules"] == "1").text)
            }.requiring("node:read"),
            DemoRoute(pathPattern: "/api/nodes/duplicates", body: duplicatesBody.text, emptyBody: #"{"groups":[]}"#).requiring("node:read"),
            DemoRoute(pathPattern: "/api/nodes/beacon", body: beaconBody(DemoWorld.node("relay-tyo-1"), epoch: nil).text,
                      emptyBody: #"{"node_id":"","state":"off","reachability":{},"sources":[],"version":0}"#) { request, state in
                guard let id = request.query["node_id"], let node = DemoWorld.node(id: id) else {
                    return .error(status: 404, code: "not_found", message: "node not found")
                }
                let epoch = await state.value(for: "fleet.beacon.epoch.\(node.id)").flatMap { Int($0) }
                return .json(beaconBody(node, epoch: epoch).text)
            }.requiring("monitor:read"),
        ]
    }

    // MARK: Status history

    /// Transitions in minutes before now, newest last, as the server echoes them.
    static func statusEdges(_ node: DemoWorldNode) -> (initial: String, events: [(minutes: Int, to: String, cause: String)]) {
        // The control plane restarted four days ago; every node reads unknown for six minutes.
        let restart: [(Int, String, String)] = [(5_760, "unknown", "server_stop"), (5_754, "online", "server_start")]
        switch node.status {
        case "never_reported":
            return ("unknown", [])
        case "offline":
            let minutes = minutesAgo(node.statusSince)
            return ("online", restart.filter { $0.0 > minutes } + [(minutes, "offline", "liveness_sweep")])
        case "disabled":
            let minutes = minutesAgo(node.statusSince)
            return ("online", restart.filter { $0.0 > minutes } + [(minutes, "offline", "liveness_sweep")])
        default:
            // A short outage two days ago on some nodes, so the strip has something to show.
            let flaps = ["edge-tyo-3", "relay-syd-2", "edge-hkg-2", "edge-sin-2"].contains(node.name)
            let blip: [(Int, String, String)] = flaps ? [(2_880, "offline", "liveness_sweep"), (2_856, "online", "beat")] : []
            return ("online", restart + blip)
        }
    }

    static func minutesAgo(_ offset: String) -> Int {
        guard offset.hasPrefix("-"), let unit = offset.last, let amount = Int(offset.dropFirst().dropLast()) else { return 0 }
        switch unit {
        case "m": return amount
        case "h": return amount * 60
        case "d": return amount * 1_440
        default: return max(1, amount / 60)
        }
    }

    static func statusHistoryJSON(_ node: DemoWorldNode, days: Int) -> DemoJSON {
        let window = days * 1_440
        let edges = statusEdges(node)
        // The state at the window start is the last edge before it.
        var initial = edges.initial
        for edge in edges.events where edge.minutes >= window { initial = edge.to }
        let inside = edges.events.filter { $0.minutes < window }
        var seconds: [String: Int] = ["online": 0, "offline": 0, "unknown": 0]
        var state = initial
        var at = window
        var episodes = initial == "offline" ? 1 : 0
        var run = 0, longest = 0
        for edge in inside {
            let span = (at - edge.minutes) * 60
            seconds[state, default: 0] += span
            if state == "offline" { run += span }
            if edge.to == "offline" { episodes += 1 }
            if state == "offline" && edge.to == "online" { longest = max(longest, run); run = 0 }
            state = edge.to
            at = edge.minutes
        }
        seconds[state, default: 0] += at * 60
        if state == "offline" { run += at * 60 }
        longest = max(longest, run)
        return .object([
            "initial": .string(initial),
            "events": .array(inside.map { edge in
                .object(["at": .time("-\(edge.minutes)m"), "to": .string(edge.to), "cause": .string(edge.cause)])
            }),
            "online_seconds": .number(Double(seconds["online"] ?? 0)),
            "offline_seconds": .number(Double(seconds["offline"] ?? 0)),
            "unknown_seconds": .number(Double(seconds["unknown"] ?? 0)),
            "episodes": .number(Double(episodes)),
            "longest_offline_seconds": .number(Double(longest)),
        ])
    }

    static func statusHistoryBody(nodes: [DemoWorldNode], days: Int) -> String {
        DemoJSON.object([
            "since": .time("-\(days)d"),
            "until": .time(),
            "now": .time(),
            "server_started_at": .time("-5754m"),
            "nodes": .object(nodes.map { ($0.id, statusHistoryJSON($0, days: days)) }),
        ]).text
    }

    // MARK: Metric history

    /// Bucket step per range, as the server's tiers answer them.
    static func step(for range: String) -> Int {
        switch range {
        case "1h": 60
        case "6h": 300
        case "24h": 600
        case "7d": 3_600
        default: 14_400
        }
    }

    static func span(for range: String) -> Int {
        switch range {
        case "1h": 3_600
        case "6h": 21_600
        case "24h": 86_400
        case "7d": 604_800
        default: 2_592_000
        }
    }

    /// A deterministic wobble per node and series, so charts look measured.
    static func wobble(_ seed: String, _ index: Int) -> Double {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in "\(seed)#\(index)".utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Double(hash % 10_000) / 10_000 - 0.5
    }

    /// `MetricsQuery` for a node. Buckets stop at the node's last report, a
    /// node that never reported has no samples, and relay-syd-2 lost an hour
    /// of samples, so gaps show.
    public static func historyBody(_ node: DemoWorldNode, range: String, now: Date) -> String {
        let step = step(for: range)
        let span = span(for: range)
        let end = Int(now.timeIntervalSince1970) / step * step
        let start = end - span
        let lastReport = node.lastSeen.map { end - minutesAgo($0) * 60 } ?? Int.min
        let gap: ClosedRange<Int>? = node.name == "relay-syd-2" ? (end - 5 * 3_600)...(end - 4 * 3_600) : nil
        var times: [Int] = []
        var time = start + step
        while time <= end {
            if time <= lastReport, gap?.contains(time) != true { times.append(time) }
            time += step
        }
        func series(_ name: String, unit: String, base: Double, swing: Double, cap: Double) -> DemoJSON {
            let values = times.enumerated().map { index, t -> Double in
                let daily = sin(Double(t % 86_400) / 86_400 * 2 * .pi) * swing * 0.6
                let value = base + daily + wobble(node.id + name, index) * swing
                return min(cap, max(0, (value * 10).rounded() / 10))
            }
            return .object([
                "name": .string(name), "kind": "gauge", "unit": .string(unit),
                "t": .array(times.map { .number(Double($0)) }),
                "avg": .array(values.map { .number($0) }),
                "min": .array(values.map { .number(max(0, ($0 * 0.8).rounded())) }),
                "max": .array(values.map { .number(min(cap, ($0 * 1.2).rounded())) }),
                "n": .array(times.map { _ in .number(Double(step / 10)) }),
            ])
        }
        let rate = 1_250_000.0
        return DemoJSON.object([
            "owner": .string("node/\(node.id)"),
            "tier": .string(step <= 60 ? "raw" : "rollup"),
            "resolution_seconds": .number(Double(min(step, 600))),
            "step_seconds": .number(Double(step)),
            "from": .time("-\(span / 60)m"),
            "to": .time(),
            "retained_from": .time("-90d"),
            "series": node.lastSeen == nil ? [] : [
                series("cpu", unit: "percent", base: node.cpuPercent, swing: max(6, node.cpuPercent * 0.4), cap: 100),
                series("mem", unit: "percent", base: node.memoryPercent, swing: 6, cap: 100),
                series("disk", unit: "percent", base: node.diskPercent, swing: 1, cap: 100),
                series("load1", unit: "load", base: node.cpuPercent / 100 * Double(node.cpuCores), swing: 0.4, cap: 64),
                series("net_rx", unit: "bytes_per_second", base: rate, swing: rate * 0.5, cap: 1e9),
                series("net_tx", unit: "bytes_per_second", base: rate * 0.66, swing: rate * 0.3, cap: 1e9),
            ],
        ]).text
    }

    // MARK: Effective network

    static func meshAddress(_ node: DemoWorldNode) -> String {
        "10.88.0.\(node.ipv4.split(separator: ".").last ?? "1")"
    }

    static func networkBody(_ node: DemoWorldNode, rules: Bool = true) -> DemoJSON {
        let home = node.region == "home"
        let groups = DemoWorld.groups.filter { node.groupIDs.contains($0.id) }
        let edgeLike = ["edge", "relay"].contains(node.role)
        let policies: [DemoJSON] = home ? [] : [
            .object([
                "id": "gp_baseline", "name": "Fleet baseline", "label": "Fleet baseline", "priority": 10, "enabled": true,
                "reach": "fleet", "state": "applies", "rules": 4, "allow": 3, "deny": 1,
            ]),
        ] + (groups.first.map { group in
            [DemoJSON.object([
                "id": .string("gp_\(group.id.dropFirst(2))"), "name": .string("\(group.name) egress"), "label": .string("\(group.name) egress"),
                "priority": 20, "enabled": true, "reach": "group",
                "via_groups": [.object(["id": .string(group.id), "name": .string(group.name)])],
                "state": "applies", "rules": edgeLike ? 6 : 2, "allow": edgeLike ? 5 : 2, "deny": edgeLike ? 1 : 0,
            ])]
        } ?? [])
        let ruleset = """
        table inet lattice_policy {
          chain output {
            type filter hook output priority 0; policy accept;
            ct state established,related accept
            ip daddr 10.88.0.0/16 tcp dport { 22, 9100 } accept
            tcp dport 53 accept
            udp dport 53 accept
            tcp dport 443 accept
            udp dport 51820 accept
            ip daddr 169.254.169.254 drop
          }
        }
        """
        return .object([
            "node_id": .string(node.id),
            "node_name": .string(node.name),
            "generated_at": .time(),
            "inbound": .object([
                "state": "ok",
                "firewall": home ? "none" : "netguard",
                "binding": home ? "none" : "managed",
                "binding_version": home ? nil : 7,
                "zones": home ? [] : [.object(["id": "zone_public", "name": "public"])],
                "security_groups": home ? [] : [
                    .object(["id": "sg_ssh_admin", "name": "ssh-admin", "rules": 3]),
                    .object(["id": "sg_web", "name": "web", "rules": 2]),
                ],
                "derived_security_groups": groups.isEmpty || home ? [] : [
                    .object(["id": "sg_mesh", "name": "mesh", "rules": 4, "via": .object(["id": .string(groups[0].id), "name": .string(groups[0].name)])]),
                ],
                "extra_ports": edgeLike ? [.object(["source": "beacon", "protocols": ["udp"], "port": 7443, "exposure": "netguard", "sources": 6])] : [],
                "drift_state": home ? nil : "in_sync",
            ]),
            "outbound": .object([
                "state": "ok",
                "source": home ? "none" : "policies",
                "default_drop": false,
                "policies": .array(policies),
            ]),
            "access": .object([
                "state": "ok",
                "enrolled": .bool(node.tags.contains("sshguard")),
                "posture": node.tags.contains("sshguard") ? "secured" : (home ? "password_open" : "partial"),
                "knock_required": .bool(node.tags.contains("sshguard")),
                "stage": node.tags.contains("sshguard") ? "awaiting_confirm" : "idle",
                "stage_is_history": false,
                "revert_armed": .bool(node.tags.contains("sshguard")),
            ]),
            "mesh": .object([
                "state": "ok",
                "address": home ? nil : .string(meshAddress(node)),
                "listen_port": home ? nil : 51820,
                "endpoint": home ? nil : .string("\(node.ipv4):51820"),
                "public_key": .bool(!home),
                "ready": .bool(!home),
                "missing": home ? ["address", "public_key"] : [],
                "peers": home ? 0 : 23,
                "not_reported": ["handshakes"],
            ]),
            "groups": .object([
                "state": "ok",
                "items": .array(groups.map { .object(["id": .string($0.id), "name": .string($0.name)]) }),
            ]),
            "tables": home ? [] : [
                .object([
                    "state": "ok", "table": "inet lattice_guard",
                    "owners": [.object(["kind": "netguard", "state": "writes"]), .object(["kind": "beacon", "state": "contributes"])],
                    "last_writer": .object(["kind": "netguard", "applied_at": .time("-3d")]),
                    "compile_now": .object(["state": "ok", "composer": "netguard", "sha256": "9c1f0e4b7a2d6c3e8f5a1b9d0c7e2f4a6b8d1c3e5f7a9b0c2d4e6f8a1b3c5d7e"]),
                    "last_applied": .object(["state": "ok", "composer": "netguard", "sha256": "9c1f0e4b7a2d6c3e8f5a1b9d0c7e2f4a6b8d1c3e5f7a9b0c2d4e6f8a1b3c5d7e"]),
                    "replan_pending": false,
                ]),
                .object([
                    "state": "ok", "table": "inet lattice_policy",
                    "owners": [.object(["kind": "outbound_policy", "state": "writes"])],
                    "compile_now": .object([
                        "state": "ok", "composer": "outbound_policy",
                        "sha256": "4e7a1c9b2d5f8e0a3c6b9d2f5a8c1e4b7d0a3f6c9e2b5d8a1f4c7e0b3d6a9c2f",
                        "ruleset": rules ? .string(ruleset) : nil,
                    ]),
                    "last_applied": .object(["state": "ok", "composer": "outbound_policy", "sha256": "4e7a1c9b2d5f8e0a3c6b9d2f5a8c1e4b7d0a3f6c9e2b5d8a1f4c7e0b3d6a9c2f"]),
                    "replan_pending": false,
                ]),
                .object([
                    "state": "ok", "table": "inet lattice_knock",
                    "owners": [.object(["kind": "sshguard", "state": node.tags.contains("sshguard") ? "writes" : "idle"])],
                    "compile_now": .object(["state": "none"]),
                    "last_applied": .object(["state": "none"]),
                    "replan_pending": false,
                    "rules_withheld": "knock",
                ]),
            ],
        ])
    }

    // MARK: Duplicates

    static let duplicatesBody: DemoJSON = .object([
        "groups": [
            .object([
                "reason": "host_fingerprint",
                "confidence": "high",
                "signal": "machine-id 4f0c9a2e1b…",
                "node_ids": .strings([DemoWorld.node("lab-pi-1").id, DemoWorld.node("lab-pi-2").id]),
            ]),
        ],
    ])

    // MARK: Beacon

    /// Relays and Tokyo edges have a listening beacon; relay-syd-2 is not
    /// listening; dns-iad-1 has an enable plan waiting (approval_d1006).
    static func beaconBody(_ node: DemoWorldNode, epoch: Int?) -> DemoJSON {
        let enabled = node.role == "relay" || node.name.hasPrefix("edge-tyo")
        let port = 7_400 + (Int(node.ipv4.split(separator: ".").last ?? "0") ?? 0)
        guard enabled, node.status != "never_reported" else {
            return .object([
                "node_id": .string(node.id),
                "state": "off",
                "reachability": .object([:]),
                "sources": [],
                "pending_approval_id": node.name == "dns-iad-1" ? "approval_d1006" : nil,
                "suggested_port": .number(Double(port)),
                "version": 0,
            ])
        }
        let notListening = node.name == "relay-syd-2"
        let reporting = node.isReporting
        let state = !reporting ? "pending" : (notListening ? "not_listening" : "listening")
        let sources = DemoWorld.nodes.filter { $0.role == "edge" && $0.id != node.id && $0.isReporting }.prefix(4)
        return .object([
            "node_id": .string(node.id),
            "state": .string(state),
            "reason": notListening ? "beacon_not_listening" : nil,
            "applied": .object([
                "enabled": true, "port": .number(Double(port)), "bind": .string(node.ipv4),
                "endpoint": .string("\(node.ipv4):\(port)"),
                "limits": .object(["source_rate_per_second": 20, "min_interval_sec": 10, "packets_per_second_max": 2]),
            ]),
            "applied_approval_id": "approval_d0902",
            "applied_at": .time("-12d"),
            "epoch": .number(Double(epoch ?? 3)),
            "rotated_at": .time(epoch == nil ? "-9d" : "-1m"),
            "last_auth_at": reporting && !notListening ? .time("-40s") : nil,
            "agent": .object([
                "responder": true,
                "state": notListening ? "bind_failed" : (reporting ? "listening" : "off"),
                "bind": .string(node.ipv4),
                "port": .number(Double(port)),
                "epoch": .number(Double(epoch ?? 3)),
                "sources": .number(Double(sources.count)),
                "last_auth_at": reporting && !notListening ? .time("-40s") : nil,
                "error": notListening ? "listen udp: address already in use" : nil,
            ]),
            "reachability": .object([
                "state": notListening ? "not_listening" : "reachable",
                "source": .string(sources.first?.id ?? ""),
                "monitor_id": .string("mon_beacon_\(node.name)"),
                "checked_at": .time("-14m"),
            ]),
            "exposure": node.region == "home" ? "internet" : "netguard",
            "sources": .array(sources.map { source in
                .object([
                    "node_id": .string(source.id), "name": .string(source.name),
                    "source_id": .number(Double(Int(source.ipv4.split(separator: ".").last ?? "0") ?? 0)),
                    "approved": true, "current": true,
                ])
            }),
            "version": 4,
        ])
    }

    // MARK: - Node writes

    static var nodeWriteRoutes: [DemoRoute] {
        [
            DemoRoute(method: "POST", pathPattern: "/api/nodes/disable") { request, state in
                guard let node = node(in: request) else { return missingNode }
                let disabled = request.bodyObject()?["disabled"] as? Bool ?? false
                if disabled {
                    await state.insert(node.id, into: "node.disabled")
                    await state.remove(node.id, from: "node.enabled")
                } else {
                    await state.remove(node.id, from: "node.disabled")
                    await state.insert(node.id, into: "node.enabled")
                }
                return .json(#"{"ok":true,"disabled":\#(disabled)}"#)
            }.requiring("node:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/nodes/rotate-token") { request, _ in
                guard let node = node(in: request) else { return missingNode }
                let suffix = String(node.id.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 65_536 }, radix: 16)
                return .json(DemoJSON.object(["node_id": .string(node.id), "token": .string("lat_demo_node_\(suffix).notasecret")]).text)
            }.requiring("node:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/nodes/update") { request, state in
                guard let node = node(in: request), let body = request.bodyObject() else { return missingNode }
                let name = (body["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let role = (body["role"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let comment = (body["comment"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let tags = Array(Set((body["tags"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
                if name.count > 64 {
                    return .error(status: 400, code: "bad_request", message: "name must be at most 64 characters")
                }
                let answer = DemoJSON.object([
                    "ok": true, "name": .string(name), "role": .string(role), "comment": .string(comment),
                    "tags": .strings(tags), "agent_source_allowlist": [], "inventory": nil,
                ]).text
                await state.setValue(answer, for: "fleet.identity.\(node.id)")
                return .json(answer)
            }.requiring("node:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/nodes/delete/plan") { request, state in
                guard let node = node(in: request), await !state.contains(node.id, in: "fleet.node.deleted") else { return missingNode }
                return .json(deleteSummaryJSON(node, mutated: false).text)
            }.requiring("node:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/nodes/delete") { request, state in
                guard let node = node(in: request), await !state.contains(node.id, in: "fleet.node.deleted") else { return missingNode }
                if node.name == "relay-hkg-1" {
                    return .error(status: 409, code: "conflict", message: "relay-hkg-1 holds the lease of line chain hkg-tyo; release the chain on web first")
                }
                await state.insert(node.id, into: "fleet.node.deleted")
                return .json(deleteSummaryJSON(node, mutated: true).text)
            }.requiring("node:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/nodes/debug") { request, state in
                guard let node = node(in: request), let body = request.bodyObject() else { return missingNode }
                guard let enabled = body["enabled"] as? Bool else {
                    return .error(status: 400, code: "bad_request", message: "enabled is required")
                }
                let collect = enabled && (body["collect"] as? Bool ?? enabled)
                await state.setValue(enabled ? (collect ? "collect" : "on") : "off", for: "fleet.debug.\(node.id)")
                return .json(nodeViewJSON(node, debug: (enabled, collect)).text)
            }.requiring("node:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/nodes/geo") { request, _ in
                guard let node = node(in: request) else { return missingNode }
                guard request.bodyObject()?["clear"] as? Bool == true else {
                    return .error(status: 400, code: "bad_request", message: "set a location on web")
                }
                return .json(DemoJSON.object([
                    "id": .string(node.id), "name": .string(node.name), "role": .string(node.role), "online": .bool(node.isReporting),
                    "status": .string(node.status), "status_reason": .string(node.statusReason), "public_ip": .string(node.ipv4),
                    "host_facts": .object([:]),
                ]).text)
            }.requiring("node:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/nodes/geo/resolve") { request, _ in
                let body = request.bodyObject() ?? [:]
                let all = body["all"] as? Bool ?? false
                let targets: [DemoWorldNode]
                if all {
                    let missingOnly = body["missing_only"] as? Bool ?? false
                    targets = DemoWorld.nodes.filter { !missingOnly || $0.region == "home" }
                } else if let node = node(in: request) {
                    targets = [node]
                } else {
                    return .error(status: 400, code: "bad_request", message: "node_id or all=true is required")
                }
                return .json(DemoJSON.object(["results": .array(targets.map(resolveResultJSON))]).text)
            }.requiring("node:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/nodes/beacon/rotate") { request, state in
                guard let node = node(in: request) else { return missingNode }
                guard node.role == "relay" || node.name.hasPrefix("edge-tyo"), node.status != "never_reported" else {
                    return .error(status: 409, code: "conflict", message: "the node's beacon is not enabled")
                }
                let current = await state.value(for: "fleet.beacon.epoch.\(node.id)").flatMap { Int($0) } ?? 3
                await state.setValue(String(current + 1), for: "fleet.beacon.epoch.\(node.id)")
                return .json(#"{"node_id":"\#(node.id)","epoch":\#(current + 1)}"#)
            }.requiring("node:admin"),
        ]
    }

    static let missingNode = DemoResponse.error(status: 404, code: "not_found", message: "node not found")

    static func node(in request: DemoRequest) -> DemoWorldNode? {
        let id = request.bodyStrings["node_id"] ?? request.query["node_id"] ?? ""
        return DemoWorld.node(id: id)
    }

    /// The node view a write answers with, with the debug policy applied.
    static func nodeViewJSON(_ node: DemoWorldNode, debug: (enabled: Bool, collect: Bool)) -> DemoJSON {
        guard case .object(var pairs) = SharedFixtures.nodeJSON(node) else { return .object([]) }
        pairs.append(("agent_debug", .object(["enabled": .bool(debug.enabled), "collect": .bool(debug.collect), "updated_at": .time()])))
        return .object(pairs)
    }

    static func resolveResultJSON(_ node: DemoWorldNode) -> DemoJSON {
        .object([
            "node_id": .string(node.id),
            "ip": .string(node.ipv4),
            "status": "updated",
            "geo": .object([
                "country": .string(node.country), "region": .string(node.region == "home" ? "ZH" : node.region),
                "city": .string(node.city), "lat": .number(node.lat), "lon": .number(node.lon),
                "ip": .string(node.ipv4), "source": "geoip", "updated_at": .time(),
            ]),
        ])
    }

    // MARK: Delete summaries

    /// What deleting a node would remove, per invented node. lab-pi-2's
    /// delete fails to purge two log stores, which the phone reports as partial.
    public static func deleteCounters(_ node: DemoWorldNode) -> [String: Int] {
        var counters: [String: Int] = [
            "tasks_stripped": 3 + node.name.count % 5,
            "tasks_deleted": node.status == "never_reported" ? 0 : 1,
            "task_results": 12 + node.name.count * 3,
            "monitors_stripped": node.isReporting ? 2 : 1,
            "monitor_results": node.lastSeen == nil ? 0 : 2_160,
            "groups": node.groupIDs.contains("g-home-lab") ? 1 : 0,
            "approvals": node.name.hasPrefix("edge-sin") ? 1 : 0,
            "log_sources": node.lastSeen == nil ? 0 : 1,
            "machine_profiles": node.region == "home" ? 0 : 1,
        ]
        switch node.role {
        case "dns":
            counters["dns_deployments"] = 1
            counters["geo_routing_stripped"] = 1
        case "relay":
            counters["managed_lines"] = 2
            counters["line_chain_definitions_deleted"] = 1
            counters["proxy_node_profiles"] = 1
            counters["proxy_usage_snapshots"] = 48
        case "edge":
            counters["net_peer_rules_stripped"] = 2
            counters["guard_bindings"] = 1
        default:
            break
        }
        if node.name == "edge-tyo-2" { counters["tunnels"] = 1 }
        if node.name == "edge-hkg-2" { counters["ddns_profiles"] = 1 }
        return counters
    }

    static func deleteSummaryJSON(_ node: DemoWorldNode, mutated: Bool) -> DemoJSON {
        var pairs: [(String, DemoJSON)] = [
            ("node_id", .string(node.id)), ("node_name", .string(node.name)), ("found", true), ("mutated", .bool(mutated)),
        ]
        let keys = [
            "tasks_stripped", "tasks_deleted", "task_results", "ddns_profiles", "machine_profiles", "nft_inputs", "dns_deployments",
            "net_policies", "net_peer_rules_stripped", "group_policy_rules_stripped", "group_policy_scopes_stripped",
            "geo_routing_stripped", "geo_routing_deleted", "agent_update_policies", "proxy_node_profiles", "proxy_usage_snapshots",
            "monitors_stripped", "monitor_results", "log_sources", "groups", "approvals", "tunnels", "guard_reality_snapshots",
            "guard_bindings", "singbox_liveness", "managed_lines", "line_chain_attempts_released", "line_chain_definitions_deleted",
            "line_chain_targets_drifted", "line_chain_lease_conflicts", "terminal_sessions", "proxy_drift_cleared",
            "log_store_purged", "log_store_purge_errs", "metrics_series_purged",
        ]
        var counters = deleteCounters(node)
        if mutated {
            let purgeErrors = node.name == "lab-pi-2" ? 2 : 0
            counters["log_store_purge_errs"] = purgeErrors
            counters["log_store_purged"] = max(0, (counters["log_sources"] ?? 0) - purgeErrors)
            counters["metrics_series_purged"] = node.lastSeen == nil ? 0 : 7
        }
        for key in keys { pairs.append((key, .number(Double(counters[key] ?? 0)))) }
        return .object(pairs)
    }

    // MARK: - Capabilities

    /// Gates this fleet has, with whether each derives from older configuration.
    static let gates: [(id: String, mutates: Bool, derived: Bool, enforced: Bool)] = [
        ("acme-dns", true, false, false),
        ("agentupdate", true, true, true),
        ("cftunnel", true, true, false),
        ("nft", true, true, true),
        ("nftpolicy", true, true, false),
        ("selfdns", true, true, false),
        ("singbox", true, true, false),
        ("sshguard", true, false, true),
        ("wireguard", true, true, false),
    ]

    /// Whether a gate admits a node without an explicit record, and why not.
    static func derived(_ gate: String, _ node: DemoWorldNode) -> (allowed: Bool, source: String, reason: String) {
        switch gate {
        case "sshguard":
            return node.tags.contains("sshguard") ? (true, "record", "") : (false, "default", "not enrolled for sshguard")
        case "nft", "nftpolicy":
            return node.region == "home" ? (false, "derived", "not configured for \(gate)") : (true, "derived", "")
        case "selfdns":
            return node.role == "dns" ? (true, "derived", "") : (false, "derived", "no self-host DNS deployment on this node")
        case "singbox":
            return node.role == "relay" ? (true, "derived", "") : (false, "derived", "sing-box discovery is off on this node")
        case "acme-dns":
            return (false, "default", "not enrolled for acme-dns")
        default:
            return (true, "derived", "")
        }
    }

    static var capabilityRoutes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/nodes/capabilities", body: nodeCapabilitiesBody(DemoWorld.node("edge-tyo-2"), records: [:], gateState: [:]),
                      emptyBody: #"{"capabilities":[],"known":[]}"#) { request, state in
                let (records, gateState) = await capabilityState(state)
                guard let id = request.query["node_id"] else {
                    return .json(recordsBody(request, records: records, gateState: gateState))
                }
                guard let node = DemoWorld.node(id: id) else {
                    return .error(status: 403, code: "forbidden", message: "forbidden")
                }
                return .json(nodeCapabilitiesBody(node, records: records, gateState: gateState))
            }.requiring("node:read"),
            DemoRoute(method: "POST", pathPattern: "/api/nodes/capabilities") { request, state in
                guard let node = node(in: request) else { return missingNode }
                let capability = request.bodyStrings["capability"] ?? ""
                let decision = request.bodyStrings["state"] ?? ""
                let reason = (request.bodyStrings["reason"] ?? "").trimmingCharacters(in: .whitespaces)
                guard gates.contains(where: { $0.id == capability }) else {
                    return .error(status: 400, code: "bad_request", message: "unknown capability \"\(capability)\"")
                }
                switch decision {
                case "enrolled", "":
                    break
                case "excluded" where reason.isEmpty:
                    return .error(status: 400, code: "bad_request", message: "a reason is required to exclude a node")
                case "excluded":
                    break
                default:
                    return .error(status: 400, code: "bad_request", message: "state must be \"enrolled\", \"excluded\", or empty to clear")
                }
                // An empty value, not a missing one, so clearing also clears a standing record.
                await state.setValue(decision.isEmpty ? "" : "\(decision)|\(reason)", for: "fleet.cap.\(node.id).\(capability)")
                let enforced = await gateEnforced(capability, state: state)
                return .json(DemoJSON.object([
                    "node_id": .string(node.id), "capability": .string(capability), "state": .string(decision),
                    "reason": reason.isEmpty ? nil : .string(reason), "actor_id": .string(DemoWorld.actorID),
                    "updated_at": .time(), "enforced": .bool(enforced),
                ]).text)
            }.requiring("node:admin"),
            DemoRoute(pathPattern: "/api/capabilities", body: gatesBody(records: [:], gateState: [:]), emptyBody: #"{"capabilities":[]}"#) { _, state in
                let (records, gateState) = await capabilityState(state)
                return .json(gatesBody(records: records, gateState: gateState))
            }.requiring("node:read"),
            DemoRoute(method: "POST", pathPattern: "/api/capabilities") { request, state in
                let capability = request.bodyStrings["capability"] ?? ""
                guard gates.contains(where: { $0.id == capability }) else {
                    return .error(status: 400, code: "bad_request", message: "unknown capability \"\(capability)\"")
                }
                let enforced = request.bodyObject()?["enforced"] as? Bool ?? false
                await state.setValue(enforced ? "true" : "false", for: "fleet.gate.\(capability)")
                let (records, gateState) = await capabilityState(state)
                return .json(impactJSON(capability, records: records, gateState: gateState).text)
            }.requiring("node:admin"),
        ]
    }

    static func gateEnforced(_ capability: String, state: DemoState) async -> Bool {
        if let value = await state.value(for: "fleet.gate.\(capability)") { return value == "true" }
        return gates.first { $0.id == capability }?.enforced ?? false
    }

    /// Explicit records and gate overrides from this session, over the
    /// standing ones: lab-pi-2 excluded from SSH Guard, and every node with an
    /// SSH Guard story enrolled in it.
    static func capabilityState(_ state: DemoState) async -> (records: [String: String], gates: [String: Bool]) {
        var records: [String: String] = ["\(DemoWorld.node("lab-pi-2").id).sshguard": "excluded|No exposed port until port forwarding is configured"]
        for name in SharedFixtures.sshGuardEnrolledNodes {
            records["\(DemoWorld.node(name).id).sshguard"] = "enrolled|"
        }
        var gateState: [String: Bool] = [:]
        for gate in gates {
            if let value = await state.value(for: "fleet.gate.\(gate.id)") { gateState[gate.id] = value == "true" }
            for node in DemoWorld.nodes {
                if let value = await state.value(for: "fleet.cap.\(node.id).\(gate.id)") {
                    records["\(node.id).\(gate.id)"] = value
                }
            }
        }
        return (records, gateState)
    }

    static func effective(_ gate: (id: String, mutates: Bool, derived: Bool, enforced: Bool), _ node: DemoWorldNode,
                          records: [String: String], gateState: [String: Bool]) -> (allowed: Bool, source: String, reason: String, state: String, recordReason: String) {
        let enforced = gateState[gate.id] ?? gate.enforced
        let record = records["\(node.id).\(gate.id)"]?.split(separator: "|", maxSplits: 1).map(String.init)
        if let record, record.first == "excluded" {
            return (false, "record", "excluded: \(record.count > 1 ? record[1] : "")", "excluded", record.count > 1 ? record[1] : "")
        }
        if let record, record.first == "enrolled" {
            return (true, "record", "", "enrolled", record.count > 1 ? record[1] : "")
        }
        let base = derived(gate.id, node)
        if !enforced { return (true, "unenforced", base.allowed ? "" : base.reason, "", "") }
        return (base.allowed, base.source, base.reason, "", "")
    }

    /// `GET /api/nodes/capabilities` without `node_id`: every explicit record
    /// on a node the caller may read, and the known capabilities.
    static func recordsBody(_ request: DemoRequest, records: [String: String], gateState: [String: Bool]) -> String {
        let scopes = request.scopes
        let rows: [DemoJSON] = records.keys.sorted().compactMap { key in
            guard let dot = key.lastIndex(of: ".") else { return nil }
            let nodeID = String(key[..<dot])
            let capability = String(key[key.index(after: dot)...])
            guard scopes.allows("node:read", nodeID: nodeID) else { return nil }
            let parts = (records[key] ?? "").split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let decision = parts.first, !decision.isEmpty else { return nil }
            let reason = parts.count > 1 ? parts[1] : ""
            return .object([
                "node_id": .string(nodeID),
                "capability": .string(capability),
                "state": .string(decision),
                "reason": reason.isEmpty ? nil : .string(reason),
                "actor_id": .string(DemoWorld.actorID),
                "updated_at": .time("-3d"),
                "enforced": .bool(gateState[capability] ?? gates.first { $0.id == capability }?.enforced ?? false),
            ])
        }
        return DemoJSON.object([
            "capabilities": .array(rows),
            "known": .array(gates.map { gate in
                .object(["id": .string(gate.id), "enforced": .bool(gateState[gate.id] ?? gate.enforced), "mutates": .bool(gate.mutates), "derived": .bool(gate.derived)])
            }),
        ]).text
    }

    static func nodeCapabilitiesBody(_ node: DemoWorldNode, records: [String: String], gateState: [String: Bool]) -> String {
        DemoJSON.object([
            "node_id": .string(node.id),
            "effective": .array(gates.map { gate in
                let answer = effective(gate, node, records: records, gateState: gateState)
                return .object([
                    "capability": .string(gate.id),
                    "enforced": .bool(gateState[gate.id] ?? gate.enforced),
                    "mutates": .bool(gate.mutates),
                    "allowed": .bool(answer.allowed),
                    "source": .string(answer.source),
                    "reason": answer.reason.isEmpty ? nil : .string(answer.reason),
                    "state": answer.state.isEmpty ? nil : .string(answer.state),
                    "record_reason": answer.recordReason.isEmpty ? nil : .string(answer.recordReason),
                    "actor_id": answer.state.isEmpty ? nil : .string(DemoWorld.actorID),
                    "updated_at": answer.state.isEmpty ? nil : .time("-3d"),
                ])
            }),
        ]).text
    }

    static func impactJSON(_ capability: String, records: [String: String], gateState: [String: Bool]) -> DemoJSON {
        guard let gate = gates.first(where: { $0.id == capability }) else { return .object([:]) }
        // The impact is "as if enforced", so it ignores the open-gate shortcut.
        let forced = gateState.merging([capability: true]) { _, new in new }
        let answers = DemoWorld.nodes.map { node in (node, effective(gate, node, records: records, gateState: forced)) }
        let refused = answers.filter { !$0.1.allowed }
        return .object([
            "capability": .string(gate.id),
            "enforced": .bool(gateState[gate.id] ?? gate.enforced),
            "mutates": .bool(gate.mutates),
            "derived": .bool(gate.derived),
            "allow_count": .number(Double(answers.count - refused.count)),
            "refuse_count": .number(Double(refused.count)),
            "refused": refused.isEmpty ? nil : .array(refused.prefix(10).map { node, answer in
                .object(["node_id": .string(node.id), "name": .string(node.name), "reason": .string(answer.reason)])
            }),
        ])
    }

    static func gatesBody(records: [String: String], gateState: [String: Bool]) -> String {
        DemoJSON.object(["capabilities": .array(gates.map { impactJSON($0.id, records: records, gateState: gateState) })]).text
    }

    // MARK: - Groups

    /// Server selectors for the invented groups; Home lab is a static list.
    static func selector(for group: DemoWorldGroup) -> DemoJSON? {
        switch group.id {
        case "g-asia-edge": .object(["match_tags_any": ["asia"], "match_roles": ["edge"]])
        case "g-europe-relays": .object(["match_tags_any": ["europe"]])
        case "g-dns": .object(["match_roles": ["dns"]])
        case "g-us-edge": .object(["match_tags_any": ["us"]])
        default: nil
        }
    }

    static func rollup(_ ids: [String]) -> DemoJSON {
        let nodes = ids.compactMap { DemoWorld.node(id: $0) }
        let online = nodes.filter { $0.status == "online" || $0.status == "degraded" }.count
        let disabled = nodes.filter { $0.status == "disabled" }.count
        return .object([
            "total": .number(Double(nodes.count)), "online": .number(Double(online)),
            "offline": .number(Double(nodes.count - online - disabled)), "disabled": .number(Double(disabled)),
        ])
    }

    static func staticMembers(_ group: DemoWorldGroup, state: DemoState?) async -> [String] {
        guard selector(for: group) == nil else { return [] }
        if let state, let stored = await state.value(for: "fleet.group.members.\(group.id)") {
            return stored.split(separator: ",").map(String.init)
        }
        return group.nodeIDs
    }

    static func groupJSON(_ group: DemoWorldGroup, members: [String]) -> DemoJSON {
        let resolved = selector(for: group) == nil ? members : group.nodeIDs
        return .object([
            "id": .string(group.id),
            "name": .string(group.name),
            "slug": .string(String(group.id.dropFirst(2))),
            "color": "blue",
            "order": .number(Double(DemoWorld.groups.firstIndex(of: group) ?? 0)),
            "members": .strings(members),
            "selector": selector(for: group),
            "created_at": .time("-60d"),
            "updated_at": .time("-5d"),
            "resolved_members": .strings(resolved.sorted()),
            "rollup": rollup(resolved),
        ])
    }

    static func groupsBody(state: DemoState?) async -> String {
        let deleted = await state?.members(of: "fleet.group.deleted") ?? []
        var views: [DemoJSON] = []
        var grouped = Set<String>()
        for group in DemoWorld.groups where !deleted.contains(group.id) {
            let members = await staticMembers(group, state: state)
            grouped.formUnion(selector(for: group) == nil ? members : group.nodeIDs)
            views.append(groupJSON(group, members: members))
        }
        let ungrouped = DemoWorld.nodes.map(\.id).filter { !grouped.contains($0) }.sorted()
        return DemoJSON.object([
            "groups": .array(views),
            "ungrouped": .object(["resolved_members": .strings(ungrouped), "rollup": rollup(ungrouped)]),
        ]).text
    }

    /// What names each group. US edge is named by nothing, so it can be deleted.
    static func uses(_ groupID: String) -> (uses: [DemoJSON], hidden: Int) {
        switch groupID {
        case "g-asia-edge":
            return ([
                .object(["kind": "check", "id": "chk_asia_mesh", "label": "Asia edge mesh", "role": "source_and_target"]),
                .object(["kind": "outbound_policy", "id": "gp_asia-edge", "label": "Asia edge egress", "role": "target"]),
            ], 0)
        case "g-europe-relays":
            return ([.object(["kind": "outbound_policy", "id": "gp_europe-relays", "label": "Europe relays egress", "role": "target"])], 0)
        case "g-dns":
            return ([.object(["kind": "check", "id": "chk_dns_answers", "label": "DNS answers", "role": "source"])], 0)
        case "g-home-lab":
            return ([], 1)
        default:
            return ([], 0)
        }
    }

    static var groupRoutes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/groups", body: #"{"groups":[],"ungrouped":{"resolved_members":[],"rollup":{"total":0,"online":0,"offline":0,"disabled":0}}}"#,
                      emptyBody: #"{"groups":[],"ungrouped":{"resolved_members":[],"rollup":{"total":0,"online":0,"offline":0,"disabled":0}}}"#) { _, state in
                .json(await groupsBody(state: state))
            }.requiring("group:read"),
            DemoRoute(pathPattern: "/api/groups/used-by", body: #"{"group_id":"g-dns","used_by":[],"hidden":0}"#,
                      emptyBody: #"{"group_id":"","used_by":[],"hidden":0}"#) { request, state in
                let id = request.query["id"] ?? ""
                guard DemoWorld.groups.contains(where: { $0.id == id }), await !state.contains(id, in: "fleet.group.deleted") else {
                    return .error(status: 404, code: "not_found", message: "node group \"\(id)\" not found")
                }
                let found = uses(id)
                return .json(DemoJSON.object(["group_id": .string(id), "used_by": .array(found.uses), "hidden": .number(Double(found.hidden))]).text)
            }.requiring("group:read"),
            DemoRoute(method: "POST", pathPattern: "/api/groups/delete") { request, state in
                let id = request.bodyStrings["id"] ?? ""
                guard let group = DemoWorld.groups.first(where: { $0.id == id }), await !state.contains(id, in: "fleet.group.deleted") else {
                    return .error(status: 409, code: "conflict", message: "group not found")
                }
                let found = uses(id)
                if !found.uses.isEmpty || found.hidden > 0 {
                    let count = found.uses.count + found.hidden
                    return .error(status: 409, code: "conflict", message: "\(group.name) is used by \(count) object\(count == 1 ? "" : "s"); remove those references first")
                }
                await state.insert(id, into: "fleet.group.deleted")
                return .json(#"{"ok":true}"#)
            }.requiring("group:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/groups/members") { request, state in
                let body = request.bodyObject() ?? [:]
                let id = body["group_id"] as? String ?? ""
                guard let group = DemoWorld.groups.first(where: { $0.id == id }), await !state.contains(id, in: "fleet.group.deleted") else {
                    return .error(status: 404, code: "not_found", message: "group not found")
                }
                let add = body["add"] as? [String] ?? []
                let remove = Set(body["remove"] as? [String] ?? [])
                var members = await staticMembers(group, state: state)
                for nodeID in add where !members.contains(nodeID) && DemoWorld.node(id: nodeID) != nil { members.append(nodeID) }
                members.removeAll { remove.contains($0) }
                await state.setValue(members.joined(separator: ","), for: "fleet.group.members.\(group.id)")
                return .json(groupJSON(group, members: members).text)
            }.requiring("group:admin"),
        ]
    }
}
