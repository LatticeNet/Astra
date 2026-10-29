import Foundation

/// One invented incident.
public struct DemoIncident: Sendable, Hashable {
    public var id: String
    public var kind: String
    public var severity: String
    public var state: String
    public var node: String?
    public var title: String
    public var subject: String = ""
    public var detail: String = ""
    public var monitorID: String = ""
    public var since: String
    public var resolvedAt: String = ""
    public var ackedAt: String = ""
    public var snoozedUntil: String = ""
    public var maintenance: String = ""
    public var maintenanceID: String = ""
    public var flapping = false
    public var opensAt: String = ""
    public var notified: String = "open"

    public init(id: String, kind: String, severity: String, state: String, node: String?, title: String, since: String) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.state = state
        self.node = node
        self.title = title
        self.since = since
    }
}

// GET /api/incidents, the T1 incident writes, maintenance windows and
// GET /api/monitors/paths.
extension SharedFixtures {
    static var monitoringRoutes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/incidents", body: incidentsBody(incidents, windows: windows), emptyBody: #"{"incidents":[],"windows":[],"durable":true,"now":"{{now}}"}"#) { request, state in
                await incidentsAnswer(request, state: state)
            }.requiring("monitor:read"),
            DemoRoute(method: "POST", pathPattern: "/api/incidents/ack") { request, state in
                await incidentWrite(request, state: state) { id in
                    await state.remove(id, from: "incident.unacked")
                    await state.insert(id, into: "incident.acked")
                }
            }.requiring("monitor:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/incidents/unack") { request, state in
                await incidentWrite(request, state: state) { id in
                    await state.remove(id, from: "incident.acked")
                    await state.insert(id, into: "incident.unacked")
                }
            }.requiring("monitor:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/incidents/snooze") { request, state in
                let minutes = (request.bodyObject()?["minutes"] as? NSNumber)?.intValue ?? 0
                return await incidentWrite(request, state: state) { id in
                    await state.setValue(String(minutes), for: "incident.snooze.\(id)")
                }
            }.requiring("monitor:admin"),
            DemoRoute(pathPattern: "/api/maintenance-windows", body: windowsBody(windows), emptyBody: #"{"windows":[],"now":"{{now}}"}"#) { _, state in
                .json(windowsBody(await currentWindows(state: state)))
            }.requiring("monitor:read"),
            DemoRoute(method: "POST", pathPattern: "/api/maintenance-windows") { request, state in
                await upsertWindow(request, state: state)
            }.requiring("monitor:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/maintenance-windows/delete") { request, state in
                guard let id = request.bodyStrings["id"] else {
                    return .error(status: 400, code: "bad_request", message: "id is required")
                }
                await state.insert(id, into: "window.deleted")
                return .json(#"{"ok":true}"#)
            }.requiring("monitor:admin"),
            DemoRoute(pathPattern: "/api/monitors/paths", body: pathsBody(window: "1h", quiet: false), emptyBody: #"{"window":"1h","observed_at":"{{now}}","sources":[],"targets":[],"paths":[],"degraded_at":null}"#) { request, _ in
                .json(pathsBody(window: request.query["window"] ?? "1h", quiet: request.scenario == .quiet))
            }.requiring("monitor:read"),
        ]
    }

    // MARK: Incidents

    public static let incidents: [DemoIncident] = {
        var list: [DemoIncident] = []
        var offline = DemoIncident(id: "inc_d01", kind: "node.offline", severity: "critical", state: "open", node: "relay-fra-2", title: "relay-fra-2 offline", since: "-3h")
        offline.detail = "No report for 3 h; last seen from 198.51.100.42."
        list.append(offline)

        var path = DemoIncident(id: "inc_d02", kind: "path.degraded", severity: "warning", state: "open", node: "edge-tyo-1", title: "Path edge-tyo-1 to relay-fra-1 degraded", since: "-48m")
        path.subject = "edge-tyo-1 → relay-fra-1"
        path.monitorID = "mon_path_tyo1_fra1"
        path.detail = "Loss 6.2% against a trigger of 2.0% over the last 15 minutes."
        list.append(path)

        var flapping = DemoIncident(id: "inc_d03", kind: "monitor.down", severity: "warning", state: "open", node: "core-lon-1", title: "tls-api.example.org check failing", since: "-22m")
        flapping.monitorID = "mon_tls_api"
        flapping.subject = "tls-api.example.org:443"
        flapping.flapping = true
        list.append(flapping)

        var info = DemoIncident(id: "inc_d04", kind: "monitor.down", severity: "info", state: "open", node: "edge-hkg-2", title: "edge-hkg-2 disk above 90%", since: "-3h")
        info.monitorID = "mon_disk_hkg2"
        info.notified = ""
        list.append(info)

        var acked = DemoIncident(id: "inc_d05", kind: "agent.stalled", severity: "warning", state: "acknowledged", node: "edge-tyo-3", title: "edge-tyo-3 agent loop stalled", since: "-14m")
        acked.ackedAt = "-10m"
        list.append(acked)

        var snoozed = DemoIncident(id: "inc_d06", kind: "node.offline", severity: "critical", state: "open", node: "edge-sjc-2", title: "edge-sjc-2 offline", since: "-25m")
        snoozed.snoozedUntil = "+35m"
        list.append(snoozed)

        var held = DemoIncident(id: "inc_d07", kind: "node.offline", severity: "critical", state: "open", node: "lab-pi-2", title: "lab-pi-2 offline", since: "-6d")
        held.maintenance = "Home lab rewiring"
        held.maintenanceID = "mw_d01"
        held.notified = ""
        list.append(held)

        var pending = DemoIncident(id: "pending:path.degraded/n-edge-syd-1~n-relay-syd-2", kind: "path.degraded", severity: "warning", state: "pending", node: "edge-syd-1", title: "Path edge-syd-1 to relay-syd-2 degraded", since: "-4m")
        pending.subject = "edge-syd-1 → relay-syd-2"
        pending.opensAt = "+3m"
        pending.notified = ""
        list.append(pending)

        var resolved = DemoIncident(id: "inc_d09", kind: "service.down", severity: "warning", state: "resolved", node: "dns-fra-1", title: "dns-fra-1 DNS answer check failing", since: "-5h")
        resolved.resolvedAt = "-2h"
        resolved.notified = "resolved"
        list.append(resolved)

        var older = DemoIncident(id: "inc_d10", kind: "node.offline", severity: "critical", state: "resolved", node: "relay-iad-3", title: "relay-iad-3 offline", since: "-28h")
        older.resolvedAt = "-26h"
        older.notified = "resolved"
        list.append(older)
        return list
    }()

    static let serverStates: Set<String> = ["pending", "open", "acknowledged", "resolved"]

    static func incidentsAnswer(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        var wanted = serverStates
        if let raw = request.query["state"], !raw.isEmpty {
            wanted = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            if let unknown = wanted.first(where: { !serverStates.contains($0) }) {
                return .error(status: 400, code: "bad_request", message: "unknown state \"\(unknown)\"")
            }
        }
        var rows = await currentIncidents(state: state, scenario: request.scenario)
        rows = rows.filter { wanted.contains($0.state) }
        if let node = request.query["node_id"], !node.isEmpty {
            rows = rows.filter { DemoWorld.node($0.node ?? "").id == node }
        }
        if wanted == ["resolved"] {
            rows.sort { offsetSeconds($0.resolvedAt) > offsetSeconds($1.resolvedAt) }
        }
        if let limit = intQuery(request, "limit") { rows = Array(rows.prefix(limit)) }
        return .json(incidentsBody(rows, windows: await currentWindows(state: state)))
    }

    /// Incidents with this session's acknowledgments and snoozes applied.
    static func currentIncidents(state: DemoState, scenario: DemoScenario) async -> [DemoIncident] {
        let acked = await state.members(of: "incident.acked")
        let unacked = await state.members(of: "incident.unacked")
        var rows: [DemoIncident] = []
        for var incident in incidents {
            if scenario == .quiet, incident.state != "resolved" { continue }
            if acked.contains(incident.id), incident.state == "open" {
                incident.state = "acknowledged"
                incident.ackedAt = "-1s"
            }
            if unacked.contains(incident.id), incident.state == "acknowledged" {
                incident.state = "open"
                incident.ackedAt = ""
            }
            if let minutes = await state.value(for: "incident.snooze.\(incident.id)").flatMap(Int.init) {
                incident.snoozedUntil = minutes > 0 ? "+\(minutes)m" : ""
            }
            rows.append(incident)
        }
        return rows
    }

    static func incidentWrite(_ request: DemoRequest, state: DemoState, apply: @Sendable (String) async -> Void) async -> DemoResponse {
        guard let id = request.bodyStrings["id"], let incident = incidents.first(where: { $0.id == id }) else {
            return .error(status: 404, code: "not_found", message: "incident not found")
        }
        if incident.id.hasPrefix("pending:") || incident.state == "resolved" {
            return .error(status: 409, code: "conflict", message: "incident is not active")
        }
        await apply(id)
        let updated = await currentIncidents(state: state, scenario: request.scenario).first { $0.id == id } ?? incident
        return .json(incidentJSON(updated).text)
    }

    static func incidentsBody(_ rows: [DemoIncident], windows: [DemoJSON]) -> String {
        DemoJSON.object([
            ("incidents", .array(rows.map(incidentJSON))),
            ("windows", .array(windows)),
            ("durable", true),
            ("now", .time()),
        ]).text
    }

    static func incidentJSON(_ incident: DemoIncident) -> DemoJSON {
        let node = incident.node.map(DemoWorld.node)
        let snoozed = !incident.snoozedUntil.isEmpty
        return .object([
            "id": .string(incident.id),
            "key": .string(incident.id.hasPrefix("pending:") ? String(incident.id.dropFirst("pending:".count)) : "\(incident.kind)/\(node?.id ?? "")"),
            "kind": .string(incident.kind),
            "recovery_kind": .string(incident.kind.split(separator: ".").first.map { "\($0).recovered" } ?? ""),
            "severity": .string(incident.severity),
            "state": .string(incident.state),
            "node_id": node.map { .string($0.id) },
            "node_name": node.map { .string($0.name) },
            "monitor_id": incident.monitorID.isEmpty ? nil : .string(incident.monitorID),
            "subject": incident.subject.isEmpty ? nil : .string(incident.subject),
            "title": .string(incident.title),
            "detail": incident.detail.isEmpty ? nil : .string(incident.detail),
            "since": .time(incident.since),
            "first_opened_at": incident.state == "pending" ? nil : .time(incident.since),
            "opened_at": incident.state == "pending" ? nil : .time(incident.since),
            "resolved_at": incident.resolvedAt.isEmpty ? nil : .time(incident.resolvedAt),
            "updated_at": .time(incident.ackedAt.isEmpty ? (incident.resolvedAt.isEmpty ? incident.since : incident.resolvedAt) : incident.ackedAt),
            "acked_by": incident.ackedAt.isEmpty ? nil : .string(DemoWorld.actorID),
            "acked_at": incident.ackedAt.isEmpty ? nil : .time(incident.ackedAt),
            "snoozed_by": snoozed ? .string(DemoWorld.actorID) : nil,
            "snoozed_until": snoozed ? .time(incident.snoozedUntil) : nil,
            "snoozed": snoozed ? true : nil,
            "notified": incident.notified.isEmpty ? nil : .string(incident.notified),
            "notified_at": incident.notified.isEmpty ? nil : .time(incident.since),
            "open_notified_at": incident.notified.isEmpty ? nil : .time(incident.since),
            "suppressed": incident.maintenance.isEmpty ? nil : .string("held by maintenance window \(incident.maintenance)"),
            "suppressed_at": incident.maintenance.isEmpty ? nil : .time(incident.since),
            "flaps": incident.flapping ? 4 : nil,
            "flapping": incident.flapping ? true : nil,
            "maintenance": incident.maintenance.isEmpty ? nil : .string(incident.maintenance),
            "maintenance_id": incident.maintenanceID.isEmpty ? nil : .string(incident.maintenanceID),
            "opens_at": incident.opensAt.isEmpty ? nil : .time(incident.opensAt),
        ])
    }

    /// Seconds from the clock's anchor for a token offset like "-2h".
    static func offsetSeconds(_ offset: String) -> Double {
        guard let sign = offset.first, sign == "-" || sign == "+", let unit = offset.last else { return 0 }
        let amount = Double(offset.dropFirst().dropLast()) ?? 0
        let factor: Double = switch unit {
        case "m": 60
        case "h": 3_600
        case "d": 86_400
        default: 1
        }
        return (sign == "-" ? -1 : 1) * amount * factor
    }

    // MARK: Maintenance windows

    static let windows: [DemoJSON] = [
        windowJSON(id: "mw_d01", name: "Home lab rewiring", reason: "Moving the rack; lab nodes go dark", nodeIDs: [], groupIDs: ["g-home-lab"], starts: "-6d", ends: "+2h"),
        windowJSON(id: "mw_d02", name: "Frankfurt kernel upgrade", reason: "Planned reboot of the Frankfurt relays", nodeIDs: [DemoWorld.node("relay-fra-1").id, DemoWorld.node("edge-fra-3").id], groupIDs: [], starts: "+1d", ends: "+2d"),
    ]

    static func windowJSON(id: String, name: String, reason: String, nodeIDs: [String], groupIDs: [String], starts: String, ends: String) -> DemoJSON {
        .object([
            "id": .string(id),
            "name": .string(name),
            "reason": .string(reason),
            "node_ids": nodeIDs.isEmpty ? nil : .strings(nodeIDs),
            "group_ids": groupIDs.isEmpty ? nil : .strings(groupIDs),
            "starts_at": .time(starts),
            "ends_at": .time(ends),
            "created_by": .string(DemoWorld.actorID),
            "created_at": .time(starts),
            "updated_at": .time(starts),
        ])
    }

    static func currentWindows(state: DemoState) async -> [DemoJSON] {
        let deleted = await state.members(of: "window.deleted")
        var list = windows.filter { window in
            guard case .object(let pairs) = window, case .string(let id)? = pairs.first(where: { $0.0 == "id" })?.1 else { return true }
            return !deleted.contains(id)
        }
        for id in await state.members(of: "window.ids").sorted() where !deleted.contains(id) {
            if let text = await state.value(for: "window.\(id)") { list.append(.raw(text)) }
        }
        return list
    }

    static func windowsBody(_ windows: [DemoJSON]) -> String {
        DemoJSON.object([("windows", .array(windows)), ("now", .time())]).text
    }

    static func upsertWindow(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        guard let body = request.bodyObject(), let name = body["name"] as? String, !name.isEmpty,
              let endsAt = body["ends_at"] as? String else {
            return .error(status: 400, code: "bad_request", message: "name and ends_at are required")
        }
        var id = (body["id"] as? String) ?? ""
        if id.isEmpty { id = "mw_new\(await state.recordHit("window.new"))" }
        let window = DemoJSON.object([
            "id": .string(id),
            "name": .string(name),
            "reason": (body["reason"] as? String).map(DemoJSON.string),
            "node_ids": (body["node_ids"] as? [String]).map(DemoJSON.strings),
            "group_ids": (body["group_ids"] as? [String]).map(DemoJSON.strings),
            "starts_at": .string(body["starts_at"] as? String ?? "{{now}}"),
            "ends_at": .string(endsAt),
            "created_by": .string(DemoWorld.actorID),
            "created_at": .time(),
            "updated_at": .time(),
        ])
        await state.insert(id, into: "window.ids")
        await state.setValue(window.text, for: "window.\(id)")
        return .json(window.text)
    }

    // MARK: Paths

    private struct DemoPath {
        var source: String?
        var target: String
        var method: String
        var state: String
        var reason: String = ""
        var p50: Double?
        var loss: Double?
        var degraded = false
    }

    private static let pathCells: [DemoPath] = [
        DemoPath(source: "edge-tyo-1", target: "relay-fra-1", method: "tcp", state: "degraded", reason: "degraded_loss", p50: 238, loss: 0.062, degraded: true),
        DemoPath(source: "edge-tyo-1", target: "relay-hkg-1", method: "tcp", state: "up", p50: 49, loss: 0),
        DemoPath(source: "edge-tyo-1", target: "relay-fra-2", method: "tcp", state: "down", p50: nil, loss: 1),
        DemoPath(source: "edge-sin-1", target: "relay-hkg-1", method: "tcp", state: "up", p50: 34, loss: 0.001),
        DemoPath(source: "edge-sin-1", target: "relay-fra-1", method: "tcp", state: "up", p50: 161, loss: 0.002),
        DemoPath(source: "relay-fra-1", target: "core-lon-1", method: "icmp", state: "up", p50: 14, loss: 0),
        DemoPath(source: "relay-fra-1", target: "relay-fra-2", method: "icmp", state: "down", p50: nil, loss: 1),
        DemoPath(source: "edge-iad-1", target: "edge-sjc-1", method: "tcp", state: "up", p50: 62, loss: 0),
        DemoPath(source: "edge-iad-1", target: "dns-iad-1", method: "beacon", state: "unknown", reason: "beacon_not_enabled"),
        DemoPath(source: "edge-sjc-2", target: "edge-sjc-1", method: "tcp", state: "unknown", reason: "agent_offline"),
        DemoPath(source: "edge-syd-1", target: "relay-syd-2", method: "tcp", state: "up", p50: 3, loss: 0.018),
        DemoPath(source: "edge-syd-1", target: "core-sjc-1", method: "tcp", state: "unknown", reason: "path_paused"),
        DemoPath(source: "edge-ams-2", target: "relay-hkg-1", method: "icmp", state: "unknown", reason: "packet_budget"),
        DemoPath(source: nil, target: "core-lon-1", method: "http", state: "up", p50: 21, loss: 0),
    ]

    static func pathsBody(window: String, quiet: Bool) -> String {
        let cells = pathCells.map { cell -> DemoPath in
            guard quiet, cell.state != "unknown" else { return cell }
            var calm = cell
            calm.state = "up"
            calm.reason = ""
            calm.degraded = false
            calm.p50 = calm.p50 ?? 120
            calm.loss = 0
            return calm
        }
        let sourceNames = Array(Set(cells.compactMap(\.source))).sorted()
        let targetNames = Array(Set(cells.map(\.target))).sorted()
        return DemoJSON.object([
            ("window", .string(window)),
            ("observed_at", .time()),
            ("sources", .array(sourceNames.map { name in
                let node = DemoWorld.node(name)
                return .object(["node_id": .string(node.id), "name": .string(node.name), "region": .string(node.region)])
            })),
            ("targets", .array(targetNames.map { name in
                let node = DemoWorld.node(name)
                return .object(["node_id": .string(node.id), "name": .string(node.name), "region": .string(node.region), "country": .string(node.country)])
            })),
            ("paths", .array(cells.map(pathJSON))),
            ("degraded_at", .time("-30s")),
            ("beacon_replans", quiet ? [] : [
                .object([
                    "node_id": .string(DemoWorld.node("dns-fra-1").id),
                    "name": "dns-fra-1",
                    "reason": "beacon_source_pending",
                    "added": .strings([DemoWorld.node("edge-fra-3").id]),
                    "removed": [],
                    "request": .object(["node_id": .string(DemoWorld.node("dns-fra-1").id), "action": "change"]),
                ]),
            ]),
        ]).text
    }

    private static func pathJSON(_ cell: DemoPath) -> DemoJSON {
        let target = DemoWorld.node(cell.target)
        let source = cell.source.map(DemoWorld.node)
        let address: String = cell.method == "http" ? "https://\(target.hostname)/healthz" : "\(target.ipv4):443"
        let monitor = "mon_\(cell.method)_\(source?.name ?? "cp")_\(target.name)"
        let degraded: DemoJSON? = cell.degraded ? .object([
            "since": .time("-48m"),
            "evaluated_at": .time("-30s"),
            "loss": .object(["value": 0.062, "baseline": 0.004, "trigger": 0.02, "sent": 900, "lost": 56]),
        ]) : nil
        var p50: DemoJSON = .null
        var p95: DemoJSON = .null
        var jitter: DemoJSON = .null
        var previous: DemoJSON?
        if let median = cell.p50 {
            p50 = .number(median)
            p95 = .number((median * 1.35).rounded())
            jitter = .number((median * 0.8).rounded() / 10)
            previous = .object(["p50_ms": .number((median * 0.97).rounded()), "loss": 0.001])
        }
        let loss: DemoJSON = cell.loss.map(DemoJSON.number) ?? .null
        let samples: Double = cell.p50 != nil || cell.state == "down" ? 60 : 0
        let expected: Double = cell.state == "unknown" ? 0 : 60
        let reason: DemoJSON? = cell.reason.isEmpty ? nil : .string(cell.reason)
        let lastAt: DemoJSON? = cell.state == "unknown" ? nil : .time("-40s")
        return .object([
            "source": .string(source?.id ?? ""),
            "target_node": .string(target.id),
            "target": .string(address),
            "monitor_id": .string(monitor),
            "managed": false,
            "check_definition_id": "def_fleet_mesh",
            "method": .string(cell.method),
            "state": .string(cell.state),
            "reason": reason,
            "degraded": degraded,
            "p50_ms": p50,
            "p95_ms": p95,
            "jitter_ms": jitter,
            "loss": loss,
            "samples": .number(samples),
            "expected": .number(expected),
            "prev": previous,
            "last_at": lastAt,
        ])
    }
}
