import Foundation

/// Demo routes for the Tasks domain, owned by the Tasks module (section 8.6):
/// the writes of section 3.2, the script reveal, and the `omit_output`
/// results read the run screens poll, all over the Shared invented tasks.
public enum TasksFixtures {
    public static let routes: [DemoRoute] = [
        DemoRoute(method: "POST", pathPattern: "/api/tasks/cancel") { request, state in
            await cancel(request, state: state)
        }.requiring("task:run"),
        DemoRoute(method: "POST", pathPattern: "/api/tasks/rerun") { request, state in
            await rerun(request, state: state, node: nil)
        }.requiring("task:run"),
        DemoRoute(method: "POST", pathPattern: "/api/tasks/rerun-node") { request, state in
            await rerun(request, state: state, node: request.bodyStrings["node_id"] ?? "")
        }.requiring("task:run"),
        DemoRoute(method: "POST", pathPattern: "/api/tasks/delete") { request, state in
            guard let task = task(request) else { return notFound }
            await state.insert(task.id, into: deletedSet)
            return .json(#"{"ok":true}"#)
        }.requiring("task:run"),
        DemoRoute(method: "POST", pathPattern: "/api/tasks/reveal-script") { request, _ in
            reveal(request)
        }.requiring("task:read"),
        // The polls of the run screens: bodies left out, the stderr head kept.
        DemoRoute(pathPattern: "/api/task-results", query: ["omit_output": "1"], body: resultsBody(ids: [], node: nil, limit: 500, offset: 0), emptyBody: resultsBody(ids: [], node: nil, limit: 500, offset: 0)) { request, _ in
            let ids = (request.query["task_id"] ?? "").split(separator: ",").map(String.init)
            let node = request.query["node_id"].flatMap { $0.isEmpty ? nil : $0 }
            let rows = request.scenario == .empty ? [] : ids
            return .json(resultsBody(ids: rows, node: node, limit: SharedFixtures.intQuery(request, "limit") ?? 100, offset: SharedFixtures.intQuery(request, "offset") ?? 0))
        }.requiring("task:read"),
    ]

    static let deletedSet = "tasks.deleted"
    static let cancelledSet = "tasks.cancelled"
    static let notFound = DemoResponse.error(status: 404, code: "not_found", message: "task not found")

    static func task(_ request: DemoRequest) -> DemoTask? {
        let id = request.bodyStrings["id"] ?? ""
        return SharedFixtures.tasks.first { $0.id == id }
    }

    static func cancel(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        guard var task = task(request), await !state.contains(request.bodyStrings["id"] ?? "", in: deletedSet) else { return notFound }
        let cancelled = await state.contains(task.id, in: cancelledSet)
        guard !cancelled, ["queued", "leased", "pending", "stalled"].contains(task.status) else {
            return .error(status: 409, code: "bad_request", message: "only queued tasks can be cancelled")
        }
        await state.insert(task.id, into: cancelledSet)
        task.status = "cancelled"
        return .json(SharedFixtures.taskJSON(task).text)
    }

    static func rerun(_ request: DemoRequest, state: DemoState, node: String?) async -> DemoResponse {
        guard let source = task(request) else { return notFound }
        if let node {
            guard source.targets.contains(node) else {
                return .error(status: 400, code: "bad_request", message: "node_id is not a target of the source task")
            }
        }
        let count = await state.recordHit("tasks.reruns")
        var fresh = DemoTask(id: "task_demo_rerun\(count)", status: "queued", script: source.script, targets: node.map { [$0] } ?? source.targets, createdAt: "")
        fresh.origin = "rerun"
        fresh.rerunOf = source.rerunOf.isEmpty ? source.id : source.rerunOf
        return .json(SharedFixtures.taskJSON(fresh).text)
    }

    static func reveal(_ request: DemoRequest) -> DemoResponse {
        // The server's refusal for a bearer token without secrets:reveal (decideSecretReveal).
        guard request.identity == .session else {
            return .error(status: 403, code: "secret_reveal_scope_required", message: "this API token cannot reveal secrets: that needs a token carrying the secrets:reveal scope, which no other scope implies and which a full administrator grants from an interactive session after step-up")
        }
        guard let task = task(request) else { return notFound }
        guard (request.bodyStrings["step_up_grant"] ?? "").isEmpty == false else {
            return .error(status: 403, code: "step_up_required", message: "a current second-factor check is required")
        }
        return .json(DemoJSON.object([
            ("ok", true),
            ("id", .string(task.id)),
            ("interpreter", "/bin/sh"),
            ("script", .string(task.script)),
            ("script_sha256", .string(PlanHasher.sha256Hex(task.script))),
            ("script_size_bytes", .number(Double(task.script.utf8.count))),
        ]).text)
    }

    /// The `omit_output` page for every named task: sizes and the first
    /// stderr line in place of the bodies, as `handleTaskResults` answers.
    static func resultsBody(ids: [String], node: String?, limit: Int, offset: Int) -> String {
        let wanted = Set(ids)
        let rows: [DemoJSON] = SharedFixtures.tasks.filter { wanted.contains($0.id) }.flatMap { task in
            task.outcomes.sorted { $0.key < $1.key }.compactMap { nodeID, outcome -> DemoJSON? in
                guard outcome.status == "finished" || outcome.status == "failed", node == nil || node == nodeID else { return nil }
                let head = outcome.stderr.split(separator: "\n").first.map(String.init)
                let settled = task.createdAt == "-2m" ? "-1m" : task.createdAt
                return .object([
                    "task_id": .string(task.id),
                    "node_id": .string(nodeID),
                    "exit_code": .number(Double(outcome.exitCode)),
                    "stdout": "",
                    "stderr": "",
                    "stdout_bytes": outcome.stdout.isEmpty ? nil : .number(Double(outcome.stdout.utf8.count)),
                    "stderr_bytes": outcome.stderr.isEmpty ? nil : .number(Double(outcome.stderr.utf8.count)),
                    "stderr_head": head.map { .string($0) },
                    "error": "",
                    "started_at": .time(task.createdAt),
                    "finished_at": .time(task.id == "task_d03" ? "-1m" : settled),
                    "exec_context": .object([("root_exec", true), ("reported_at", .time("-5m"))]),
                ])
            }
        }
        return SharedFixtures.page("results", rows, limit: limit, offset: offset).text
    }
}
