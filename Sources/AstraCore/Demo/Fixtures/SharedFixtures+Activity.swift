import Foundation

/// One invented task run.
public struct DemoTask: Sendable, Hashable {
    public var id: String
    public var status: String
    public var script: String
    public var targets: [String]
    public var createdAt: String
    public var origin: String = "direct"
    public var approvalID: String = ""
    public var rerunOf: String = ""
    /// Per node: the target's status and its result, when it has one.
    public var outcomes: [String: DemoTaskOutcome] = [:]
    public var stalledReason: String = ""
    public var attempts = 0

    public init(id: String, status: String, script: String, targets: [String], createdAt: String) {
        self.id = id
        self.status = status
        self.script = script
        self.targets = targets
        self.createdAt = createdAt
    }
}

/// One node's share of a demo task.
public struct DemoTaskOutcome: Sendable, Hashable {
    public var status: String
    public var exitCode: Int
    public var stdout: String
    public var stderr: String = ""

    public init(status: String, exitCode: Int = 0, stdout: String = "", stderr: String = "") {
        self.status = status
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

// GET /api/tasks, /api/tasks/counts, /api/task-results, /api/audit,
// /api/notify/deliveries and /api/expiring.
extension SharedFixtures {
    static var activityRoutes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/tasks", body: DemoJSON.array(tasks.map(taskJSON)).text) { request, state in
                await tasksAnswer(request, state: state)
            },
            DemoRoute(pathPattern: "/api/tasks/counts", body: taskCountsBody(tasks), emptyBody: taskCountsBody([])) { request, state in
                .json(taskCountsBody(await sessionTasks(state, scenario: request.scenario)))
            }.requiring("task:read"),
            DemoRoute(pathPattern: "/api/task-results", body: DemoJSON.array(taskResults(nil)).text) { request, state in
                taskResultsAnswer(request, deleted: await state.members(of: deletedTasksSet))
            }.requiring("task:read"),
            DemoRoute(pathPattern: "/api/audit", body: DemoJSON.array(auditEvents.map(\.json)).text) { request, _ in
                auditAnswer(request)
            }.requiring("audit:read"),
            DemoRoute(pathPattern: "/api/notify/deliveries", body: deliveriesBody(deliveries), emptyBody: deliveriesBody([])) { request, _ in
                deliveriesAnswer(request)
            }.requiring("notify:admin"),
            DemoRoute(pathPattern: "/api/expiring", body: expiringBody(within: 30), emptyBody: #"{"generated_at":"{{now}}","within_days":30,"items":[],"totals":[],"hidden_kinds":[]}"#) { request, _ in
                let scopes = DemoTransport.scopes(for: request.identity, scenario: request.scenario)
                return .json(expiringBody(within: intQuery(request, "within") ?? 30, scopes: scopes))
            },
        ]
    }

    // MARK: Tasks

    private static func ids(_ names: [String]) -> [String] { names.map { DemoWorld.node($0).id } }

    public static let tasks: [DemoTask] = {
        var list: [DemoTask] = []

        var update = DemoTask(id: "task_d01", status: "finished", script: "apt-get update -qq && apt-get -y -qq upgrade", targets: ids(["edge-tyo-1", "edge-tyo-2", "relay-tyo-1", "edge-sin-1", "edge-sin-2"]), createdAt: "-1d")
        for id in update.targets {
            update.outcomes[id] = DemoTaskOutcome(status: "finished", stdout: "Reading package lists...\n0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n")
        }
        list.append(update)

        var restart = DemoTask(id: "task_d02", status: "failed", script: "systemctl restart sing-box && systemctl is-active sing-box", targets: ids(["edge-hkg-2", "relay-hkg-1", "edge-tyo-1"]), createdAt: "-3h")
        restart.outcomes[DemoWorld.node("edge-hkg-2").id] = DemoTaskOutcome(status: "failed", exitCode: 1, stdout: "failed\n", stderr: "Job for sing-box.service failed because the control process exited with error code.\nNo space left on device\n")
        restart.outcomes[DemoWorld.node("relay-hkg-1").id] = DemoTaskOutcome(status: "finished", stdout: "active\n")
        restart.outcomes[DemoWorld.node("edge-tyo-1").id] = DemoTaskOutcome(status: "finished", stdout: "active\n")
        list.append(restart)

        let fleet = ["edge-tyo-1", "edge-tyo-2", "relay-tyo-1", "dns-tyo-1", "edge-sin-1", "edge-sin-2", "relay-hkg-1", "edge-hkg-2", "relay-fra-1", "edge-fra-3", "dns-fra-1", "edge-ams-2"]
        var diagnostics = DemoTask(id: "task_d03", status: "leased", script: "lattice-agent diagnose --json", targets: ids(fleet), createdAt: "-2m")
        for (index, name) in fleet.enumerated() {
            let id = DemoWorld.node(name).id
            switch index {
            case 0..<9: diagnostics.outcomes[id] = DemoTaskOutcome(status: "finished", stdout: #"{"ok":true,"checks":14}"# + "\n")
            case 9: diagnostics.outcomes[id] = DemoTaskOutcome(status: "failed", exitCode: 2, stderr: "diagnose: nft list ruleset: permission denied\n")
            default: diagnostics.outcomes[id] = DemoTaskOutcome(status: "leased")
            }
        }
        list.append(diagnostics)

        var stalled = DemoTask(id: "task_d04", status: "stalled", script: "logrotate -f /etc/logrotate.conf", targets: ids(["lab-pi-1"]), createdAt: "-50m")
        stalled.stalledReason = "stopped re-leasing after 3 attempts (the agent restarted during each run)."
        stalled.attempts = 3
        list.append(stalled)

        list.append(DemoTask(id: "task_d05", status: "expired", script: "certbot renew --quiet", targets: ids(["relay-fra-2"]), createdAt: "-2d"))
        list.append(DemoTask(id: "task_d06", status: "queued", script: "uptime", targets: ids(["edge-sjc-2"]), createdAt: "-20m"))
        list.append(DemoTask(id: "task_d07", status: "pending", script: "dig +short example.org @127.0.0.1", targets: ids(["dns-tyo-1"]), createdAt: "-5m"))
        list.append(DemoTask(id: "task_d08", status: "cancelled", script: "reboot", targets: ids(["edge-ams-2"]), createdAt: "-6h"))

        var apply = DemoTask(id: "task_d0905apply", status: "queued", script: "lattice-agent-update apply", targets: ids(["relay-fra-2"]), createdAt: "-3h")
        apply.origin = "approval"
        apply.approvalID = "approval_d0905"
        list.append(apply)

        var rerun = DemoTask(id: "task_d09", status: "finished", script: "systemctl restart sing-box && systemctl is-active sing-box", targets: ids(["edge-tyo-1"]), createdAt: "-2h")
        rerun.origin = "rerun"
        rerun.rerunOf = "task_d02"
        rerun.outcomes[DemoWorld.node("edge-tyo-1").id] = DemoTaskOutcome(status: "finished", stdout: "active\n")
        list.append(rerun)
        return list
    }()

    // The Tasks writes (TasksFixtures) record what they did here, so every
    // later read of the run list, counts and results agrees with them.
    static let deletedTasksSet = "tasks.deleted"
    static let cancelledTasksSet = "tasks.cancelled"
    /// Members are "<new id>|<source id>|<node id, empty for every target>".
    static let rerunTasksSet = "tasks.reruns"

    /// The invented runs with this session's deletes, cancels and reruns
    /// applied, newest first as the server lists them.
    static func sessionTasks(_ state: DemoState, scenario: DemoScenario) async -> [DemoTask] {
        let deleted = await state.members(of: deletedTasksSet)
        let cancelled = await state.members(of: cancelledTasksSet)
        let base = scenario == .quiet ? tasks.filter { $0.status == "finished" } : tasks
        // Oldest rerun first, so a rerun of a rerun finds its source.
        let entries = await state.members(of: rerunTasksSet)
            .map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.count == 3 }
            .sorted { rerunNumber($0[0]) < rerunNumber($1[0]) }
        var reruns: [DemoTask] = []
        for parts in entries {
            guard let source = (reruns + tasks).first(where: { $0.id == parts[1] }) else { continue }
            var fresh = DemoTask(id: parts[0], status: "queued", script: source.script, targets: parts[2].isEmpty ? source.targets : [parts[2]], createdAt: "")
            fresh.origin = "rerun"
            fresh.rerunOf = source.rerunOf.isEmpty ? source.id : source.rerunOf
            reruns.append(fresh)
        }
        return (reruns.reversed() + base).compactMap { task in
            guard !deleted.contains(task.id) else { return nil }
            var task = task
            if cancelled.contains(task.id) { task.status = "cancelled" }
            return task
        }
    }

    private static func rerunNumber(_ id: String) -> Int {
        Int(id.drop { !$0.isNumber }) ?? 0
    }

    static func tasksAnswer(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        let scopes = DemoTransport.scopes(for: request.identity, scenario: request.scenario)
        guard scopes.allows("task:read") || scopes.allows("task:run") else {
            return .error(status: 403, code: "forbidden", message: "missing scope task:read")
        }
        var rows = await sessionTasks(state, scenario: request.scenario)
        guard !request.query.isEmpty else { return .json(DemoJSON.array(rows.map(taskJSON)).text) }
        if let status = request.query["status"], !status.isEmpty {
            let wanted = Set(status.split(separator: ",").map(String.init))
            rows = rows.filter { wanted.contains($0.status) }
        }
        if let node = request.query["node_id"], !node.isEmpty { rows = rows.filter { $0.targets.contains(node) } }
        if let origin = request.query["origin"], !origin.isEmpty { rows = rows.filter { origin.split(separator: ",").map(String.init).contains($0.origin) } }
        if let approval = request.query["approval_id"], !approval.isEmpty { rows = rows.filter { $0.approvalID == approval } }
        return .json(page("tasks", rows.map(taskJSON), limit: intQuery(request, "limit") ?? 50, offset: intQuery(request, "offset")).text)
    }

    static func taskJSON(_ task: DemoTask) -> DemoJSON {
        let settled = ["finished", "failed", "cancelled", "expired"].contains(task.status)
        let single = task.targets.count == 1
        let fanOut: DemoJSON? = task.status == "leased" ? .object(task.outcomes.sorted { $0.key < $1.key }.map { id, outcome in
            (id, DemoJSON.object([
                "status": .string(outcome.status),
                "attempts": outcome.status == "leased" ? 1 : nil,
                "max_attempts": outcome.status == "leased" ? 3 : nil,
                "lease_age_seconds": outcome.status == "leased" ? 95 : nil,
            ]))
        }) : nil
        return .object([
            "id": .string(task.id),
            "actor_id": .string(task.origin == "approval" ? "lattice-server" : DemoWorld.actorID),
            "token_id": task.origin == "direct" ? "tok_demo0001phone" : nil,
            "approval_id": task.approvalID.isEmpty ? nil : .string(task.approvalID),
            "targets": .strings(task.targets),
            "interpreter": "/bin/sh",
            "script_sha256": .string(PlanHasher.sha256Hex(task.script)),
            "script_size_bytes": .number(Double(task.script.utf8.count)),
            "timeout_sec": 300,
            "output_limit": 65_536,
            "status": .string(task.status),
            "leased_by": task.status == "leased" && single ? .string(task.targets[0]) : nil,
            "rerun_of_task_id": task.rerunOf.isEmpty ? nil : .string(task.rerunOf),
            "created_at": .time(task.createdAt),
            "started_at": ["pending", "queued", "expired", "cancelled"].contains(task.status) ? nil : .time(task.createdAt),
            "finished_at": settled ? .time(task.createdAt == "-2m" ? "-1m" : task.createdAt) : nil,
            "attempts": task.attempts > 0 ? .number(Double(task.attempts)) : nil,
            "max_attempts": task.attempts > 0 ? 3 : nil,
            "lease_age_seconds": task.status == "stalled" ? 2_940 : nil,
            "stalled_reason": task.stalledReason.isEmpty ? nil : .string(task.stalledReason),
            "target_states": fanOut,
            "origin": .string(task.origin),
        ])
    }

    static func taskCountsBody(_ rows: [DemoTask]) -> String {
        func count(_ status: String) -> Double { Double(rows.filter { $0.status == status }.count) }
        return DemoJSON.object([
            ("pending", .number(count("pending"))),
            ("queued", .number(count("queued"))),
            ("running", .number(count("leased"))),
            ("stalled", .number(count("stalled"))),
            ("failed_24h", .number(count("failed"))),
            ("finished_24h", .number(count("finished"))),
            ("total", .number(Double(rows.count))),
            ("generated_at", .time()),
        ]).text
    }

    static func taskResults(_ taskID: String?) -> [DemoJSON] {
        tasks.filter { taskID == nil || $0.id == taskID }.flatMap { task in
            task.outcomes.sorted { $0.key < $1.key }.compactMap { nodeID, outcome -> DemoJSON? in
                guard outcome.status == "finished" || outcome.status == "failed" else { return nil }
                return .object([
                    "task_id": .string(task.id),
                    "node_id": .string(nodeID),
                    "exit_code": .number(Double(outcome.exitCode)),
                    "stdout": .string(outcome.stdout),
                    "stderr": outcome.stderr.isEmpty ? nil : .string(outcome.stderr),
                    "stdout_bytes": .number(Double(outcome.stdout.utf8.count)),
                    "stderr_bytes": .number(Double(outcome.stderr.utf8.count)),
                    "started_at": .time(task.createdAt),
                    "finished_at": .time(task.createdAt == "-2m" ? "-1m" : task.createdAt),
                ])
            }
        }
    }

    static func taskResultsAnswer(_ request: DemoRequest, deleted: Set<String> = []) -> DemoResponse {
        let kept = { (row: DemoJSON) -> Bool in
            guard case .object(let pairs) = row, case .string(let id)? = pairs.first(where: { $0.0 == "task_id" })?.1 else { return true }
            return !deleted.contains(id)
        }
        guard !request.query.isEmpty else { return .json(DemoJSON.array(taskResults(nil).filter(kept)).text) }
        var rows = taskResults(request.query["task_id"]).filter(kept)
        if let node = request.query["node_id"], !node.isEmpty {
            rows = rows.filter { row in
                guard case .object(let pairs) = row, case .string(let id)? = pairs.first(where: { $0.0 == "node_id" })?.1 else { return false }
                return id == node
            }
        }
        return .json(page("results", rows, limit: intQuery(request, "limit") ?? 200, offset: intQuery(request, "offset")).text)
    }

    // MARK: Audit

    struct DemoAuditEvent: Sendable {
        var id: String
        var at: String
        var action: String
        var node: String?
        var decision: String = "allow"
        var scope: String = ""
        var reason: String = ""
        var correlation: String = ""
        var actor: String = DemoWorld.actorID
        var metadata: [(String, String)] = []

        var json: DemoJSON {
            .object([
                "id": .string(id),
                "at": .time(at),
                "actor_id": .string(actor),
                "token_id": actor == DemoWorld.actorID ? "tok_demo0001phone" : "",
                "node_id": .string(node.map { DemoWorld.node($0).id } ?? ""),
                "action": .string(action),
                "scope": .string(scope),
                "decision": .string(decision),
                "reason": .string(reason),
                "correlation_id": .string(correlation),
                "metadata": metadata.isEmpty ? nil : .object(metadata.map { ($0.0, DemoJSON.string($0.1)) }),
            ])
        }

        var nodeID: String { node.map { DemoWorld.node($0).id } ?? "" }
    }

    static let auditEvents: [DemoAuditEvent] = [
        DemoAuditEvent(id: "audit_d30", at: "-1m", action: "task.create", node: nil, scope: "task:run", correlation: "corr_diag", metadata: [("task_id", "task_d03"), ("targets", "12")]),
        DemoAuditEvent(id: "audit_d29", at: "-6m", action: "sshguard.confirm.plan", node: "edge-tyo-2", scope: "network:plan", correlation: "corr_sshguard", metadata: [("approval_id", "approval_d1001"), ("plugin", "sshguard")]),
        DemoAuditEvent(id: "audit_d28", at: "-10m", action: "incident.ack", node: "edge-tyo-3", scope: "monitor:admin", metadata: [("incident_id", "inc_d05")]),
        DemoAuditEvent(id: "audit_d27", at: "-11m", action: "plugin.operation.execute", node: "edge-tyo-2", scope: "network:apply,sshguard:admin", correlation: "corr_sshguard", actor: "lattice-server", metadata: [("approval_id", "approval_d0904"), ("task_id", "task_d0904apply")]),
        DemoAuditEvent(id: "audit_d26", at: "-12m", action: "network.sshguard.approve", node: "edge-tyo-2", scope: "network:apply,sshguard:admin", correlation: "corr_sshguard", metadata: [("approval_id", "approval_d0904"), ("plan_sha256", "see approval")]),
        DemoAuditEvent(id: "audit_d25", at: "-15m", action: "network.policy.plan", node: "relay-iad-3", scope: "netpolicy:admin", metadata: [("approval_id", "approval_d1009")]),
        DemoAuditEvent(id: "audit_d24", at: "-20m", action: "beacon.plan", node: "dns-iad-1", scope: "monitor:admin,node:admin,network:plan", metadata: [("approval_id", "approval_d1006")]),
        DemoAuditEvent(id: "audit_d23", at: "-29m", action: "approval.auto_approve", node: "relay-hkg-1", scope: "network:apply", actor: "lattice-server", metadata: [("approval_id", "approval_d0908")]),
        DemoAuditEvent(id: "audit_d22", at: "-35m", action: "network.policy.plan", node: "relay-fra-1", scope: "netpolicy:admin", metadata: [("approval_id", "approval_d1005")]),
        DemoAuditEvent(id: "audit_d21", at: "-40m", action: "sshguard.plan", node: "edge-tyo-2", scope: "network:plan", correlation: "corr_sshguard", metadata: [("approval_id", "approval_d0904"), ("plugin", "sshguard")]),
        DemoAuditEvent(id: "audit_d20", at: "-48m", action: "authorize.scope", node: "core-lon-1", decision: "deny", scope: "terminal:open", reason: "token lacks terminal:open"),
        DemoAuditEvent(id: "audit_d19", at: "-50m", action: "task.create", node: "lab-pi-1", scope: "task:run", metadata: [("task_id", "task_d04")]),
        DemoAuditEvent(id: "audit_d18", at: "-1h", action: "dns.plan", node: "dns-tyo-1", scope: "dns:admin,network:plan", metadata: [("approval_id", "approval_d1007")]),
        DemoAuditEvent(id: "audit_d17", at: "-2h", action: "task.rerun", node: "edge-tyo-1", scope: "task:run", correlation: "corr_restart", metadata: [("task_id", "task_d09"), ("rerun_of", "task_d02")]),
        DemoAuditEvent(id: "audit_d16", at: "-2h", action: "agent.update.plan", node: "edge-sin-1", scope: "node:admin,network:plan", correlation: "corr_agent", actor: "lattice-server", metadata: [("approval_id", "approval_d1002")]),
        DemoAuditEvent(id: "audit_d15", at: "-2h", action: "agent.update.plan", node: "edge-sin-2", scope: "node:admin,network:plan", correlation: "corr_agent", actor: "lattice-server", metadata: [("approval_id", "approval_d1003")]),
        DemoAuditEvent(id: "audit_d14", at: "-2h", action: "agent.update.plan", node: "edge-ams-1", scope: "node:admin,network:plan", correlation: "corr_agent", actor: "lattice-server", metadata: [("approval_id", "approval_d1004")]),
        DemoAuditEvent(id: "audit_d13", at: "-3h", action: "task.create", node: nil, scope: "task:run", correlation: "corr_restart", metadata: [("task_id", "task_d02"), ("targets", "3")]),
        DemoAuditEvent(id: "audit_d12", at: "-3h", action: "network.agentupdate.approve", node: "relay-fra-2", scope: "network:apply,node:admin", metadata: [("approval_id", "approval_d0905")]),
        DemoAuditEvent(id: "audit_d11", at: "-5h", action: "network.nftpolicy.reject", node: "edge-hkg-2", scope: "network:apply,netpolicy:admin", metadata: [("approval_id", "approval_d0903")]),
        DemoAuditEvent(id: "audit_d10", at: "-6h", action: "maintenance.upsert", node: nil, scope: "monitor:admin", metadata: [("window_id", "mw_d02")]),
        DemoAuditEvent(id: "audit_d09", at: "-6h", action: "task.cancel", node: "edge-ams-2", scope: "task:run", metadata: [("task_id", "task_d08")]),
        DemoAuditEvent(id: "audit_d08", at: "-1d", action: "network.agentupdate.approve", node: "edge-tyo-1", scope: "network:apply,node:admin", metadata: [("approval_id", "approval_d0901")]),
        DemoAuditEvent(id: "audit_d07", at: "-1d", action: "task.create", node: nil, scope: "task:run", metadata: [("task_id", "task_d01"), ("targets", "5")]),
        DemoAuditEvent(id: "audit_d06", at: "-2d", action: "network.selfdns.reject", node: "dns-fra-1", scope: "network:apply,dns:admin", metadata: [("approval_id", "approval_d0902")]),
        DemoAuditEvent(id: "audit_d05", at: "-2d", action: "node.disable", node: "edge-iad-2", scope: "node:admin", reason: "token leaked"),
        DemoAuditEvent(id: "audit_d04", at: "-2d", action: "token.create", node: nil, scope: "token:admin", metadata: [("token_id", "tok_demo0001phone"), ("name", "phone")]),
        DemoAuditEvent(id: "audit_d03", at: "-6d", action: "maintenance.upsert", node: nil, scope: "monitor:admin", metadata: [("window_id", "mw_d01")]),
        DemoAuditEvent(id: "audit_d02", at: "-9d", action: "node.disable", node: "backup-ams-4", scope: "node:admin", reason: "cold storage"),
        DemoAuditEvent(id: "audit_d01", at: "-9d", action: "login", node: nil, scope: "", metadata: [("method", "password+totp")]),
    ]

    static func auditAnswer(_ request: DemoRequest) -> DemoResponse {
        guard !request.query.isEmpty else { return .json(DemoJSON.array(auditEvents.map(\.json)).text) }
        var rows = auditEvents
        let q = request.query
        if let action = q["action"], !action.isEmpty { rows = rows.filter { $0.action == action || $0.action.hasPrefix(action + ".") } }
        if let exclude = q["exclude_action"], !exclude.isEmpty { rows = rows.filter { !exclude.split(separator: ",").map(String.init).contains($0.action) } }
        if let decision = q["decision"], !decision.isEmpty { rows = rows.filter { $0.decision == decision } }
        if let actor = q["actor_id"], !actor.isEmpty { rows = rows.filter { $0.actor == actor } }
        if let node = q["node_id"], !node.isEmpty { rows = rows.filter { $0.nodeID == node } }
        if let correlation = q["correlation_id"], !correlation.isEmpty { rows = rows.filter { $0.correlation == correlation } }
        if let text = q["q"]?.lowercased(), !text.isEmpty {
            rows = rows.filter { event in
                ([event.action, event.reason, event.nodeID, event.correlation] + event.metadata.map(\.1)).contains { $0.lowercased().contains(text) }
            }
        }
        return .json(page("events", rows.map(\.json), limit: intQuery(request, "limit") ?? 100, offset: intQuery(request, "offset")).text)
    }

    // MARK: Deliveries

    static let deliveries: [DemoJSON] = [
        delivery(id: "dlv_d01", event: "inc_d01", type: "incident.open", severity: "critical", channel: ("ch_bark", "Phone (Bark)", "bark"), outcome: "sent", at: "-175m", title: "relay-fra-2 offline", incidents: ["inc_d01"]),
        delivery(id: "dlv_d02", event: "inc_d01", type: "incident.open", severity: "critical", channel: ("ch_mail", "Ops mail", "email"), outcome: "failed", at: "-175m", title: "relay-fra-2 offline", incidents: ["inc_d01"], reason: "smtp: 421 try again later"),
        delivery(id: "dlv_d03", event: "inc_d02", type: "incident.open", severity: "warning", channel: ("ch_bark", "Phone (Bark)", "bark"), outcome: "sent", at: "-45m", title: "Path edge-tyo-1 to relay-fra-1 degraded", incidents: ["inc_d02"]),
        delivery(id: "dlv_d04", event: "inc_d07", type: "incident.open", severity: "critical", channel: ("ch_bark", "Phone (Bark)", "bark"), outcome: "suppressed", at: "-6d", title: "lab-pi-2 offline", incidents: ["inc_d07"], reason: "held by maintenance window Home lab rewiring"),
        delivery(id: "dlv_d05", event: "inc_d09", type: "incident.resolved", severity: "warning", channel: ("ch_bark", "Phone (Bark)", "bark"), outcome: "sent", at: "-2h", title: "dns-fra-1 DNS answer check recovered", incidents: ["inc_d09"]),
        delivery(id: "dlv_d06", event: "evt_d06", type: "plugin.health", severity: "info", channel: ("", "", ""), outcome: "no_route", at: "-4h", title: "Plugin example-labs.reports restarted", incidents: [], reason: "no rule matches plugin.health"),
        delivery(id: "dlv_d07", event: "inc_d03", type: "incident.open", severity: "warning", channel: ("ch_bark", "Phone (Bark)", "bark"), outcome: "sent", at: "-20m", title: "tls-api.example.org check failing", incidents: ["inc_d03"]),
    ]

    private static func delivery(id: String, event: String, type: String, severity: String, channel: (String, String, String), outcome: String, at: String, title: String, incidents: [String], reason: String = "") -> DemoJSON {
        let attempted = outcome == "sent" || outcome == "failed"
        return .object([
            "id": .string(id),
            "event_id": .string(event),
            "event_type": .string(type),
            "source": .string(type.hasPrefix("plugin") ? "plugin" : "server"),
            "source_id": .string(incidents.first ?? event),
            "severity": .string(severity),
            "rule_id": channel.0.isEmpty ? nil : "rule_incidents",
            "rule_name": channel.0.isEmpty ? nil : "Incidents to the phone",
            "channel_id": channel.0.isEmpty ? nil : .string(channel.0),
            "channel_name": channel.1.isEmpty ? nil : .string(channel.1),
            "channel_kind": channel.2.isEmpty ? nil : .string(channel.2),
            "role": channel.0 == "ch_mail" ? "fallback" : "primary",
            "outcome": .string(outcome),
            "reason": reason.isEmpty ? nil : .string(reason),
            "attempts": attempted ? [.object([
                "at": .time(at),
                "ok": .bool(outcome == "sent"),
                "kind": .string(channel.2),
                "status": outcome == "sent" ? 200 : nil,
                "duration_ms": outcome == "sent" ? 412 : 30_000,
            ])] : nil,
            "title": .string(title),
            "body": .string(title + "."),
            "created_at": .time(at),
            "settled_at": .time(at),
            "incident_ids": incidents.isEmpty ? nil : .strings(incidents),
        ])
    }

    static func deliveriesBody(_ rows: [DemoJSON]) -> String {
        DemoJSON.object([
            ("deliveries", .array(rows)),
            ("stored", .number(Double(rows.count))),
            ("durable", true),
            ("max", 2_000),
            ("floor", 200),
        ]).text
    }

    static func deliveriesAnswer(_ request: DemoRequest) -> DemoResponse {
        var rows = deliveries
        for name in ["channel_id", "event_type", "outcome", "event_id", "source", "source_id"] {
            guard let wanted = request.query[name], !wanted.isEmpty else { continue }
            rows = rows.filter { row in
                guard case .object(let pairs) = row, case .string(let value)? = pairs.first(where: { $0.0 == name })?.1 else { return false }
                return value == wanted
            }
        }
        if let limit = intQuery(request, "limit") { rows = Array(rows.prefix(limit)) }
        return .json(deliveriesBody(rows))
    }

    // MARK: Expiring

    /// The kinds of `/api/expiring` and the scope each needs, as the server
    /// decides them; VPN users and shares are hidden from a confined token.
    static func expiringReadable(_ scopes: ScopeSet) -> Set<String> {
        var kinds: Set<String> = []
        if scopes.allows("inventory:read") { kinds.insert("machine_renewal") }
        if !scopes.isConfined, scopes.allows("proxy:read") { kinds.insert("vpn_user") }
        if !scopes.isConfined, scopes.allows("proxy:admin") { kinds.insert("share") }
        if scopes.allows("monitor:read") { kinds.insert("tls_certificate") }
        return kinds
    }

    /// Machine rows carry the profile id (`m-<node>`) and the figures of the
    /// Inventory demo machines, so a due row opens the right machine.
    static func expiringBody(within days: Int, scopes: ScopeSet = ScopeSet(scopes: ["*"])) -> String {
        func machine(_ name: String, vendor: String, region: String, days: Int, state: String, cost: Int, currency: String) -> (days: Int, kind: String, node: String?, json: DemoJSON) {
            let id = "m-\(name)"
            return (days, "machine_renewal", DemoWorld.node(name).id, expiring(kind: "machine_renewal", id: id, title: name, subtitle: "\(vendor) · \(region)", days: days, state: state, cost: cost, currency: currency, href: "/inventory?machine=\(id)"))
        }
        let items: [(days: Int, kind: String, node: String?, json: DemoJSON)] = [
            machine("edge-tyo-1", vendor: "Northwind Cloud", region: "Tokyo", days: -2, state: "overdue", cost: 1_200, currency: "USD"),
            machine("relay-fra-1", vendor: "Fabrikam Hosting", region: "Frankfurt", days: 3, state: "due", cost: 2_400, currency: "EUR"),
            (5, "vpn_user", nil, expiring(kind: "vpn_user", id: "vu_alice", title: "alice", subtitle: "alice@example.org", days: 5, state: "due", cost: 0, href: "/plugins/latticenet.vpn-core/users")),
            (6, "tls_certificate", nil, expiring(kind: "tls_certificate", id: "cert_tls_api", title: "tls-api.example.org", subtitle: "tls-api.example.org:443", days: 6, state: "due", cost: 0, href: "/monitoring?view=checks&open=mon_tls_api")),
            (9, "share", nil, expiring(kind: "share", id: "share_family", title: "family", subtitle: "12 users", days: 9, state: "upcoming", cost: 0, href: "/platform/publishing?view=routes&origin=share&open=share_family")),
            machine("core-lon-1", vendor: "Tailspin Metal", region: "London", days: 12, state: "auto", cost: 4_900, currency: "USD"),
        ]
        let readable = expiringReadable(scopes)
        let visible = scopes.isConfined ? Set(scopes.serverAllowlist) : nil
        let within = items.filter { item in
            item.days <= days && readable.contains(item.kind) && (item.node.map { visible?.contains($0) ?? true } ?? true)
        }
        var totals: [String: (cents: Double, count: Int)] = [:]
        for item in within where item.days >= -30 {
            guard case .object(let pairs) = item.json,
                  case .number(let cents)? = pairs.first(where: { $0.0 == "cost_cents" })?.1, cents > 0,
                  case .string(let currency)? = pairs.first(where: { $0.0 == "currency" })?.1 else { continue }
            totals[currency, default: (0, 0)].cents += cents
            totals[currency, default: (0, 0)].count += 1
        }
        let hidden = ["machine_renewal", "vpn_user", "share", "tls_certificate"].filter { !readable.contains($0) }
        return DemoJSON.object([
            ("generated_at", .time()),
            ("within_days", .number(Double(days))),
            ("items", .array(within.map(\.json))),
            ("totals", .array(totals.keys.sorted().map { code in
                .object(["currency": .string(code), "cost_cents": .number(totals[code]!.cents), "count": .number(Double(totals[code]!.count))])
            })),
            ("hidden_kinds", .strings(hidden)),
        ]).text
    }

    private static func expiring(kind: String, id: String, title: String, subtitle: String, days: Int, state: String, cost: Int, currency: String = "", href: String) -> DemoJSON {
        .object([
            "kind": .string(kind),
            "id": .string(id),
            "title": .string(title),
            "subtitle": .string(subtitle),
            "due_at": .time(days >= 0 ? "+\(days)d" : "\(days)d"),
            "days": .number(Double(days)),
            "state": .string(state),
            "cost_cents": .number(Double(cost)),
            "currency": .string(currency),
            "href": .string(href),
        ])
    }
}
