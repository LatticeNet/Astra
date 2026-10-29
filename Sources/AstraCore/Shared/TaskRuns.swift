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
    public var since: Date?
    public var limit: Int?
    public var offset: Int?

    public init(statuses: [String] = [], nodeID: String? = nil, since: Date? = nil, limit: Int? = nil, offset: Int? = nil) {
        self.statuses = statuses
        self.nodeID = nodeID
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
    /// The run state of `lib/taskLease.ts`, including pending, stalled and expired.
    func runState(now: Date) -> TaskRunState {
        // M0a: implement. Port taskLease.ts (stalled from lease heartbeats, expired from the lease deadline).
        TaskRunState(serverValue: status)
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
