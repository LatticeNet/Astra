import Foundation

/// Demo routes for the Monitoring domain, owned by the Monitoring module
/// (section 8.6): checks with their newest results, result history, path
/// and latency series, check definitions, line chains and the M3 writes.
/// Ids line up with the Shared path and incident fixtures (`mon_tls_api`,
/// `mon_tcp_edge-tyo-1_relay-fra-1`, `def_fleet_mesh`).
public enum MonitoringFixtures {
    public static let routes: [DemoRoute] = [
        DemoRoute(pathPattern: "/api/monitors", body: monitorsBody(checks, state: [:]), emptyBody: "[]") { _, state in
            .json(await currentMonitorsBody(state: state))
        }.requiring("monitor:read"),
        DemoRoute(pathPattern: "/api/monitors/results", body: "[]") { request, state in
            await resultsAnswer(request, state: state)
        }.requiring("monitor:read"),
        DemoRoute(pathPattern: "/api/monitors/series", body: seriesBody(profile: .steady(48), window: "1h", compare: false), emptyBody: emptySeriesBody) { request, _ in
            seriesAnswer(request)
        }.requiring("monitor:read"),
        DemoRoute(pathPattern: "/api/monitors/latency/series", body: latencySeriesBody(source: "", target: "", window: "24h"), emptyBody: #"{"source":"","target":"","monitor_id":"","window":"24h","bucket_sec":3600,"from":"{{now-24h}}","to":"{{now}}","buckets":[]}"#) { request, _ in
            .json(latencySeriesBody(source: request.query["source"] ?? "", target: request.query["target"] ?? "", window: request.query["window"] ?? "24h"))
        }.requiring("monitor:read"),
        DemoRoute(pathPattern: "/api/monitors/latency/rollups", body: rollupsBody, emptyBody: #"{"generated_at":"{{now}}","interval_sec":60,"pairs":[]}"#).requiring("monitor:read"),
        DemoRoute(pathPattern: "/api/monitors/definitions", body: definitionsBody(state: [:], deleted: []), emptyBody: #"{"definitions":[]}"#) { request, state in
            await definitionsAnswer(request, state: state)
        }.requiring("monitor:read"),
        DemoRoute(method: "POST", pathPattern: "/api/monitors/update") { request, state in
            await updateAnswer(request, state: state)
        }.requiring("monitor:admin"),
        DemoRoute(method: "POST", pathPattern: "/api/monitors/delete") { request, state in
            await deleteAnswer(request, state: state)
        }.requiring("monitor:admin"),
        DemoRoute(method: "POST", pathPattern: "/api/monitors/definitions/delete") { request, state in
            await definitionDeleteAnswer(request, state: state)
        }.requiring("monitor:admin"),
        DemoRoute(pathPattern: "/api/network/lines/chains", body: chainsBody, emptyBody: #"{"chains":[]}"#).requiring("proxy:read"),
    ]

    // MARK: Checks

    enum Health: Sendable {
        case up(Double)
        case failing(String)
        case stale(Int)
        case unmeasured(String)
    }

    struct Check: Sendable {
        var id: String
        var name: String
        var type: String
        var target: String
        var interval = 60
        var timeout = 10
        /// Node names; empty for a tls check, which the control plane runs.
        var nodes: [String]
        var enabled = true
        var version: Int = 3
        var managedBy = ""
        var definition = ""
        var health: Health
        var targetNode = ""
        var thresholdDays = 0
        var dnsName = ""
        var expectStatus = ""
        var packets = 0
        var alert = "down"
        var created = "-40d"
    }

    static let checks: [Check] = {
        var list: [Check] = [
            Check(id: "mon_tls_api", name: "tls-api", type: "tls", target: "tls-api.example.org:443", interval: 300, nodes: [],
                  health: .failing("certificate expires in 9 days, under the 14-day threshold"), thresholdDays: 14),
            Check(id: "mon_disk_hkg2", name: "hkg-2 disk probe", type: "http", target: "http://edge-hkg-2.example.net:9100/healthz/disk",
                  nodes: ["edge-hkg-2"], health: .failing("status 507: disk above 90%"), expectStatus: "200-299", alert: "off"),
            Check(id: "mon_http_portal", name: "status portal", type: "http", target: "https://status.example.org/",
                  nodes: ["edge-iad-1", "edge-fra-3", "edge-sin-1"], version: 4, health: .up(142), expectStatus: "200-399"),
            Check(id: "mon_dns_resolver", name: "resolver answers", type: "dns", target: "https://dns.example.net/dns-query",
                  nodes: ["dns-fra-1", "dns-iad-1", "dns-tyo-1"], health: .up(18), dnsName: "example.org"),
            Check(id: "mon_tcp_bastion", name: "bastion ssh", type: "tcp", target: "203.0.113.20:22",
                  nodes: ["edge-lon-1"], enabled: false, health: .up(9)),
            Check(id: "mon_icmp_home", name: "home router ping", type: "icmp", target: "203.0.113.41", interval: 30,
                  nodes: ["studio-mac"], health: .stale(22), targetNode: "home-router", packets: 5),
            Check(id: "mon_icmp_lab", name: "lab gateway ping", type: "icmp", target: "198.51.100.90",
                  nodes: ["lab-pi-1"], health: .unmeasured("icmp_not_permitted"), packets: 3),
            Check(id: "mon_latency_relay-hkg-1", name: "latency probe to relay-hkg-1", type: "tcp", target: "198.51.100.19:7443",
                  nodes: ["edge-sin-2", "probe-sin-3"], managedBy: "latency", health: .up(38), targetNode: "relay-hkg-1"),
        ]
        let mesh: [(String?, String, String, Health)] = [
            ("edge-tyo-1", "relay-fra-1", "tcp", .up(238)),
            ("edge-tyo-1", "relay-hkg-1", "tcp", .up(49)),
            ("edge-tyo-1", "relay-fra-2", "tcp", .failing("dial tcp: i/o timeout")),
            ("edge-sin-1", "relay-hkg-1", "tcp", .up(34)),
            ("edge-sin-1", "relay-fra-1", "tcp", .up(161)),
            ("relay-fra-1", "core-lon-1", "icmp", .up(14)),
            ("relay-fra-1", "relay-fra-2", "icmp", .failing("5 of 5 echoes lost")),
            ("edge-iad-1", "edge-sjc-1", "tcp", .up(62)),
            ("edge-syd-1", "relay-syd-2", "tcp", .up(3)),
            ("edge-ams-2", "relay-hkg-1", "icmp", .unmeasured("packet_budget")),
            (nil, "core-lon-1", "http", .up(21)),
        ]
        for (source, target, method, health) in mesh {
            let node = DemoWorld.node(target)
            list.append(Check(
                id: "mon_\(method)_\(source ?? "cp")_\(target)",
                name: "Fleet mesh to \(target)" + (source.map { " from \($0)" } ?? ""),
                type: method,
                target: method == "http" ? "https://\(node.hostname)/healthz" : "\(node.ipv4):443",
                nodes: source.map { [$0] } ?? [],
                version: 7, definition: "def_fleet_mesh", health: health, targetNode: target, alert: "down_and_degraded"
            ))
        }
        for name in ["dns-fra-1", "dns-iad-1", "dns-tyo-1"] {
            list.append(Check(
                id: "mon_dns_watch_\(name)", name: "DNS answers from \(name)", type: "dns", target: "udp://\(DemoWorld.node(name).ipv4):53",
                nodes: [name], version: 2, definition: "def_dns_watch", health: .up(11), dnsName: "www.example.org"
            ))
        }
        return list
    }()

    static func currentMonitorsBody(state: DemoState) async -> String {
        monitorsBody(await visibleChecks(state: state), state: await overrides(state: state))
    }

    /// Checks this session has not deleted, with pause and resume applied.
    static func visibleChecks(state: DemoState) async -> [Check] {
        let deleted = await state.members(of: "monitor.deleted")
        let deletedDefinitions = await state.members(of: "definition.deleted")
        return checks.filter { !deleted.contains($0.id) && !deletedDefinitions.contains($0.definition) }
    }

    /// `id -> (enabled, version)` from this session's updates.
    static func overrides(state: DemoState) async -> [String: (Bool, Int)] {
        var result: [String: (Bool, Int)] = [:]
        for check in checks {
            if let raw = await state.value(for: "monitor.update.\(check.id)") {
                let parts = raw.split(separator: ":")
                if parts.count == 2, let version = Int(parts[1]) { result[check.id] = (parts[0] == "1", version) }
            }
        }
        return result
    }

    static func monitorsBody(_ list: [Check], state: [String: (Bool, Int)]) -> String {
        DemoJSON.array(list.map { monitorJSON($0, override: state[$0.id]) }).text
    }

    static func monitorJSON(_ check: Check, override: (Bool, Int)?) -> DemoJSON {
        let enabled = override?.0 ?? check.enabled
        let version = override?.1 ?? check.version
        let nodeIDs = check.nodes.map { DemoWorld.node($0).id }
        return .object([
            "id": .string(check.id),
            "name": .string(check.name),
            "type": .string(check.type),
            "target": .string(check.target),
            "interval_sec": .number(Double(check.interval)),
            "timeout_sec": .number(Double(check.timeout)),
            "assign_all": false,
            "node_ids": nodeIDs.isEmpty ? nil : .strings(nodeIDs),
            "threshold_days": check.thresholdDays > 0 ? .number(Double(check.thresholdDays)) : nil,
            "enabled": .bool(enabled),
            "target_node": check.targetNode.isEmpty ? nil : .string(DemoWorld.node(check.targetNode).id),
            "packets": check.packets > 0 ? .number(Double(check.packets)) : nil,
            "expect_status": check.expectStatus.isEmpty ? nil : .string(check.expectStatus),
            "dns_name": check.dnsName.isEmpty ? nil : .string(check.dnsName),
            "dns_type": check.dnsName.isEmpty ? nil : "A",
            "managed_by": check.managedBy.isEmpty ? nil : .string(check.managedBy),
            "check_definition_id": check.definition.isEmpty ? nil : .string(check.definition),
            "alert": .string(check.alert),
            "alert_after": 2,
            "version": .number(Double(version)),
            "created_at": .time(check.created),
            "updated_at": .time(override == nil ? "-3d" : "-1s"),
            "latest": .array(enabled ? latestJSON(check) : []),
        ])
    }

    /// Each assigned node's newest result, as the list carries it.
    static func latestJSON(_ check: Check) -> [DemoJSON] {
        let sources = check.nodes.isEmpty ? [""] : check.nodes.map { DemoWorld.node($0).id }
        return sources.enumerated().map { index, nodeID in
            switch check.health {
            case .up(let ms):
                return .object([
                    "node_id": .string(nodeID), "at": .time("-\(10 + index * 7)s"), "success": true,
                    "latency_ms": .number(ms + Double(index) * 3.5), "fail_streak": 0, "since": .time("-2d"),
                ])
            case .failing(let error):
                // On a multi-node check only the first node fails.
                let fails = index == 0
                return .object([
                    "node_id": .string(nodeID), "at": .time("-\(20 + index * 5)s"), "success": .bool(!fails),
                    "latency_ms": .number(fails ? 0 : 120), "error": fails ? .string(error) : nil,
                    "fail_streak": fails ? 6 : 0, "since": .time(fails ? "-22m" : "-1d"),
                ])
            case .stale(let minutes):
                return .object([
                    "node_id": .string(nodeID), "at": .time("-\(minutes)m"), "success": true, "latency_ms": 4.2,
                    "fail_streak": 0, "since": .time("-3d"), "sent": 5, "lost": 0,
                ])
            case .unmeasured(let reason):
                return .object([
                    "node_id": .string(nodeID), "at": .time("-40s"), "success": false, "latency_ms": 0, "fail_streak": 0,
                    "since": .time("-1h"), "reason": .string(reason), "reason_at": .time("-40s"),
                ])
            }
        }
    }

    // MARK: Results

    static func resultsAnswer(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        guard let id = request.query["monitor_id"], !id.isEmpty else {
            return .error(status: 400, code: "bad_request", message: "monitor_id is required")
        }
        guard let check = await visibleChecks(state: state).first(where: { $0.id == id }) else { return .json("[]") }
        let limit = min(SharedFixtures.intQuery(request, "limit") ?? 500, 160)
        var sources = check.nodes.isEmpty ? [""] : check.nodes.map { DemoWorld.node($0).id }
        if let node = request.query["node_id"] { sources = sources.filter { $0 == node } }
        var rows: [(offset: Int, json: DemoJSON)] = []
        for (nodeIndex, nodeID) in sources.enumerated() {
            for step in 0..<max(1, limit / max(sources.count, 1)) {
                let offset = 10 + nodeIndex * 7 + step * check.interval + staleShift(check)
                rows.append((offset, resultJSON(check, nodeID: nodeID, nodeIndex: nodeIndex, step: step, offset: offset)))
            }
        }
        rows.sort { $0.offset < $1.offset }
        return .json(DemoJSON.array(rows.prefix(limit).map(\.json)).text)
    }

    private static func staleShift(_ check: Check) -> Int {
        if case .stale(let minutes) = check.health { return minutes * 60 }
        return 0
    }

    private static func resultJSON(_ check: Check, nodeID: String, nodeIndex: Int, step: Int, offset: Int) -> DemoJSON {
        var success = true
        var error: String?
        var reason: String?
        var latency = 0.0
        switch check.health {
        case .up(let ms):
            latency = ms + Double((step * 7 + nodeIndex * 3) % 11) - 5
            // An old blip, so the history is not uniform.
            if step == 37 { success = false; error = "dial tcp: i/o timeout" }
        case .failing(let message):
            if nodeIndex == 0 && step < 6 {
                success = false
                error = message
            } else {
                latency = 118 + Double(step % 9)
            }
        case .stale:
            latency = 4 + Double(step % 3) / 10
        case .unmeasured(let why):
            if step < 3 { reason = why; success = false } else { latency = 6 + Double(step % 4) }
        }
        return .object([
            "monitor_id": .string(check.id),
            "node_id": .string(nodeID),
            "at": .time("-\(offset)s"),
            "success": .bool(success),
            "latency_ms": success ? .number(max(latency, 0.4)) : nil,
            "error": error.map(DemoJSON.string),
            "reason": reason.map(DemoJSON.string),
            "received_at": .time("-\(max(offset - 1, 0))s"),
            "cert_not_after": check.type == "tls" ? .time("+9d") : nil,
            "sent": check.type == "icmp" && reason == nil ? .number(Double(max(check.packets, 1))) : nil,
            "lost": check.type == "icmp" && reason == nil ? .number(success ? 0 : Double(max(check.packets, 1))) : nil,
        ])
    }

    // MARK: Series

    enum Profile: Sendable {
        /// A healthy path around this p50.
        case steady(Double)
        /// Loss climbing over the last 48 minutes, with a gap of no data earlier on.
        case degraded
        /// Every run failing for the last three hours.
        case down
        /// A source that stopped reporting before this window began.
        case silent
        /// A method change from icmp to tcp halfway through.
        case methodChange(Double)
    }

    static func profile(source: String, target: String) -> Profile {
        let pair = "\(DemoWorld.node(id: source)?.name ?? source)~\(DemoWorld.node(id: target)?.name ?? target)"
        switch pair {
        case "edge-tyo-1~relay-fra-1": return .degraded
        case "edge-tyo-1~relay-fra-2", "relay-fra-1~relay-fra-2": return .down
        case "edge-sjc-2~edge-sjc-1", "edge-iad-1~dns-iad-1", "edge-syd-1~core-sjc-1", "edge-ams-2~relay-hkg-1": return .silent
        case "edge-sin-1~relay-fra-1": return .methodChange(161)
        case "edge-tyo-1~relay-hkg-1": return .steady(49)
        case "edge-sin-1~relay-hkg-1": return .steady(34)
        case "relay-fra-1~core-lon-1": return .steady(14)
        case "edge-iad-1~edge-sjc-1": return .steady(62)
        case "edge-syd-1~relay-syd-2": return .steady(3)
        default: return .steady(48)
        }
    }

    static func seriesAnswer(_ request: DemoRequest) -> DemoResponse {
        let window = request.query["window"] ?? "24h"
        guard ["1h", "6h", "24h", "3d", "7d", "14d"].contains(window) else {
            return .error(status: 400, code: "bad_request", message: "window must be one of 1h, 6h, 24h, 3d, 7d, 14d")
        }
        let compare = request.query["compare"] == "previous"
        let source = request.query["source"] ?? ""
        let chosen: Profile
        if let target = request.query["target_node"], !target.isEmpty {
            if let check = request.query["check"], !check.isEmpty, !pairHasCheck(check, source: source, target: target) {
                return .error(status: 404, code: "not_found", message: "no check measures that pair")
            }
            chosen = profile(source: source, target: target)
        } else if let monitor = request.query["monitor"], let check = checks.first(where: { $0.id == monitor }) {
            switch check.health {
            case .up(let ms): chosen = .steady(ms)
            case .failing: chosen = .down
            case .stale, .unmeasured: chosen = .silent
            }
        } else {
            return .error(status: 400, code: "bad_request", message: "source and target_node, or monitor, are required")
        }
        return .json(seriesBody(profile: chosen, window: window, compare: compare))
    }

    /// `pairCheckFor`: a pair's `check` names a definition or an operator's
    /// own check on that pair; a generated monitor's id names nothing.
    static func pairHasCheck(_ check: String, source: String, target: String) -> Bool {
        if definitionVersions[check] != nil { return true }
        return checks.contains { candidate in
            candidate.id == check && candidate.definition.isEmpty && candidate.managedBy.isEmpty && !candidate.targetNode.isEmpty
                && DemoWorld.node(candidate.targetNode).id == target
                && candidate.nodes.contains { DemoWorld.node($0).id == source }
        }
    }

    static let emptySeriesBody = #"{"window":"1h","step_seconds":60,"from":"{{now-1h}}","to":"{{now}}","method_changes":[],"buckets":[],"baseline":null}"#

    /// Step and count per window, as the server tiers them.
    static func steps(_ window: String) -> (step: Int, count: Int) {
        switch window {
        case "1h": (60, 60)
        case "6h": (300, 72)
        case "24h": (300, 288)
        case "3d": (3600, 72)
        case "7d": (3600, 168)
        default: (3600, 336)
        }
    }

    static func seriesBody(profile: Profile, window: String, compare: Bool) -> String {
        let (step, count) = steps(window)
        let span = step * count
        var buckets: [DemoJSON] = []
        var previous: [DemoJSON] = []
        var base = 48.0
        var methodChanges: [DemoJSON] = []
        switch profile {
        case .steady(let ms), .methodChange(let ms): base = ms
        case .degraded: base = 238
        case .down, .silent: base = 160
        }
        if case .methodChange = profile {
            methodChanges = [
                .object(["t": .time("-\(span)s"), "method": "icmp"]),
                .object(["t": .time("-\(span / 2)s"), "method": "tcp"]),
            ]
        } else if case .silent = profile {
            methodChanges = []
        } else {
            methodChanges = [.object(["t": .time("-\(span)s"), "method": "tcp"])]
        }
        for index in 0..<count {
            let ago = span - index * step
            let wave = sin(Double(index) / 5) * base * 0.06
            var n = max(step / 60, 1)
            let expected = n
            var fail = 0
            var p50: Double? = base + wave
            var loss: Double? = 0.002
            switch profile {
            case .steady:
                if index % 97 == 41 { loss = 0.01; fail = 0 }
            case .methodChange:
                if index < count / 2 { p50 = (base * 0.82) + wave }
            case .degraded:
                // A stretch with no data, which the chart must leave as a gap.
                if index >= count / 3 && index < count / 3 + max(3, count / 20) {
                    n = 0; p50 = nil; loss = nil
                } else if ago <= 48 * 60 {
                    loss = 0.045 + Double(index % 5) * 0.006
                    fail = Int((Double(n) * (loss ?? 0)).rounded())
                    p50 = base * 1.4 + wave
                }
            case .down:
                if ago <= 3 * 3600 {
                    fail = n; p50 = nil; loss = 1
                }
            case .silent:
                n = 0; p50 = nil; loss = nil
            }
            let p95 = p50.map { ($0 * 1.35).rounded() }
            let minValue: DemoJSON = p50.map { .number(($0 * 0.9).rounded()) } ?? .null
            let p50Value: DemoJSON = p50.map { .number(($0 * 10).rounded() / 10) } ?? .null
            let p95Value: DemoJSON = p95.map(DemoJSON.number) ?? .null
            let maxValue: DemoJSON = p95.map { .number(($0 * 1.2).rounded()) } ?? .null
            let jitterValue: DemoJSON = p50.map { .number(($0 * 0.4).rounded() / 10) } ?? .null
            let lossValue: DemoJSON = loss.map(DemoJSON.number) ?? .null
            let fields: [(String, DemoJSON)] = [
                ("t", .time("-\(ago)s")),
                ("n", .number(Double(n))),
                ("expected", .number(Double(expected))),
                ("fail", .number(Double(fail))),
                ("min_ms", minValue),
                ("p50_ms", p50Value),
                ("p95_ms", p95Value),
                ("max_ms", maxValue),
                ("jitter_ms", jitterValue),
                ("loss", lossValue),
                ("sent", .number(Double(n * 10))),
                ("lost", .number((Double(n * 10) * (loss ?? 0)).rounded())),
            ]
            buckets.append(.object(fields))
            let earlier: DemoJSON
            if case .silent = profile {
                earlier = .null
            } else {
                earlier = .number(((base * 0.95 + cos(Double(index) / 6) * base * 0.05) * 10).rounded() / 10)
            }
            previous.append(earlier)
        }
        let baseline: DemoJSON
        switch profile {
        case .silent:
            baseline = .null
        default:
            baseline = .object([
                "from": .time("-7d"), "to": .time(), "hours": 168, "ready": true,
                "p50_ms": .number(base * 0.95 >= 100 ? (base * 0.68).rounded() : (base * 0.95 * 10).rounded() / 10),
                "loss": 0.004,
                "trigger_p50_ms": .number((base * 1.9).rounded()),
                "trigger_loss": 0.02,
                "rule": .object(["loss_percent": 2, "loss_factor": 2, "latency_factor": 2, "latency_margin_ms": 30]),
            ])
        }
        var pairs: [(String, DemoJSON)] = [
            ("check", "def_fleet_mesh"),
            ("window", .string(window)),
            ("step_seconds", .number(Double(step))),
            ("from", .time("-\(span)s")),
            ("to", .time()),
            ("method_changes", .array(methodChanges)),
            ("buckets", .array(buckets)),
            ("baseline", baseline),
        ]
        if compare {
            pairs.append(("previous", .object([
                "from": .time("-\(span * 2)s"), "to": .time("-\(span)s"), "offset_seconds": .number(Double(span)),
                "step_seconds": .number(Double(step)), "p50_ms": .array(previous),
            ])))
        }
        return DemoJSON.object(pairs).text
    }

    static func latencySeriesBody(source: String, target: String, window: String) -> String {
        let step = window == "1h" ? 60 : 3600
        let count = window == "7d" ? 168 : (window == "1h" ? 60 : 24)
        let buckets: [DemoJSON] = (0..<count).map { index in
            let ago = (count - index) * step
            let gap = index == count / 2
            return .object([
                "at": .time("-\(ago)s"),
                "samples": gap ? 0 : .number(Double(max(step / 60, 1))),
                "failures": 0,
                "expected": .number(Double(max(step / 60, 1))),
                "p50_ms": gap ? nil : .number(48 + Double(index % 6)),
                "p95_ms": gap ? nil : .number(63 + Double(index % 6)),
                "loss": gap ? nil : 0.001,
            ])
        }
        return DemoJSON.object([
            ("source", .string(source)), ("target", .string(target)), ("monitor_id", .string("mon_latency_relay-hkg-1")),
            ("window", .string(window)), ("bucket_sec", .number(Double(step))),
            ("from", .time("-\(count * step)s")), ("to", .time()), ("buckets", .array(buckets)),
        ]).text
    }

    static let rollupsBody: String = {
        let pairs: [DemoJSON] = ["edge-sin-2", "probe-sin-3"].map { name in
            .object([
                "source": .string(DemoWorld.node(name).id),
                "target": .string(DemoWorld.node("relay-hkg-1").id),
                "monitor_id": "mon_latency_relay-hkg-1",
                "windows": .object([
                    "1h": .object(["samples": 60, "failures": 0, "expected": 60, "p50_ms": 38, "p95_ms": 51, "loss": 0]),
                    "24h": .object(["samples": 1438, "failures": 3, "expected": 1440, "p50_ms": 39, "p95_ms": 55, "loss": 0.002]),
                    "7d": .object(["samples": 10071, "failures": 9, "expected": 10080, "p50_ms": 40, "p95_ms": 57, "loss": 0.001]),
                ]),
                "latest": .object([
                    "monitor_id": "mon_latency_relay-hkg-1", "node_id": .string(DemoWorld.node(name).id),
                    "at": .time("-20s"), "success": true, "latency_ms": 37.8,
                ]),
            ])
        }
        return DemoJSON.object([("generated_at", .time()), ("interval_sec", 60), ("pairs", .array(pairs))]).text
    }()

    // MARK: Definitions

    static func definitionsAnswer(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        let overrides = await overrides(state: state)
        let deleted = await state.members(of: "definition.deleted")
        if let wanted = request.query["id"], !wanted.isEmpty {
            guard !deleted.contains(wanted), let json = definitionJSON(wanted, detail: true, overrides: overrides) else {
                return .error(status: 404, code: "not_found", message: "check definition not found")
            }
            return .json(json.text)
        }
        return .json(definitionsBody(state: overrides, deleted: deleted))
    }

    static func definitionsBody(state: [String: (Bool, Int)], deleted: Set<String>) -> String {
        let list = ["def_dns_watch", "def_fleet_mesh"].filter { !deleted.contains($0) }.compactMap { definitionJSON($0, detail: false, overrides: state) }
        return DemoJSON.object([
            ("definitions", .array(list)),
            ("fleet_mesh", .object([
                "name": "Fleet mesh", "enabled": true, "stored": true, "version": 7, "method": "auto",
                "sources": 9, "targets": 8, "paths": 13, "paused_targets": 1, "migrated": true, "definitions": .strings(["def_fleet_mesh"]),
            ])),
        ]).text
    }

    static let definitionVersions = ["def_fleet_mesh": 7, "def_dns_watch": 2]

    static func definitionJSON(_ id: String, detail: Bool, overrides: [String: (Bool, Int)]) -> DemoJSON? {
        let members = checks.filter { $0.definition == id }
        guard !members.isEmpty, let version = definitionVersions[id] else { return nil }
        let isMesh = id == "def_fleet_mesh"
        var monitors: [DemoJSON] = members.map { check in
            .object([
                "monitor_id": .string(check.id),
                "method": .string(check.type),
                "target": .string(check.target),
                "target_node": check.targetNode.isEmpty ? nil : .string(DemoWorld.node(check.targetNode).id),
                "in_set": true,
                "enabled": .bool(overrides[check.id]?.0 ?? check.enabled),
                "sources": .strings(check.nodes.map { DemoWorld.node($0).id }),
                "runs": .number(Double(check.interval == 60 ? 40_320 : 8_064)),
            ])
        }
        if isMesh {
            // A target that left the set: kept paused with its history.
            monitors.append(.object([
                "monitor_id": "mon_tcp_edge-ams-1_backup-ams-4",
                "method": "tcp",
                "target": .string("\(DemoWorld.node("backup-ams-4").ipv4):443"),
                "target_node": .string(DemoWorld.node("backup-ams-4").id),
                "in_set": false,
                "enabled": false,
                "sources": .strings([DemoWorld.node("edge-ams-1").id]),
                "runs": 4_210,
            ]))
        }
        let inSet = members.count
        return .object([
            "id": .string(id),
            "name": isMesh ? "Fleet mesh" : "DNS answers",
            "type": isMesh ? "auto" : "dns",
            "sources": isMesh
                ? .object(["all": true, "exclude": .strings([DemoWorld.node("home-nas").id, DemoWorld.node("studio-mac").id])])
                : .object(["nodes": .strings(["dns-fra-1", "dns-iad-1", "dns-tyo-1"].map { DemoWorld.node($0).id })]),
            "targets": isMesh
                ? .object(["nodes": .strings(["relay-fra-1", "relay-fra-2", "relay-hkg-1", "core-lon-1", "edge-sjc-1", "relay-syd-2"].map { DemoWorld.node($0).id })])
                : .object([:]),
            "addresses": isMesh ? nil : .strings(["udp://resolver"]),
            "interval_sec": 60,
            "timeout_sec": 10,
            "dns_name": isMesh ? nil : "www.example.org",
            "alert": isMesh ? "down_and_degraded" : "down",
            "alert_after": 2,
            "enabled": true,
            "excluded_pairs": isMesh ? .array([.object(["source": .string(DemoWorld.node("edge-syd-1").id), "target": .string(DemoWorld.node("core-sjc-1").id)])]) : nil,
            "version": .number(Double(version)),
            "created_at": .time("-60d"),
            "updated_at": .time("-3d"),
            "updated_by": .string(DemoWorld.actorID),
            "summary": .object([
                "monitors": .number(Double(inSet + (isMesh ? 1 : 0))),
                "paths": .number(Double(inSet)),
                "paused_targets": isMesh ? 1 : 0,
                "paused_runs": isMesh ? 4_210 : 0,
            ]),
            "monitors": detail ? .array(monitors) : nil,
        ])
    }

    // MARK: Writes

    static func updateAnswer(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        guard let body = request.bodyObject(), let id = body["id"] as? String else {
            return .error(status: 400, code: "bad_request", message: "id is required")
        }
        guard let check = await visibleChecks(state: state).first(where: { $0.id == id }) else {
            return .error(status: 404, code: "not_found", message: "monitor not found")
        }
        if !check.definition.isEmpty {
            return .error(status: 409, code: "conflict", message: "monitor \(id) is expanded from check definition \(check.definition); change that definition instead")
        }
        if !check.managedBy.isEmpty {
            return .error(status: 409, code: "conflict", message: "monitor \(id) is generated by the \(check.managedBy) probe configuration; change that configuration instead")
        }
        let current = await overrides(state: state)[id] ?? (check.enabled, check.version)
        let sent = (body["version"] as? NSNumber)?.intValue ?? 0
        guard sent == current.1 else {
            return .error(status: 409, code: "version_conflict", message: "monitor \(id) changed since it was read (version \(current.1))")
        }
        let enabled = (body["enabled"] as? Bool) ?? current.0
        let next = (enabled, current.1 + 1)
        await state.setValue("\(enabled ? 1 : 0):\(next.1)", for: "monitor.update.\(id)")
        return .json(monitorJSON(check, override: next).text)
    }

    static func deleteAnswer(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        guard let id = request.bodyStrings["id"] else {
            return .error(status: 400, code: "bad_request", message: "id is required")
        }
        if let check = checks.first(where: { $0.id == id }), !check.definition.isEmpty || !check.managedBy.isEmpty {
            return .error(status: 409, code: "conflict", message: "monitor \(id) is expanded from check definition \(check.definition); change that definition instead")
        }
        await state.insert(id, into: "monitor.deleted")
        return .json(#"{"ok":true}"#)
    }

    static func definitionDeleteAnswer(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        guard let body = request.bodyObject(), let id = body["id"] as? String, let version = definitionVersions[id] else {
            return .error(status: 404, code: "not_found", message: "check definition not found")
        }
        guard (body["version"] as? NSNumber)?.intValue == version else {
            return .error(status: 409, code: "version_conflict", message: "check definition \(id) changed since it was read")
        }
        var expected = checks.filter { $0.definition == id }.map(\.id)
        if id == "def_fleet_mesh" { expected.append("mon_tcp_edge-ams-1_backup-ams-4") }
        let sent = (body["monitor_ids"] as? [String]) ?? []
        guard Set(sent) == Set(expected), sent.count == expected.count else {
            return .error(status: 409, code: "conflict", message: "the monitors named are not the definition's monitors now; read it again")
        }
        await state.insert(id, into: "definition.deleted")
        return .json(DemoJSON.object([("ok", true), ("deleted", .strings(expected)), ("runs", .number(Double(expected.count * 40_320)))]).text)
    }

    // MARK: Line chains

    private static func line(_ n: Int) -> String {
        String(format: "7a1c0e52-0000-4000-8000-%012d", n)
    }

    static let chainsBody: String = {
        func row(_ source: Int, _ sourceNode: String, _ target: Int, _ targetNode: String, status: String, attempt: DemoJSON? = nil, error: String? = nil) -> DemoJSON {
            .object([
                "source_line_uuid": .string(line(source)),
                "source_node_id": .string(DemoWorld.node(sourceNode).id),
                "status": .string(status),
                "current": .object([
                    "target_line_uuid": .string(line(target)),
                    "target_node_id": .string(DemoWorld.node(targetNode).id),
                    "artifact_digest": .string(String(repeating: "3f9a", count: 15) + "c210"),
                    "status": .string(status),
                ]),
                "attempt": attempt,
                "last_error": error.map(DemoJSON.string),
            ])
        }
        let rows: [DemoJSON] = [
            row(1, "edge-tyo-1", 2, "relay-hkg-1", status: "converged"),
            row(2, "relay-hkg-1", 3, "relay-fra-1", status: "converged"),
            row(4, "edge-sin-1", 5, "relay-fra-2", status: "drifted", error: "observed_route_missing"),
            row(6, "edge-iad-1", 7, "edge-sjc-1", status: "applying", attempt: .object([
                "operation": "route", "candidate_target_line_uuid": .string(line(7)), "approval_id": "apr_d_chain_01",
                "status": "applying",
            ])),
        ]
        return DemoJSON.object([("chains", .array(rows))]).text
    }()
}
