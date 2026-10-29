import Foundation

/// Mirrors the server `taskView`: the script body is never returned, only its
/// SHA-256 and size.
public struct LatticeTask: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var actorID: String
    public var tokenID: String
    public var targets: [String]
    public var interpreter: String
    public var scriptSHA256: String
    public var scriptSizeBytes: Int
    public var timeoutSec: Int
    public var outputLimit: Int
    public var status: String
    public var leasedBy: String
    public var createdAt: Date?
    public var startedAt: Date?
    public var finishedAt: Date?
    /// The approval that queued the task, when one did.
    public var approvalID: String = ""
    /// `approval`, `rerun` or `direct`; empty from an older server.
    public var origin: String = ""
    public var rerunOfTaskID: String = ""
    public var rerunOfNodeID: String = ""
    /// Lease progress of a single-target task (servers that count attempts).
    public var attempts: Int = 0
    public var maxAttempts: Int = 0
    public var leaseAgeSeconds: Double?
    /// Why the store stopped re-leasing, verbatim from the server.
    public var stalledReason: String = ""
    /// The same progress per node for a fan-out.
    public var targetStates: [String: LatticeTaskTargetState] = [:]

    public init(id: String, actorID: String = "", tokenID: String = "", targets: [String] = [], interpreter: String = "", scriptSHA256: String = "", scriptSizeBytes: Int = 0, timeoutSec: Int = 0, outputLimit: Int = 0, status: String = "", leasedBy: String = "", createdAt: Date? = nil, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.id = id
        self.actorID = actorID
        self.tokenID = tokenID
        self.targets = targets
        self.interpreter = interpreter
        self.scriptSHA256 = scriptSHA256
        self.scriptSizeBytes = scriptSizeBytes
        self.timeoutSec = timeoutSec
        self.outputLimit = outputLimit
        self.status = status
        self.leasedBy = leasedBy
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, targets, interpreter, status
        case actorID = "actor_id"
        case tokenID = "token_id"
        case scriptSHA256 = "script_sha256"
        case scriptSizeBytes = "script_size_bytes"
        case timeoutSec = "timeout_sec"
        case outputLimit = "output_limit"
        case leasedBy = "leased_by"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case approvalID = "approval_id"
        case origin, attempts
        case rerunOfTaskID = "rerun_of_task_id"
        case rerunOfNodeID = "rerun_of_node_id"
        case maxAttempts = "max_attempts"
        case leaseAgeSeconds = "lease_age_seconds"
        case stalledReason = "stalled_reason"
        case targetStates = "target_states"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        actorID = try container.decodeIfPresent(String.self, forKey: .actorID) ?? ""
        tokenID = try container.decodeIfPresent(String.self, forKey: .tokenID) ?? ""
        targets = try container.decodeIfPresent([String].self, forKey: .targets) ?? []
        interpreter = try container.decodeIfPresent(String.self, forKey: .interpreter) ?? ""
        scriptSHA256 = try container.decodeIfPresent(String.self, forKey: .scriptSHA256) ?? ""
        scriptSizeBytes = try container.decodeIfPresent(Int.self, forKey: .scriptSizeBytes) ?? 0
        timeoutSec = try container.decodeIfPresent(Int.self, forKey: .timeoutSec) ?? 0
        outputLimit = try container.decodeIfPresent(Int.self, forKey: .outputLimit) ?? 0
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        leasedBy = try container.decodeIfPresent(String.self, forKey: .leasedBy) ?? ""
        createdAt = try DateValue.decodeIfPresent(from: container, forKey: .createdAt)
        startedAt = try DateValue.decodeIfPresent(from: container, forKey: .startedAt)
        finishedAt = try DateValue.decodeIfPresent(from: container, forKey: .finishedAt)
        approvalID = try container.decodeIfPresent(String.self, forKey: .approvalID) ?? ""
        origin = try container.decodeIfPresent(String.self, forKey: .origin) ?? ""
        rerunOfTaskID = try container.decodeIfPresent(String.self, forKey: .rerunOfTaskID) ?? ""
        rerunOfNodeID = try container.decodeIfPresent(String.self, forKey: .rerunOfNodeID) ?? ""
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        maxAttempts = try container.decodeIfPresent(Int.self, forKey: .maxAttempts) ?? 0
        leaseAgeSeconds = try container.decodeIfPresent(Double.self, forKey: .leaseAgeSeconds)
        stalledReason = try container.decodeIfPresent(String.self, forKey: .stalledReason) ?? ""
        targetStates = try container.decodeIfPresent([String: LatticeTaskTargetState].self, forKey: .targetStates) ?? [:]
    }
}

/// One node's share of a fan-out task (`TaskTargetStateView`).
public struct LatticeTaskTargetState: Codable, Equatable, Hashable, Sendable {
    /// `queued`, `leased`, `finished`, `failed` or `stalled`.
    public var status: String
    public var attempts: Int
    public var maxAttempts: Int
    public var leaseAgeSeconds: Double?
    public var stalledReason: String

    public init(status: String, attempts: Int = 0, maxAttempts: Int = 0, leaseAgeSeconds: Double? = nil, stalledReason: String = "") {
        self.status = status
        self.attempts = attempts
        self.maxAttempts = maxAttempts
        self.leaseAgeSeconds = leaseAgeSeconds
        self.stalledReason = stalledReason
    }

    enum CodingKeys: String, CodingKey {
        case status, attempts
        case maxAttempts = "max_attempts"
        case leaseAgeSeconds = "lease_age_seconds"
        case stalledReason = "stalled_reason"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        maxAttempts = try c.decodeIfPresent(Int.self, forKey: .maxAttempts) ?? 0
        leaseAgeSeconds = try c.decodeIfPresent(Double.self, forKey: .leaseAgeSeconds)
        stalledReason = try c.decodeIfPresent(String.self, forKey: .stalledReason) ?? ""
    }
}

/// How far a leased task has got on one node (`lib/taskLease.ts`
/// `TaskLeaseProgress`): the attempts the store counted and why it gave up.
public struct TaskLeaseProgress: Sendable, Hashable {
    /// Per-target status when the server sent one; nil for the task-level scalars.
    public var status: String?
    public var attempts: Int
    public var maxAttempts: Int
    public var leaseAgeSeconds: Double?
    public var stalledReason: String?

    public init(status: String? = nil, attempts: Int, maxAttempts: Int, leaseAgeSeconds: Double? = nil, stalledReason: String? = nil) {
        self.status = status
        self.attempts = attempts
        self.maxAttempts = maxAttempts
        self.leaseAgeSeconds = leaseAgeSeconds
        self.stalledReason = stalledReason
    }

    /// `formatLeaseAge`: "30 s", "41 min", "2 h 5 min", "6 d 2 h"; two units at most.
    public static func formatLeaseAge(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days) d \(hours) h" : "\(days) d" }
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total) s"
    }

    /// `leaseAttemptLabel`: "leased 41 min, attempt 2 of 3" while a lease is
    /// held, the stalled reason once the store gave up (attempt count kept as
    /// its evidence), and "" when there is nothing to say.
    public var label: String {
        var parts: [String] = []
        if let stalledReason, !stalledReason.isEmpty {
            parts.append(Self.unterminate(stalledReason))
        } else if let leaseAgeSeconds {
            parts.append("leased \(Self.formatLeaseAge(leaseAgeSeconds))")
        }
        if attempts > 0, maxAttempts > 0 {
            parts.append("attempt \(attempts) of \(maxAttempts)")
        }
        return parts.joined(separator: ", ")
    }

    /// Strips the punctuation a sentence ends on, so the attempt count joins with a comma.
    private static func unterminate(_ sentence: String) -> String {
        let trailing: Set<Character> = [" ", "\t", "\n", ".", ";", ",", "\u{3002}", "\u{FF1B}", "\u{FF0C}"]
        var text = Substring(sentence)
        while let last = text.last, trailing.contains(last) { text = text.dropLast() }
        return String(text)
    }
}

public struct LatticeTaskResult: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var taskID: String
    public var nodeID: String
    public var exitCode: Int
    public var stdout: String
    public var stderr: String
    public var error: String
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(taskID: String, nodeID: String, exitCode: Int = 0, stdout: String = "", stderr: String = "", error: String = "", startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.taskID = taskID
        self.nodeID = nodeID
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var id: String { "\(taskID).\(nodeID)" }

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case nodeID = "node_id"
        case exitCode = "exit_code"
        case stdout, stderr, error
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try container.decodeIfPresent(String.self, forKey: .taskID) ?? ""
        nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode) ?? 0
        stdout = try container.decodeIfPresent(String.self, forKey: .stdout) ?? ""
        stderr = try container.decodeIfPresent(String.self, forKey: .stderr) ?? ""
        error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
        startedAt = try DateValue.decodeIfPresent(from: container, forKey: .startedAt)
        finishedAt = try DateValue.decodeIfPresent(from: container, forKey: .finishedAt)
    }
}

public extension LatticeClient {
    // Tasks
    func listTasks() async throws -> [LatticeTask] {
        try await perform([LatticeTask].self, path: "/api/tasks")
    }

    func listTaskResults() async throws -> [LatticeTaskResult] {
        try await perform([LatticeTaskResult].self, path: "/api/task-results")
    }
}

/// `GET /api/tasks/counts`: rows by status, and runs settled in the last 24 h.
public struct TaskCounts: Decodable, Equatable, Sendable {
    public var pending: Int
    public var queued: Int
    public var running: Int
    public var stalled: Int
    public var failed24h: Int
    public var finished24h: Int
    public var total: Int
    public var generatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case pending, queued, running, stalled, total
        case failed24h = "failed_24h"
        case finished24h = "finished_24h"
        case generatedAt = "generated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pending = try c.decodeIfPresent(Int.self, forKey: .pending) ?? 0
        queued = try c.decodeIfPresent(Int.self, forKey: .queued) ?? 0
        running = try c.decodeIfPresent(Int.self, forKey: .running) ?? 0
        stalled = try c.decodeIfPresent(Int.self, forKey: .stalled) ?? 0
        failed24h = try c.decodeIfPresent(Int.self, forKey: .failed24h) ?? 0
        finished24h = try c.decodeIfPresent(Int.self, forKey: .finished24h) ?? 0
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        generatedAt = try DateValue.decodeIfPresent(from: c, forKey: .generatedAt)
    }
}

/// Filters for `GET /api/tasks`. Any filter switches the server to the
/// `{tasks, total, limit, offset}` envelope.
public struct TaskQuery: Sendable, Hashable {
    /// Comma-joined on the wire: `failed,stalled`.
    public var statuses: [String]
    public var nodeID: String?
    /// Comma-joined on the wire: `approval,rerun`.
    public var origins: [String]
    public var approvalID: String?
    public var since: Date?
    public var limit: Int?
    public var offset: Int?

    public init(statuses: [String] = [], nodeID: String? = nil, origins: [String] = [], approvalID: String? = nil, since: Date? = nil, limit: Int? = nil, offset: Int? = nil) {
        self.statuses = statuses
        self.nodeID = nodeID
        self.origins = origins
        self.approvalID = approvalID
        self.since = since
        self.limit = limit
        self.offset = offset
    }

    public var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if !statuses.isEmpty { items.append(URLQueryItem(name: "status", value: statuses.joined(separator: ","))) }
        if let nodeID, !nodeID.isEmpty { items.append(URLQueryItem(name: "node_id", value: nodeID)) }
        if let since { items.append(URLQueryItem(name: "since", value: AstraDateParser.string(from: since))) }
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let offset { items.append(URLQueryItem(name: "offset", value: String(offset))) }
        if !origins.isEmpty { items.append(URLQueryItem(name: "origin", value: origins.joined(separator: ","))) }
        if let approvalID, !approvalID.isEmpty { items.append(URLQueryItem(name: "approval_id", value: approvalID)) }
        return items
    }
}

/// The envelope form of `GET /api/tasks`.
public struct TaskListResponse: Decodable, Equatable, Sendable {
    public var tasks: [LatticeTask]
    public var total: Int
    public var limit: Int
    public var offset: Int

    enum CodingKeys: String, CodingKey { case tasks, total, limit, offset }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decodeIfPresent([LatticeTask].self, forKey: .tasks) ?? []
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? tasks.count
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 0
        offset = try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0
    }
}

public extension LatticeTask {
    /// The run state of `lib/taskLease.ts`, including pending, stalled and
    /// expired. The server derives all three (expired when the queue
    /// deadline passed, stalled when the store stopped re-leasing after its
    /// attempts), so the phone reads the word rather than guessing from
    /// clocks; `now` is kept for the frozen signature.
    func runState(now: Date) -> TaskRunState {
        TaskRunState(serverValue: status)
    }

    /// One node's share: its target record when the server sent one, else
    /// the task's own state. A node that has a result is settled by it.
    func runState(nodeID: String, result: LatticeTaskResult? = nil, now: Date) -> TaskRunState {
        if let result, result.finishedAt != nil || !result.error.isEmpty || result.exitCode != 0 {
            return result.exitCode == 0 && result.error.isEmpty ? .finished : .failed
        }
        if let target = targetStates[nodeID] { return TaskRunState(serverValue: target.status) }
        return runState(now: now)
    }

    /// `taskLeaseProgress`: the per-target record, or the task-level scalars
    /// when the task has one target or no node is named.
    func leaseProgress(nodeID: String? = nil) -> TaskLeaseProgress? {
        if let nodeID, let target = targetStates[nodeID] {
            return TaskLeaseProgress(
                status: target.status,
                attempts: target.attempts,
                maxAttempts: target.maxAttempts,
                leaseAgeSeconds: target.leaseAgeSeconds,
                stalledReason: target.stalledReason.isEmpty ? nil : target.stalledReason
            )
        }
        if nodeID != nil, targets.count != 1 { return nil }
        if attempts == 0, stalledReason.isEmpty { return nil }
        return TaskLeaseProgress(
            attempts: attempts,
            maxAttempts: maxAttempts,
            leaseAgeSeconds: leaseAgeSeconds,
            stalledReason: stalledReason.isEmpty ? nil : stalledReason
        )
    }
}

public extension LatticeClient {
    /// `GET /api/tasks` with filters, always in the envelope form.
    func listTasks(query: TaskQuery) async throws -> TaskListResponse {
        var items = query.queryItems
        if items.isEmpty { items = [URLQueryItem(name: "limit", value: "200")] }
        return try await perform(TaskListResponse.self, path: "/api/tasks", query: items)
    }

    func fetchTaskCounts() async throws -> TaskCounts {
        try await perform(TaskCounts.self, path: "/api/tasks/counts")
    }

    /// `GET /api/task-results?task_id=`, bare or enveloped.
    func listTaskResults(taskID: String) async throws -> [LatticeTaskResult] {
        let data = try await performData(path: "/api/task-results", query: [URLQueryItem(name: "task_id", value: taskID)])
        return try LatticeListDecoder.decode(LatticeTaskResult.self, from: data, key: "results")
    }
}
