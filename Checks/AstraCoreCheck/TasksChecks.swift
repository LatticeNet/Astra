import Foundation
import AstraCore

public func checkTasks() async throws {
    try checkTasksDecoding()
    try await checkTasksWriteBodies()
    try checkTasksResultsQuery()
    try checkTasksLease()
    try checkTasksRunStates()
    try checkTasksNodeRows()
    try checkTasksSummaries()
    try checkTasksTokens()
    try checkTasksFilter()
    try await checkTasksIntentFlows()
    try await checkTasksDemo()
}

private let tasksBase = "https://lattice.example.com"
private let tasksClock = DemoClock(pinned: "2026-10-28T12:00:00Z")!

private func tasksMock(_ responses: [String: (Int, Data)], session: Bool = false) -> (LatticeClient, MockTransport) {
    let transport = MockTransport(responses: responses)
    let credential = session ? LatticeCredential(sessionCookie: "sid", csrfToken: "csrf-token") : LatticeCredential(bearerToken: "lat_check.notasecret")
    return (LatticeClient(baseURL: URL(string: tasksBase)!, credential: credential, transport: transport), transport)
}

private func tasksDemo(_ identity: DemoIdentity = .pat, scenario: DemoScenario = .normal) -> LatticeClient {
    LatticeClient(baseURL: DemoWorld.baseURL, credential: identity == .session ? LatticeCredential(sessionCookie: "sess_demo_notasecret", csrfToken: "csrf") : LatticeCredential(bearerToken: DemoWorld.token),
                  transport: DemoTransport(identity: identity, scenario: scenario, clock: tasksClock, state: DemoState()))
}

private func tasksCanonical(_ data: Data?) throws -> String {
    let data = try expectUnwrapped(data, "request body")
    let object = try JSONSerialization.jsonObject(with: data)
    return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

private struct TasksAuthStub: WriteAuthenticator {
    let outcome: DeviceAuthOutcome
    func authenticate(reason: String) async -> DeviceAuthOutcome { outcome }
}

private func tasksTask(_ json: String) throws -> LatticeTask {
    try JSONDecoder().decode(LatticeTask.self, from: Data(json.utf8))
}

private let tasksFanOut = #"{"id":"task_f","actor_id":"admin","token_id":"tok","targets":["n1","n2","n3","n4"],"interpreter":"sh","script_sha256":"3f9a","script_size_bytes":31,"timeout_sec":300,"output_limit":65536,"status":"leased","created_at":"2026-10-28T11:50:00Z","started_at":"2026-10-28T11:50:01Z","target_states":{"n1":{"status":"finished"},"n2":{"status":"leased","attempts":1,"max_attempts":3,"lease_age_seconds":90},"n3":{"status":"stalled","attempts":3,"max_attempts":3,"lease_age_seconds":518400,"stalled_reason":"agent lost during run three times."},"n4":{"status":"leased","attempts":2,"max_attempts":3,"lease_age_seconds":420}},"origin":"direct"}"#

// MARK: Decoding

private func checkTasksDecoding() throws {
    // The envelope an omit_output poll answers, with the fields it adds.
    let page = try TasksResultsPage.decode(json(#"{"results":[{"task_id":"t1","node_id":"n1","exit_code":127,"stdout":"","stderr":"","stdout_bytes":0,"stderr_bytes":24,"stderr_head":"sh: 1: curl: not found","error":"","started_at":"2026-10-28T11:00:00Z","finished_at":"2026-10-28T11:00:02Z","exec_context":{"sandbox":"none","non_root":true,"reported_at":"2026-10-28T10:59:00Z"}}],"total":7,"limit":1,"offset":0}"#), query: TasksResultsQuery(taskIDs: ["t1"]))
    try expectEqual(page.total, 7, "results total")
    let row = try expectUnwrapped(page.results.first, "result row")
    try expectEqual(row.stderrHead, "sh: 1: curl: not found", "stderr head")
    try expectEqual(row.stderrBytes, 24, "stderr bytes")
    try expectEqual(row.execContext?.nonRoot, true, "exec context non_root")
    try expectEqual(row.result.exitCode, 127, "exit code")
    try expect(row.result.finishedAt != nil, "finished_at parsed")

    // A bare array from an older server is the whole answer; sizes fall back to the bodies.
    let bare = try TasksResultsPage.decode(json(#"[{"task_id":"t1","node_id":"n2","exit_code":0,"stdout":"ok\n","stderr":"","error":"","started_at":"2026-10-28T11:00:00Z","finished_at":"2026-10-28T11:00:01Z"}]"#), query: TasksResultsQuery(taskIDs: ["t1"]))
    try expectEqual(bare.results.count, 1, "bare results")
    try expectEqual(bare.results[0].stdoutBytes, 3, "bare stdout size from body")
    try expect(bare.results[0].execContext == nil, "absent exec context stays unknown")
    do {
        _ = try TasksResultsPage.decode(json(#"{"results":"nope"}"#), query: TasksResultsQuery(taskIDs: []))
        throw CheckFailure.failed("a malformed results body must not decode")
    } catch LatticeAPIError.invalidResponse {}

    // Every task field the server sends, including the lease fields of a fan-out.
    let task = try tasksTask(tasksFanOut)
    try expectEqual(task.targetStates["n3"]?.stalledReason, "agent lost during run three times.", "target stalled reason")
    try expectEqual(task.targetStates["n2"]?.leaseAgeSeconds, 90, "target lease age")
    try expectEqual(task.origin, "direct", "origin")

    let reveal = try JSONDecoder().decode(TasksScriptReveal.self, from: json(#"{"ok":true,"id":"task_a","interpreter":"sh","script":"uptime\n","script_sha256":"ab","script_size_bytes":7}"#))
    try expectEqual(reveal.script, "uptime\n", "revealed script")
    try expectEqual(reveal.scriptSizeBytes, 7, "revealed script size")
    try expect((try? JSONDecoder().decode(TasksScriptReveal.self, from: json(#"{"ok":true,"id":"task_a"}"#))) == nil, "a reveal without its script is not that shape")

    let deleted = try JSONDecoder().decode(TasksDeleteResponse.self, from: json(#"{"ok":true}"#))
    try expect(deleted.ok, "delete ok")

    let counts = try JSONDecoder().decode(TaskCounts.self, from: json(#"{"pending":1,"queued":2,"running":3,"stalled":1,"failed_24h":2,"finished_24h":9,"total":18,"generated_at":"2026-10-28T12:00:00Z"}"#))
    try expectEqual(counts.failed24h, 2, "counts failed_24h")
}

// MARK: Request bodies

private func checkTasksWriteBodies() async throws {
    let taskJSON = #"{"id":"task_new","targets":["n1"],"status":"queued","created_at":"2026-10-28T12:00:00Z","origin":"rerun","rerun_of_task_id":"task_a"}"#
    let (client, transport) = tasksMock([
        "\(tasksBase)/api/tasks/cancel": (200, json(#"{"id":"task_a","targets":["n1"],"status":"cancelled","created_at":"2026-10-28T11:00:00Z"}"#)),
        "\(tasksBase)/api/tasks/rerun": (200, json(taskJSON)),
        "\(tasksBase)/api/tasks/rerun-node": (200, json(taskJSON)),
        "\(tasksBase)/api/tasks/delete": (200, json(#"{"ok":true}"#)),
    ])
    let cancelled = try await client.cancelTask(id: "task_a")
    try expectEqual(cancelled.status, "cancelled", "cancel answer")
    try expectEqual(try tasksCanonical(await transport.lastBody), #"{"id":"task_a"}"#, "cancel body")
    let rerun = try await client.tasksRerun(id: "task_a")
    try expectEqual(rerun.rerunOfTaskID, "task_a", "rerun answer")
    try expectEqual(try tasksCanonical(await transport.lastBody), #"{"id":"task_a"}"#, "rerun body")
    _ = try await client.tasksRerunNode(id: "task_a", nodeID: "n1")
    try expectEqual(try tasksCanonical(await transport.lastBody), #"{"id":"task_a","node_id":"n1"}"#, "rerun-node body")
    try await client.tasksDelete(id: "task_a")
    try expectEqual(try tasksCanonical(await transport.lastBody), #"{"id":"task_a"}"#, "delete body")
    let methods = await transport.methods
    try expect(methods.allSatisfy { $0 == "POST" }, "every task write is a POST")

    // The reveal runs on the session client and carries the grant in its body.
    let (session, sessionTransport) = tasksMock([
        "\(tasksBase)/api/tasks/reveal-script": (200, json(#"{"ok":true,"id":"task_a","interpreter":"sh","script":"uptime","script_sha256":"ab","script_size_bytes":6}"#)),
    ], session: true)
    let grant = StepUpGrant(grant: "grant_x", expiresAt: Date().addingTimeInterval(60))
    let script = try await session.tasksRevealScript(id: "task_a", grant: grant)
    try expectEqual(script.script, "uptime", "reveal answer")
    try expectEqual(try tasksCanonical(await sessionTransport.lastBody), #"{"id":"task_a","step_up_grant":"grant_x"}"#, "reveal-script body")
    try expectEqual(await sessionTransport.csrfHeaders.last ?? nil, "csrf-token", "reveal carries the CSRF header")
}

private func checkTasksResultsQuery() throws {
    let ids = (1...120).map { "t\($0)" }
    let items = TasksResultsQuery(taskIDs: ids, nodeID: "n1", offset: 500).queryItems
    let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    try expectEqual(byName["task_id"]?.split(separator: ",").count, 100, "at most 100 ids per read")
    try expectEqual(byName["omit_output"], "1", "polls omit output")
    try expectEqual(byName["node_id"], "n1", "node filter")
    try expectEqual(byName["limit"], "500", "server's largest page")
    try expectEqual(byName["offset"], "500", "offset")
    let full = TasksResultsQuery(taskIDs: ["t1"], nodeID: "n1", omitOutput: false).queryItems
    try expect(!full.contains { $0.name == "omit_output" }, "the output screen asks for the bodies")
}

// MARK: Lease (lib/taskLease.ts cases)

private func checkTasksLease() throws {
    let cases: [(Double, String)] = [
        (0, "0 s"), (30, "30 s"), (59.9, "59 s"), (60, "1 min"), (41 * 60, "41 min"), (3600, "1 h"),
        (2 * 3600 + 5 * 60 + 9, "2 h 5 min"), (86400, "1 d"), (6 * 86400 + 2 * 3600 + 30 * 60, "6 d 2 h"), (-5, "0 s"),
    ]
    for (seconds, want) in cases {
        try expectEqual(TaskLeaseProgress.formatLeaseAge(seconds), want, "lease age \(seconds)")
    }
    let single = try tasksTask(#"{"id":"t","targets":["hk-edge-01"],"interpreter":"sh","status":"leased","attempts":2,"max_attempts":3,"lease_age_seconds":2460}"#)
    try expectEqual(single.leaseProgress(nodeID: "hk-edge-01")?.label, "leased 41 min, attempt 2 of 3", "single-target lease")
    let fanOut = try tasksTask(#"{"id":"t","targets":["hk-edge-01","sg-edge-02"],"status":"leased","target_states":{"hk-edge-01":{"status":"leased","attempts":1,"max_attempts":3,"lease_age_seconds":90},"sg-edge-02":{"status":"stalled","attempts":3,"max_attempts":3,"lease_age_seconds":518400,"stalled_reason":"agent lost during run three times"}}}"#)
    try expectEqual(fanOut.leaseProgress(nodeID: "hk-edge-01")?.label, "leased 1 min, attempt 1 of 3", "fan-out target lease")
    try expectEqual(fanOut.leaseProgress(nodeID: "sg-edge-02")?.label, "agent lost during run three times, attempt 3 of 3", "fan-out stalled target")
    try expect(fanOut.leaseProgress(nodeID: "jp-edge-03") == nil, "no row for a node that is not a target")
    let older = try tasksTask(#"{"id":"t","targets":["hk-edge-01"],"status":"queued"}"#)
    try expect(older.leaseProgress(nodeID: "hk-edge-01") == nil, "an older server produces no label")
    let real = try tasksTask(#"{"id":"t","targets":["hk-edge-01"],"status":"stalled","attempts":3,"max_attempts":3,"stalled_reason":"The store stopped re-leasing after 3 attempts (last lease expired 2026-08-27T08:51:00Z)."}"#)
    try expectEqual(TasksModel.stalledText(real.leaseProgress(nodeID: "hk-edge-01")),
                    "The store stopped re-leasing after 3 attempts (last lease expired 2026-08-27T08:51:00Z), attempt 3 of 3", "stall sentence joined once")
    try expectEqual(TasksModel.stalledText(nil), "Nothing is running this and no result arrived; cancel it or rerun", "stall fallback")
}

/// The server derives pending, stalled and expired; the phone reads the word.
private func checkTasksRunStates() throws {
    let words: [(String, TaskRunState)] = [
        ("pending", .pending), ("queued", .queued), ("leased", .leased), ("running", .leased), ("finished", .finished),
        ("failed", .failed), ("stalled", .stalled), ("expired", .expired), ("cancelled", .cancelled), ("canceled", .cancelled),
        ("some-future-state", .queued),
    ]
    for (word, state) in words {
        try expectEqual(TaskRunState(serverValue: word), state, "run state \(word)")
    }
    try expectEqual(TaskRunState.leased.tasksWord, "running", "a leased run reads running")
    for status in ["pending", "queued", "leased", "stalled"] {
        try expect(TasksModel.isCancellable(status), "\(status) is cancellable")
    }
    for status in ["finished", "failed", "cancelled", "expired"] {
        try expect(!TasksModel.isCancellable(status), "\(status) is settled")
    }
}

private func checkTasksNodeRows() throws {
    let now = try expectUnwrapped(ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z"), "now")
    let task = try tasksTask(tasksFanOut)
    let failed = TasksResultRow(result: LatticeTaskResult(taskID: "task_f", nodeID: "n1", exitCode: 2, startedAt: now.addingTimeInterval(-60), finishedAt: now.addingTimeInterval(-20)), stderrHead: "diagnose: permission denied")
    let rows = TasksModel.nodeRows(for: task, results: [failed], now: now)
    try expectEqual(rows.map(\.nodeID), ["n1", "n3", "n2", "n4"], "failed, stalled, then running")
    try expectEqual(rows[0].state, .failed, "a result settles the node")
    try expectEqual(rows[0].reason, "exit 2: diagnose: permission denied", "first stderr line")
    try expectEqual(rows[0].duration, 40, "duration from the result")
    try expectEqual(rows[1].reason, "agent lost during run three times, attempt 3 of 3", "stalled reason")
    try expectEqual(rows[2].reason, "leased 1 min, attempt 1 of 3", "running lease")
    try expect(!rows[2].oldLease, "a 90 s lease is not old")
    try expect(rows[3].oldLease, "a lease past the run's timeout is old")
    try expectEqual(rows[3].reason, "No heartbeat for 7 min", "old lease copy")
    try expectEqual(TasksModel.failedNodes(rows), ["n1"], "rerun failed walks failed nodes only")

    let expired = try tasksTask(#"{"id":"task_e","targets":["n9"],"status":"expired","created_at":"2026-10-26T12:00:00Z"}"#)
    let expiredRow = try expectUnwrapped(TasksModel.nodeRows(for: expired, results: [], now: now).first, "expired row")
    try expectEqual(expiredRow.state, .expired, "an expired node never reads failed")
    try expectEqual(expiredRow.reason, "The node never picked it up", "expired copy")

    let cancelled = try tasksTask(#"{"id":"task_c","targets":["n9"],"status":"cancelled"}"#)
    try expectEqual(TasksModel.nodeRows(for: cancelled, results: [], now: now).first?.reason, "Cancelled before any agent ran it", "cancelled copy")

    let pending = try tasksTask(#"{"id":"task_p","targets":["n9","n8"],"status":"pending"}"#)
    try expect(TasksModel.nodeRows(for: pending, results: [], now: now).allSatisfy { $0.state == .pending }, "pending nodes")
}

private func checkTasksSummaries() throws {
    let task = try tasksTask(#"{"id":"t","targets":["a","b","c","a"],"status":"leased"}"#)
    let older = TasksResultRow(result: LatticeTaskResult(taskID: "t", nodeID: "a", exitCode: 1, finishedAt: Date(timeIntervalSince1970: 100)))
    let newer = TasksResultRow(result: LatticeTaskResult(taskID: "t", nodeID: "a", exitCode: 0, finishedAt: Date(timeIntervalSince1970: 200)))
    let failedB = TasksResultRow(result: LatticeTaskResult(taskID: "t", nodeID: "b", exitCode: 0, error: "agent refused"))
    let summary = TasksModel.summary(of: task, results: [newer, older, failedB])
    try expectEqual(summary.total, 3, "distinct targets")
    try expectEqual(summary.passed, 1, "the newest result per node wins")
    try expectEqual(summary.failed, 1, "an agent error is a failure")
    try expectEqual(summary.firstFailure?.result.nodeID, "b", "first failure")
    try expectEqual(TasksModel.listProgress(summary), "1 ok, 1 failed", "list progress")
    try expect(TasksModel.listProgress(summary, complete: false) == nil, "a truncated read claims no count")
    try expect(TasksModel.listProgress(TasksRunSummary(total: 3, passed: 0, failed: 0)) == nil, "no count before any report")
    try expectEqual(TasksModel.liveProgress(TasksRunSummary(total: 12, passed: 9, failed: 1)), "10 of 12 finished, 1 failed", "live progress")
    try expectEqual(TasksModel.liveProgress(TasksRunSummary(total: 12, passed: 9, failed: 0)), "9 of 12 finished", "live progress without failures")

    try expectEqual(TasksModel.failureReason(TasksResultRow(result: LatticeTaskResult(taskID: "t", nodeID: "a", exitCode: 127, stderr: "\n  sh: 1: curl: not found\nmore"))), "exit 127: sh: 1: curl: not found", "first stderr line")
    try expectEqual(TasksModel.failureReason(TasksResultRow(result: LatticeTaskResult(taskID: "t", nodeID: "a", exitCode: 1, error: "timeout"), stderrHead: "ignored")), "exit 1: timeout", "agent error first")
    try expectEqual(TasksModel.failureReason(TasksResultRow(result: LatticeTaskResult(taskID: "t", nodeID: "a", exitCode: 3))), "exit 3", "exit code alone")

    let facts = TasksModel.scriptFacts(try tasksTask(#"{"id":"t","interpreter":"sh","script_sha256":"3f9a1c2b7d4e5f60718293a4","script_size_bytes":31,"timeout_sec":300}"#))
    try expectEqual(facts, "sh, 31 bytes, sha256 3f9a1c2b7d4e…, timeout 5 min", "script facts")
    try expectEqual(TasksModel.scriptFacts(try tasksTask(#"{"id":"t","timeout_sec":0}"#)), "", "unread clauses are left out")

    let approval = try tasksTask(#"{"id":"t","approval_id":"ap1","origin":"approval"}"#)
    try expectEqual(TasksModel.origin(of: approval), .approval(id: "ap1"), "approval origin")
    try expectEqual(TasksModel.origin(of: try tasksTask(#"{"id":"t","rerun_of_task_id":"t0"}"#)), .rerun(of: "t0", node: ""), "rerun origin from an older server")
    try expectEqual(TasksModel.origin(of: try tasksTask(#"{"id":"t","actor_id":"admin"}"#)).word, "direct", "direct origin")
}

private func checkTasksTokens() throws {
    let words = TasksTokens.scan(#"status:failed node:"edge tyo 1" "node:x" free"#)
    try expectEqual(words.map(\.word), ["status:failed", "node:edge tyo 1", "node:x", "free"], "scan honours quotes")
    try expectEqual(words[2].bare, 0, "a quoted key is text")

    let resolvers: [String: @Sendable (String) -> String?] = ["node": { $0 == "edge-tyo-1" ? "n-edge-tyo-1" : ($0.hasPrefix("n-") ? $0 : nil) }]
    let parsed = TasksTokens.parse("status:failed,STALLED status:bogus origin:approval node:edge-tyo-1 approval:ap1 \"node:x\" words", grammar: TasksModel.grammar, resolvers: resolvers)
    try expectEqual(parsed.enums["status"], ["stalled", "failed"], "enums add up in canonical order")
    try expectEqual(parsed.enums["origin"], ["approval"], "origin enum")
    try expectEqual(parsed.values["node"], "n-edge-tyo-1", "node name resolves to its id")
    try expectEqual(parsed.values["approval"], "ap1", "approval value")
    try expectEqual(parsed.text, "node:x words", "free text kept apart")
    try expectEqual(parsed.problems, [TasksTokenProblem(token: "status:bogus", kind: .unknownValue)], "unknown enum value reported")

    let unresolved = TasksTokens.parse("node:nowhere node: ", grammar: TasksModel.grammar, resolvers: resolvers)
    try expectEqual(unresolved.problems.map(\.kind), [.unresolved, .emptyValue], "unresolved and empty tokens reported")
    try expectEqual(unresolved.values["node"], "nowhere", "an unresolved node is sent as typed")
    try expectEqual(TasksTokens.parse("status:running", grammar: TasksModel.grammar).enums["status"], ["leased"], "running reads as leased")
    // Quotes survive the alias: a quoted node name stays one value, a quoted key stays text.
    let quoted = TasksTokens.parse(#"status:Running node:"edge tyo 1" "node:x""#, grammar: TasksModel.grammar)
    try expectEqual(quoted.values["node"], "edge tyo 1", "a quoted node name is one value")
    try expectEqual(quoted.text, "node:x", "a quoted key is text")
    try expectEqual(quoted.enums["status"], ["leased"], "the alias applies after parsing")
}

private func checkTasksFilter() throws {
    let filter = TasksModel.filter(TasksTokens.parse("status:failed origin:approval,rerun node:n1 approval:ap", grammar: TasksModel.grammar), since: Date(timeIntervalSince1970: 1_000))
    let items = Dictionary(uniqueKeysWithValues: filter.query(limit: 50, offset: 50).queryItems.map { ($0.name, $0.value ?? "") })
    try expectEqual(items["status"], "failed", "status sent")
    try expectEqual(items["node_id"], "n1", "node sent")
    try expectEqual(items["limit"], "50", "limit always sent")
    try expect(items["since"] != nil, "since sent")
    try expectEqual(items["origin"], "approval,rerun", "origin sent as a comma list")
    try expectEqual(items["approval_id"], "ap", "approval sent")
    try expectEqual(items["offset"], "50", "offset sent")

    let match = try tasksTask(#"{"id":"a","targets":["n1"],"status":"failed","approval_id":"ap","origin":"approval","created_at":"1970-01-01T00:30:00Z"}"#)
    try expect(filter.matches(match), "a matching row")
    let direct = try tasksTask(#"{"id":"b","targets":["n1"],"status":"failed","origin":"direct","created_at":"1970-01-01T00:30:00Z"}"#)
    try expect(!filter.matches(direct), "origin guarded on device for an older server")

    let sorted = TasksModel.sorted([
        try tasksTask(#"{"id":"old","status":"finished","created_at":"2026-10-28T10:00:00Z"}"#),
        try tasksTask(#"{"id":"new","status":"failed","created_at":"2026-10-28T11:00:00Z"}"#),
        try tasksTask(#"{"id":"live","status":"leased","created_at":"2026-10-27T11:00:00Z"}"#),
    ])
    try expectEqual(sorted.map(\.id), ["live", "new", "old"], "running first, then newest")
}

// MARK: Intents

private func checkTasksIntentFlows() async throws {
    let task = try tasksTask(#"{"id":"task_a","targets":["n1","n2","n3"],"status":"failed","timeout_sec":300}"#)

    // T3 and T4 send nothing when Face ID is cancelled.
    for intent in [TasksIntents.rerun(task), TasksIntents.rerunNode(task, nodeID: "n1", nodeName: "edge-1"), TasksIntents.delete(task)] {
        let (client, transport) = tasksMock([:])
        let result = await WriteFlow(intent: intent, client: client, authenticator: TasksAuthStub(outcome: .cancelled)).commit(choices: ConfirmChoices())
        guard case .cancelled = result else { throw CheckFailure.failed("\(intent.title) did not cancel") }
        try expectEqual(await transport.requestURLs.count, 0, "\(intent.title) sent nothing after a cancelled authentication")
    }
    try expectEqual(TasksIntents.cancel(task).tier, .t2, "cancel is T2")
    try expectEqual(TasksIntents.rerun(task).tier, .t3, "rerun is T3")
    try expectEqual(TasksIntents.rerunNode(task, nodeID: "n1", nodeName: "edge-1").tier, .t3, "rerun node is T3")
    try expectEqual(TasksIntents.delete(task).tier, .t4, "delete is T4")
    try expectEqual(TasksIntents.delete(task).title, "Delete task task_a", "delete names the task")
    try expectEqual(TasksIntents.revealScript(task).scopes, ["task:read"], "reveal needs task:read on the session")
    try expect(TasksIntents.rerunFailed(task, nodes: []).consequence.hasPrefix("Each node becomes a separate task run."), "rerun failed says each node is its own run")

    // Rerun failed: sequential calls, per-node outcomes, partial when one is refused.
    let nodes = ["n1", "n2", "n3"].map { ObjectRef(kind: "node", id: $0, name: "edge-\($0)") }
    let transport = SequencedRerunTransport(statuses: [200, 409, 200])
    let client = LatticeClient(baseURL: URL(string: tasksBase)!, credential: LatticeCredential(bearerToken: "lat_check.notasecret"), transport: transport)
    let result = await WriteFlow(intent: TasksIntents.rerunFailed(task, nodes: nodes), client: client, authenticator: TasksAuthStub(outcome: .confirmed)).commit(choices: ConfirmChoices())
    guard case .finished(.partial(let succeeded, let failed, let message)) = result else { throw CheckFailure.failed("rerun failed should be partial, got \(result)") }
    try expectEqual(succeeded.map(\.id), ["n1", "n3"], "rerun failed succeeded nodes")
    try expectEqual(failed.map(\.object.id), ["n2"], "rerun failed refused node")
    try expectEqual(message, "2 queued, 1 not queued", "partial message")
    let bodies = await transport.bodies
    try expectEqual(try bodies.map { try tasksCanonical($0) }, ["n1", "n2", "n3"].map { #"{"id":"task_a","node_id":"\#($0)"}"# }, "one rerun-node call per node, in order")

    // A lost answer is unconfirmed, never "not queued" (section 6.7).
    let lossy = SequencedRerunTransport(statuses: [200, 409, 0])
    let lossyClient = LatticeClient(baseURL: URL(string: tasksBase)!, credential: LatticeCredential(bearerToken: "lat_check.notasecret"), transport: lossy)
    let mixed = await WriteFlow(intent: TasksIntents.rerunFailed(task, nodes: nodes), client: lossyClient, authenticator: TasksAuthStub(outcome: .confirmed)).commit(choices: ConfirmChoices())
    guard case .finished(.partial(_, let mixedFailed, let mixedMessage)) = mixed else { throw CheckFailure.failed("a lost rerun among others should be partial, got \(mixed)") }
    try expectEqual(mixedMessage, "1 queued, 1 not queued, 1 not confirmed", "a lost node is counted apart")
    try expect(mixedFailed.last?.reason.hasPrefix("Could not confirm") == true, "the lost node says it is unconfirmed")
    try expectEqual(await lossy.bodies.count, 3, "a lost rerun is not retried")
    let allLost = SequencedRerunTransport(statuses: [0])
    let allLostClient = LatticeClient(baseURL: URL(string: tasksBase)!, credential: LatticeCredential(bearerToken: "lat_check.notasecret"), transport: allLost)
    let unknown = await WriteFlow(intent: TasksIntents.rerunFailed(task, nodes: [nodes[0]]), client: allLostClient, authenticator: TasksAuthStub(outcome: .confirmed)).commit(choices: ConfirmChoices())
    guard case .finished(.unknown(let unknownText)) = unknown else { throw CheckFailure.failed("a lost single rerun should be unknown, got \(unknown)") }
    try expect(unknownText.contains("edge-n1") && unknownText.contains("Check the task list"), "names the node and says what to check: \(unknownText)")
    try expectEqual(await allLost.bodies.count, 1, "a lost single rerun is not retried")

    // A refusal from the server is an outcome, not a thrown error.
    let (refusing, _) = tasksMock(["\(tasksBase)/api/tasks/cancel": (409, json(#"{"error":"only queued tasks can be cancelled","code":"bad_request"}"#))])
    let refused = await WriteFlow(intent: TasksIntents.cancel(task), client: refusing, authenticator: TasksAuthStub(outcome: .confirmed)).commit(choices: ConfirmChoices())
    guard case .finished(.refused(_, let text)) = refused else { throw CheckFailure.failed("cancel refusal should be refused") }
    try expect(text.contains("only queued"), "the server's reason is kept: \(text)")
}

/// Answers each rerun-node call with the next status, recording bodies.
/// Status 0 times out after the request was sent.
private actor SequencedRerunTransport: HTTPTransport {
    private var statuses: [Int]
    private(set) var bodies: [Data?] = []

    init(statuses: [Int]) { self.statuses = statuses }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        bodies.append(request.httpBody)
        let status = statuses.isEmpty ? 500 : statuses.removeFirst()
        if status == 0 { throw URLError(.timedOut) }
        let body = status == 200
            ? #"{"id":"task_r","targets":["n"],"status":"queued","created_at":"2026-10-28T12:00:00Z"}"#
            : #"{"error":"node n2 is managed by NetGuard","code":"conflict"}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

// MARK: Demo

private func checkTasksDemo() async throws {
    let client = tasksDemo()
    let page = try await client.tasksResults(TasksResultsQuery(taskIDs: ["task_d02", "task_d03"]))
    try expect(page.results.count >= 4, "the omit_output read answers a comma list")
    try expect(page.results.allSatisfy { $0.result.stdout.isEmpty }, "bodies left out")
    let failing = try expectUnwrapped(page.results.first { $0.result.exitCode != 0 && $0.result.taskID == "task_d02" }, "failed result")
    try expect(failing.stderrHead.contains("sing-box.service"), "stderr head kept")

    let list = try await client.listTasks(query: TaskQuery(limit: 50))
    let states = Set(list.tasks.map { TaskRunState(serverValue: $0.status) })
    for state in TaskRunState.allCases {
        try expect(states.contains(state), "demo tasks cover \(state)")
    }
    let found = try await client.tasksFind(id: "task_d04")
    let absent = try await client.tasksFind(id: "task_nope")
    try expect(found != nil, "find by id")
    try expect(absent == nil, "absent id is nil")

    let finished = try expectUnwrapped(list.tasks.first { $0.id == "task_d01" }, "finished demo task")
    // The demo token is the Operator preset, which holds no task:run.
    do {
        _ = try await client.cancelTask(id: "task_d06")
        throw CheckFailure.failed("the Operator preset must not cancel a task")
    } catch LatticeAPIError.forbidden {}
    let writer = tasksDemo(.session)
    do {
        _ = try await writer.cancelTask(id: finished.id)
        throw CheckFailure.failed("cancelling a finished task must be refused")
    } catch LatticeAPIError.conflict(_, let message, _) {
        try expect(message.contains("only queued"), "demo refusal text")
    }
    let queued = try await writer.cancelTask(id: "task_d06")
    try expectEqual(queued.status, "cancelled", "demo cancel")
    let rerun = try await writer.tasksRerunNode(id: "task_d02", nodeID: DemoWorld.node("edge-hkg-2").id)
    try expectEqual(rerun.rerunOfTaskID, "task_d02", "demo rerun names its source")
    try expectEqual(rerun.targets, [DemoWorld.node("edge-hkg-2").id], "demo rerun-node runs on one node")

    // The reveal needs a session and a grant.
    do {
        _ = try await client.tasksRevealScript(id: "task_d02", grant: StepUpGrant(grant: "g", expiresAt: Date().addingTimeInterval(60)))
        throw CheckFailure.failed("a token must not reveal a script")
    } catch LatticeAPIError.forbidden(let code, _) {
        try expectEqual(code, "secret_reveal_scope_required", "a token is refused with the server's reveal scope code")
    }
    let session = tasksDemo(.session)
    let script = try await session.tasksRevealScript(id: "task_d02", grant: StepUpGrant(grant: "grant_demo_notasecret", expiresAt: Date().addingTimeInterval(60)))
    try expect(script.script.contains("systemctl restart sing-box"), "demo script")
    try expectEqual(script.scriptSHA256, PlanHasher.sha256Hex(script.script), "demo script digest matches its body")
}
