import Foundation
import AstraCore

public func checkAudit() async throws {
    try checkAuditDecoding()
    try checkAuditExportGolden()
    try checkAuditExportEdges()
    try checkAuditRequests()
    try checkAuditTrace()
    try checkAuditActionWords()
    try await checkAuditPaging()
    try await checkAuditDemo()
}

private let auditBase = "https://lattice.example.com"
private let auditClock = DemoClock(pinned: "2026-10-28T12:00:00Z")!

private func auditDemo(_ scenario: DemoScenario = .normal) -> LatticeClient {
    LatticeClient(baseURL: DemoWorld.baseURL, credential: LatticeCredential(bearerToken: DemoWorld.token),
                  transport: DemoTransport(identity: .pat, scenario: scenario, clock: auditClock, state: DemoState()))
}

private func auditGoldenPage() throws -> AuditPage {
    try AuditPage.decode(try fixture("audit-export-events.json"), query: AuditQuery(limit: 500))
}

private func auditText(_ name: String) throws -> String {
    String(decoding: try fixture(name), as: UTF8.self)
}

// MARK: Decoding

private func checkAuditDecoding() throws {
    let page = try auditGoldenPage()
    try expectEqual(page.events.count, 5, "events")
    try expectEqual(page.scanned, 5, "scanned")
    try expectEqual(page.complete, true, "complete")
    try expect(!page.isPartial, "a complete scan is not partial")
    try expect(page.events.allSatisfy { !$0.rawJSON.isEmpty }, "each event keeps its raw slice")
    try expectEqual(page.events[1].metadata["why"], "scope, missing", "metadata")

    let capped = try AuditPage.decode(json(#"{"events":[],"total":50000,"limit":100,"offset":0,"scanned":200000,"complete":false}"#), query: AuditQuery())
    try expect(capped.isPartial, "a capped scan is partial")
    try expectEqual(AuditModel.scanLine(capped), "At least 50,000 events. Scanned 200,000 events; refine to see older.", "capped footer")
    try expectEqual(AuditModel.scanLine(page), "5 events", "complete footer")
    let older = try AuditPage.decode(json(#"{"events":[],"total":3,"limit":100,"offset":0}"#), query: AuditQuery())
    try expect(older.complete == nil && !older.isPartial, "a server that does not say is not partial")
    let bare = try AuditPage.decode(json(#"[{"id":"a1","at":"2026-10-28T11:00:00Z","action":"login"}]"#), query: AuditQuery())
    try expectEqual(bare.events.first?.rawJSON, #"{"id":"a1","at":"2026-10-28T11:00:00Z","action":"login"}"#, "bare array keeps raw slices")
    do {
        _ = try AuditPage.decode(json(#"{"events":"nope"}"#), query: AuditQuery())
        throw CheckFailure.failed("a malformed audit body must not decode")
    } catch LatticeAPIError.invalidResponse {}

    let verified = try JSONDecoder().decode(AuditChainStatus.self, from: json(#"{"enabled":true,"ok":true,"count":5760,"head":"9f2c","anchored":true,"anchor_count":5760,"anchor_head":"9f2c","anchor_pending":{"count":5761,"head":"ab01"}}"#))
    try expectEqual(verified.head, "9f2c", "verify head")
    try expectEqual(verified.anchorPending, AuditAnchorCheckpoint(count: 5761, head: "ab01"), "anchor pending")
    let broken = try JSONDecoder().decode(AuditChainStatus.self, from: json(#"{"enabled":true,"ok":false,"count":411,"head":"77aa","anchored":false,"error":"audit wal: record 412: prev_hash does not match the running head"}"#))
    try expect(!broken.ok && broken.error?.contains("record 412") == true, "broken chain keeps the first broken link")
    let disabled = try JSONDecoder().decode(AuditChainStatus.self, from: json(#"{"enabled":false}"#))
    try expect(!disabled.enabled && disabled.head.isEmpty, "verification off")
}

// MARK: Export against the console's own output

/// The goldens were written by `audit-export-generate.mjs`, which runs the
/// console's export functions cut verbatim from `AuditView.vue` over the
/// same fixture. Compared line by line.
private func checkAuditExportGolden() throws {
    let events = try auditGoldenPage().events
    try expectLines(AuditExport.csv(events), try auditText("audit-export-golden.csv"), "CSV")
    try expectLines(AuditExport.ndjson(events), try auditText("audit-export-golden.ndjson"), "NDJSON")

    let raw = try auditText("audit-export-events.json")
    for line in AuditExport.ndjson(events).split(separator: "\n") {
        try expect(raw.contains(line), "each NDJSON line is the server's slice")
    }

    let status = try JSONDecoder().decode(AuditChainStatus.self, from: json(#"{"enabled":true,"ok":true,"count":5760,"head":"\#(String(repeating: "9f2c", count: 16))","anchored":true,"anchor_count":5760,"anchor_head":"\#(String(repeating: "9f2c", count: 16))","anchor_pending":{"count":5761,"head":"\#(String(repeating: "ab01", count: 16))"}}"#))
    let at = try expectUnwrapped(ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z"), "verified at")
    try expectEqual(AuditExport.headRecord(status, verifiedAt: at), try auditText("audit-export-golden-head.json"), "audit head record")
}

private func expectLines(_ actual: String, _ expected: String, _ label: String) throws {
    let a = actual.components(separatedBy: "\n"), e = expected.components(separatedBy: "\n")
    for (index, pair) in zip(a, e).enumerated() where pair.0 != pair.1 {
        throw CheckFailure.failed("\(label) line \(index + 1): got \(pair.0) want \(pair.1)")
    }
    try expectEqual(a.count, e.count, "\(label) line count")
}

private func checkAuditExportEdges() throws {
    // Raw bytes survive: the server's escapes are not re-encoded.
    let page = try AuditPage.decode(json(#"{"events":[{"id":"e1","at":"2026-10-28T11:00:00.000000001Z","action":"notify.test","reason":"a <b>","metadata":{"url":"https://x.example.net/a?b=1&c=2"}}],"total":1,"limit":100,"offset":0}"#), query: AuditQuery())
    let line = AuditExport.ndjson(page.events)
    try expect(line.contains(#"<b>"#), "NDJSON keeps the server's escapes")
    let csv = AuditExport.csv(page.events).components(separatedBy: "\n")
    try expectEqual(csv[1], #"2026-10-28T11:00:00.000000001Z,,notify.test,,,,,,a <b>,"{""url"":""https://x.example.net/a?b=1&c=2""}""#, "CSV reads strings, keeps metadata bytes and the server's precision")

    // Go escapes < > & in metadata; the CSV writes them as JSON.stringify does. NDJSON stays raw.
    let escaped = try AuditPage.decode(json(#"{"events":[{"id":"e2","action":"notify.test","metadata":{"note":"\\u003c","url":"a?b=1\u0026c=\u003cd\u003e"}}],"total":1,"limit":100,"offset":0}"#), query: AuditQuery())
    let escapedCSV = AuditExport.csv(escaped.events).components(separatedBy: "\n")
    try expect(escapedCSV[1].hasSuffix(#""{""note"":""\\u003c"",""url"":""a?b=1&c=<d>""}""#), "CSV metadata unescapes Go's escapes only: \(escapedCSV[1])")
    try expect(AuditExport.ndjson(escaped.events).contains(#"\u0026"#), "NDJSON keeps Go's escapes")

    // A partial scan says so on the first line and in the share title.
    let scan = AuditExportScan(scanned: 200_000)
    try expectEqual(AuditExport.csv([], partial: scan).components(separatedBy: "\n").first, "Partial: scanned 200000 events", "partial CSV first line")
    try expectEqual(AuditExport.ndjson([], partial: scan), #"{"partial":"Partial: scanned 200000 events"}"#, "partial NDJSON first line parses")
    try expectEqual(AuditExport.shareTitle(.csv, count: 10, partial: scan), "Partial: scanned 200000 events", "partial share title")
    try expectEqual(AuditExport.shareTitle(.ndjson, count: 1, partial: nil), "1 audit event, NDJSON", "share title")
    try expectEqual(AuditExport.fileName(.csv, partial: true), "lattice-audit-partial.csv", "partial file name")

    // An event built without its slice still exports, metadata in Go's order.
    let built = AuditEvent(id: "b", action: "login", decision: "allow", metadata: ["z": "1", "a": "x,y"])
    try expectEqual(AuditExport.csv([built]).components(separatedBy: "\n")[1], #",allow,login,,,,,,,"{""a"":""x,y"",""z"":""1""}""#, "fallback CSV")

    // No anchored, verified head: nothing to export.
    try expect(AuditExport.headRecord(AuditChainStatus(enabled: true, ok: true, count: 3), verifiedAt: Date()) == nil, "no head without an anchor")
    try expect(AuditExport.headRecord(AuditChainStatus(enabled: true, ok: false, count: 3), verifiedAt: Date()) == nil, "no head for a broken chain")
    try expectEqual(AuditExport.csvCell("plain"), "plain", "plain cell")
    try expectEqual(AuditExport.csvCell("a\"b"), "\"a\"\"b\"", "quoted cell")
    try expectEqual(AuditExport.csvCell("line one\r\nline two"), "\"line one\r\nline two\"", "a CRLF cell is quoted, as the console's /[\",\\n]/ does")
}

// MARK: Requests

private func checkAuditRequests() throws {
    let resolvers: [String: @Sendable (String) -> String?] = ["node": { $0 == "core-lon-1" ? "n-core-lon-1" : nil }]
    let tokens = TasksTokens.parse("node:core-lon-1 actor:admin decision:deny scope:terminal:open trace:corr_1 action:task.* lost words", grammar: AuditModel.grammar, resolvers: resolvers)
    let from = Date(timeIntervalSince1970: 0)
    let query = AuditModel.request(layer: .changes, tokens: tokens, from: from, to: nil, offset: 100)
    let items = Dictionary(uniqueKeysWithValues: query.queryItems.map { ($0.name, $0.value ?? "") })
    try expectEqual(items["node_id"], "n-core-lon-1", "node resolved")
    try expectEqual(items["actor_id"], "admin", "actor")
    try expectEqual(items["decision"], "deny", "decision")
    try expectEqual(items["scope"], "terminal:open", "scope keeps its colon")
    try expectEqual(items["correlation_id"], "corr_1", "trace")
    try expectEqual(items["action"], "task.*", "action prefix")
    try expectEqual(items["q"], "lost words", "free text")
    try expectEqual(items["exclude_action"], "node.online,node.offline", "Changes hides node flips")
    try expectEqual(items["exclude_decision"], "observe", "Changes hides observe events")
    try expectEqual(items["limit"], "100", "page size")
    try expectEqual(items["offset"], "100", "offset")
    try expect(items["at_from"] != nil && items["at_to"] == nil, "window")

    let flips = TasksTokens.parse("action:node.offline decision:observe", grammar: AuditModel.grammar)
    let asked = Dictionary(uniqueKeysWithValues: AuditModel.request(layer: .changes, tokens: flips, from: nil, to: nil, offset: 0).queryItems.map { ($0.name, $0.value ?? "") })
    try expect(asked["exclude_action"] == nil && asked["exclude_decision"] == nil, "a question about flips is answered, not contradicted")
    let all = Dictionary(uniqueKeysWithValues: AuditModel.request(layer: .all, tokens: TasksParsedTokens(), from: nil, to: nil, offset: 0).queryItems.map { ($0.name, $0.value ?? "") })
    try expect(all["exclude_action"] == nil, "All hides nothing")
}

private func checkAuditTrace() throws {
    let decoder = JSONDecoder()
    let events = try decoder.decode([AuditEvent].self, from: json(#"[{"id":"b","at":"2026-10-28T11:00:00Z","decision":"deny","node_id":"n2","metadata":{"task_id":"t1"}},{"id":"a","at":"2026-10-28T11:00:00Z","node_id":"n1","metadata":{"approval_id":"ap1","task_id":"t1"}},{"id":"c","at":"2026-10-28T10:00:00Z","metadata":{"approval_id":" ap2 "}}]"#))
    try expectEqual(AuditModel.orderTimeline(events).map(\.id), ["c", "a", "b"], "oldest first, ties by id")
    try expectEqual(AuditModel.referencedApprovalIDs(events), ["ap1", "ap2"], "approval refs, first seen")
    try expectEqual(AuditModel.referencedTaskIDs(events), ["t1"], "task refs")
    let summary = AuditModel.summarize(events)
    try expectEqual(summary.total, 3, "trace total")
    try expectEqual(summary.denied, 1, "trace denied")
    try expectEqual(summary.nodes, ["n1", "n2"], "trace nodes")
    try expectEqual(AuditModel.decision(of: events[0]), .deny, "deny decision")
    try expectEqual(AuditModel.object(of: events[1]), "t1", "object prefers the task")
}

private func checkAuditActionWords() throws {
    try expectEqual(AuditActionWords.label(for: "task.create"), "Task queued", "task.create")
    try expectEqual(AuditActionWords.label(for: "inventory.auto_roll"), "Renewal date rolled forward", "inventory.auto_roll")
    try expectEqual(AuditActionWords.label(for: "network.latticenet.vpn-core.approve"), "Plan approved", "plan decision with dots in the plugin id")
    try expectEqual(AuditActionWords.label(for: "network.sshguard.reject"), "Plan rejected", "plan reject")
    try expectEqual(AuditActionWords.label(for: "network.agentupdate.dismiss"), "Plan dismissed", "plan dismiss")
    try expect(AuditActionWords.label(for: "network.approve") == nil, "no plugin, no plan decision")
    try expect(AuditActionWords.label(for: "api.deny") == nil, "unlisted actions keep their raw name")
    try expectEqual(AuditActionWords.words(for: "api.deny"), "api.deny", "raw name")
    try expectEqual(AuditActionWords.labels.count, 196, "every labelled console action")
}

// MARK: Paging

private func checkAuditPaging() async throws {
    // Lookup by id walks pages of 100 and stops at the end.
    let first = (0..<100).map { #"{"id":"e\#($0)","action":"login"}"# }.joined(separator: ",")
    let second = #"{"id":"target","action":"task.create"}"#
    let transport = MockTransport(responses: [
        "\(auditBase)/api/audit?limit=100&offset=0": (200, json(#"{"events":[\#(first)],"total":101,"limit":100,"offset":0}"#)),
        "\(auditBase)/api/audit?limit=100&offset=100": (200, json(#"{"events":[\#(second)],"total":101,"limit":100,"offset":100}"#)),
    ])
    let client = LatticeClient(baseURL: URL(string: auditBase)!, credential: LatticeCredential(bearerToken: "lat_check.notasecret"), transport: transport)
    let found = try await client.auditFind(id: "target")
    try expectEqual(found?.action, "task.create", "found on the second page")
    try expectEqual(await transport.requestURLs.count, 2, "two pages read")

    // The export reads to the end of the range and carries the server's partial flag.
    let exportTransport = MockTransport(responses: [
        "\(auditBase)/api/audit?limit=500&offset=0": (200, json(#"{"events":[{"id":"x1"},{"id":"x2"}],"total":3,"limit":500,"offset":0,"scanned":200000,"complete":false}"#)),
        "\(auditBase)/api/audit?limit=500&offset=2": (200, json(#"{"events":[{"id":"x3"}],"total":3,"limit":500,"offset":2,"scanned":200000,"complete":false}"#)),
    ])
    let exporter = LatticeClient(baseURL: URL(string: auditBase)!, credential: LatticeCredential(bearerToken: "lat_check.notasecret"), transport: exportTransport)
    let result = try await AuditExport.collect(AuditQuery(), client: exporter)
    try expectEqual(result.events.map(\.id), ["x1", "x2", "x3"], "export pages to the end")
    try expectEqual(result.partial?.label, "Partial: scanned 200000 events", "server partial labelled")

    // Stopping at the page cap is partial too.
    let capTransport = MockTransport(responses: [
        "\(auditBase)/api/audit?limit=500&offset=0": (200, json(#"{"events":[{"id":"y1"}],"total":9,"limit":500,"offset":0,"scanned":9,"complete":true}"#)),
    ])
    let capped = try await AuditExport.collect(AuditQuery(), client: LatticeClient(baseURL: URL(string: auditBase)!, credential: LatticeCredential(bearerToken: "t"), transport: capTransport), maxPages: 1)
    try expectEqual(capped.partial?.label, "Partial: first 1 of 9 events", "page cap labelled by what the file holds")

    // An event appended between pages shifts the offsets; the repeated row is written once.
    let shiftTransport = MockTransport(responses: [
        "\(auditBase)/api/audit?limit=500&offset=0": (200, json(#"{"events":[{"id":"z1"},{"id":"z2"}],"total":3,"limit":500,"offset":0}"#)),
        "\(auditBase)/api/audit?limit=500&offset=2": (200, json(#"{"events":[{"id":"z2"},{"id":"z3"}],"total":4,"limit":500,"offset":2}"#)),
    ])
    let shifted = try await AuditExport.collect(AuditQuery(), client: LatticeClient(baseURL: URL(string: auditBase)!, credential: LatticeCredential(bearerToken: "t"), transport: shiftTransport))
    try expectEqual(shifted.events.map(\.id), ["z1", "z2", "z3"], "a shifted row is not written twice")
}

private func checkAuditDemo() async throws {
    let client = auditDemo()
    let status = try await client.verifyAuditChain()
    try expect(status.enabled && status.ok && status.anchored, "demo chain verifies")
    try expectEqual(status.head, AuditFixtures.head, "demo head")
    let off = try await auditDemo(.empty).verifyAuditChain()
    try expect(!off.enabled, "empty scenario: verification off")

    let trace = try await client.auditTrace(correlationID: "corr_sshguard")
    try expect(trace.events.count >= 3 && !trace.truncated, "demo trace")
    try expect(zip(trace.events, trace.events.dropFirst()).allSatisfy { ($0.at ?? .distantPast) <= ($1.at ?? .distantPast) }, "trace oldest first")
    let page = try await client.auditPage(AuditQuery(limit: 100))
    try expect(page.events.allSatisfy { !$0.rawJSON.isEmpty }, "demo events keep raw slices")
    let found = try await client.auditFind(id: "audit_d20")
    try expectEqual(found?.decision, "deny", "demo lookup by id")
}
