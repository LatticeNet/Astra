import Foundation

struct TaskIDRequest: Encodable {
    var id: String
}

/// `POST /api/tasks/rerun-node {id, node_id}`.
public struct TasksRerunNodeRequest: Encodable, Sendable, Hashable {
    public var id: String
    public var nodeID: String

    public init(id: String, nodeID: String) {
        self.id = id
        self.nodeID = nodeID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
    }
}

/// `POST /api/tasks/reveal-script {id, step_up_grant}`.
public struct TasksRevealScriptRequest: Encodable, Sendable, Hashable {
    public var id: String
    public var stepUpGrant: String

    public init(id: String, stepUpGrant: String) {
        self.id = id
        self.stepUpGrant = stepUpGrant
    }

    enum CodingKeys: String, CodingKey {
        case id
        case stepUpGrant = "step_up_grant"
    }
}

/// The answer of `POST /api/tasks/reveal-script` (`handleRevealTaskScript`).
public struct TasksScriptReveal: Decodable, Sendable, Hashable {
    public var ok: Bool
    public var id: String
    public var interpreter: String
    public var script: String
    public var scriptSHA256: String
    public var scriptSizeBytes: Int

    enum CodingKeys: String, CodingKey {
        case ok, id, interpreter, script
        case scriptSHA256 = "script_sha256"
        case scriptSizeBytes = "script_size_bytes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        interpreter = try c.decodeIfPresent(String.self, forKey: .interpreter) ?? ""
        // The script is the point of the call: a body without it is not this shape.
        script = try c.decode(String.self, forKey: .script)
        scriptSHA256 = try c.decodeIfPresent(String.self, forKey: .scriptSHA256) ?? ""
        scriptSizeBytes = try c.decodeIfPresent(Int.self, forKey: .scriptSizeBytes) ?? 0
    }
}

/// The agent posture pinned when a result was recorded (`taskExecContextView`).
/// Absent for older results, which read as unknown, never as any posture.
public struct TasksExecContext: Decodable, Sendable, Hashable {
    public var sandbox: String
    public var nonRoot: Bool
    public var rootExec: Bool
    public var execDisabled: Bool
    public var reportedAt: Date?

    enum CodingKeys: String, CodingKey {
        case sandbox
        case nonRoot = "non_root"
        case rootExec = "root_exec"
        case execDisabled = "exec_disabled"
        case reportedAt = "reported_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sandbox = try c.decodeIfPresent(String.self, forKey: .sandbox) ?? ""
        nonRoot = try c.decodeIfPresent(Bool.self, forKey: .nonRoot) ?? false
        rootExec = try c.decodeIfPresent(Bool.self, forKey: .rootExec) ?? false
        execDisabled = try c.decodeIfPresent(Bool.self, forKey: .execDisabled) ?? false
        reportedAt = try DateValue.decodeIfPresent(from: c, forKey: .reportedAt)
    }
}

/// One `taskResultView` with the fields an `omit_output` read adds: the
/// sizes of the bodies it left out and the first line of stderr.
public struct TasksResultRow: Decodable, Sendable, Hashable, Identifiable {
    public var result: LatticeTaskResult
    public var stdoutBytes: Int
    public var stderrBytes: Int
    public var stderrHead: String
    public var execContext: TasksExecContext?

    public var id: String { result.id }

    public init(result: LatticeTaskResult, stdoutBytes: Int = 0, stderrBytes: Int = 0, stderrHead: String = "", execContext: TasksExecContext? = nil) {
        self.result = result
        self.stdoutBytes = stdoutBytes
        self.stderrBytes = stderrBytes
        self.stderrHead = stderrHead
        self.execContext = execContext
    }

    enum CodingKeys: String, CodingKey {
        case stdoutBytes = "stdout_bytes"
        case stderrBytes = "stderr_bytes"
        case stderrHead = "stderr_head"
        case execContext = "exec_context"
    }

    public init(from decoder: Decoder) throws {
        result = try LatticeTaskResult(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stdoutBytes = try c.decodeIfPresent(Int.self, forKey: .stdoutBytes) ?? result.stdout.utf8.count
        stderrBytes = try c.decodeIfPresent(Int.self, forKey: .stderrBytes) ?? result.stderr.utf8.count
        stderrHead = try c.decodeIfPresent(String.self, forKey: .stderrHead) ?? ""
        execContext = try c.decodeIfPresent(TasksExecContext.self, forKey: .execContext)
    }
}

/// Filters for `GET /api/task-results` (`handleTaskResults`). Any of them
/// switches the server to the `{results, total, limit, offset}` envelope.
public struct TasksResultsQuery: Sendable, Hashable {
    /// Comma-joined on the wire; the server takes at most 100.
    public var taskIDs: [String]
    public var nodeID: String?
    /// Bodies stripped, sizes and the stderr head reported instead: for polls.
    public var omitOutput: Bool
    public var limit: Int
    public var offset: Int

    public static let maxTaskIDs = 100
    public static let maxLimit = 500

    public init(taskIDs: [String], nodeID: String? = nil, omitOutput: Bool = true, limit: Int = TasksResultsQuery.maxLimit, offset: Int = 0) {
        self.taskIDs = taskIDs
        self.nodeID = nodeID
        self.omitOutput = omitOutput
        self.limit = limit
        self.offset = offset
    }

    public var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "task_id", value: taskIDs.prefix(Self.maxTaskIDs).joined(separator: ","))]
        if let nodeID, !nodeID.isEmpty { items.append(URLQueryItem(name: "node_id", value: nodeID)) }
        if omitOutput { items.append(URLQueryItem(name: "omit_output", value: "1")) }
        items.append(URLQueryItem(name: "limit", value: String(limit)))
        items.append(URLQueryItem(name: "offset", value: String(offset)))
        return items
    }
}

/// One page of `GET /api/task-results`; a bare array from an older server is the whole answer.
public struct TasksResultsPage: Sendable, Hashable {
    public var results: [TasksResultRow]
    public var total: Int
    public var limit: Int
    public var offset: Int

    public init(results: [TasksResultRow], total: Int, limit: Int, offset: Int) {
        self.results = results
        self.total = total
        self.limit = limit
        self.offset = offset
    }

    private struct Envelope: Decodable {
        var results: [TasksResultRow]?
        var total: Int?
        var limit: Int?
        var offset: Int?
    }

    public static func decode(_ data: Data, query: TasksResultsQuery) throws -> TasksResultsPage {
        let decoder = JSONDecoder()
        if let rows = try? decoder.decode([TasksResultRow].self, from: data) {
            return TasksResultsPage(results: rows, total: rows.count, limit: rows.count, offset: 0)
        }
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { throw LatticeAPIError.invalidResponse }
        let rows = envelope.results ?? []
        return TasksResultsPage(results: rows, total: envelope.total ?? rows.count, limit: envelope.limit ?? query.limit, offset: envelope.offset ?? query.offset)
    }
}

/// `{ok: true}` from `POST /api/tasks/delete`.
public struct TasksDeleteResponse: Decodable, Sendable, Hashable {
    public var ok: Bool
}

public extension LatticeClient {
    @discardableResult
    func cancelTask(id: String) async throws -> LatticeTask {
        try await perform(
            LatticeTask.self,
            path: "/api/tasks/cancel",
            method: "POST",
            body: TaskIDRequest(id: id)
        )
    }

    /// `POST /api/tasks/rerun {id}`: a fresh task on every target of `id`.
    func tasksRerun(id: String) async throws -> LatticeTask {
        try await perform(LatticeTask.self, path: "/api/tasks/rerun", method: "POST", body: TaskIDRequest(id: id))
    }

    /// `POST /api/tasks/rerun-node {id, node_id}`: a fresh task on one target.
    func tasksRerunNode(id: String, nodeID: String) async throws -> LatticeTask {
        try await perform(LatticeTask.self, path: "/api/tasks/rerun-node", method: "POST", body: TasksRerunNodeRequest(id: id, nodeID: nodeID))
    }

    /// `POST /api/tasks/delete {id}`: removes the task and its results.
    func tasksDelete(id: String) async throws {
        let response = try await perform(TasksDeleteResponse.self, path: "/api/tasks/delete", method: "POST", body: TaskIDRequest(id: id))
        guard response.ok else { throw LatticeAPIError.invalidResponse }
    }

    /// `POST /api/tasks/reveal-script`, on the session client with a step-up grant.
    func tasksRevealScript(id: String, grant: StepUpGrant) async throws -> TasksScriptReveal {
        try await perform(TasksScriptReveal.self, path: "/api/tasks/reveal-script", method: "POST", body: TasksRevealScriptRequest(id: id, stepUpGrant: grant.grant))
    }

    /// `GET /api/task-results` with `omit_output`, `node_id` and paging.
    /// yagni: the Shared `listTaskResults(taskID:)` sends none of these and
    /// drops `stderr_head`; this folds into it at the next integration window.
    func tasksResults(_ query: TasksResultsQuery) async throws -> TasksResultsPage {
        let data = try await performData(path: "/api/task-results", query: query.queryItems)
        return try TasksResultsPage.decode(data, query: query)
    }

    /// Every result for `taskIDs`, page after page up to `maxPages`
    /// (`readResultPages`). `truncated` is true when the server had more.
    func tasksAllResults(taskIDs: [String], nodeID: String? = nil, omitOutput: Bool = true, maxPages: Int = 4) async throws -> (rows: [TasksResultRow], truncated: Bool) {
        guard !taskIDs.isEmpty else { return ([], false) }
        let wanted = Set(taskIDs)
        var rows: [TasksResultRow] = []
        var offset = 0
        for _ in 0..<maxPages {
            let page = try await tasksResults(TasksResultsQuery(taskIDs: taskIDs, nodeID: nodeID, omitOutput: omitOutput, offset: offset))
            rows += page.results.filter { wanted.contains($0.result.taskID) }
            offset += page.results.count
            if page.results.isEmpty || offset >= page.total { return (rows, false) }
        }
        return (rows, true)
    }

    /// One task by id. The list has no id filter, so this reads the newest
    /// 200 and looks (section 2.5, "Opening by id"); nil when absent.
    func tasksFind(id: String) async throws -> LatticeTask? {
        try await listTasks(query: TaskQuery(limit: TasksModel.lookupLimit)).tasks.first { $0.id == id }
    }

    /// A run seen before, read again on a narrower question that must still
    /// hold it (its first target, changed since it was queued), so a 3 s poll
    /// reads one short page (`findTask` with a hint). Falls back to the walk.
    func tasksFind(id: String, hint: LatticeTask?) async throws -> LatticeTask? {
        if let hint, hint.id == id, let first = hint.targets.first, let created = hint.createdAt {
            let narrow = try await listTasks(query: TaskQuery(nodeID: first, since: created, limit: TasksModel.lookupLimit))
            if let found = narrow.tasks.first(where: { $0.id == id }) { return found }
        }
        return try await tasksFind(id: id)
    }
}
