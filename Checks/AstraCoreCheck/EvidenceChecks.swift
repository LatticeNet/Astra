import Foundation
import AstraCore

public func checkEvidence() async throws {
    try await checkEvidenceDecoding()
    try await checkEvidenceRequests()
    try checkEvidenceReadiness()
    try checkEvidenceCoverage()
    try checkEvidenceCapture()
    try checkEvidenceConnectionRows()
    try checkEvidenceQuery()
    try checkEvidenceLogs()
    try checkEvidenceBudget()
    try await checkEvidenceDemo()
}

private let evidenceBase = "https://lattice.example.com"

private func evidenceClient(_ responses: [String: (Int, Data)]) -> (LatticeClient, MockTransport) {
    let transport = MockTransport(responses: responses)
    let client = LatticeClient(baseURL: URL(string: evidenceBase)!, credential: LatticeCredential(bearerToken: "lat_check.notasecret"), transport: transport)
    return (client, transport)
}

private func evidenceInstant(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

private func evidenceCanonical(_ data: Data?) throws -> String {
    let object = try bodyObject(data)
    let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: canonical, as: UTF8.self)
}

private let evidenceRecordJSON = #"""
{"node_id":"n-a","line_uuid":"6f1e2d3c-4b5a-4968-8778-a1b2c3d4e5f6","inbound_tag":"vless-in","inbound_type":"vless","user_name":"u_3f9a2c1e7b6d4a05","user_id":"vu-ana","user_kind":"managed",
 "log_id":4021558870,"network":"tcp","src_ip":"198.51.100.23","src_port":51034,"dst_host":"api.example.org","dst_ip":"203.0.113.200","dst_port":443,"sniffed_protocol":"tls","sniffed_domain":"api.example.org",
 "rule_index":3,"rule_text":"rule 3","outbound_tag":"direct","outbound_type":"direct","started_at":"2026-10-28T11:58:01.123456789Z","ended_at":"2026-10-28T11:58:09Z","duration_ms":8012,
 "upload":12800,"download":1258291,"bytes_known":true,"close_reason":"eof","core_generation":7,"session_ids":["trace_s1"],"hop_path_id":"hp_1"}
"""#

// MARK: Decoding, one check per response type of the M10 rows

private func checkEvidenceDecoding() async throws {
    let (client, _) = evidenceClient([
        "\(evidenceBase)/api/trace/sessions": (200, json(#"""
        {"sessions":[{"id":"trace_1","name":"phone edge 2026-10-28 12:05Z","filter":{"node_ids":["n-a"]},"level":"debug","started_at":"2026-10-28T12:05:00Z","expires_at":"2026-10-28T12:20:00Z","state":"running","started_by":"u-1","correlation_id":"c-1","lines":10,"records":2,"dropped":0},
                     {"id":"trace_2","name":"old","filter":{},"level":"info","started_at":"2026-10-27T12:00:00Z","expires_at":"2026-10-27T12:15:00Z","ended_at":"2026-10-27T12:10:00Z","state":"stopped","started_by":"u-1","lines":0,"records":0,"dropped":0}]}
        """#)),
        "\(evidenceBase)/api/trace/policy": (200, json(#"""
        {"policies":[{"node_id":"n-a","enabled":true,"level":"debug","budget_lines_per_sec":0,"raw":{"enabled":true},"updated_at":"2026-10-20T00:00:00Z","raw_effective":true,
          "collector":{"state":"ready","since":"2026-10-26T00:00:00Z","level":"debug","clash_api_addr":"127.0.0.1:9090","addr_source":"config","raw_lines":true,"lines_per_sec":42.5,"budget_lines_per_sec":5000,"shed_connections":37,"counters_since":"2026-10-28T11:00:00Z","reported_by":"agent","received_at":"2026-10-28T11:59:52Z"}},
         {"node_id":"n-b","enabled":false,"level":"","budget_lines_per_sec":0}]}
        """#)),
        "\(evidenceBase)/api/trace/stats": (200, json(#"{"path":"/var/lib/lattice/trace.db","schema_version":4,"records":60,"open_records":2,"lines":33270,"rollups":410,"size_bytes":432013312,"max_bytes":2147483648,"cipher_enabled":true}"#)),
        "\(evidenceBase)/api/trace/connections?limit=200&include_open=true": (200, json("{\"records\":[\(evidenceRecordJSON)],\"next_cursor\":\"abc\",\"collected_total\":1204,\"collected_newest_at\":\"2026-10-28T11:58:01Z\"}")),
        "\(evidenceBase)/api/trace/markers": (200, json(#"{"markers":[{"kind":"core_restart","at":"2026-10-28T11:20:00Z","node_id":"n-a","title":"sing-box restarted","detail":"closed 4 live connection(s); core generation 6","count":4},{"kind":"session","at":"2026-10-28T12:05:00Z","title":"trace session started","detail":"x at debug","correlation_id":"c-1"}]}"#)),
        "\(evidenceBase)/api/logs/sources": (200, json(#"{"sources":[{"id":"singbox-0011223344556677","name":"sing-box - edge","node_id":"n-a","path":"singbox://n-a","enabled":true,"max_line_bytes":8192,"max_batch_lines":500,"created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-01T00:00:00Z","managed":true},{"id":"ls_1","name":"","node_id":"n-b","path":"/var/log/syslog","enabled":false,"max_line_bytes":16384,"max_batch_lines":500,"created_at":"0001-01-01T00:00:00Z","updated_at":"0001-01-01T00:00:00Z"}]}"#)),
        "\(evidenceBase)/api/logs/stats": (200, json(#"{"stats":[{"source_id":"ls_1","node_id":"n-b","name":"","path":"/var/log/syslog","enabled":false,"lines":120,"bytes":19200,"first_at":"2026-10-01T00:00:00Z","last_at":"2026-10-28T11:00:00Z","last_ingest_at":"2026-10-28T11:00:00Z","rot_id":"rot-1"}]}"#)),
        "\(evidenceBase)/api/evidence/settings": (200, json(#"{"settings":{"trace_db_max_bytes":2147483648,"record_ttl_seconds":1209600,"line_ttl_seconds":604800,"rollup_5m_ttl_seconds":7776000,"raw_source_max_bytes":67108864,"version":3,"updated_at":"2026-10-16T00:00:00Z","updated_by":"u-1"},"stored":true,"env_ignored":["LATTICE_LOG_MAX_SOURCE_BYTES"],"bounds":{"trace_db_max_bytes":[268435456,17179869184]}}"#)),
    ])

    let sessions = try await client.evidenceListSessions()
    try expectEqual(sessions.map(\.id), ["trace_1", "trace_2"], "sessions decode")
    try expectEqual(sessions[0].filter.nodeIDs, ["n-a"], "session node filter")
    try expect(sessions[0].isActive(now: evidenceInstant("2026-10-28T12:10:00Z")), "running before its deadline")
    try expect(!sessions[0].isActive(now: evidenceInstant("2026-10-28T12:21:00Z")), "a running session past its deadline is not active")
    try expect(sessions[1].filter.nodeIDs.isEmpty && sessions[1].endedAt != nil, "an empty filter and an end time")
    try expect(EvidenceTraceSession(id: "x", filter: EvidenceTraceFilter(), state: "running").covers(nodeID: "n-z", now: Date()), "an empty node list covers the fleet")

    let policies = try await client.evidencePolicies()
    try expectEqual(policies.first?.collector?.shedConnections, 37, "collector counters")
    try expectEqual(policies.first?.rawEnabled, true, "raw switch")
    try expect(policies[1].collector == nil && policies[1].rawEffective == nil, "a policy from a server without readiness")

    let stats = try await client.evidenceTraceStats()
    try expect(!stats.scoped && stats.sizeBytes == 432_013_312 && stats.cipherEnabled, "full trace stats")
    let scoped = try JSONDecoder().decode(EvidenceTraceStats.self, from: json(#"{"scoped":true,"schema_version":4,"cipher_enabled":false}"#))
    try expect(scoped.scoped && scoped.records == nil && scoped.maxBytes == nil, "scoped trace stats carry no counts")

    let page = try await client.evidenceConnections(EvidenceConnectionQuery(), since: nil, until: nil)
    try expectEqual(page.nextCursor, "abc", "keyset cursor")
    try expectEqual(page.collectedTotal, 1204, "collected total")
    let record = try expectUnwrapped(page.records.first, "a record")
    try expectEqual(record.key.string, "n-a:7:4021558870:2026-10-28T11:58:01.123456789Z", "the key keeps the server's start time to the nanosecond")
    try expectEqual(record.destination, "api.example.org:443", "destination text")
    try expectEqual(record.source, "198.51.100.23:51034", "source text")
    try expect(record.bytesKnown && record.download == 1_258_291 && record.durationMS == 8012, "bytes and duration")
    let bare = try JSONDecoder().decode(EvidenceConnRecord.self, from: json(#"{"node_id":"n-b","log_id":1,"started_at":"2026-10-28T11:00:00Z","src_ip":"2001:db8::5","src_port":443}"#))
    try expect(!bare.bytesKnown && bare.durationMS == nil && !bare.open, "omitempty fields default to unknown, never to zero")
    try expectEqual(bare.source, "[2001:db8::5]:443", "an IPv6 source is bracketed")
    let emptyPage = try JSONDecoder().decode(EvidenceConnectionsPage.self, from: json(#"{"records":[],"collected_total":0}"#))
    try expect(emptyPage.nextCursor == nil && emptyPage.collectedNewestAt == nil, "an empty page")

    let hops = try JSONDecoder().decode(EvidenceHopsResponse.self, from: json("""
    {"path":{"id":"hp_1","confidence":"exact","record_keys":[{"node_id":"n-a","core_generation":7,"log_id":4021558870,"started_at":"2026-10-28T11:58:01.123456789Z"}]},"records":[\(evidenceRecordJSON)],"candidates":[],"candidates_complete":true}
    """))
    try expectEqual(hops.path.recordKeys.first, record.key, "a hop key equals the record's key")
    try expect(hops.record(for: record.key) != nil, "the anchor is among the path's records")
    let noPath = try JSONDecoder().decode(EvidenceHopsResponse.self, from: json(#"{"path":{"id":"","confidence":"none","record_keys":[]},"records":[],"candidates":[],"candidates_complete":false}"#))
    try expect(noPath.path.candidates.isEmpty && !noPath.candidatesComplete, "a path with nothing joined")

    let markers = try await client.evidenceMarkers()
    try expectEqual(markers.map(\.kind), [EvidenceMarker.coreRestart, EvidenceMarker.session], "markers decode")
    try expectEqual(markers[0].count, 4, "marker count")

    let sources = try await client.listLogSources()
    try expect(sources[0].managed && sources[0].maxLineBytes == 8192, "managed source")
    try expect(sources[1].createdAt == nil, "Go's zero time reads as no time")
    try expectEqual(sources[1].displayName, "/var/log/syslog", "a nameless source shows its path")
    let sourceStats = try await client.logStats()
    try expectEqual(sourceStats.first?.rotID, "rot-1", "stats decode")

    let settings = try await client.evidenceSettings()
    try expect(settings.stored && settings.settings.recordTTLSeconds == 1_209_600 && settings.envIgnored == ["LATTICE_LOG_MAX_SOURCE_BYTES"], "settings decode")
    try expectEqual(settings.bounds["trace_db_max_bytes"], [268_435_456, 17_179_869_184], "bounds decode")

    // A body that is not the server's shape is the app being behind, never an empty list.
    let (behind, _) = evidenceClient(["\(evidenceBase)/api/logs/sources": (200, json("<!doctype html>"))])
    do {
        _ = try await behind.listLogSources()
        throw CheckFailure.failed("an undecodable source list must throw")
    } catch let error as LatticeAPIError {
        try expectEqual(error, .invalidResponse, "companion behind")
    }
}

// MARK: Request goldens

private func checkEvidenceRequests() async throws {
    let now = evidenceInstant("2026-10-28T12:05:41Z")
    let sessionJSON = json(#"{"id":"trace_9","name":"phone edge-tyo-1 2026-10-28 12:05Z","filter":{"node_ids":["n-edge-tyo-1"]},"level":"debug","started_at":"2026-10-28T12:05:41Z","expires_at":"2026-10-28T12:20:41Z","state":"running","started_by":"u-1","lines":0,"records":0,"dropped":0}"#)
    let stoppedJSON = json(#"{"id":"trace_9","name":"phone edge-tyo-1 2026-10-28 12:05Z","filter":{"node_ids":["n-edge-tyo-1"]},"level":"debug","started_at":"2026-10-28T12:05:41Z","expires_at":"2026-10-28T12:20:41Z","ended_at":"2026-10-28T12:07:00Z","state":"stopped","started_by":"u-1","lines":0,"records":0,"dropped":0}"#)
    let (client, transport) = evidenceClient([
        "\(evidenceBase)/api/trace/sessions": (200, sessionJSON),
        "\(evidenceBase)/api/trace/sessions/stop": (200, stoppedJSON),
    ])
    let start = EvidenceIntents.startCapture(nodeID: "n-edge-tyo-1", nodeName: "edge-tyo-1", preset: .fifteenMinutes, now: now)
    try expect(start.tier == .t2 && start.scopes == ["log:admin"] && start.changes == [.evidence] && !start.idempotent, "capture start is a T2 log:admin write")
    try expectEqual(start.title, "Capture 15 min on edge-tyo-1", "dialog title")
    try expectEqual(start.consequence, "Records connection metadata for users on edge-tyo-1 for 15 minutes, then stops by itself.", "dialog message")
    let started = try await start.perform(client, ConfirmChoices())
    guard case .done(let message, _) = started else { throw CheckFailure.failed("capture start outcome") }
    try expectEqual(message, "Capturing on edge-tyo-1 for 15 minutes", "capture start banner")
    try expectEqual(try evidenceCanonical(await transport.bodies.last ?? nil),
                    #"{"filter":{"node_ids":["n-edge-tyo-1"]},"level":"debug","name":"phone edge-tyo-1 2026-10-28 12:05Z","ttl_seconds":900}"#,
                    "capture start body: name, node filter, the console's level, the preset")
    try expectEqual(await transport.methods.last ?? nil, "POST", "capture start method")

    let stop = EvidenceIntents.stopCapture(EvidenceTraceSession(id: "trace_9", name: "phone edge-tyo-1 2026-10-28 12:05Z"), nodeNames: ["edge-tyo-1"])
    try expect(stop.tier == .t2 && stop.scopes == ["log:admin"] && stop.idempotent, "capture stop is an idempotent T2 log:admin write")
    let stopped = try await stop.perform(client, ConfirmChoices())
    guard case .done = stopped else { throw CheckFailure.failed("capture stop outcome") }
    try expectEqual(try evidenceCanonical(await transport.bodies.last ?? nil), #"{"id":"trace_9"}"#, "capture stop body")
    try expectEqual(await transport.requestURLs.last, "\(evidenceBase)/api/trace/sessions/stop", "capture stop path")

    // Every preset sends its own ttl_seconds.
    for (preset, seconds) in [(EvidenceCapturePreset.fiveMinutes, 300), (.fifteenMinutes, 900), (.sixtyMinutes, 3600)] {
        let request = EvidenceCapture.request(nodeID: "n-x", nodeName: "x", preset: preset, now: now)
        try expect(request.ttlSeconds == seconds && request.level == "debug" && request.filter.nodeIDs == ["n-x"], "preset \(preset.title)")
    }
    let filterJSON = String(decoding: try JSONEncoder().encode(EvidenceTraceFilter()), as: UTF8.self)
    try expectEqual(filterJSON, "{}", "empty filter lists are left out")

    // Hops, logs and connections address the server with its own names.
    let key = try expectUnwrapped(EvidenceRecordKey.parse("n-a:7:4021558870:2026-10-28T11:58:01.123456789Z"), "key parses")
    let (hopsClient, hopsTransport) = evidenceClient([
        "\(evidenceBase)/api/trace/hops?node_id=n-a&core_generation=7&log_id=4021558870&started_at=2026-10-28T11:58:01.123456789Z":
            (200, json(#"{"path":{"id":"","confidence":"none","record_keys":[]},"records":[],"candidates":[],"candidates_complete":true}"#)),
        "\(evidenceBase)/api/logs/query?source_id=s1&limit=200": (200, json(#"{"lines":[{"source_id":"s1","node_id":"node-a","seq":42,"offset":900,"at":"2026-06-17T02:00:00Z","line":"hello"}],"truncated":true,"next_before_seq":41}"#)),
        "\(evidenceBase)/api/logs/query?source_id=s1&limit=200&before_seq=41": (200, json(#"{"lines":[{"source_id":"s1","node_id":"node-a","seq":40,"offset":800,"at":"2026-06-17T01:59:00Z","line":"older"}],"truncated":false}"#)),
    ])
    _ = try await hopsClient.evidenceHops(key)
    let hopsSeen = await hopsTransport.requestURLs.count
    try expectEqual(hopsSeen, 1, "hops request")
    let logs = try await hopsClient.queryLogs(sourceID: "s1", limit: 200)
    try expectEqual(logs.lines.first?.line, "hello", "log line text")
    try expectEqual(logs.nextBeforeSeq, 41, "log pagination cursor")
    try expect(logs.truncated, "log truncated flag")
    let older = try await hopsClient.queryLogs(sourceID: "s1", limit: 200, beforeSeq: logs.nextBeforeSeq)
    try expect(older.nextBeforeSeq == nil && older.lines.first?.line == "older", "paging by before_seq reaches the end")

    let items = EvidenceConnectionQuery(nodeID: "n-a,n-b", userID: "vu-ana", dst: "example.org", lineUUID: "L", sessionID: "trace_1")
        .queryItems(since: evidenceInstant("2026-10-28T11:00:00Z"), until: nil, limit: 200, cursor: "c200")
    try expectEqual(items.map { "\($0.name)=\($0.value ?? "")" },
                    ["limit=200", "since=2026-10-28T11:00:00Z", "node_id=n-a,n-b", "user_id=vu-ana", "line_uuid=L", "session_id=trace_1", "dst=example.org", "include_open=true", "cursor=c200"],
                    "connections query uses the server's filter names")
    try expectEqual(EvidenceLogs.queryItems(sourceID: "s", search: "  ", limit: 50, beforeSeq: 0).map(\.name), ["source_id", "limit"], "blank search and a zero cursor are left out")
}

// MARK: Readiness (ported from evidenceModel.ts)

private func checkEvidenceReadiness() throws {
    func policy(_ enabled: Bool, _ collector: EvidenceCollectorView?, raw: Bool? = true) -> EvidenceTracePolicy {
        EvidenceTracePolicy(nodeID: "n", enabled: enabled, level: "debug", rawEffective: raw, collector: collector)
    }
    try expect(EvidenceReadiness.of(policy: policy(true, nil, raw: nil), capturing: 0) == nil, "an older server reports no readiness")
    try expectEqual(EvidenceReadiness.of(policy: policy(true, nil), capturing: 0), .waiting, "wanted with no report is waiting")
    try expectEqual(EvidenceReadiness.of(policy: policy(false, nil), capturing: 0), .off, "not wanted with no report is off")
    try expectEqual(EvidenceReadiness.of(policy: policy(true, EvidenceCollectorView(state: "ready", level: "trace")), capturing: 0), .ready(level: "trace"), "ready at the agent's level")
    try expectEqual(EvidenceReadiness.of(policy: policy(false, EvidenceCollectorView(state: "off")), capturing: 1),
                    .notReady(state: "off", known: true, detail: nil, inferred: false), "off while a capture wants it has not applied the change")
    try expectEqual(EvidenceReadiness.of(policy: policy(true, EvidenceCollectorView(state: "agent_too_old", reportedBy: "server")), capturing: 0),
                    .notReady(state: "agent_too_old", known: true, detail: nil, inferred: true), "inferred by the server")
    try expectEqual(EvidenceReadiness.of(policy: policy(true, EvidenceCollectorView(state: "warp_drive")), capturing: 0),
                    .notReady(state: "warp_drive", known: false, detail: nil, inferred: false), "an unknown state is not ready, never ready")
    try expectEqual(EvidenceReadiness.of(policy: policy(true, EvidenceCollectorView(state: "ready", stale: true)), capturing: 0),
                    .stale(last: .ready(level: "debug"), heardAt: nil), "a quiet agent that is wanted is stale")
    try expectEqual(EvidenceReadiness.of(policy: policy(false, EvidenceCollectorView(state: "ready", stale: true)), capturing: 0), .off, "a quiet agent nobody wants is off")
    try expectEqual(EvidenceReadiness.of(policy: policy(true, EvidenceCollectorView(state: "ready", pending: true)), capturing: 0), .pending, "a report older than the change is pending")

    try expectEqual(EvidenceNodeState.of(readiness: .ready(level: "debug"), policy: nil, capturing: 1).word, "recording", "ready inside a capture records")
    try expectEqual(EvidenceNodeState.of(readiness: .ready(level: "debug"), policy: nil, capturing: 0).word, "ready", "ready")
    try expectEqual(EvidenceNodeState.of(readiness: .notReady(state: "no_clash_api", known: true, detail: nil, inferred: false), policy: nil, capturing: 0).reason, "No Clash API.", "reason line")
    try expectEqual(EvidenceNodeState.of(readiness: .notReady(state: "agent_too_old", known: true, detail: nil, inferred: true), policy: nil, capturing: 0), .cannotTell, "too old cannot tell")
    try expectEqual(EvidenceNodeState.of(readiness: .pending, policy: nil, capturing: 0).word, "waiting for the agent", "pending waits")
    try expectEqual(EvidenceNodeState.of(readiness: nil, policy: EvidenceTracePolicy(nodeID: "n", enabled: true), capturing: 0).word, "on", "older server: the switch")
    try expectEqual(EvidenceNodeState.of(readiness: .stale(last: .ready(level: "debug"), heardAt: nil), policy: nil, capturing: 0).word, "not heard from", "stale")
    for state in [EvidenceNodeState.recording(level: ""), .ready(level: "", reported: true), .notReady(reason: "x", detail: nil, inferred: false), .notHeard(last: "", heardAt: nil), .waiting, .cannotTell, .off] {
        try expect(!state.word.isEmpty && !state.symbol.isEmpty, "every node state has a word and a symbol")
    }
    let symbols = [EvidenceNodeState.recording(level: ""), .ready(level: "", reported: true), .notReady(reason: "x", detail: nil, inferred: false), .notHeard(last: "", heardAt: nil), .waiting, .cannotTell, .off].map(\.symbol)
    try expectEqual(Set(symbols).count, symbols.count, "every node state has its own symbol")
}

private func checkEvidenceCoverage() throws {
    let now = evidenceInstant("2026-10-28T12:00:00Z")
    let ready = EvidenceCollectorView(state: "ready")
    let policies = [
        EvidenceTracePolicy(nodeID: "n-quiet", enabled: false, rawEffective: false, collector: EvidenceCollectorView(state: "off")),
        EvidenceTracePolicy(nodeID: "n-broken", enabled: true, rawEffective: true, collector: EvidenceCollectorView(state: "no_clash_api")),
        EvidenceTracePolicy(nodeID: "n-on", enabled: true, rawEffective: true, collector: ready),
        EvidenceTracePolicy(nodeID: "n-cap", enabled: false, rawEffective: false, collector: ready),
    ]
    let sessions = [
        EvidenceTraceSession(id: "s1", filter: EvidenceTraceFilter(nodeIDs: ["n-cap"]), expiresAt: evidenceInstant("2026-10-28T12:10:00Z")),
        EvidenceTraceSession(id: "s2", filter: EvidenceTraceFilter(nodeIDs: ["n-on"]), expiresAt: evidenceInstant("2026-10-28T11:50:00Z")),
    ]
    let sources = [LogSource(id: "src-1", name: "syslog", nodeID: "n-src", path: "/var/log/syslog", enabled: true)]
    let rows = EvidenceCoverage.rows(nodes: [("n-on", "alpha"), ("n-src", "src-node")], policies: policies, sessions: sessions, sources: sources, stats: [], now: now)
    try expectEqual(rows.map(\.nodeID), ["n-broken", "n-cap", "n-on", "n-src", "n-quiet"], "attention, then captures, then collecting, then sources, then quiet")
    try expect(rows[0].needsAttention && rows[1].capturing == 1 && rows[2].capturing == 0, "an expired running session covers nothing")
    try expectEqual(rows[1].state.word, "recording", "a captured ready node records")
    try expect(rows.last!.quiet && !rows[3].quiet, "quiet only with trace off, no source and nothing captured")
    try expect(rows[3].sources.first?.stale == true && rows[3].heldLines == nil, "a source with no stats is stale and its count unread")
    try expectEqual(rows[2].name, "alpha", "names from the node list")
    let summary = EvidenceCoverage.summary(rows)
    try expect(summary.recording == 2 && summary.needsAttention == 1 && summary.total == 5, "coverage summary")
    let unread = EvidenceCoverage.rows(nodes: [("n-a", "a")], policies: nil, sessions: [], sources: [], sourcesKnown: false, stats: [], now: now)
    try expect(unread.count == 1 && !unread[0].quiet, "a row whose lists were not read is never quiet")
}

private func checkEvidenceCapture() throws {
    let now = evidenceInstant("2026-10-28T12:00:00Z")
    try expectEqual(EvidenceCapture.sessionName(nodeName: "edge-tyo-1", at: evidenceInstant("2026-10-28T03:07:59Z")), "phone edge-tyo-1 2026-10-28 03:07Z", "session name says where and when, in UTC")
    let running = (0..<8).map { EvidenceTraceSession(id: "s\($0)", filter: EvidenceTraceFilter(nodeIDs: ["n-a"]), expiresAt: now.addingTimeInterval(600)) }
    try expectEqual(EvidenceCapture.block(canAdmin: false, storeReady: true, sessions: [], nodeID: "n-a", now: now), .needsAdmin, "needs log:admin")
    try expectEqual(EvidenceCapture.block(canAdmin: true, storeReady: false, sessions: [], nodeID: "n-a", now: now), .storeOff, "store off")
    try expectEqual(EvidenceCapture.block(canAdmin: true, storeReady: true, sessions: nil, nodeID: "n-a", now: now), .sessionsUnread, "an unread list is not an empty one")
    try expectEqual(EvidenceCapture.block(canAdmin: true, storeReady: true, sessions: running, nodeID: "n-a", now: now), .limitNode, "eight per node")
    try expect(EvidenceCapture.block(canAdmin: true, storeReady: true, sessions: running, nodeID: "n-b", now: now) == nil, "another node is free")
    let sixteen = (0..<16).map { EvidenceTraceSession(id: "t\($0)", filter: EvidenceTraceFilter(nodeIDs: ["n-\($0)"]), expiresAt: now.addingTimeInterval(600)) }
    try expectEqual(EvidenceCapture.block(canAdmin: true, storeReady: true, sessions: sixteen, nodeID: "n-x", now: now), .limitTotal, "sixteen in all")
    try expectEqual(EvidenceCapturePreset.allCases.map(\.title), ["5 min", "15 min", "60 min"], "the spec's presets")
}

private func checkEvidenceConnectionRows() throws {
    let record = try JSONDecoder().decode(EvidenceConnRecord.self, from: json(evidenceRecordJSON))
    try expectEqual(EvidenceCloseState.of(record).word, "finished", "eof finishes")
    try expectEqual(EvidenceCloseState.reason("dial_failed").severity, .fail, "dial failed is a failure")
    try expectEqual(EvidenceCloseState.reason("reset").severity, .warn, "reset warns")
    let unknown = EvidenceCloseState.reason("quantum_tunnel")
    try expect(!unknown.certain && unknown.raw == "quantum_tunnel" && unknown.severity == .quiet, "an unknown reason is uncertain, never green")
    try expect(!EvidenceCloseState.reason("").certain, "no reason recorded")
    let symbols = (EvidenceCloseState.reasons + ["open"]).map { $0 == "open" ? "arrow.left.arrow.right.circle" : EvidenceCloseState.reason($0).symbol }
    try expectEqual(Set(symbols).count, symbols.count, "every close state has its own symbol")
    try expectEqual(EvidenceBytes.text(record), "\u{2191} 12.5 KB \u{2193} 1.2 MB", "bytes")
    try expectEqual(EvidenceBytes.spoken(record), "12.5 KB up, 1.2 MB down", "spoken bytes")
    var unsampled = record
    unsampled.bytesKnown = false
    try expectEqual(EvidenceBytes.text(unsampled), "bytes not sampled", "an unsampled counter is not zero")
    try expectEqual(EvidenceDuration.text(milliseconds: 340), "340 ms", "milliseconds")
    try expectEqual(EvidenceDuration.text(milliseconds: 252_000), "4 min 12 s", "minutes")
    try expectEqual(EvidenceDuration.text(milliseconds: 7_500_000), "2 h 5 min", "hours")
    try expect(EvidenceDuration.text(milliseconds: nil) == nil, "no terminal line, no duration")
    try expectEqual(EvidenceDuration.retention(seconds: 1_209_600), "14 days", "retention days")
    try expectEqual(EvidenceDuration.retention(seconds: 7200), "2 hours", "retention hours")
    try expectEqual(EvidenceHopConfidence.of("exact").word, "exact", "exact")
    try expectEqual(EvidenceHopConfidence.of("Teleport").id, "unknown", "an unknown confidence is not downgraded to none")
    try expectEqual(EvidenceUserKind.word("unobserved"), "not observed", "user kind words")

    let key = record.key
    try expectEqual(EvidenceRecordKey.parse(key.string), key, "the key round-trips with the colons in its time")
    let respelled = EvidenceRecordKey(nodeID: "n-a", coreGeneration: 7, logID: 1, startedAtText: "2026-10-28T11:58:01+00:00")
    try expect(respelled.names(EvidenceRecordKey(nodeID: "n-a", coreGeneration: 7, logID: 1, startedAtText: "2026-10-28T11:58:01Z")), "the same instant spelled differently names the same record")
    try expect(!respelled.names(EvidenceRecordKey(nodeID: "n-a", coreGeneration: 7, logID: 1, startedAtText: "2026-10-28T11:58:02Z")), "another instant is another record")
    try expect(EvidenceRecordKey.parse("n-a:x:1:2026") == nil && EvidenceRecordKey.parse("n-a:1:2") == nil, "malformed keys")
    let link = LatticeDeepLink.connection(id: key.string)
    try expectEqual(LatticeDeepLink(url: try expectUnwrapped(link.customURL, "link URL")), link, "the app link round-trips the key")
}

private func checkEvidenceQuery() throws {
    let names = ["edge-tyo-1": "n-edge-tyo-1"]
    let query = EvidenceConnectionQuery.parse("node:edge-tyo-1 user:vu-ana dest:example.org line:L session:trace_1 \"api 443\" reset", nodeID: { names[$0] })
    try expectEqual(query, EvidenceConnectionQuery(nodeID: "n-edge-tyo-1", userID: "vu-ana", dst: "example.org", lineUUID: "L", sessionID: "trace_1", text: "api 443 reset"), "tokens and free words")
    try expectEqual(query.formatted(nodeName: { id in names.first { $0.value == id }?.key ?? id }), "node:edge-tyo-1 user:vu-ana dst:example.org line:L session:trace_1 api 443 reset", "written back by name")
    try expectEqual(EvidenceConnectionQuery.parse("node:n-unknown").nodeID, "n-unknown", "an unknown name is kept as typed")
    try expectEqual(EvidenceConnectionQuery.parse("example.org:443").text, "example.org:443", "a host and port stays free text")
    try expect(!EvidenceConnectionQuery.parse("is:closed").includeOpen && EvidenceConnectionQuery.parse("").includeOpen, "open connections on by default, is:closed turns them off")
    try expect(!EvidenceConnectionQuery(text: "x").isFiltered && EvidenceConnectionQuery(dst: "x").isFiltered, "free text is not a server filter")
    let record = try JSONDecoder().decode(EvidenceConnRecord.self, from: json(evidenceRecordJSON))
    try expect(EvidenceConnectionQuery(text: "API 443").matchesText(record, nodeName: "edge"), "every word matches somewhere")
    try expect(!EvidenceConnectionQuery(text: "api 22").matchesText(record, nodeName: "edge"), "a missing word fails")
}

private func checkEvidenceLogs() throws {
    let sources = [
        LogSource(id: "a", name: "alpha", nodeID: "n-1", enabled: true),
        LogSource(id: "b", name: "beta", nodeID: "n-1", enabled: true),
        LogSource(id: "c", name: "gamma", nodeID: "n-2", enabled: false),
    ]
    let stats = try JSONDecoder().decode([LogSourceStats].self, from: json(#"[{"source_id":"b","last_ingest_at":"2026-10-28T12:00:00Z"},{"source_id":"a","last_ingest_at":"2026-10-28T11:00:00Z"}]"#))
    try expectEqual(EvidenceLogs.pickSource(sources, sourceID: nil, nodeID: nil, stats: stats)?.id, "b", "the freshest enabled source")
    try expectEqual(EvidenceLogs.pickSource(sources, sourceID: "c", nodeID: "n-1", stats: stats)?.id, "c", "a named source wins")
    try expectEqual(EvidenceLogs.pickSource(sources, sourceID: nil, nodeID: "n-2", stats: stats)?.id, "c", "the node's source")
    try expect(EvidenceLogs.pickSource(sources, sourceID: nil, nodeID: "n-9", stats: stats) == nil, "a node without a source gets none")

    let newestFirst = LogQueryResponse(lines: [LogLine(sourceID: "s", seq: 3, line: "three"), LogLine(sourceID: "s", seq: 2, line: "two")], nextBeforeSeq: 2)
    let shown = EvidenceLogs.chronological(newestFirst)
    try expectEqual(shown.map(\.line), ["two", "three"], "newest at the bottom")
    let older = LogQueryResponse(lines: [LogLine(sourceID: "s", seq: 2, line: "two"), LogLine(sourceID: "s", seq: 1, line: "one")])
    try expectEqual(EvidenceLogs.prependingOlder(shown, page: older).map(\.line), ["one", "two", "three"], "older lines go on top, once each")
    let matches = EvidenceLogs.matches(EvidenceLogs.prependingOlder(shown, page: older), find: "T")
    try expectEqual(matches.count, 2, "find is case-insensitive")
    try expectEqual(EvidenceLogs.step(matches, from: matches[1], forward: true), matches[0], "find wraps forward")
    try expectEqual(EvidenceLogs.step(matches, from: nil, forward: false), matches[1], "find starts from the bottom going back")
    try expect(EvidenceLogs.matches(shown, find: "  ").isEmpty, "a blank find matches nothing")
}

private func checkEvidenceBudget() throws {
    let settings = try JSONDecoder().decode(EvidenceSettingsView.self, from: json(#"{"settings":{"trace_db_max_bytes":2147483648,"record_ttl_seconds":1209600,"line_ttl_seconds":604800,"rollup_5m_ttl_seconds":7776000,"raw_source_max_bytes":67108864,"version":1},"stored":false,"bounds":{}}"#))
    let full = try JSONDecoder().decode(EvidenceTraceStats.self, from: json(#"{"schema_version":4,"size_bytes":536870912,"max_bytes":2147483648,"cipher_enabled":true}"#))
    let sourceStats = try JSONDecoder().decode([LogSourceStats].self, from: json(#"[{"source_id":"a","bytes":33554432},{"source_id":"b","bytes":1024}]"#))
    let lines = EvidenceBudget.lines(settings: settings, stats: full, sourceStats: sourceStats)
    try expectEqual(lines.map(\.label), ["Connection store", "Largest raw log", "Records kept", "Capture lines kept", "Rollups kept"], "budget lines")
    try expectEqual(lines[0].value, "512.0 MB of 2.0 GB", "store use")
    try expectEqual(lines[0].fraction, 0.25, "store fraction")
    try expectEqual(lines[1].fraction, 0.5, "largest raw source against its cap")
    let scoped = try JSONDecoder().decode(EvidenceTraceStats.self, from: json(#"{"scoped":true,"schema_version":4,"cipher_enabled":true}"#))
    let narrow = EvidenceBudget.lines(settings: settings, stats: scoped, sourceStats: nil)
    try expect(narrow[0].label == "Connection store cap" && narrow[0].fraction == nil, "a scoped caller sees the cap, not the use")
}

// MARK: The demo server

private func checkEvidenceDemo() async throws {
    let state = DemoState()
    let clock = DemoClock(pinned: "2026-10-28T12:00:00Z")!
    func client(_ scenario: DemoScenario = .normal) -> LatticeClient {
        LatticeClient(baseURL: DemoWorld.baseURL, credential: LatticeCredential(bearerToken: DemoWorld.token), transport: DemoTransport(identity: .pat, scenario: scenario, clock: clock, state: state))
    }
    let now = clock.anchor
    let policies = try await client().evidencePolicies()
    try expectEqual(policies.count, DemoWorld.nodes.count, "one policy row per node")
    let sessions = try await client().evidenceListSessions()
    try expectEqual(Set(sessions.map(\.state)), ["running", "stopped", "expired"], "captures in every state")
    let sources = try await client().listLogSources()
    let stats = try await client().logStats()
    let rows = EvidenceCoverage.rows(nodes: DemoWorld.nodes.map { ($0.id, $0.name) }, policies: policies, sessions: sessions, sources: sources, stats: stats, now: now)
    let words = Set(rows.map(\.state.word))
    try expectEqual(words, ["recording", "ready", "not ready", "not heard from", "waiting for the agent", "cannot tell", "off"], "the demo covers every node state")
    try expectEqual(rows.first?.needsAttention, true, "attention rows lead")
    try expect(rows.contains { $0.sources.contains { $0.stale } } && rows.contains { $0.sources.contains { !$0.enabled } }, "a stale and a disabled source")

    let page = try await client().evidenceConnections(EvidenceConnectionQuery(), since: nil, until: nil)
    try expect(page.records.count >= 40 && page.collectedTotal == 60, "records and the collected total")
    let starts = page.records.compactMap(\.startedAt)
    try expectEqual(starts, starts.sorted(by: >), "newest first")
    try expect(Set(page.records.map { EvidenceCloseState.of($0).id }).isSuperset(of: ["eof", "reset", "dial_failed", "timeout", "handshake_failed", "auth_failed", "udp_idle", "core_restart", "unknown", "open"]), "every way a connection ends")
    let closedOnly = try await client().evidenceConnections(EvidenceConnectionQuery(includeOpen: false), since: nil, until: nil)
    try expect(!closedOnly.records.contains(where: \.open), "is:closed leaves open connections out")
    let byNode = try await client().evidenceConnections(EvidenceConnectionQuery(nodeID: "n-edge-fra-3"), since: nil, until: nil)
    try expect(!byNode.records.isEmpty && byNode.records.allSatisfy { $0.nodeID == "n-edge-fra-3" }, "the node filter reaches the demo server")
    let small = try await client().evidenceConnections(EvidenceConnectionQuery(), since: nil, until: nil, limit: 25)
    let next = try await client().evidenceConnections(EvidenceConnectionQuery(), since: nil, until: nil, limit: 25, cursor: small.nextCursor)
    try expect(small.nextCursor != nil && Set(small.records.map(\.id)).isDisjoint(with: next.records.map(\.id)), "keyset pages do not overlap")

    let chained = try expectUnwrapped(page.records.first { !$0.hopPathID.isEmpty && $0.nodeID == "n-edge-tyo-1" }, "a chained record")
    let hops = try await client().evidenceHops(chained.key)
    try expect(hops.path.confidence == "exact" && hops.records.count == 2 && hops.record(for: chained.key) != nil, "the chain's two hops")
    let markers = try await client().evidenceMarkers(nodeIDs: ["n-edge-fra-3"])
    try expect(markers.contains { $0.kind == EvidenceMarker.coreRestart }, "a core restart marker")

    // Log paging: the older page continues the first without overlap.
    let source = try expectUnwrapped(EvidenceLogs.pickSource(sources, sourceID: nil, nodeID: "n-edge-tyo-1", stats: stats), "edge-tyo-1 has a source")
    let first = try await client().queryLogs(sourceID: source.id, limit: 100)
    let cursor = try expectUnwrapped(first.nextBeforeSeq, "a first page has an older one")
    let second = try await client().queryLogs(sourceID: source.id, limit: 100, beforeSeq: cursor)
    try expect(Set(first.lines.map(\.id)).isDisjoint(with: second.lines.map(\.id)) && second.lines.allSatisfy { $0.seq < cursor }, "before_seq pages older lines")
    let searched = try await client().queryLogs(sourceID: source.id, search: "ERROR", limit: 100)
    try expect(!searched.lines.isEmpty && searched.lines.allSatisfy { $0.line.contains("ERROR") }, "the server-side search")

    // Capture start and stop through the intents, as the phone sends them.
    let start = EvidenceIntents.startCapture(nodeID: "n-edge-fra-3", nodeName: "edge-fra-3", preset: .fiveMinutes, now: now)
    _ = try await start.perform(client(), ConfirmChoices())
    let afterStart = try await client().evidenceListSessions()
    let created = try expectUnwrapped(afterStart.first { $0.name == "phone edge-fra-3 2026-10-28 12:00Z" }, "the started capture is listed")
    try expect(created.isActive(now: Date()) && created.filter.nodeIDs == ["n-edge-fra-3"], "running on that node")
    _ = try await EvidenceIntents.stopCapture(created, nodeNames: ["edge-fra-3"]).perform(client(), ConfirmChoices())
    try expectEqual(try await client().evidenceListSessions().first { $0.id == created.id }?.state, "stopped", "stopped")

    do {
        _ = try await client(.limitedToken).evidenceStartCapture(EvidenceCapture.request(nodeID: "n-edge-fra-3", nodeName: "edge-fra-3", preset: .fiveMinutes, now: now))
        throw CheckFailure.failed("Triage cannot start a capture")
    } catch let error as LatticeAPIError {
        guard case .forbidden = error else { throw CheckFailure.failed("Triage start answers 403, got \(error)") }
    }
    let confinedPolicies = try await client(.confinedToken).evidencePolicies()
    try expectEqual(Set(confinedPolicies.map(\.nodeID)), Set(DemoWorld.confinedNodeIDs), "the confined token reads only its nodes")
    let confinedStats = try await client(.confinedToken).evidenceTraceStats()
    try expect(confinedStats.scoped, "the confined token gets scoped store stats")
    let confinedPage = try await client(.confinedToken).evidenceConnections(EvidenceConnectionQuery(), since: nil, until: nil)
    try expect(confinedPage.records.allSatisfy { DemoWorld.confinedNodeIDs.contains($0.nodeID) }, "confined records")
    let empty = try await client(.empty).evidenceListSessions()
    try expect(empty.isEmpty, "the empty scenario")
}
