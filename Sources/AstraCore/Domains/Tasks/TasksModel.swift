import Foundation

/// Pure rules of the Tasks screens, ported from the console's
/// `views/operations/tasksModel.ts` and `lib/taskLease.ts`.
public enum TasksModel {
    /// Rows per page of the Runs list.
    public static let pageSize = 50
    /// The newest rows a deep link reads to find one run (section 2.5).
    public static let lookupLimit = 200

    /// The statuses `GET /api/tasks` accepts, in the order the field writes them.
    public static let statuses = ["pending", "queued", "leased", "stalled", "failed", "finished", "cancelled", "expired"]
    public static let origins = ["approval", "rerun", "direct"]

    /// `status`, `node`, `origin` and `approval`. The task list has no text
    /// search, so free words are reported rather than sent.
    public static let grammar = TasksTokenGrammar(fields: [
        TasksTokenField(key: "status", kind: .enumeration(statuses)),
        TasksTokenField(key: "node", resolve: "node"),
        TasksTokenField(key: "origin", kind: .enumeration(origins)),
        TasksTokenField(key: "approval"),
    ])

    /// `running` is the word an operator types for a leased run.
    public static func normalizedQuery(_ text: String) -> String {
        TasksTokens.scan(text).map { word in
            word.word.lowercased().hasPrefix("status:") ? word.word.replacingOccurrences(of: "running", with: "leased", options: .caseInsensitive) : word.word
        }.joined(separator: " ")
    }

    // MARK: Liveness

    /// A run that can still change on its own: waiting, running or stalled.
    public static func isLive(_ status: String) -> Bool {
        ["queued", "pending", "leased", "running", "stalled"].contains(status)
    }

    /// The server cancels every live run (nothing ran yet, or nothing is answering).
    public static func isCancellable(_ status: String) -> Bool {
        isLive(status)
    }

    // MARK: Results

    public static func resultFailed(_ result: LatticeTaskResult) -> Bool {
        !result.error.isEmpty || result.exitCode != 0
    }

    /// The newest result per node.
    public static func latestByNode(_ rows: [TasksResultRow]) -> [String: TasksResultRow] {
        var out: [String: TasksResultRow] = [:]
        for row in rows {
            let time = row.result.finishedAt ?? .distantPast
            if let held = out[row.result.nodeID], (held.result.finishedAt ?? .distantPast) > time { continue }
            out[row.result.nodeID] = row
        }
        return out
    }

    /// "exit 127: sh: 1: curl: not found": the exit code, then the agent's
    /// error, the stderr head, or the first non-empty stderr line.
    public static func failureReason(_ row: TasksResultRow) -> String {
        let exit = "exit \(row.result.exitCode)"
        let firstStderr = row.result.stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        let candidates = [row.result.error.trimmingCharacters(in: .whitespaces), row.stderrHead.trimmingCharacters(in: .whitespaces), firstStderr ?? ""]
        guard let detail = candidates.first(where: { !$0.isEmpty }) else { return exit }
        return "\(exit): \(detail)"
    }

    // MARK: Run summary

    /// The targets that answered and how (`runSummary`).
    public static func summary(of task: LatticeTask, results: [TasksResultRow]) -> TasksRunSummary {
        let latest = latestByNode(results)
        var seen: Set<String> = []
        var passed = 0
        var failed = 0
        var firstFailure: TasksResultRow?
        var total = 0
        for node in task.targets where !seen.contains(node) {
            seen.insert(node)
            total += 1
            guard let row = latest[node] else { continue }
            if resultFailed(row.result) {
                failed += 1
                if firstFailure == nil { firstFailure = row }
            } else {
                passed += 1
            }
        }
        return TasksRunSummary(total: total, passed: passed, failed: failed, firstFailure: firstFailure)
    }

    /// The list row's count, "12 ok, 2 failed". Nil before any node reports,
    /// and nil when the results read stopped short (a failure may be unread).
    public static func listProgress(_ summary: TasksRunSummary, complete: Bool = true) -> String? {
        guard complete, summary.reported > 0 else { return nil }
        var parts = ["\(summary.passed) ok"]
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        return parts.joined(separator: ", ")
    }

    /// The run header's count while live: "9 of 12 finished, 1 failed".
    /// A running task never shows a spinner, only this (section 4.2).
    public static func liveProgress(_ summary: TasksRunSummary) -> String {
        var line = "\(summary.reported) of \(summary.total) finished"
        if summary.failed > 0 { line += ", \(summary.failed) failed" }
        return line
    }

    // MARK: Nodes

    /// Per-node rows, worst first: failed, stalled, expired, running,
    /// waiting, finished, cancelled (section 5.5, M4-02).
    public static func nodeRows(for task: LatticeTask, results: [TasksResultRow], now: Date) -> [TasksNodeRow] {
        let latest = latestByNode(results)
        var seen: Set<String> = []
        var rows: [TasksNodeRow] = []
        for node in task.targets where !seen.contains(node) {
            seen.insert(node)
            rows.append(nodeRow(task: task, nodeID: node, result: latest[node], now: now))
        }
        return rows.enumerated().sorted { a, b in
            a.element.state.tasksRank != b.element.state.tasksRank ? a.element.state.tasksRank < b.element.state.tasksRank : a.offset < b.offset
        }.map(\.element)
    }

    public static func nodeRow(task: LatticeTask, nodeID: String, result: TasksResultRow?, now: Date) -> TasksNodeRow {
        let state: TaskRunState
        if let result {
            state = resultFailed(result.result) ? .failed : .finished
        } else {
            state = task.runState(nodeID: nodeID, now: now)
        }
        let progress = task.leaseProgress(nodeID: nodeID)
        var reason: String?
        var reasonIsProblem = false
        var oldLease = false
        switch state {
        case .failed:
            reason = result.map(failureReason)
            reasonIsProblem = true
        case .stalled:
            reason = stalledText(progress)
            reasonIsProblem = true
        case .expired:
            reason = "Expired: the node never picked it up"
            reasonIsProblem = true
        case .leased:
            if let age = progress?.leaseAgeSeconds, isOldLease(age, timeout: task.timeoutSec) {
                oldLease = true
                reason = "No heartbeat for \(TaskLeaseProgress.formatLeaseAge(age))"
                reasonIsProblem = true
            } else if let label = progress?.label, !label.isEmpty {
                reason = label
            }
        case .cancelled:
            reason = result == nil ? "Cancelled before any agent ran it" : nil
        case .pending, .queued, .finished:
            break
        }
        let duration: TimeInterval? = {
            guard let start = result?.result.startedAt, let end = result?.result.finishedAt, end >= start else { return nil }
            return end.timeIntervalSince(start)
        }()
        return TasksNodeRow(
            nodeID: nodeID, state: state, result: result, attempts: progress.flatMap { $0.attempts > 0 ? $0 : nil },
            leaseAgeSeconds: progress?.leaseAgeSeconds, oldLease: oldLease, duration: duration,
            reason: reason, reasonIsProblem: reasonIsProblem
        )
    }

    /// A lease older than the run's own timeout has outlived anything the
    /// script could still be doing; the server gives up five minutes later.
    public static func isOldLease(_ age: Double, timeout: Int) -> Bool {
        age > Double(timeout > 0 ? timeout : 900)
    }

    /// `stalledText`: the server's reason with the attempt count, or the
    /// generic sentence an older server falls back to.
    public static func stalledText(_ progress: TaskLeaseProgress?) -> String {
        let label = progress?.label ?? ""
        return label.isEmpty ? "Nothing is running this and no result arrived; cancel it or rerun" : label
    }

    /// Nodes a "Rerun failed nodes" walks, in target order.
    public static func failedNodes(_ rows: [TasksNodeRow]) -> [String] {
        rows.filter { $0.state == .failed }.map(\.nodeID)
    }

    // MARK: Origin

    public static func origin(of task: LatticeTask) -> TasksOrigin {
        if !task.approvalID.isEmpty || task.origin == "approval" { return .approval(id: task.approvalID) }
        if !task.rerunOfTaskID.isEmpty || task.origin == "rerun" { return .rerun(of: task.rerunOfTaskID, node: task.rerunOfNodeID) }
        return .direct(actor: task.actorID)
    }

    /// "sh, 31 bytes, sha256 3f9a1c2b7d4e…, timeout 5 min" (`scriptClauses`);
    /// a clause whose value was not read is left out, never written as zero.
    public static func scriptFacts(_ task: LatticeTask) -> String {
        var parts: [String] = []
        if !task.interpreter.isEmpty { parts.append(task.interpreter) }
        if task.scriptSizeBytes > 0 { parts.append(task.scriptSizeBytes == 1 ? "1 byte" : "\(task.scriptSizeBytes) bytes") }
        if !task.scriptSHA256.isEmpty { parts.append("sha256 \(task.scriptSHA256.prefix(12))…") }
        if task.timeoutSec > 0 { parts.append("timeout \(TaskLeaseProgress.formatLeaseAge(Double(task.timeoutSec)))") }
        return parts.joined(separator: ", ")
    }

    // MARK: List

    /// What the Runs field asks for, as server filters plus the parts the
    /// Shared task query cannot send (origin, approval, an upper bound),
    /// which are applied on device.
    /// The list filters on `since` only and has no upper bound
    /// (`TASK_RANGES`), so a range here is a start, never a window.
    public static func filter(_ tokens: TasksParsedTokens, since: Date?) -> TasksListFilter {
        TasksListFilter(
            statuses: tokens.enums["status"] ?? [],
            nodeID: tokens.values["node"],
            origins: tokens.enums["origin"] ?? [],
            approvalID: tokens.values["approval"],
            since: since
        )
    }

    /// Running tasks first, then newest first (section 5.5, M4-01).
    public static func sorted(_ tasks: [LatticeTask]) -> [LatticeTask] {
        tasks.enumerated().sorted { a, b in
            let liveA = isLive(a.element.status), liveB = isLive(b.element.status)
            if liveA != liveB { return liveA }
            let timeA = a.element.createdAt ?? .distantPast, timeB = b.element.createdAt ?? .distantPast
            return timeA != timeB ? timeA > timeB : a.offset < b.offset
        }.map(\.element)
    }
}

public struct TasksRunSummary: Sendable, Hashable {
    /// Distinct targets.
    public var total: Int
    public var passed: Int
    public var failed: Int
    /// The first failing target in target order, for the row's reason.
    public var firstFailure: TasksResultRow?

    public init(total: Int, passed: Int, failed: Int, firstFailure: TasksResultRow? = nil) {
        self.total = total
        self.passed = passed
        self.failed = failed
        self.firstFailure = firstFailure
    }

    public var reported: Int { passed + failed }
}

/// One target of a run, as the run screen lists it.
public struct TasksNodeRow: Sendable, Hashable, Identifiable {
    public var nodeID: String
    public var state: TaskRunState
    public var result: TasksResultRow?
    /// Lease attempts, when the server counted any.
    public var attempts: TaskLeaseProgress?
    public var leaseAgeSeconds: Double?
    /// The lease outlived the run's timeout: shown in the warning style.
    public var oldLease: Bool
    public var duration: TimeInterval?
    /// The one line under the node: why it failed, stalled or expired, or its lease.
    public var reason: String?
    public var reasonIsProblem: Bool

    public var id: String { nodeID }

    public var attemptsText: String? {
        guard let attempts, attempts.attempts > 0, attempts.maxAttempts > 0 else { return nil }
        return "attempt \(attempts.attempts) of \(attempts.maxAttempts)"
    }
}

/// How a run was queued.
public enum TasksOrigin: Sendable, Hashable {
    case approval(id: String)
    case rerun(of: String, node: String)
    case direct(actor: String)

    public var word: String {
        switch self {
        case .approval: "approval"
        case .rerun: "rerun"
        case .direct: "direct"
        }
    }
}

/// The Runs question. Every part is a server filter (`parseTaskListFilter`),
/// so the server's total counts what the question matches.
public struct TasksListFilter: Sendable, Hashable {
    public var statuses: [String]
    public var nodeID: String?
    public var origins: [String]
    public var approvalID: String?
    public var since: Date?

    public init(statuses: [String] = [], nodeID: String? = nil, origins: [String] = [], approvalID: String? = nil, since: Date? = nil) {
        self.statuses = statuses
        self.nodeID = nodeID
        self.origins = origins
        self.approvalID = approvalID
        self.since = since
    }

    public var isEmpty: Bool {
        statuses.isEmpty && nodeID == nil && origins.isEmpty && approvalID == nil && since == nil
    }

    /// The request (`taskListRequest`). `limit` is always sent so the server pages.
    public func query(limit: Int, offset: Int) -> TasksListQuery {
        TasksListQuery(statuses: statuses, nodeID: nodeID, origins: origins, approvalID: approvalID, since: since, limit: limit, offset: offset)
    }

    /// Whether a row answers the question (`taskMatches`): a guard for an
    /// older server that ignored a filter.
    public func matches(_ task: LatticeTask) -> Bool {
        if !statuses.isEmpty, !statuses.contains(task.status == "running" ? "leased" : task.status) { return false }
        if !origins.isEmpty, !origins.contains(TasksModel.origin(of: task).word) { return false }
        if let nodeID, !task.targets.contains(nodeID) { return false }
        if let approvalID, task.approvalID != approvalID { return false }
        let changed = [task.createdAt, task.startedAt, task.finishedAt].compactMap { $0 }.max()
        if let since, (changed ?? .distantPast) < since { return false }
        return true
    }
}

public extension TaskRunState {
    /// The run screen's node order: failed, stalled, expired, running,
    /// waiting, finished, cancelled.
    var tasksRank: Int {
        switch self {
        case .failed: 0
        case .stalled: 1
        case .expired: 2
        case .leased: 3
        case .queued: 4
        case .pending: 5
        case .finished: 6
        case .cancelled: 7
        }
    }
}

/// A task as Browse search sees it: the run and its targets' names.
public struct TasksSearchRow: Sendable, Hashable {
    public var task: LatticeTask
    public var nodeNames: [String]

    public init(task: LatticeTask, nodeNames: [String]) {
        self.task = task
        self.nodeNames = nodeNames
    }
}

/// The fields Browse search filters tasks with (section 6.14).
public enum TasksQueryFields: QueryFieldProvider {
    public typealias Row = TasksSearchRow

    public static var fields: [LatticeQueryField<TasksSearchRow>] {
        [
            LatticeQueryField(key: "status", aliases: ["state"], type: .enumeration, values: TasksModel.statuses, valueAliases: ["running": "leased", "canceled": "cancelled"],
                              get: { .string($0.task.status == "running" ? "leased" : $0.task.status) }),
            LatticeQueryField(key: "origin", type: .enumeration, values: TasksModel.origins, get: { .string(TasksModel.origin(of: $0.task).word) }),
            LatticeQueryField(key: "node", aliases: ["target"], type: .list, get: { .strings($0.nodeNames + $0.task.targets) }),
            LatticeQueryField(key: "approval", type: .string, get: { .string($0.task.approvalID) }),
            LatticeQueryField(key: "actor", type: .string, get: { .string($0.task.actorID) }),
        ]
    }

    public static func text(_ row: TasksSearchRow) -> [String] {
        [row.task.id, row.task.actorID] + row.nodeNames + row.task.targets
    }
}
