import Foundation

/// Demo routes for the Evidence domain, owned by the Evidence module (section 8.6).
///
/// The invented fleet records connections on five nodes, one of them inside
/// a running capture; three nodes are asked to record and cannot (no Clash
/// API, a failing stream, an agent gone quiet), one waits for its agent and
/// one runs an agent too old to say. Records, hops, markers and raw log
/// lines are generated from the same tables, so a connection opened from a
/// row finds its hop path and its node's log. Every read is narrowed to the
/// twelve allowlisted nodes for the Confined token, as `visibleNodeIDs` does,
/// and starting or stopping a capture needs log:admin, which Triage lacks.
public enum EvidenceFixtures {
    public static var routes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/trace/sessions", body: #"{"sessions":[]}"#, emptyBody: #"{"sessions":[]}"#) { request, state in
                .json(DemoJSON.object([("sessions", .array(await sessionsJSON(request, state: state)))]).text)
            }.requiring(readScope),
            DemoRoute(method: "POST", pathPattern: "/api/trace/sessions") { request, state in
                await startCapture(request, state: state)
            }.requiring(adminScope),
            DemoRoute(method: "POST", pathPattern: "/api/trace/sessions/stop") { request, state in
                await stopCapture(request, state: state)
            }.requiring(adminScope),
            DemoRoute(pathPattern: "/api/trace/policy", body: #"{"policies":[]}"#, emptyBody: #"{"policies":[]}"#) { request, _ in
                .json(DemoJSON.object([("policies", .array(visibleNodes(request).map(policyJSON)))]).text)
            }.requiring(readScope),
            DemoRoute(pathPattern: "/api/trace/stats", body: statsBody(scoped: false), emptyBody: emptyStatsBody) { request, _ in
                .json(statsBody(scoped: isConfined(request)))
            }.requiring(readScope),
            DemoRoute(pathPattern: "/api/trace/connections", body: #"{"records":[],"collected_total":0}"#, emptyBody: #"{"records":[],"collected_total":0}"#) { request, _ in
                connections(request)
            }.requiring(readScope),
            DemoRoute(pathPattern: "/api/trace/hops", body: emptyHops, emptyBody: emptyHops) { request, _ in
                hops(request)
            }.requiring(readScope),
            DemoRoute(pathPattern: "/api/trace/markers", body: #"{"markers":[]}"#, emptyBody: #"{"markers":[]}"#) { request, _ in
                markers(request)
            }.requiring(readScope),
            DemoRoute(pathPattern: "/api/logs/sources", body: #"{"sources":[]}"#, emptyBody: #"{"sources":[]}"#) { request, _ in
                .json(DemoJSON.object([("sources", .array(visibleSources(request).map(sourceJSON)))]).text)
            }.requiring(readScope),
            DemoRoute(pathPattern: "/api/logs/stats", body: #"{"stats":[]}"#, emptyBody: #"{"stats":[]}"#) { request, _ in
                let only = request.query["source_id"] ?? ""
                let shown = visibleSources(request).filter { only.isEmpty || $0.id == only }
                return .json(DemoJSON.object([("stats", .array(shown.map(statJSON)))]).text)
            }.requiring(readScope),
            DemoRoute(pathPattern: "/api/logs/query", body: #"{"lines":[],"truncated":false}"#, emptyBody: #"{"lines":[],"truncated":false}"#) { request, _ in
                logQuery(request)
            }.requiring(readScope),
            DemoRoute(pathPattern: "/api/evidence/settings", body: settingsBody, emptyBody: settingsBody).requiring(readScope),
        ]
    }

    static let readScope = "log:read"
    static let adminScope = "log:admin"

    // MARK: Visibility

    static func isConfined(_ request: DemoRequest) -> Bool {
        request.scenario == .confinedToken && request.identity == .pat
    }

    static func visible(_ nodeID: String, _ request: DemoRequest) -> Bool {
        !isConfined(request) || DemoWorld.confinedNodeIDs.contains(nodeID)
    }

    static func visibleNodes(_ request: DemoRequest) -> [DemoWorldNode] {
        DemoWorld.nodes.filter { visible($0.id, request) }
    }

    // MARK: Trace policies and readiness

    struct Collector {
        var enabled: Bool
        var state: String
        var level = "debug"
        var detail = ""
        var reportedBy = "agent"
        var stale = false
        var pending = false
        var received = "-8s"
        var shed = 0
    }

    /// Nodes that collect, by name; every other node has trace off and an idle collector.
    static let collectors: [String: Collector] = [
        "edge-tyo-1": Collector(enabled: true, state: "ready"),
        "relay-tyo-1": Collector(enabled: true, state: "ready", shed: 37),
        "edge-tyo-2": Collector(enabled: true, state: "ready"),
        "edge-fra-3": Collector(enabled: true, state: "ready"),
        "core-lon-1": Collector(enabled: true, state: "ready", level: "trace"),
        "edge-hkg-2": Collector(enabled: true, state: "no_clash_api", detail: "no loopback Clash API address in the policy or the sing-box config"),
        "edge-sjc-1": Collector(enabled: true, state: "stream_failing", detail: "GET /logs: 401 Unauthorized"),
        "relay-fra-2": Collector(enabled: true, state: "ready", stale: true, received: "-3h"),
        "edge-sin-1": Collector(enabled: true, state: "agent_too_old", reportedBy: "server"),
        "edge-iad-1": Collector(enabled: false, state: "off", pending: true),
    ]

    static func policyJSON(_ node: DemoWorldNode) -> DemoJSON {
        let collector = collectors[node.name] ?? Collector(enabled: false, state: node.isReporting ? "off" : "")
        let raw = collector.enabled
        let collectorJSON: DemoJSON? = collector.state.isEmpty ? nil : .object([
            "state": .string(collector.state),
            "since": .time("-2d"),
            "level": collector.state == "ready" ? .string(collector.level) : nil,
            "clash_api_addr": collector.state == "ready" ? "127.0.0.1:9090" : nil,
            "addr_source": collector.state == "ready" ? "config" : nil,
            "detail": collector.detail.isEmpty ? nil : .string(collector.detail),
            "raw_lines": collector.state == "ready" ? true : nil,
            "lines_per_sec": collector.state == "ready" ? .number(42.5) : nil,
            "budget_lines_per_sec": collector.shed > 0 ? .number(5000) : nil,
            "shed_connections": collector.shed > 0 ? .number(Double(collector.shed)) : nil,
            "counters_since": collector.shed > 0 ? .time("-1h") : nil,
            "reported_by": .string(collector.reportedBy),
            "collected_at": .time(collector.received),
            "received_at": .time(collector.received),
            "stale": collector.stale ? true : nil,
            "pending": collector.pending ? true : nil,
        ])
        return .object([
            "node_id": .string(node.id),
            "enabled": .bool(collector.enabled),
            "level": .string(collector.level),
            "budget_lines_per_sec": 0,
            "raw": .object(["enabled": .bool(raw)]),
            "updated_at": collector.enabled ? .time("-5d") : nil,
            "last_core_generation": collector.enabled ? 7 : nil,
            "raw_effective": .bool(raw),
            "collector": collectorJSON,
        ])
    }

    // MARK: Capture sessions

    struct Session {
        var id: String
        var name: String
        var node: String
        var started: String
        var expires: String
        var ended: String?
        var state: String
        var startedBy: String
        var lines: Int
        var records: Int
    }

    static let sessions: [Session] = [
        Session(id: "trace_s1", name: "debug handshake edge-tyo-1", node: "edge-tyo-1", started: "-6m", expires: "+9m", state: "running", startedBy: DemoWorld.actorID, lines: 1840, records: 212),
        Session(id: "trace_s2", name: "console capture edge-iad-1", node: "edge-iad-1", started: "-2m", expires: "+58m", state: "running", startedBy: "u-demo-oncall", lines: 0, records: 0),
        Session(id: "trace_s3", name: "reset storm relay-fra-2", node: "relay-fra-2", started: "-200m", expires: "-140m", ended: "-185m", state: "stopped", startedBy: DemoWorld.actorID, lines: 9412, records: 1210),
        Session(id: "trace_s4", name: "nightly edge-fra-3", node: "edge-fra-3", started: "-26h", expires: "-25h", state: "expired", startedBy: "u-demo-oncall", lines: 22018, records: 3304),
    ]

    static let createdSet = "evidence.sessions.created"
    static let stoppedSet = "evidence.sessions.stopped"

    static func sessionJSON(_ session: Session, stoppedAt: String?) -> DemoJSON {
        let node = DemoWorld.node(session.node)
        return .object([
            "id": .string(session.id),
            "name": .string(session.name),
            "filter": .object(["node_ids": .strings([node.id])]),
            "level": "debug",
            "started_at": .time(session.started),
            "expires_at": .time(session.expires),
            "ended_at": stoppedAt.map(DemoJSON.string) ?? session.ended.map { .time($0) },
            "state": .string(stoppedAt == nil ? session.state : "stopped"),
            "started_by": .string(session.startedBy),
            "correlation_id": .string("corr-\(session.id)"),
            "lines": .number(Double(session.lines)),
            "records": .number(Double(session.records)),
            "dropped": 0,
        ])
    }

    /// Fixture sessions with any stop applied, then the ones started in this launch.
    static func allSessions(state: DemoState) async -> [(nodes: [String], json: DemoJSON, running: Bool, expires: Date?)] {
        var out: [(nodes: [String], json: DemoJSON, running: Bool, expires: Date?)] = []
        let stopped = await state.members(of: stoppedSet)
        for session in sessions {
            let stoppedAt = stopped.contains(session.id) ? await state.value(for: "evidence.stopped.\(session.id)") : nil
            out.append(([DemoWorld.node(session.node).id], sessionJSON(session, stoppedAt: stoppedAt), session.state == "running" && stoppedAt == nil, nil))
        }
        for id in await state.members(of: createdSet).sorted() {
            guard let text = await state.value(for: "evidence.session.\(id)"),
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
            let nodes = ((object["filter"] as? [String: Any])?["node_ids"] as? [String]) ?? []
            let expires = (object["expires_at"] as? String).flatMap(AstraDateParser.date(from:))
            out.append((nodes, .raw(text), (object["state"] as? String) == "running", expires))
        }
        return out
    }

    static func sessionsJSON(_ request: DemoRequest, state: DemoState) async -> [DemoJSON] {
        await allSessions(state: state).filter { entry in entry.nodes.allSatisfy { visible($0, request) } }.map(\.json)
    }

    static func startCapture(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        guard let body = request.bodyObject() else { return .error(status: 400, code: "bad_request", message: "invalid JSON body") }
        let name = (body["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return .error(status: 400, code: "bad_request", message: "name is required") }
        let level = (body["level"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "debug"
        guard ["info", "debug", "trace"].contains(level) else {
            return .error(status: 400, code: "bad_request", message: "level \"\(level)\" must be info, debug or trace")
        }
        var nodes = ((body["filter"] as? [String: Any])?["node_ids"] as? [String]) ?? []
        if nodes.isEmpty { nodes = visibleNodes(request).map(\.id) }
        for node in nodes where !visible(node, request) {
            return .error(status: 403, code: "forbidden", message: "missing scope log:admin for node \(node)")
        }
        let now = Date()
        let active = await allSessions(state: state).filter { $0.running && ($0.expires.map { $0 > now } ?? true) }
        guard active.count < EvidenceCapture.maxActive else {
            return .error(status: 409, code: "conflict", message: "\(active.count) capture sessions are already running, which is the limit; stop one before starting another")
        }
        for node in nodes where active.filter({ $0.nodes.contains(node) }).count >= EvidenceCapture.maxPerNode {
            return .error(status: 409, code: "conflict", message: "node \(node) already has \(EvidenceCapture.maxPerNode) capture sessions, which is the limit")
        }
        var ttl = (body["ttl_seconds"] as? Int) ?? 0
        if ttl <= 0 { ttl = 900 }
        ttl = min(ttl, 7200)
        let id = "trace_p\(await state.members(of: createdSet).count + 1)"
        // Live captures use the wall clock so their countdown matches the phone's.
        let json = DemoJSON.object([
            "id": .string(id),
            "name": .string(name),
            "filter": .object(["node_ids": .strings(nodes)]),
            "level": .string(level),
            "started_at": .string(AstraDateParser.string(from: now)),
            "expires_at": .string(AstraDateParser.string(from: now.addingTimeInterval(TimeInterval(ttl)))),
            "state": "running",
            "started_by": .string(DemoWorld.actorID),
            "correlation_id": .string("corr-\(id)"),
            "lines": 0, "records": 0, "dropped": 0,
        ]).text
        await state.setValue(json, for: "evidence.session.\(id)")
        await state.insert(id, into: createdSet)
        return .json(json)
    }

    static func stopCapture(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        let id = (request.bodyStrings["id"] ?? "").trimmingCharacters(in: .whitespaces)
        let ended = AstraDateParser.string(from: Date())
        if let session = sessions.first(where: { $0.id == id }) {
            guard visible(DemoWorld.node(session.node).id, request) else { return .error(status: 403, code: "forbidden", message: "missing scope log:admin") }
            if session.state == "running", !(await state.contains(id, in: stoppedSet)) {
                await state.setValue(ended, for: "evidence.stopped.\(id)")
                await state.insert(id, into: stoppedSet)
            }
            let stoppedAt = await state.contains(id, in: stoppedSet) ? await state.value(for: "evidence.stopped.\(id)") : nil
            return .json(sessionJSON(session, stoppedAt: stoppedAt).text)
        }
        guard await state.contains(id, in: createdSet), let text = await state.value(for: "evidence.session.\(id)"),
              var object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return .error(status: 404, code: "not_found", message: "trace session not found")
        }
        if object["state"] as? String == "running" {
            object["state"] = "stopped"
            object["ended_at"] = ended
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(text.utf8)
        let updated = String(decoding: data, as: UTF8.self)
        await state.setValue(updated, for: "evidence.session.\(id)")
        return .json(updated)
    }

    // MARK: Connection records

    struct Record {
        var index: Int
        var node: String
        var ageSeconds: Int
        var network = "tcp"
        var src: String
        var srcPort: Int
        var host: String
        var ip: String
        var port: Int
        var sniffed: String = "tls"
        var domain: String = ""
        var user: String
        var userID: String = ""
        var userKind: String
        var outbound = "direct"
        var outboundType = "direct"
        var duration: Int?
        var up: Int = 0
        var down: Int = 0
        var bytesKnown = true
        var close: String = "eof"
        var closeError = ""
        var open = false
        var stalled = false
        var generation = 7
        var hopPath = ""
        var chainEdge = ""
        var sessions: [String] = []
        var rule = "rule 3: domain_suffix example.org => direct"

        var logID: Int { Int((UInt64(index + 1) &* 2_654_435_761) % 4_294_967_291) }
    }

    static let lineUUID = "6f1e2d3c-4b5a-4968-8778-a1b2c3d4e5f6"

    static let destinations: [(host: String, ip: String, port: Int, sniffed: String)] = [
        ("api.example.org", "203.0.113.200", 443, "tls"),
        ("cdn.example.net", "198.51.100.210", 443, "tls"),
        ("git.example.org", "203.0.113.201", 443, "tls"),
        ("mail.example.org", "203.0.113.202", 993, "tls"),
        ("chat.example.net", "198.51.100.211", 443, "quic"),
        ("203.0.113.203", "203.0.113.203", 22, "ssh"),
    ]

    static let users: [(name: String, id: String, kind: String)] = [
        ("u_3f9a2c1e7b6d4a05", "vu-ana", "managed"),
        ("u_8c21d0f4a9e3b712", "vu-ben", "managed"),
        ("alice-laptop", "", "legacy"),
        ("guest-17", "", "discovered"),
        ("#2", "", "unnamed"),
        ("u_ffff0000aaaa1111", "", "unresolved"),
        ("", "", "unobserved"),
    ]

    static let recordNodes = ["edge-tyo-1", "relay-tyo-1", "edge-fra-3", "edge-tyo-2", "core-lon-1", "edge-tyo-1"]

    static let records: [Record] = {
        var out: [Record] = []
        for index in 0..<60 {
            let node = recordNodes[index % recordNodes.count]
            let dest = destinations[(index * 7 + index / 6) % destinations.count]
            let user = users[(index * 3) % users.count]
            let age = index < 30 ? 25 + index * 95 : 3600 + (index - 30) * 2300
            var record = Record(index: index, node: node, ageSeconds: age, src: "198.51.100.\(150 + (index * 11) % 50)", srcPort: 40_000 + (index * 977) % 20_000,
                                host: dest.host, ip: dest.ip, port: dest.port, sniffed: dest.sniffed, domain: dest.sniffed == "ssh" ? "" : dest.host,
                                user: user.name, userID: user.id, userKind: user.kind,
                                duration: 800 + (index * 7919) % 290_000, up: 2_000 + (index * 15_013) % 900_000, down: 30_000 + (index * 270_001) % 48_000_000)
            if node == "edge-tyo-1" && age < 360 { record.sessions = ["trace_s1"] }
            out.append(record)
        }
        // The chain: a VLESS connection on edge-tyo-1 relayed through relay-tyo-1, identity carried.
        out[0].outbound = "to-relay-tyo-1"; out[0].outboundType = "vless"; out[0].hopPath = "hp_tyo_chain"; out[0].chainEdge = "ce-tyo-edge-relay"
        out[0].host = "api.example.org"; out[0].domain = "api.example.org"; out[0].ip = "203.0.113.200"; out[0].port = 443
        out[0].user = users[0].name; out[0].userID = users[0].id; out[0].userKind = "managed"
        out[1].node = "relay-tyo-1"; out[1].src = DemoWorld.node("edge-tyo-1").ipv4; out[1].hopPath = "hp_tyo_chain"
        out[1].host = "api.example.org"; out[1].domain = "api.example.org"; out[1].ip = "203.0.113.200"; out[1].port = 443
        out[1].user = users[0].name; out[1].userID = users[0].id; out[1].userKind = "managed"; out[1].ageSeconds = out[0].ageSeconds
        // How connections end, one of each.
        out[2].close = "reset"; out[2].closeError = "read tcp 203.0.113.43:443->198.51.100.172:51022: connection reset by peer"
        out[3].close = "dial_failed"; out[3].closeError = "dial tcp 203.0.113.202:993: i/o timeout"; out[3].duration = 5012; out[3].up = 0; out[3].down = 0
        out[4].close = "timeout"; out[4].closeError = "i/o timeout"
        out[5].close = "handshake_failed"; out[5].closeError = "TLS handshake: remote error: tls: bad certificate"; out[5].duration = 340
        out[6].open = true; out[6].duration = nil; out[6].close = ""
        out[7].open = true; out[7].stalled = true; out[7].duration = nil; out[7].close = ""
        out[8].close = "auth_failed"; out[8].closeError = "process connection from 198.51.100.188:50211: unknown user"; out[8].user = ""; out[8].userKind = "unobserved"; out[8].duration = 12
        out[9].network = "udp"; out[9].host = "time.example.net"; out[9].domain = ""; out[9].ip = "192.0.2.123"; out[9].port = 123; out[9].sniffed = "ntp"; out[9].close = "udp_idle"
        out[10].close = ""; out[10].duration = nil; out[10].bytesKnown = false
        out[11].bytesKnown = false
        out[14].close = "core_restart"; out[14].node = "edge-fra-3"; out[14].generation = 6; out[14].closeError = "core generation changed under an open connection"
        out[15].close = "canceled"
        return out
    }()

    static func recordJSON(_ record: Record) -> DemoJSON {
        let node = DemoWorld.node(record.node)
        let ended = record.open ? nil : record.duration.map { "-\(max(1, record.ageSeconds - $0 / 1000))s" } ?? "-\(max(1, record.ageSeconds - 1))s"
        return .object([
            "node_id": .string(node.id),
            "line_uuid": .string(lineUUID),
            "line_hash_id": "lh_7d1c0e2a",
            "inbound_tag": "vless-in",
            "inbound_type": "vless",
            "user_name": record.user.isEmpty ? nil : .string(record.user),
            "user_id": record.userID.isEmpty ? nil : .string(record.userID),
            "user_kind": .string(record.userKind),
            "log_id": .number(Double(record.logID)),
            "network": .string(record.network),
            "src_ip": .string(record.src),
            "src_port": .number(Double(record.srcPort)),
            "dst_host": .string(record.host),
            "dst_ip": .string(record.ip),
            "dst_port": .number(Double(record.port)),
            "sniffed_protocol": .string(record.sniffed),
            "sniffed_domain": record.domain.isEmpty ? nil : .string(record.domain),
            "rule_index": 3,
            "rule_text": .string(record.rule),
            "outbound_tag": .string(record.outbound),
            "outbound_type": .string(record.outboundType),
            "chain_edge_uuid": record.chainEdge.isEmpty ? nil : .string(record.chainEdge),
            "started_at": .time("-\(record.ageSeconds)s"),
            "ended_at": ended.map { .time($0) },
            "duration_ms": record.duration.map { .number(Double($0)) },
            "open": record.open ? true : nil,
            "upload": record.bytesKnown && record.up > 0 ? .number(Double(record.up)) : nil,
            "download": record.bytesKnown && record.down > 0 ? .number(Double(record.down)) : nil,
            "bytes_known": record.bytesKnown ? true : nil,
            "close_reason": record.close.isEmpty ? nil : .string(record.close),
            "close_error": record.closeError.isEmpty ? nil : .string(record.closeError),
            "stalled_at": record.stalled ? .time("-\(max(1, record.ageSeconds - 30))s") : nil,
            "core_generation": .number(Double(record.generation)),
            "session_ids": record.sessions.isEmpty ? nil : .strings(record.sessions),
            "hop_path_id": record.hopPath.isEmpty ? nil : .string(record.hopPath),
        ])
    }

    static func connections(_ request: DemoRequest) -> DemoResponse {
        let q = request.query
        let nodes = (q["node_id"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        func list(_ key: String) -> [String] { (q[key] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty } }
        let users = list("user_id"), lines = list("line_uuid"), sessionIDs = list("session_id")
        let dst = (q["dst"] ?? "").lowercased()
        let window = q["since"].flatMap(AstraDateParser.date(from:)).map { Date().timeIntervalSince($0) + 5 }
        let visibleRecords = records.filter { visible(DemoWorld.node($0.node).id, request) }
        let shown = visibleRecords.filter { record in
            let nodeID = DemoWorld.node(record.node).id
            if !nodes.isEmpty && !nodes.contains(nodeID) { return false }
            if !users.isEmpty && !users.contains(record.userID) { return false }
            if !lines.isEmpty && !lines.contains(lineUUID) { return false }
            if !sessionIDs.isEmpty && Set(sessionIDs).isDisjoint(with: record.sessions) { return false }
            if !dst.isEmpty && !record.host.lowercased().contains(dst) { return false }
            if let window, Double(record.ageSeconds) > window { return false }
            if record.open && q["include_open"] != "true" && q["stalled"] != "true" { return false }
            if q["stalled"] == "true" && !record.stalled { return false }
            return true
        }.sorted { $0.ageSeconds < $1.ageSeconds }
        let limit = min(max(Int(q["limit"] ?? "") ?? 200, 1), 1000)
        let offset = Int((q["cursor"] ?? "").dropFirst()) ?? 0
        let page = Array(shown.dropFirst(offset).prefix(limit))
        let next = offset + page.count < shown.count ? "c\(offset + page.count)" : nil
        let newest = visibleRecords.map(\.ageSeconds).min()
        return .json(DemoJSON.object([
            "records": .array(page.map(recordJSON)),
            "next_cursor": next.map(DemoJSON.string),
            "collected_total": .number(Double(visibleRecords.count)),
            "collected_newest_at": newest.map { .time("-\($0)s") },
        ]).text)
    }

    static let emptyHops = #"{"path":{"id":"","confidence":"none","record_keys":[]},"records":[],"candidates":[],"candidates_complete":true}"#

    static func keyJSON(_ record: Record) -> DemoJSON {
        .object([
            "node_id": .string(DemoWorld.node(record.node).id),
            "core_generation": .number(Double(record.generation)),
            "log_id": .number(Double(record.logID)),
            "started_at": .time("-\(record.ageSeconds)s"),
        ])
    }

    static func hops(_ request: DemoRequest) -> DemoResponse {
        let q = request.query
        guard let nodeID = q["node_id"], !nodeID.isEmpty else { return .error(status: 400, code: "bad_request", message: "node_id is required") }
        guard visible(nodeID, request) else { return .error(status: 403, code: "forbidden", message: "missing scope log:read") }
        guard let generation = Int(q["core_generation"] ?? "") else { return .error(status: 400, code: "bad_request", message: "core_generation must be a uint64") }
        guard let logID = Int(q["log_id"] ?? "") else { return .error(status: 400, code: "bad_request", message: "log_id must be a uint32") }
        guard let anchor = records.first(where: { DemoWorld.node($0.node).id == nodeID && $0.generation == generation && $0.logID == logID }) else {
            return .error(status: 404, code: "not_found", message: "connection record not found")
        }
        let path: (id: String, confidence: String, records: [Record], candidates: [Record])
        if !anchor.hopPath.isEmpty {
            path = (anchor.hopPath, "exact", records.filter { $0.hopPath == anchor.hopPath }.sorted { $0.index < $1.index }, [])
        } else if anchor.index == 4 {
            path = ("hp_ambiguous_4", "ambiguous", [anchor], [records[16], records[22]])
        } else {
            path = ("", "none", [anchor], [])
        }
        let shownRecords = path.records.filter { visible(DemoWorld.node($0.node).id, request) }
        let shownCandidates = path.candidates.filter { visible(DemoWorld.node($0.node).id, request) }
        return .json(DemoJSON.object([
            "path": .object([
                "id": .string(path.id),
                "confidence": .string(path.confidence),
                "record_keys": .array(path.records.map(keyJSON)),
                "candidates": path.candidates.isEmpty ? nil : .array(path.candidates.map(keyJSON)),
            ]),
            "records": .array(shownRecords.map(recordJSON)),
            "candidates": .array(shownCandidates.map(recordJSON)),
            "candidates_complete": true,
        ]).text)
    }

    // MARK: Markers

    static func markers(_ request: DemoRequest) -> DemoResponse {
        let nodes = (request.query["node_id"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        func wanted(_ name: String) -> Bool {
            let id = DemoWorld.node(name).id
            return visible(id, request) && (nodes.isEmpty || nodes.contains(id))
        }
        var out: [(age: Int, json: DemoJSON)] = []
        if wanted("edge-fra-3") {
            out.append((records[14].ageSeconds + 2, .object([
                "kind": "core_restart", "at": .time("-\(records[14].ageSeconds - 2)s"), "node_id": .string(DemoWorld.node("edge-fra-3").id),
                "title": "sing-box restarted", "detail": "closed 4 live connection(s); core generation 6", "count": 4,
            ])))
        }
        if wanted("edge-tyo-1") {
            out.append((5400, .object([
                "kind": "config_apply", "at": .time("-90m"), "node_id": .string(DemoWorld.node("edge-tyo-1").id),
                "title": "configuration applied", "detail": "proxy.apply (allow)", "correlation_id": "corr-apply-tyo-1",
            ])))
        }
        for session in sessions where visible(DemoWorld.node(session.node).id, request) {
            out.append((0, .object([
                "kind": "session", "at": .time(session.started), "title": "trace session started",
                "detail": .string("\(session.name) at debug"), "correlation_id": .string("corr-\(session.id)"),
            ])))
        }
        return .json(DemoJSON.object([("markers", .array(out.map(\.json)))]).text)
    }

    // MARK: Raw log sources

    struct Source {
        var id: String
        var name: String
        var node: String
        var path: String
        var enabled = true
        var managed = false
        var lines: Int
        var lastIngest: String?
        var kind: String
    }

    static func singBoxID(_ name: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "singbox|\(DemoWorld.node(name).id)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return "singbox-" + String(format: "%016llx", hash)
    }

    static let sources: [Source] = {
        var out: [Source] = []
        for name in ["edge-tyo-1", "relay-tyo-1", "edge-tyo-2", "edge-fra-3", "core-lon-1", "relay-fra-2"] {
            let node = DemoWorld.node(name)
            out.append(Source(id: singBoxID(name), name: "sing-box - \(name)", node: name, path: "singbox://\(node.id)", managed: true,
                              lines: name == "relay-fra-2" ? 96_400 : 420, lastIngest: name == "relay-fra-2" ? "-3h" : "-4s", kind: "singbox"))
        }
        out.append(Source(id: "ls_nginx_tyo1", name: "nginx access", node: "edge-tyo-1", path: "/var/log/nginx/access.log", lines: 120, lastIngest: "-11s", kind: "nginx"))
        out.append(Source(id: "ls_syslog_nas", name: "syslog", node: "home-nas", path: "/var/log/syslog", lines: 120, lastIngest: "-40s", kind: "syslog"))
        out.append(Source(id: "ls_unbound_tyo", name: "unbound", node: "dns-tyo-1", path: "/var/log/unbound/unbound.log", lines: 120, lastIngest: "-3d", kind: "unbound"))
        out.append(Source(id: "ls_ci_build", name: "CI runner", node: "build-fra-4", path: "/var/log/ci-runner.log", enabled: false, lines: 0, lastIngest: nil, kind: "ci"))
        return out
    }()

    static func visibleSources(_ request: DemoRequest) -> [Source] {
        sources.filter { visible(DemoWorld.node($0.node).id, request) }
    }

    static func sourceJSON(_ source: Source) -> DemoJSON {
        .object([
            "id": .string(source.id),
            "name": .string(source.name),
            "node_id": .string(DemoWorld.node(source.node).id),
            "path": .string(source.path),
            "enabled": .bool(source.enabled),
            "max_line_bytes": .number(source.managed ? 8192 : 16384),
            "max_batch_lines": 500,
            "created_at": .time("-30d"),
            "updated_at": .time("-5d"),
            "managed": source.managed ? true : nil,
        ])
    }

    static func statJSON(_ source: Source) -> DemoJSON {
        .object([
            "source_id": .string(source.id),
            "node_id": .string(DemoWorld.node(source.node).id),
            "name": .string(source.name),
            "path": .string(source.path),
            "enabled": .bool(source.enabled),
            "lines": .number(Double(source.lines)),
            "bytes": .number(Double(source.lines * (source.id == singBoxID("relay-fra-2") ? 340 : 160))),
            "first_at": source.lastIngest == nil ? nil : .time("-29d"),
            "last_at": source.lastIngest.map { .time($0) },
            "last_ingest_at": source.lastIngest.map { .time($0) },
            "rot_id": source.lastIngest == nil ? nil : "rot-1",
        ])
    }

    /// Lines held for a source, oldest first: (seq, offset, seconds ago, text).
    /// Eight lines share each chunk's seq and the offset is 0, as the server sends them.
    static func logLines(_ source: Source) -> [(seq: Int, offset: Int, age: Int, text: String)] {
        let count = min(source.lines, 420)
        let baseAge = source.lastIngest == "-3d" ? 259_200 : source.lastIngest == "-3h" ? 10_800 : 4
        return (0..<count).map { index in
            let fromNewest = count - 1 - index
            let age = baseAge + fromNewest * 9
            return (index / 8 + 1, 0, age, logText(source.kind, index: index))
        }
    }

    static func logText(_ kind: String, index: Int) -> String {
        let id = (UInt64(index + 7) &* 2_654_435_761) % 4_294_967_291
        let client = "198.51.100.\(150 + (index * 13) % 50):\(40_000 + (index * 977) % 20_000)"
        let dest = destinations[index % destinations.count]
        switch kind {
        case "singbox":
            switch index % 6 {
            case 0: return "INFO [\(id) 0ms] inbound/vless[vless-in]: inbound connection from \(client)"
            case 1: return "INFO [\(id) 1ms] inbound/vless[vless-in]: [\(users[index % 2].name)] inbound connection to \(dest.host):\(dest.port)"
            case 2: return "INFO [\(id) 3ms] outbound/direct[direct]: outbound connection to \(dest.host):\(dest.port)"
            case 3: return "DEBUG [\(id) \(index % 9 + 1).\(index % 10)s] connection download finished"
            case 4: return index % 4 == 0
                ? "ERROR [\(id) 5.0s] connection: open connection to \(dest.host):\(dest.port) using outbound/direct[direct]: dial tcp \(dest.ip):\(dest.port): i/o timeout"
                : "DEBUG [\(id) 2.\(index % 10)s] connection upload finished"
            default: return "WARN [\(id) 12.4s] inbound/vless[vless-in]: process connection from \(client): read: connection reset by peer"
            }
        case "nginx":
            let paths = ["/healthz", "/api/v1/status", "/static/app.js", "/login", "/api/v1/items?page=2"]
            let codes = [200, 200, 304, 200, 404, 502]
            return "\(client.split(separator: ":")[0]) - - \"GET \(paths[index % paths.count]) HTTP/1.1\" \(codes[index % codes.count]) \(512 + index * 37 % 9000) \"-\" \"Mozilla/5.0\""
        case "syslog":
            let lines = ["systemd[1]: Started Daily apt download activities.", "smartd[812]: Device: /dev/sda, SMART Usage Attribute: 194 Temperature_Celsius changed from 34 to 35",
                         "kernel: [8123.441] EXT4-fs (md0): mounted filesystem with ordered data mode", "CRON[\(4000 + index)]: (root) CMD (/usr/local/bin/snapshot --quiet)",
                         "sshd[\(2000 + index)]: Accepted publickey for ops from 192.0.2.10 port 52114 ssh2"]
            return lines[index % lines.count]
        default:
            return "info: resolving example.org. A IN"
        }
    }

    static func logQuery(_ request: DemoRequest) -> DemoResponse {
        let q = request.query
        let id = (q["source_id"] ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return .error(status: 400, code: "bad_request", message: "source_id is required") }
        guard let source = sources.first(where: { $0.id == id }) else { return .error(status: 404, code: "not_found", message: "log source not found") }
        guard visible(DemoWorld.node(source.node).id, request) else { return .error(status: 403, code: "forbidden", message: "forbidden") }
        let limit = min(max(Int(q["limit"] ?? "") ?? 200, 1), 1000)
        let before = Int(q["before_seq"] ?? "") ?? 0
        let needle = (q["q"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let all = logLines(source)
        let chunks = Dictionary(grouping: all, by: \.seq)
        var out: [DemoJSON] = []
        var next: Int?
        let seqs = chunks.keys.sorted(by: >).filter { before == 0 || $0 < before }
        for (position, seq) in seqs.enumerated() {
            for line in chunks[seq]!.reversed() where needle.isEmpty || line.text.lowercased().contains(needle) {
                out.append(.object([
                    "source_id": .string(source.id), "node_id": .string(DemoWorld.node(source.node).id), "path": .string(source.path),
                    "seq": .number(Double(line.seq)), "offset": .number(Double(line.offset)), "at": .time("-\(line.age)s"),
                    "line": .string(line.text), "truncated": line.text.count > 140 ? true : nil,
                ]))
            }
            if out.count >= limit {
                if position + 1 < seqs.count { next = seq }
                break
            }
        }
        return .json(DemoJSON.object([
            "lines": .array(out),
            "truncated": false,
            "next_before_seq": next.map { .number(Double($0)) },
        ]).text)
    }

    // MARK: Budgets and the store

    static let settingsBody = DemoJSON.object([
        "settings": .object([
            "trace_db_max_bytes": .number(2_147_483_648),
            "record_ttl_seconds": .number(1_209_600),
            "line_ttl_seconds": .number(604_800),
            "rollup_5m_ttl_seconds": .number(7_776_000),
            "raw_source_max_bytes": .number(67_108_864),
            "version": 3,
            "updated_at": .time("-12d"),
            "updated_by": .string(DemoWorld.actorID),
        ]),
        "stored": true,
        "bounds": .object([
            "trace_db_max_bytes": [.number(268_435_456), .number(17_179_869_184)],
            "record_ttl_seconds": [.number(86_400), .number(7_776_000)],
            "line_ttl_seconds": [.number(3_600), .number(2_592_000)],
            "rollup_5m_ttl_seconds": [.number(86_400), .number(34_560_000)],
            "raw_source_max_bytes": [.number(1_048_576), .number(1_073_741_824)],
        ]),
    ]).text

    static let emptyStatsBody = #"{"path":"/var/lib/lattice/trace.db","schema_version":4,"records":0,"open_records":0,"lines":0,"rollups":0,"size_bytes":4096,"max_bytes":2147483648,"cipher_enabled":true}"#

    static func statsBody(scoped: Bool) -> String {
        if scoped { return #"{"scoped":true,"schema_version":4,"cipher_enabled":true}"# }
        return DemoJSON.object([
            "path": "/var/lib/lattice/trace.db",
            "schema_version": 4,
            "records": .number(Double(records.count)),
            "open_records": 2,
            "lines": 33_270,
            "rollups": 410,
            "oldest_record_at": .time("-\(records.map(\.ageSeconds).max() ?? 0)s"),
            "newest_record_at": .time("-\(records.map(\.ageSeconds).min() ?? 0)s"),
            "size_bytes": .number(432_013_312),
            "max_bytes": .number(2_147_483_648),
            "cipher_enabled": true,
        ]).text
    }
}
