import Foundation
import AstraCore

public func checkMonitoring() async throws {
    try await checkMonitorCreateBody()
    try checkMonitorStats()
    try checkMonitorDecoding()
    try checkSeriesDecoding()
    try checkDefinitionDecoding()
    try checkChainDecoding()
    try await checkMonitoringRequestBodies()
    try await checkSeriesSubjects()
    try await checkMaintenanceBodies()
    try checkMonitorHealth()
    try checkPathVerdict()
    try checkSeriesGaps()
    try checkStrip()
    try checkPathItems()
    try checkMatrix()
    try checkEvidenceAndLinks()
    try checkChainComposition()
    try checkMaintenanceRules()
    try checkMonitoringQueries()
    try checkMonitoringRefusals()
    try await checkMonitoringDemo()
}

private let base = URL(string: "https://lattice.example.com")!
private let now = ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z")!

private func client(_ responses: [String: (Int, Data)]) -> (LatticeClient, MockTransport) {
    let transport = MockTransport(responses: responses)
    return (LatticeClient(baseURL: base, credential: LatticeCredential(bearerToken: "lat_check.notasecret"), transport: transport), transport)
}

private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    try JSONDecoder().decode(T.self, from: json(text))
}

private func checkMonitorCreateBody() async throws {
    let transport = MockTransport(responses: [
        "https://lattice.example.com/api/monitors": (200, #"{"id":"mon1","name":"api","type":"http","target":"https://x","enabled":true}"#.data(using: .utf8)!),
    ])
    let session = LatticeClient(baseURL: URL(string: "https://lattice.example.com")!, credential: LatticeCredential(sessionCookie: "sid", csrfToken: "csrf-token"), transport: transport)

    try await session.createMonitor(name: "api", type: .http, target: "https://x", intervalSec: 60, timeoutSec: 10, assignAll: true, nodeIDs: [])
    let monitorBody = try await bodyObject(transport.bodies.last ?? nil)
    try expectEqual(Set(monitorBody.keys), ["name", "type", "target", "interval_sec", "timeout_sec", "assign_all", "node_ids"], "monitor create sends exactly the server fields")
    try expectEqual(monitorBody["type"] as? String, "http", "monitor type field")
    try expectEqual(await transport.methods.last ?? nil, "POST", "monitor create is POST")
    try expectEqual(await transport.csrfHeaders.last ?? nil, "csrf-token", "monitor create carries CSRF header")
}

private func checkMonitorStats() throws {
    let results = [
        MonitorResult(monitorID: "x", nodeID: "n1", at: now, success: true, latencyMs: 100),
        MonitorResult(monitorID: "x", nodeID: "n1", at: now.addingTimeInterval(60), success: false, latencyMs: 0, error: "timeout"),
        MonitorResult(monitorID: "x", nodeID: "n1", at: now.addingTimeInterval(120), success: true, latencyMs: 200),
    ]
    let stats = MonitorStats(results: results)
    try expectEqual(stats.successCount, 2, "monitor success count")
    try expect(abs((stats.uptimeFraction ?? 0) - 2.0 / 3.0) < 0.001, "monitor uptime fraction")
    try expect(abs((stats.averageLatencyMs ?? 0) - 150) < 0.001, "monitor average latency over successes")
    try expectEqual(stats.lastResult?.latencyMs, 200, "monitor last result by time")
}

// MARK: Decoding

private let monitorViewJSON = #"""
{"id":"mon_def","name":"Fleet mesh to fra-2","type":"tcp","target":"198.51.100.42:443","interval_sec":60,"timeout_sec":10,
 "assign_all":false,"node_ids":["n-a"],"enabled":true,"target_node":"n-fra-2","check_definition_id":"def_mesh",
 "paused_node_ids":["n-b"],"alert":"down_and_degraded","alert_after":2,"version":7,
 "created_at":"2026-09-01T00:00:00Z","updated_at":"2026-10-01T00:00:00Z",
 "latest":[{"node_id":"n-a","at":"2026-10-28T11:59:40Z","success":false,"latency_ms":0,"error":"timeout","fail_streak":3,"since":"2026-10-28T11:57:00Z",
            "received_at":"2026-10-28T11:59:41Z","sent":5,"lost":5,"rtts_ms":[],"reason_at":"0001-01-01T00:00:00Z"}]}
"""#

private func checkMonitorDecoding() throws {
    let monitor = try decode(Monitor.self, monitorViewJSON)
    try expectEqual(monitor.version, 7, "monitor view version")
    try expectEqual(monitor.checkDefinitionID, "def_mesh", "monitor view definition id")
    try expect(monitor.isGenerated, "a definition's monitor is generated")
    try expect(!monitor.isEditable, "a generated monitor is not editable")
    try expectEqual(monitor.pausedNodeIDs, ["n-b"], "monitor view paused sources")
    try expectEqual(monitor.latest.first?.failStreak, 3, "latest fail streak")
    try expectEqual(monitor.latest.first?.lost, 5, "latest lost echoes")
    try expect(monitor.latest.first?.reasonAt == nil, "Go's zero time reads as absent")
    try expectEqual(monitor.type, .tcp, "monitor type")

    let operatorCheck = try decode(Monitor.self, #"{"id":"m2","name":"api","type":"tls","target":"x:443","enabled":false,"version":3,"latest":[]}"#)
    try expect(operatorCheck.isEditable, "an operator check with a version is editable")
    try expectEqual(operatorCheck.type, .tls, "tls monitor type")
    let legacy = try decode(Monitor.self, #"{"id":"m3","type":"http","enabled":true,"version":0}"#)
    try expect(legacy.isEditable && legacy.version == 0, "an operator check never edited since versioning is editable at version 0")

    let bare = try LatticeListDecoder.decode(Monitor.self, from: json("[\(monitorViewJSON)]"), key: "monitors")
    let envelope = try LatticeListDecoder.decode(Monitor.self, from: json(#"{"monitors":[\#(monitorViewJSON)]}"#), key: "monitors")
    try expectEqual(bare, envelope, "monitors list decodes bare and envelope alike")

    let results = try LatticeListDecoder.decode(MonitorResult.self, from: json(#"{"results":[{"monitor_id":"m","node_id":"n","at":"2026-10-28T11:00:00Z","success":false,"reason":"icmp_not_permitted","cert_not_after":"2026-11-06T00:00:00Z","dns_rcode":"NOERROR","dns_answers":["192.0.2.1"]}]}"#), key: "results")
    try expectEqual(results.first?.outcome, .unmeasured, "a result with a reason is unmeasured")
    try expectEqual(results.first?.dnsAnswers, ["192.0.2.1"], "dns answers decode")
    try expect(results.first?.certNotAfter != nil, "cert expiry decodes")
}

private func checkSeriesDecoding() throws {
    let series = try decode(MonitoringPathSeries.self, #"""
    {"check":"def_mesh","window":"1h","step_seconds":60,"from":1761649200,"to":"2026-10-28T12:00:00Z",
     "method_changes":[{"t":"2026-10-28T11:00:00Z","method":"icmp"},{"t":"2026-10-28T11:30:00Z","method":"tcp"}],
     "buckets":[{"t":"2026-10-28T11:00:00Z","n":1,"expected":1,"fail":0,"min_ms":10,"p50_ms":12.5,"p95_ms":15,"max_ms":18,"jitter_ms":0.4,"loss":0,"sent":5,"lost":0},
                {"t":"2026-10-28T11:01:00Z","n":0,"expected":1,"fail":0,"min_ms":null,"p50_ms":null,"p95_ms":null,"max_ms":null,"jitter_ms":null,"loss":null}],
     "baseline":{"from":"2026-10-21T12:00:00Z","to":"2026-10-28T12:00:00Z","hours":168,"ready":true,"p50_ms":11,"loss":0.001,"trigger_p50_ms":52,"trigger_loss":0.02,"rule":{"loss_percent":2}},
     "previous":{"from":1761645600,"to":1761649200,"offset_seconds":3600,"step_seconds":60,"p50_ms":[11.2,null]}}
    """#)
    try expectEqual(series.buckets.count, 2, "series buckets")
    try expect(series.buckets[1].p50Ms == nil && series.buckets[1].n == 0, "an empty step keeps nil figures")
    try expect(series.from != nil, "unix seconds read as a time")
    try expectEqual(series.methodChanges.map(\.method), ["icmp", "tcp"], "method changes")
    try expectEqual(series.baseline?.triggerLoss, 0.02, "baseline trigger")
    try expectEqual(series.previous?.p50Ms.count, 2, "previous p50 per step")
    try expect(series.previous?.p50Ms[1] == nil, "previous keeps its gaps")
    let noBaseline = try decode(MonitoringPathSeries.self, #"{"window":"24h","step_seconds":300,"method_changes":null,"buckets":[],"baseline":null}"#)
    try expect(noBaseline.baseline == nil && noBaseline.methodChanges.isEmpty, "null baseline and method changes")

    let latency = try decode(MonitoringLatencySeries.self, #"""
    {"source":"n-a","target":"n-b","monitor_id":"lat","window":"24h","bucket_sec":3600,"from":"2026-10-27T12:00:00Z","to":"2026-10-28T12:00:00Z",
     "buckets":[{"at":"2026-10-28T10:00:00Z","samples":60,"failures":1,"expected":60,"p50_ms":40,"p95_ms":52,"loss":0.016},{"at":"2026-10-28T11:00:00Z","samples":0,"failures":0,"expected":60}]}
    """#)
    try expectEqual(latency.buckets.first?.stats.p50Ms, 40, "latency bucket figures")
    try expect(latency.asPathSeries.buckets[1].p50Ms == nil && latency.asPathSeries.buckets[1].loss == nil, "an empty latency bucket stays a gap")

    let rollups = try decode(MonitoringLatencyRollups.self, #"{"generated_at":"2026-10-28T12:00:00Z","interval_sec":60,"pairs":[{"source":"a","target":"b","monitor_id":"lat","windows":{"1h":{"samples":60,"failures":0,"expected":60,"p50_ms":38}},"latest":{"monitor_id":"lat","node_id":"a","at":"2026-10-28T11:59:00Z","success":true,"latency_ms":37}}]}"#)
    try expectEqual(rollups.pairs.first?.windows["1h"]?.p50Ms, 38, "rollup window stats")
    try expectEqual(rollups.pairs.first?.latest?.latencyMs, 37, "rollup latest result")
}

private func checkDefinitionDecoding() throws {
    let list = try decode(MonitoringDefinitionList.self, #"""
    {"definitions":[{"id":"def_mesh","name":"Fleet mesh","type":"auto","sources":{"all":true,"exclude":["n-x"]},"targets":{"nodes":["n-a","n-b"]},
      "interval_sec":60,"timeout_sec":10,"enabled":true,"excluded_pairs":[{"source":"n-a","target":"n-b"}],"version":7,
      "created_at":"2026-09-01T00:00:00Z","updated_at":"2026-10-01T00:00:00Z","summary":{"monitors":3,"paths":2,"paused_targets":1,"paused_runs":4210}}],
     "fleet_mesh":{"name":"Fleet mesh","enabled":true,"stored":true,"version":7,"method":"auto","sources":9,"targets":8,"paths":13,"paused_targets":1,"migrated":true,"definitions":["def_mesh"]}}
    """#)
    try expectEqual(list.definitions.first?.summary?.pausedRuns, 4210, "definition summary")
    try expect(list.definitions.first?.monitors == nil, "the list carries no monitors")
    try expectEqual(list.fleetMesh?.definitions, ["def_mesh"], "fleet mesh migration")
    try expect(list.definitions.first?.sources.all == true, "selector all")

    let one = try decode(MonitoringCheckDefinition.self, #"""
    {"id":"def_mesh","name":"Fleet mesh","type":"auto","sources":{"all":true},"targets":{"nodes":["n-a"]},"interval_sec":60,"timeout_sec":10,"enabled":true,"version":7,
     "created_at":"2026-09-01T00:00:00Z","updated_at":"2026-10-01T00:00:00Z","summary":{"monitors":2,"paths":1,"paused_targets":1,"paused_runs":10},
     "monitors":[{"monitor_id":"m1","method":"tcp","target":"192.0.2.1:443","target_node":"n-a","in_set":true,"enabled":true,"sources":["n-s"],"runs":40},
                 {"monitor_id":"m2","method":"tcp","target":"192.0.2.2:443","in_set":false,"enabled":false,"sources":["n-s"],"runs":10}]}
    """#)
    try expectEqual(one.monitors?.filter { !$0.inSet }.map(\.monitorID), ["m2"], "paused targets read from in_set")
    let deleted = try decode(MonitoringDefinitionDeleteResult.self, #"{"ok":true,"deleted":["m1","m2"],"runs":50}"#)
    try expectEqual(deleted.deleted, ["m1", "m2"], "definition delete answer")
}

private func checkChainDecoding() throws {
    let row = #"{"source_line_uuid":"l1","source_node_id":"n-a","status":"converged","current":{"target_line_uuid":"l2","target_node_id":"n-b","artifact_digest":"d","status":"converged"},"attempt":null}"#
    let chain = try decode(MonitoringLineChain.self, row)
    try expectEqual(chain.current?.targetNodeID, "n-b", "chain current target")
    let planned = try decode(MonitoringLineChain.self, #"{"source_line_uuid":"l3","source_node_id":"n-c","status":"planned","current":null,"attempt":{"operation":"route","approval_id":"apr","status":"failed","error_code":"x","error":"y"}}"#)
    try expectEqual(MonitoringChainState(planned), .failed, "a failed attempt reads failed")
    try expectEqual(MonitoringChainState(chain), .converged, "converged chain")
}

// MARK: Request bodies

private func checkMonitoringRequestBodies() async throws {
    let (api, transport) = client([
        "https://lattice.example.com/api/monitors/update": (200, json(#"{"id":"m","name":"api","type":"http","enabled":false,"version":5,"latest":[]}"#)),
        "https://lattice.example.com/api/monitors/delete": (200, json(#"{"ok":true}"#)),
        "https://lattice.example.com/api/monitors/definitions/delete": (200, json(#"{"ok":true,"deleted":["m1","m2"],"runs":3}"#)),
        "https://lattice.example.com/api/monitors/series?source=n-a&target_node=n-b&check=def&window=6h&compare=previous": (200, json(#"{"window":"6h","step_seconds":300,"buckets":[]}"#)),
        "https://lattice.example.com/api/monitors/results?monitor_id=m&node_id=&limit=2000": (200, json("[]")),
    ])
    let updated = try await api.monitoringSetEnabled(id: "m", version: 4, enabled: false)
    try expectEqual(updated.version, 5, "update returns the new view")
    let update = try await bodyObject(transport.bodies[0])
    try expectEqual(Set(update.keys), ["id", "version", "enabled"], "pause sends exactly id, version and enabled")
    try expectEqual(update["version"] as? Int, 4, "pause sends the version that was read")
    try expectEqual(update["enabled"] as? Bool, false, "pause sends enabled false")

    try await api.deleteMonitor(id: "m")
    let delete = try await bodyObject(transport.bodies[1])
    try expectEqual(Set(delete.keys), ["id"], "check delete sends only the id")

    let definition = try decode(MonitoringCheckDefinition.self, #"{"id":"def","version":9,"monitors":[{"monitor_id":"m1","in_set":true},{"monitor_id":"m2","in_set":false}]}"#)
    let request = try expectUnwrapped(MonitoringDefinitionDeleteRequest(definition: definition), "delete request from a read definition")
    _ = try await api.monitoringDeleteDefinition(request)
    let definitionBody = try await bodyObject(transport.bodies[2])
    try expectEqual(Set(definitionBody.keys), ["id", "version", "monitor_ids"], "definition delete keys")
    try expectEqual(definitionBody["monitor_ids"] as? [String], ["m1", "m2"], "definition delete names every monitor, paused ones included")
    try expectEqual(definitionBody["version"] as? Int, 9, "definition delete sends the version read")
    let listed = try decode(MonitoringCheckDefinition.self, #"{"id":"def","version":9}"#)
    try expect(MonitoringDefinitionDeleteRequest(definition: listed) == nil, "a listed definition without its monitors cannot be deleted")

    _ = try await api.monitoringPathSeries(.pair(source: "n-a", targetNode: "n-b", check: "def"), window: .sixHours, compare: true)
    _ = try await api.monitoringResults(monitorID: "m", nodeID: "", limit: 5000)
    let urls = await transport.requestURLs
    try expect(urls.contains { $0.contains("compare=previous") }, "compare asks for the previous period")
    try expect(urls.contains { $0.hasSuffix("limit=2000") }, "results limit is capped at the server maximum")
    try expectEqual(await transport.methods.prefix(3).map { $0 ?? "" }, ["POST", "POST", "POST"], "monitoring writes are POST")

    let legacy = try decode(Monitor.self, #"{"id":"m","type":"http","enabled":true,"version":0}"#)
    let (legacyAPI, legacyTransport) = client(["https://lattice.example.com/api/monitors/update": (200, json(#"{"id":"m","type":"http","enabled":false,"version":1}"#))])
    _ = try await legacyAPI.monitoringSetEnabled(id: legacy.id, version: legacy.version, enabled: false)
    let legacyBody = try await bodyObject(try expectUnwrapped(legacyTransport.bodies.first, "version 0 pause body"))
    try expectEqual(legacyBody["version"] as? Int, 0, "a version 0 check sends version 0 as read")
}

private func checkSeriesSubjects() async throws {
    let unmigrated = try decode(PathView.self, #"{"source":"n-a","target_node":"n-b","monitor_id":"mon_latency_gen","managed":true,"method":"tcp","state":"up"}"#)
    let authored = try decode(PathView.self, #"{"source":"n-a","target_node":"n-b","monitor_id":"mon_own","managed":false,"method":"tcp","state":"up"}"#)
    let defined = try decode(PathView.self, #"{"source":"n-a","target_node":"n-b","monitor_id":"mon_gen","check_definition_id":"def_mesh","managed":true,"method":"tcp","state":"up"}"#)
    let addressed = try decode(PathView.self, #"{"source":"","target":"https://core.example.net","monitor_id":"mon_tls","method":"tls","state":"up"}"#)
    let base = "https://lattice.example.com/api/monitors/series?"
    let empty = (200, json(#"{"window":"1h","step_seconds":60,"buckets":[]}"#))
    let (api, transport) = client([
        base + "source=n-a&target_node=n-b&window=1h": empty,
        base + "source=n-a&target_node=n-b&check=mon_own&window=1h": empty,
        base + "source=n-a&target_node=n-b&check=def_mesh&window=1h": empty,
        base + "monitor=mon_tls&window=1h": empty,
    ])
    for path in [unmigrated, authored, defined, addressed] {
        _ = try await api.monitoringPathSeries(MonitoringSeriesSubject(path: path), window: .oneHour)
    }
    let urls = await transport.requestURLs
    try expectEqual(urls.count, 4, "every subject asks once")
    try expect(!urls[0].contains("check="), "an unmigrated path-set cell names no check: the server keys its series on no id")
    try expect(urls[1].contains("check=mon_own"), "an operator check on a pair is named by its monitor id")
    try expect(urls[2].contains("check=def_mesh"), "a definition's cell is named by its definition")
    try expect(urls[3].contains("monitor=mon_tls") && !urls[3].contains("source="), "a control-plane path asks by monitor alone")
}

private func checkMaintenanceBodies() async throws {
    let (api, transport) = client([
        "https://lattice.example.com/api/maintenance-windows": (200, json(#"{"id":"mw1","name":"x","node_ids":["n-a"],"starts_at":"2026-10-28T12:00:00Z","ends_at":"2026-10-28T13:00:00Z"}"#)),
    ])
    let start = MonitoringMaintenance.input(name: "  Maintenance edge-tyo-3 12:00 ", reason: "kernel", nodeIDs: ["n-a"], startsAt: now, endsAt: now.addingTimeInterval(3_600))
    _ = try await api.upsertMaintenanceWindow(start)
    let body = try await bodyObject(transport.bodies[0])
    try expectEqual(Set(body.keys), ["name", "node_ids", "starts_at", "ends_at", "reason"], "maintenance start keys")
    try expectEqual(body["name"] as? String, "Maintenance edge-tyo-3 12:00", "maintenance name is trimmed")
    try expectEqual(body["starts_at"] as? String, "2026-10-28T12:00:00Z", "maintenance start time")
    try expectEqual(body["ends_at"] as? String, "2026-10-28T13:00:00Z", "maintenance end time")
    let noNote = MonitoringMaintenance.input(name: "x", reason: "  ", nodeIDs: ["n-a"], startsAt: now, endsAt: now.addingTimeInterval(60))
    try expect(noNote.reason == nil, "an empty note is not sent")

    var window = MaintenanceWindow(id: "mw1", name: "Frankfurt kernel", reason: "reboot", nodeIDs: ["n-a"], groupIDs: ["g-1"], startsAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(3_600))
    window.createdBy = "u-ops"
    let (endAPI, endTransport) = client([
        "https://lattice.example.com/api/maintenance-windows": (200, json(#"{"id":"mw1","name":"Frankfurt kernel","node_ids":["n-a"],"starts_at":"2026-10-28T11:50:00Z","ends_at":"2026-10-28T12:00:00Z"}"#)),
    ])
    _ = try await endAPI.upsertMaintenanceWindow(MaintenanceWindowInput(ending: window, at: now))
    let end = try await bodyObject(endTransport.bodies[0])
    try expectEqual(Set(end.keys), ["id", "name", "reason", "node_ids", "group_ids", "starts_at", "ends_at"], "end now resends the full window")
    try expectEqual(end["ends_at"] as? String, "2026-10-28T12:00:00Z", "end now sets only ends_at")
    try expectEqual(end["starts_at"] as? String, "2026-10-28T11:50:00Z", "end now keeps the stored start")
    try expectEqual(end["group_ids"] as? [String], ["g-1"], "end now keeps the groups")
}

// MARK: Logic

private func latest(_ node: String, _ ago: TimeInterval, success: Bool = true, reason: String = "", latency: Double? = 10) -> MonitoringLatest {
    MonitoringLatest(nodeID: node, at: now.addingTimeInterval(-ago), success: success, latencyMs: latency, reason: reason)
}

private func checkMonitorHealth() throws {
    var monitor = Monitor(id: "m", intervalSec: 60)
    try expectEqual(MonitoringHealth.of(monitor, results: nil, now: now), .unread, "unread before results")
    try expectEqual(MonitoringHealth.of(monitor, results: [], now: now), .none, "no results")
    let failing = MonitoringHealth.of(monitor, results: [latest("a", 10, success: false), latest("b", 20)], now: now)
    try expect(failing.isFailing, "one failing node fails the check")
    if case .failing(let failed, let total, _) = failing {
        try expectEqual([failed, total], [1, 2], "failing counts")
    }
    try expectEqual(MonitoringHealth.of(monitor, results: [latest("a", 200)], now: now), .stale(lastAt: now.addingTimeInterval(-200)), "older than three minutes is stale")
    try expectEqual(MonitoringHealth.staleAfter(intervalSec: 300), 900, "stale after three intervals")
    if case .unmeasured(let total, let reason, _) = MonitoringHealth.of(monitor, results: [latest("a", 10, success: false, reason: "icmp_not_permitted")], now: now) {
        try expectEqual(total, 1, "unmeasured total")
        try expectEqual(reason, "icmp_not_permitted", "unmeasured reason")
    } else {
        throw CheckFailure.failed("a result with a reason is unmeasured, never failing")
    }
    let up = MonitoringHealth.of(monitor, results: [latest("a", 10, latency: 10), latest("a", 70, success: false), latest("b", 15, latency: 30)], now: now)
    try expectEqual(up, .up(total: 2, latencyMs: 20, lastAt: now.addingTimeInterval(-10)), "each node's newest result decides, latency is their mean")
    monitor.enabled = false
    try expectEqual(MonitoringHealth.of(monitor, results: [latest("a", 10, success: false)], now: now), .disabled, "a paused check is disabled")
    try expect(MonitoringHealth.failing(failing: 1, total: 1, lastAt: now).rank < MonitoringHealth.up(total: 1, latencyMs: nil, lastAt: now).rank, "failing ranks first")
}

private func verdictPath(_ state: String, _ reason: String = "", source: String = "") throws -> PathView {
    var fields = [#""state":"\#(state)""#, #""monitor_id":"m""#, #""target_node":"t""#]
    if !reason.isEmpty { fields.append(#""reason":"\#(reason)""#) }
    if !source.isEmpty { fields.append(#""source":"\#(source)""#) }
    return try decode(PathView.self, "{" + fields.joined(separator: ",") + "}")
}

/// Goldens from the console's checksModel tests for `withPathVerdict`.
private func checkPathVerdict() throws {
    let at = now
    let failing = MonitoringHealth.failing(failing: 1, total: 2, lastAt: at)
    func verdict(_ health: MonitoringHealth, _ paths: [PathView], _ latest: [MonitoringLatest] = []) -> MonitoringHealth {
        health.withPathVerdict(paths, latest: latest, judgesDegraded: true)
    }
    try expectEqual(verdict(failing, [try verdictPath("unknown", "icmp_filtered"), try verdictPath("up")]), .unmeasured(total: 2, reason: "icmp_filtered", lastAt: at), "a failing check whose path is filtered reads unmeasured, not failing")
    try expectEqual(verdict(failing, [try verdictPath("down"), try verdictPath("unknown", "icmp_filtered")]), failing, "a down path keeps it failing")
    try expectEqual(verdict(failing, [try verdictPath("unknown", "source_paused"), try verdictPath("up")]), failing, "a pause is not the reason")
    try expectEqual(verdict(failing, []), failing, "no paths read: the results decide")
    let upOne = MonitoringHealth.up(total: 1, latencyMs: nil, lastAt: at)
    try expectEqual(verdict(upOne, [try verdictPath("unknown", "icmp_filtered")]), upOne, "an unknown path does not change a passing check")

    let up = MonitoringHealth.up(total: 3, latencyMs: 356, lastAt: at)
    try expectEqual(verdict(up, [try verdictPath("degraded"), try verdictPath("degraded"), try verdictPath("up"), try verdictPath("unknown", "results_stopped")]),
                    .degraded(degraded: 2, total: 3, lastAt: at), "degraded on N of the judged paths")
    try expectEqual(verdict(up, [try verdictPath("degraded")]), .degraded(degraded: 1, total: 1, lastAt: at), "one degraded path")
    try expectEqual(verdict(up, [try verdictPath("up"), try verdictPath("up")]), up, "no degraded path, still up")
    try expectEqual(verdict(up, [try verdictPath("degraded"), try verdictPath("down")]), up, "a down path left behind keeps the results' word")
    try expectEqual(up.withPathVerdict([try verdictPath("degraded")], latest: [], judgesDegraded: false), up, "a server that does not judge degraded leaves it up")
    try expectEqual(verdict(failing, [try verdictPath("degraded"), try verdictPath("up")]), failing, "no failing source named: a failing check keeps the results' word")

    let single = MonitoringHealth.failing(failing: 1, total: 1, lastAt: at)
    let twoReasons = [try verdictPath("unknown", "icmp_filtered", source: "sh"), try verdictPath("unknown", "agent_too_old", source: "volc")]
    try expectEqual(verdict(single, twoReasons, [MonitoringLatest(nodeID: "sh", at: at, success: false)]), .unmeasured(total: 1, reason: "icmp_filtered", lastAt: at), "the failing source's own reason, not the first one")
    try expectEqual(verdict(single, twoReasons), .unmeasured(total: 1, reason: "", lastAt: at), "two reasons and no failing source: unmeasured without one reason")

    let lossFailing = MonitoringHealth.failing(failing: 1, total: 3, lastAt: at)
    let lossy = [try verdictPath("degraded", "degraded_loss", source: "sh"), try verdictPath("degraded", "degraded_loss", source: "hk"), try verdictPath("unknown", "results_stopped", source: "volc")]
    let lossLatest = [MonitoringLatest(nodeID: "sh", at: at, success: false), MonitoringLatest(nodeID: "hk", at: at, success: true, latencyMs: 343), MonitoringLatest(nodeID: "volc", at: at, success: true, latencyMs: 90)]
    try expectEqual(verdict(lossFailing, lossy, lossLatest), .degraded(degraded: 2, total: 2, lastAt: at), "a loss-degraded source whose newest run failed reads degraded")
    let mixed = [try verdictPath("degraded", "degraded_loss", source: "sh"), try verdictPath("unknown", "agent_too_old", source: "mk")]
    let mixedHealth = verdict(lossFailing, mixed, [MonitoringLatest(nodeID: "sh", at: at, success: false), MonitoringLatest(nodeID: "mk", at: at, success: false)])
    try expectEqual(mixedHealth.rank, MonitoringHealth.degraded(degraded: 1, total: 1, lastAt: at).rank, "one failing source degraded: the check is degraded, not unmeasured")

    var monitor = Monitor(id: "m", intervalSec: 60)
    monitor.latest = [MonitoringLatest(nodeID: "sh", at: at.addingTimeInterval(-10), success: false)]
    let response = try decode(PathsResponse.self, #"{"degraded_at":null,"paths":[{"source":"sh","target_node":"t","monitor_id":"m","state":"unknown","reason":"icmp_filtered"},{"source":"sh","target_node":"u","monitor_id":"other","state":"down"}]}"#)
    try expectEqual(MonitoringHealth.judged(monitor, paths: response, now: now), .unmeasured(total: 1, reason: "icmp_filtered", lastAt: at.addingTimeInterval(-10)), "judged reads only the check's own paths")
    try expect(MonitoringHealth.judged(monitor, paths: nil, now: now).isFailing, "before the matrix is read, the results decide")
}

private func bucket(_ minute: Int, n: Int = 1, fail: Int = 0, p50: Double? = 10, loss: Double? = 0) -> MonitoringPathBucket {
    MonitoringPathBucket(t: now.addingTimeInterval(Double(minute) * 60), n: n, expected: 1, fail: fail, p50Ms: n > 0 ? p50 : nil, p95Ms: n > 0 ? p50.map { $0 * 1.3 } : nil, loss: n > 0 ? loss : nil)
}

private func checkSeriesGaps() throws {
    // Steps 0-2 data, 3-4 empty, 5-6 data, then a 4-step hole in time, then 11.
    let buckets = [bucket(0), bucket(1), bucket(2), bucket(3, n: 0), bucket(4, n: 0), bucket(5), bucket(6), bucket(11)]
    let series = MonitoringPathSeries(window: "1h", stepSeconds: 60, buckets: buckets)
    let runs = MonitoringSeriesSegments.p50(series)
    try expectEqual(runs.map(\.count), [3, 2, 1], "empty steps and time holes split the line, never bridged")
    try expect(runs.allSatisfy { run in zip(run, run.dropFirst()).allSatisfy { $1.t.timeIntervalSince($0.t) <= 150 } }, "no segment spans more than 2.5 steps")
    let raw = MonitoringSeriesSegments.segments([(now, 1), (now.addingTimeInterval(150), 2), (now.addingTimeInterval(301), 3)], stepSeconds: 60)
    try expectEqual(raw.map(\.count), [2, 1], "exactly 2.5 steps joins, more splits")
    try expectEqual(MonitoringSeriesSegments.loss(series).count, 6, "loss has a mark only where runs were heard")
    try expect(!MonitoringSeriesSegments.isEmpty(series), "a series with data is not empty")
    let silent = MonitoringPathSeries(window: "1h", stepSeconds: 60, buckets: [bucket(0, n: 0), bucket(1, n: 0)])
    try expect(MonitoringSeriesSegments.isEmpty(silent), "a series with no runs is replaced by a sentence")
    try expect(MonitoringSeriesSegments.p50(silent).isEmpty, "no line for a silent series")
    try expectEqual(MonitoringSeriesSegments.lastData(series), now.addingTimeInterval(660), "newest step with data")
}

private func checkStrip() throws {
    var buckets: [MonitoringPathBucket] = []
    for minute in 0..<48 {
        switch minute {
        case 0..<4: buckets.append(bucket(minute, n: 1, fail: 1, p50: nil, loss: 1))
        case 4..<8: buckets.append(MonitoringPathBucket(t: now.addingTimeInterval(Double(minute) * 60), n: 0, expected: 1))
        case 8..<12: buckets.append(MonitoringPathBucket(t: now.addingTimeInterval(Double(minute) * 60), n: 0, expected: 0))
        case 12..<16: buckets.append(bucket(minute, n: 10, fail: 1, loss: 0.1))
        default: buckets.append(bucket(minute))
        }
    }
    let cells = MonitoringStrip.cells(MonitoringPathSeries(window: "1h", stepSeconds: 60, buckets: buckets))
    try expectEqual(cells.count, 24, "24 cells over the window")
    try expectEqual(Array(cells.prefix(8)), [.down, .down, .unknown, .unknown, .paused, .paused, .degraded, .degraded], "down, no data, nothing expected, loss over trigger")
    try expect(cells.dropFirst(8).allSatisfy { $0 == .up }, "the rest is up")
    try expectEqual(MonitoringStrip.summary(cells), "Last 24 intervals: 2 down, 2 degraded, 2 no data, 2 paused, 16 up", "strip summary in words")
    let short = MonitoringStrip.cells(MonitoringPathSeries(window: "1h", stepSeconds: 60, buckets: Array(buckets.suffix(5))))
    try expectEqual(short.count, 5, "fewer steps than cells gives one cell per step")
}

private func pathsResponse() throws -> PathsResponse {
    try decode(PathsResponse.self, #"""
    {"window":"1h","observed_at":"2026-10-28T12:00:00Z","degraded_at":"2026-10-28T11:59:30Z",
     "sources":[{"node_id":"n-tyo","name":"tyo-1","region":"asia"},{"node_id":"n-sin","name":"sin-1","region":"asia"}],
     "targets":[{"node_id":"n-fra","name":"fra-2","region":"europe","country":"DE"},{"node_id":"n-hkg","name":"hkg-1","region":"asia","country":"HK"},{"node_id":"n-tyo","name":"tyo-1","region":"asia","country":"JP"}],
     "paths":[
      {"source":"n-tyo","target_node":"n-fra","target":"198.51.100.1:443","monitor_id":"m1","method":"tcp","state":"degraded","reason":"degraded_loss","p50_ms":238,"loss":0.062,"samples":60,"expected":60,
       "degraded":{"since":"2026-10-28T11:12:00Z","loss":{"value":0.062,"baseline":0.004,"trigger":0.02,"sent":900,"lost":56}}},
      {"source":"n-tyo","target_node":"n-hkg","target":"198.51.100.2:443","monitor_id":"m2","method":"tcp","state":"up","p50_ms":49,"loss":0,"samples":60,"expected":60},
      {"source":"n-sin","target_node":"n-hkg","target":"198.51.100.2:443","monitor_id":"m3","method":"icmp","state":"unknown","reason":"packet_budget","samples":0,"expected":0},
      {"source":"n-sin","target_node":"n-fra","target":"198.51.100.1:443","monitor_id":"m4","method":"tcp","state":"down","loss":1,"samples":60,"expected":60},
      {"source":"n-sin","target_node":"n-fra","target":"198.51.100.1:443","monitor_id":"m5","method":"icmp","state":"up","p50_ms":160,"samples":60,"expected":60},
      {"source":"n-sin","target_node":"n-tyo","target":"198.51.100.3:443","monitor_id":"m6","method":"tcp","state":"unknown","reason":"path_paused"},
      {"source":"n-fra","target_node":"n-tyo","target":"198.51.100.3:443","monitor_id":"m7","method":"tcp","state":"unknown","reason":"agent_offline"},
      {"source":"","target_node":"","target":"https://core.example.net/healthz","monitor_id":"m8","method":"http","state":"up","p50_ms":21,"samples":60,"expected":60}]}
    """#)
}

private func checkPathItems() throws {
    let response = try pathsResponse()
    let items = MonitoringPaths.items(response) { $0 == "n-fra" ? "from the directory" : nil }
    try expectEqual(items.first?.spokenTitle, "tyo-1 to fra-2", "names come from the response")
    try expectEqual(items.last?.sourceName, "control plane", "an empty source is the control plane")
    try expectEqual(items.last?.targetName, "core.example.net", "an address reads as its host")
    try expectEqual(items[6].sourceName, "fra-2", "a source missing from the sources list takes its target name before the directory")
    try expectEqual(items[2].stateWord, "skipped", "packet budget is skipped by its check")

    let shown = MonitoringPaths.visible(items, showUnmeasured: false)
    try expectEqual(shown.count, items.count - 1, "skipped pairs are hidden until Show unmeasured")
    try expectEqual(MonitoringPaths.visible(items, showUnmeasured: true).count, items.count, "Show unmeasured brings them back")
    try expectEqual(MonitoringPaths.groups(shown).map(\.group), [.down, .degraded, .unknown, .paused, .up], "groups in topology order")
    let counts = MonitoringPaths.counts(items)
    try expectEqual([counts.paths, counts.up, counts.degraded, counts.down, counts.unknown, counts.paused, counts.skipped], [6, 3, 1, 1, 1, 1, 1], "countPaths: measured paths only")
    try expectEqual(MonitoringPaths.recentlyDegraded(items).map(\.path.monitorID), ["m1", "m4"], "problem paths for Overview")
    try expectEqual(MonitoringPaths.figures(items[0]), "p50 238 ms, loss 6.2%", "figures in words")
    try expect(MonitoringPaths.figures(items[5]) == nil, "a paused path has no current figures")
    try expectEqual(MonitoringPaths.reverse(of: items[1], in: items)?.path.monitorID, nil, "no reverse when the matrix lacks it")
    try expectEqual(MonitoringPaths.reverse(of: items[6], in: items)?.path.monitorID, "m1", "fra-2 to tyo-1 reverses to tyo-1 to fra-2")

    let pair = MonitoringPaths.checks(onPair: "n-sin~n-fra", in: items)
    try expectEqual(pair.map(\.path.monitorID), ["m4", "m5"], "pairOrder: a pair's live checks, worst first")
    try expectEqual(MonitoringPaths.cell(key: "n-sin~n-fra", monitorID: "m5", in: items)?.path.monitorID, "m5", "a named check opens its own cell, not the pair's first")
    try expectEqual(MonitoringPaths.cell(key: "n-sin~n-fra", monitorID: nil, in: items)?.path.monitorID, "m4", "no check named: the pair's first in pairOrder")
    try expectEqual(MonitoringPaths.cell(key: "n-sin~n-fra", monitorID: "gone", in: items)?.path.monitorID, "m4", "a check no longer on the pair falls back to pairOrder")
    let reordered = MonitoringPaths.pairOrder(pair.reversed())
    try expectEqual(reordered.map(\.path.monitorID), ["m4", "m5"], "pairOrder does not depend on the server's order")

    let notJudged = try decode(PathsResponse.self, #"{"paths":[{"source":"a","target_node":"b","state":"degraded","reason":"degraded_loss"}]}"#)
    try expectEqual(MonitoringPaths.items(notJudged).first?.stateWord, "unknown", "degraded counts only from a server that judges it")
}

private func checkMatrix() throws {
    let items = MonitoringPaths.visible(MonitoringPaths.items(try pathsResponse()), showUnmeasured: false)
    let matrix = MonitoringMatrix(items: items)
    try expectEqual(matrix.columns.map(\.name), ["core.example.net", "fra-2", "hkg-1", "tyo-1"], "targets as columns, by name")
    try expectEqual(matrix.rows.map(\.name), ["control plane", "fra-2", "sin-1", "tyo-1"], "sources as rows, by name")
    let sin = try expectUnwrapped(matrix.rows.first { $0.name == "sin-1" }, "sin-1 row")
    try expectEqual(sin.cells, [nil, .down, nil, .paused], "the worst check on a pair wins; missing pairs are empty")
    try expectEqual(sin.summary, "sin-1: 1 down, 1 paused", "per-source summary")
    try expect(sin.hasProblems, "a source with a down path is a problem path for the rotor")
    try expectEqual(MonitoringMatrix.sourceQuery(sin), "source:sin-1", "row header query")
    try expectEqual(MonitoringMatrix.targetQuery(MonitoringMatrixColumn(id: "x", name: "control plane", targetNode: "")), #"target:"control plane""#, "quoted query values")
}

private func checkEvidenceAndLinks() throws {
    let items = MonitoringPaths.items(try pathsResponse())
    try expectEqual(
        MonitoringPathEvidence.sentence(items[0].path.degraded, since: "11:12"),
        "Loss 6.2% against a baseline of 0.4%, trigger 2.0%, since 11:12",
        "evidence sentence"
    )
    try expect(MonitoringPathEvidence.sentence(nil, since: "x") == nil, "no evidence without degradation")

    var byMonitor = Incident(id: "i1", kind: "path.degraded", nodeID: "n-sin", monitorID: "m4")
    try expectEqual(MonitoringIncidentLink.pathKey(for: byMonitor, in: items), "n-sin~n-fra", "server key: source and check")
    let upCheck = Incident(id: "i1b", kind: "path.degraded", nodeID: "n-sin", monitorID: "m5")
    try expectEqual(MonitoringIncidentLink.item(for: upCheck, in: items)?.path.monitorID, "m5", "the incident opens its own check's cell, not the pair's first")
    byMonitor.monitorID = "unknown"
    byMonitor.subject = "tyo-1 → hkg-1"
    try expectEqual(MonitoringIncidentLink.pathKey(for: byMonitor, in: items), "n-tyo~n-hkg", "subject names as a fallback")
    var pending = Incident(id: "pending:path.degraded/n-tyo~n-fra", kind: "path.degraded", state: "pending")
    pending.key = "path.degraded/n-tyo~n-fra"
    try expectEqual(MonitoringIncidentLink.pathKey(for: pending, in: items), "n-tyo~n-fra", "a pending key carries the path key")
    let titled = Incident(id: "i2", kind: "path.degraded", title: "Path sin-1 to fra-2 degraded")
    try expectEqual(MonitoringIncidentLink.pathKey(for: titled, in: items), "n-sin~n-fra", "title names as the last fallback")
    try expect(MonitoringIncidentLink.pathKey(for: Incident(id: "i3", kind: "node.offline", nodeID: "n-sin"), in: items) == nil, "a node incident has no path")
    try expect(MonitoringIncidentLink.names(in: "a to b to c") == nil, "ambiguous subjects are not guessed")
}

private func chainRow(_ source: String, _ node: String, _ target: String?, _ targetNode: String = "", status: String = "converged") throws -> MonitoringLineChain {
    let current = target.map { #"{"target_line_uuid":"\#($0)","target_node_id":"\#(targetNode)","artifact_digest":"d","status":"\#(status)"}"# } ?? "null"
    return try decode(MonitoringLineChain.self, #"{"source_line_uuid":"\#(source)","source_node_id":"\#(node)","status":"\#(status)","current":\#(current),"attempt":null}"#)
}

private func checkChainComposition() throws {
    let rows = [
        try chainRow("l2", "n-hkg", "l3", "n-fra"),
        try chainRow("l1", "n-tyo", "l2", "n-hkg"),
        try chainRow("l4", "n-sin", "l5", "n-fra", status: "drifted"),
        try chainRow("l6", "n-iad", nil, status: "planned"),
        try chainRow("c1", "n-x", "c2", "n-y"),
        try chainRow("c2", "n-y", "c1", "n-x"),
    ]
    let chains = MonitoringChain.compose(rows)
    try expectEqual(chains.count, 4, "every row lands in one chain, cycles included")
    let long = try expectUnwrapped(chains.first { $0.id == "l1" }, "the tyo chain")
    try expectEqual(long.hops.map(\.nodeID), ["n-tyo", "n-hkg", "n-fra"], "hops in order: entry, relay, exit")
    try expectEqual(long.hops.map(\.role), [.entry, .relay, .exit], "hop roles")
    try expectEqual(long.state, .converged, "converged chain")
    try expectEqual(chains.first?.state, .drifted, "the worst chains sort first")
    let planned = try expectUnwrapped(chains.first { $0.id == "l6" }, "planned chain")
    try expectEqual(planned.hops.count, 1, "a planned route has no exit yet")
    try expectEqual(planned.state, .pending, "planned reads pending")
    let cycle = try expectUnwrapped(chains.first { $0.hops.contains { $0.nodeID == "n-x" } }, "cycle chain")
    try expectEqual(cycle.hops.count, 3, "a cycle stops where it started")
    try expectEqual(MonitoringChain.pathKey(from: long.hops[0], to: long.hops[1]), "n-tyo~n-hkg", "hop path key")
}

private func checkMaintenanceRules() throws {
    let end = now.addingTimeInterval(3_600)
    try expect(MonitoringMaintenance.problem(name: "x", reason: "", hasSubject: true, startsAt: now, endsAt: end, now: now) == nil, "a valid window passes")
    try expectEqual(MonitoringMaintenance.problem(name: "  ", reason: "", hasSubject: true, startsAt: now, endsAt: end, now: now), "Name the window.", "name required")
    try expectEqual(MonitoringMaintenance.problem(name: String(repeating: "é", count: 61), reason: "", hasSubject: true, startsAt: now, endsAt: end, now: now), "The name is at most 120 characters.", "name length counted in bytes")
    try expect(MonitoringMaintenance.problem(name: String(repeating: "a", count: 120), reason: "", hasSubject: true, startsAt: now, endsAt: end, now: now) == nil, "120 bytes is allowed")
    try expectEqual(MonitoringMaintenance.problem(name: "x", reason: "", hasSubject: false, startsAt: now, endsAt: end, now: now), "Choose a node.", "subject required")
    try expectEqual(MonitoringMaintenance.problem(name: "x", reason: "", hasSubject: true, startsAt: now, endsAt: now, now: now), "The end must be in the future.", "end in the future")
    try expect(MonitoringMaintenance.problem(name: "x", reason: "", hasSubject: true, startsAt: now, endsAt: now.addingTimeInterval(30 * 86_400), now: now) == nil, "exactly 30 days is allowed")
    try expectEqual(MonitoringMaintenance.problem(name: "x", reason: "", hasSubject: true, startsAt: now, endsAt: now.addingTimeInterval(30 * 86_400 + 1), now: now), "A window lasts at most 30 days.", "at most 30 days")
    try expectEqual(MonitoringMaintenance.problem(name: "x", reason: String(repeating: "n", count: 501), hasSubject: true, startsAt: now, endsAt: end, now: now), "The note is at most 500 characters.", "note length")
    try expectEqual(MonitoringMaintenance.Preset.oneHour.end(from: now), end, "1 h preset")
    try expect(MonitoringMaintenance.Preset.until.end(from: now) == nil, "Until has no fixed end")
    try expectEqual(MonitoringMaintenance.defaultName(subject: "edge-tyo-3", time: "14:05"), "Maintenance edge-tyo-3 14:05", "prefilled name")
    try expectEqual(MonitoringMaintenance.defaultName(subject: String(repeating: "x", count: 200), time: "1").utf8.count, 120, "prefilled name is clipped to the limit")
    let window = MaintenanceWindow(id: "mw", name: "Home lab")
    var held = Incident(id: "i")
    held.maintenanceID = "mw"
    try expect(MonitoringMaintenance.holds(window, held), "a window holds its incidents by id")
    held.maintenanceID = ""
    held.maintenance = "Home lab"
    try expect(MonitoringMaintenance.holds(window, held), "or by name")
}

private func checkMonitoringQueries() throws {
    let items = MonitoringPaths.items(try pathsResponse())
    func paths(_ query: String) -> [String] {
        MonitoringQuery.filter(items, query: query, provider: MonitoringPathQueryFields.self, now: now).rows.map(\.path.monitorID)
    }
    try expectEqual(paths("source:sin-1"), ["m3", "m4", "m5", "m6"], "source: filters by source name")
    try expectEqual(paths("target:fra-2 state:down"), ["m4"], "target and state combine")
    try expectEqual(paths("method:icmp"), ["m3", "m5"], "method:")
    try expectEqual(paths("state:skipped"), ["m3"], "state:skipped names unmeasured pairs")
    try expectEqual(paths("loss>5"), ["m1", "m4"], "loss in percent")
    try expectEqual(paths("core"), ["m8"], "free text searches the address")
    try expect(MonitoringQuery.filter(items, query: "stauts:down", provider: MonitoringPathQueryFields.self, now: now).error != nil, "an unknown field is an error, not an empty list")

    let monitors = [
        MonitoringCheckItem(monitor: Monitor(id: "a", name: "api", typeRaw: "tls"), health: .failing(failing: 1, total: 1, lastAt: now), nodeNames: []),
        MonitoringCheckItem(monitor: Monitor(id: "b", name: "portal", typeRaw: "http", nodeIDs: ["n-fra"]), health: .up(total: 1, latencyMs: 4, lastAt: now), nodeNames: ["fra-2"]),
        MonitoringCheckItem(monitor: Monitor(id: "c", name: "ssh", typeRaw: "tcp", enabled: false), health: .disabled, nodeNames: []),
    ]
    func checksMatching(_ query: String) -> [String] {
        MonitoringQuery.filter(monitors, query: query, provider: MonitoringCheckQueryFields.self, now: now).rows.map(\.monitor.id)
    }
    try expectEqual(checksMatching("type:tls"), ["a"], "type:")
    try expectEqual(checksMatching("node:fra-2"), ["b"], "node: by name")
    try expectEqual(checksMatching("state:failing"), ["a"], "state:failing")
    try expectEqual(checksMatching("state:paused"), ["c"], "state:paused aliases disabled")
    try expectEqual(monitors[2].stateWord, "paused", "a disabled check reads paused")

    var snoozed = Incident(id: "s", kind: "node.offline", severity: "critical", state: "open", nodeName: "sjc-2")
    snoozed.snoozedUntil = now.addingTimeInterval(600)
    let open = Incident(id: "o", kind: "path.degraded", severity: "warning", state: "open", nodeName: "tyo-1")
    let acked = Incident(id: "a", kind: "agent.stalled", state: "acknowledged", nodeName: "tyo-3")
    let incidents = [snoozed, open, acked].map { MonitoringIncidentItem(incident: $0, now: now) }
    func incidentsMatching(_ query: String) -> [String] {
        MonitoringQuery.filter(incidents, query: query, provider: MonitoringIncidentQueryFields.self, now: now).rows.map(\.incident.id)
    }
    try expectEqual(incidentsMatching("state:open"), ["o"], "state:open is open minus snoozed (the console's Open chip)")
    try expectEqual(incidentsMatching("state:snoozed"), ["s"], "state:snoozed")
    try expectEqual(incidentsMatching("kind:path.degraded"), ["o"], "kind:")
    try expectEqual(incidentsMatching("node:tyo-3"), ["a"], "node:")
}

private func checkMonitoringRefusals() throws {
    let version = WriteFlow.refusal(for: .conflict(code: "version_conflict", message: "monitor m changed", findings: []))
    if case .refused(.versionConflict, _)? = version {} else {
        throw CheckFailure.failed("409 version_conflict maps to versionConflict")
    }
}

// MARK: Demo transport round trips

private func checkMonitoringDemo() async throws {
    let transport = DemoTransport(identity: .pat, clock: DemoClock(pinned: "2026-10-28T12:00:00Z")!, state: DemoState())
    let api = LatticeClient(baseURL: DemoWorld.baseURL, credential: LatticeCredential(bearerToken: DemoWorld.token), transport: transport)

    let monitors = try await api.listMonitors()
    let portal = try expectUnwrapped(monitors.first { $0.id == "mon_http_portal" }, "demo portal check")
    try expect(portal.isEditable && portal.version == 4, "the portal check is an editable operator check")
    let generated = try expectUnwrapped(monitors.first { $0.id == "mon_tcp_edge-tyo-1_relay-fra-1" }, "demo mesh check")
    try expect(generated.isGenerated, "the mesh check is generated by its definition")
    try expectEqual(generated.managedBy, "check:def_fleet_mesh", "a definition's check carries the server's owner stamp")
    let healths = Set(monitors.map { MonitoringHealth.of($0, results: $0.latest, now: now).rank })
    try expect(healths.isSuperset(of: [0, 2, 3, 6, 7]), "demo checks cover failing, stale, unmeasured, up and paused: \(healths.sorted())")

    let paused = try await api.monitoringSetEnabled(id: "mon_http_portal", version: 4, enabled: false)
    try expect(!paused.enabled && paused.version == 5, "demo pause bumps the version")
    do {
        _ = try await api.monitoringSetEnabled(id: "mon_http_portal", version: 4, enabled: true)
        throw CheckFailure.failed("a stale version must be refused")
    } catch LatticeAPIError.conflict(let code, _, _) {
        try expectEqual(code, "version_conflict", "demo stale version answers version_conflict")
    }
    do {
        _ = try await api.monitoringSetEnabled(id: generated.id, version: generated.version, enabled: false)
        throw CheckFailure.failed("a generated check must refuse edits")
    } catch LatticeAPIError.conflict(let code, let message, _) {
        try expectEqual(code, "conflict", "generated refusal code")
        try expect(message.contains("check definition"), "generated refusal names the definition")
    }

    let definitions = try await api.monitoringDefinitions()
    try expectEqual(definitions.definitions.map(\.id), ["def_dns_watch", "def_fleet_mesh"], "demo definitions")
    let mesh = try await api.monitoringDefinition(id: "def_fleet_mesh")
    let request = try expectUnwrapped(MonitoringDefinitionDeleteRequest(definition: mesh), "mesh delete request")
    try expect(request.monitorIDs.contains("mon_tcp_edge-ams-1_backup-ams-4"), "the paused target goes with the definition")
    do {
        _ = try await api.monitoringDeleteDefinition(MonitoringDefinitionDeleteRequest(id: mesh.id, version: mesh.version, monitorIDs: Array(request.monitorIDs.dropLast())))
        throw CheckFailure.failed("a partial monitor list must be refused")
    } catch LatticeAPIError.conflict {}
    let deleted = try await api.monitoringDeleteDefinition(request)
    try expectEqual(deleted.deleted.count, request.monitorIDs.count, "demo deletes exactly the named monitors")
    let remaining = try await api.listMonitors()
    try expect(remaining.allSatisfy { $0.checkDefinitionID != "def_fleet_mesh" }, "the definition's checks leave the list")

    let series = try await api.monitoringPathSeries(.pair(source: "n-edge-tyo-1", targetNode: "n-relay-fra-1", check: nil), window: .oneHour, compare: true)
    try expectEqual(series.buckets.count, 60, "1 h at one-minute steps")
    try expect(MonitoringSeriesSegments.p50(series).count >= 2, "the degraded demo path has a gap")
    try expectEqual(series.previous?.p50Ms.count, 60, "compare adds one previous p50 per step")
    _ = try await api.monitoringPathSeries(.pair(source: "n-edge-tyo-1", targetNode: "n-relay-fra-1", check: "def_fleet_mesh"), window: .oneHour)
    do {
        _ = try await api.monitoringPathSeries(.pair(source: "n-edge-tyo-1", targetNode: "n-relay-fra-1", check: "mon_tcp_edge-tyo-1_relay-fra-1"), window: .oneHour)
        throw CheckFailure.failed("a generated monitor's id names no check on the pair")
    } catch LatticeAPIError.notFound {}
    let silent = try await api.monitoringPathSeries(.pair(source: "n-edge-sjc-2", targetNode: "n-edge-sjc-1", check: nil), window: .oneDay)
    try expect(MonitoringSeriesSegments.isEmpty(silent), "the offline source's path has no data")
    _ = try await api.monitoringLatencySeries(source: "n-edge-sin-2", target: "n-relay-hkg-1", window: "24h")
    _ = try await api.monitoringLatencyRollups()
    let results = try await api.monitoringResults(monitorID: "mon_tls_api", limit: 20)
    try expectEqual(results.count, 20, "demo results honor the limit")
    try expect(results.first?.success == false, "the failing check's newest result failed")
    let chains = MonitoringChain.compose(try await api.monitoringLineChains())
    try expectEqual(chains.count, 3, "demo chains")
    try expect(chains.contains { $0.hops.count == 3 }, "a three-hop demo chain")
}
