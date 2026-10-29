import Foundation

/// The only `state` values `GET /api/incidents` accepts (server_incidents.go:129).
/// The console's `active`, `snoozed` and `all` are URL filter names, never API
/// values, so they cannot be expressed here.
public enum IncidentServerState: String, Sendable, Hashable, CaseIterable {
    case pending, open, acknowledged, resolved
}

/// One problem on one subject (lattice-server incidents.go).
public struct Incident: Identifiable, Codable, Equatable, Hashable, Sendable {
    /// "pending:<key>" for a derived pending incident.
    public var id: String
    public var key: String
    /// The open event type: node.offline, service.down, monitor.down, agent.stalled, path.degraded.
    public var kind: String
    public var recoveryKind: String
    /// info, warning or critical.
    public var severity: String
    /// pending, open, acknowledged or resolved.
    public var state: String
    public var nodeID: String
    public var nodeName: String
    public var monitorID: String
    public var subject: String
    public var title: String
    public var detail: String
    public var since: Date?
    public var firstOpenedAt: Date?
    public var openedAt: Date?
    public var resolvedAt: Date?
    public var updatedAt: Date?
    public var ackedBy: String
    public var ackedAt: Date?
    public var snoozedBy: String
    public var snoozedUntil: Date?
    public var snoozed: Bool
    /// What the phone was last told: "open", "resolved", or "".
    public var notified: String
    public var notifiedAt: Date?
    public var owedOpen: Bool
    public var owedRecovery: Bool
    public var suppressed: String
    public var flaps: Int
    public var flapping: Bool
    /// The active maintenance window covering its node, by name; "" when none.
    public var maintenance: String
    public var maintenanceID: String
    /// When a pending incident opens if its condition holds.
    public var opensAt: Date?

    public init(
        id: String,
        key: String = "",
        kind: String = "",
        severity: String = "warning",
        state: String = "open",
        nodeID: String = "",
        nodeName: String = "",
        monitorID: String = "",
        subject: String = "",
        title: String = "",
        since: Date? = nil
    ) {
        self.id = id
        self.key = key
        self.kind = kind
        self.recoveryKind = ""
        self.severity = severity
        self.state = state
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.monitorID = monitorID
        self.subject = subject
        self.title = title
        self.detail = ""
        self.since = since
        self.ackedBy = ""
        self.snoozedBy = ""
        self.snoozed = false
        self.notified = ""
        self.owedOpen = false
        self.owedRecovery = false
        self.suppressed = ""
        self.flaps = 0
        self.flapping = false
        self.maintenance = ""
        self.maintenanceID = ""
    }

    enum CodingKeys: String, CodingKey {
        case id, key, kind, severity, state, subject, title, detail, since, snoozed, notified
        case suppressed, flaps, flapping, maintenance
        case recoveryKind = "recovery_kind"
        case nodeID = "node_id"
        case nodeName = "node_name"
        case monitorID = "monitor_id"
        case firstOpenedAt = "first_opened_at"
        case openedAt = "opened_at"
        case resolvedAt = "resolved_at"
        case updatedAt = "updated_at"
        case ackedBy = "acked_by"
        case ackedAt = "acked_at"
        case snoozedBy = "snoozed_by"
        case snoozedUntil = "snoozed_until"
        case notifiedAt = "notified_at"
        case owedOpen = "owed_open"
        case owedRecovery = "owed_recovery"
        case maintenanceID = "maintenance_id"
        case opensAt = "opens_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        recoveryKind = try c.decodeIfPresent(String.self, forKey: .recoveryKind) ?? ""
        severity = try c.decodeIfPresent(String.self, forKey: .severity) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        nodeName = try c.decodeIfPresent(String.self, forKey: .nodeName) ?? ""
        monitorID = try c.decodeIfPresent(String.self, forKey: .monitorID) ?? ""
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        since = try DateValue.decodeIfPresent(from: c, forKey: .since)
        firstOpenedAt = try DateValue.decodeIfPresent(from: c, forKey: .firstOpenedAt)
        openedAt = try DateValue.decodeIfPresent(from: c, forKey: .openedAt)
        resolvedAt = try DateValue.decodeIfPresent(from: c, forKey: .resolvedAt)
        updatedAt = try DateValue.decodeIfPresent(from: c, forKey: .updatedAt)
        ackedBy = try c.decodeIfPresent(String.self, forKey: .ackedBy) ?? ""
        ackedAt = try DateValue.decodeIfPresent(from: c, forKey: .ackedAt)
        snoozedBy = try c.decodeIfPresent(String.self, forKey: .snoozedBy) ?? ""
        snoozedUntil = try DateValue.decodeIfPresent(from: c, forKey: .snoozedUntil)
        snoozed = try c.decodeIfPresent(Bool.self, forKey: .snoozed) ?? false
        notified = try c.decodeIfPresent(String.self, forKey: .notified) ?? ""
        notifiedAt = try DateValue.decodeIfPresent(from: c, forKey: .notifiedAt)
        owedOpen = try c.decodeIfPresent(Bool.self, forKey: .owedOpen) ?? false
        owedRecovery = try c.decodeIfPresent(Bool.self, forKey: .owedRecovery) ?? false
        suppressed = try c.decodeIfPresent(String.self, forKey: .suppressed) ?? ""
        flaps = try c.decodeIfPresent(Int.self, forKey: .flaps) ?? 0
        flapping = try c.decodeIfPresent(Bool.self, forKey: .flapping) ?? false
        maintenance = try c.decodeIfPresent(String.self, forKey: .maintenance) ?? ""
        maintenanceID = try c.decodeIfPresent(String.self, forKey: .maintenanceID) ?? ""
        opensAt = try DateValue.decodeIfPresent(from: c, forKey: .opensAt)
    }

    /// A derived pending incident; it accepts no writes.
    public var isDerivedPending: Bool { id.hasPrefix("pending:") }

    /// The title to show: the server's title, else the subject, else the kind.
    public var displayTitle: String {
        [title, subject, kind].first { !$0.isEmpty } ?? id
    }

    /// Section 4.2, with precedence held, snoozed, acknowledged, then severity.
    public func displayState(now: Date) -> IncidentDisplayState {
        switch state {
        case "resolved": return .resolved
        case "pending": return .pending(opensAt: opensAt)
        default: break
        }
        if !maintenance.isEmpty { return .held(window: maintenance) }
        if IncidentFilter.isSnoozed(self, now: now) { return .snoozed(until: snoozedUntil) }
        if state == "acknowledged" { return .acknowledged }
        switch severity {
        case "critical": return .openCritical
        case "warning": return .openWarning
        default: return .openInfo
        }
    }
}

/// A maintenance window: incidents for its subjects are held and no alerts are sent.
public struct MaintenanceWindow: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var reason: String
    public var nodeIDs: [String]
    public var groupIDs: [String]
    public var startsAt: Date?
    public var endsAt: Date?
    public var createdBy: String
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(id: String, name: String, reason: String = "", nodeIDs: [String] = [], groupIDs: [String] = [], startsAt: Date? = nil, endsAt: Date? = nil) {
        self.id = id
        self.name = name
        self.reason = reason
        self.nodeIDs = nodeIDs
        self.groupIDs = groupIDs
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.createdBy = ""
    }

    enum CodingKeys: String, CodingKey {
        case id, name, reason
        case nodeIDs = "node_ids"
        case groupIDs = "group_ids"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        nodeIDs = try c.decodeIfPresent([String].self, forKey: .nodeIDs) ?? []
        groupIDs = try c.decodeIfPresent([String].self, forKey: .groupIDs) ?? []
        startsAt = try DateValue.decodeIfPresent(from: c, forKey: .startsAt)
        endsAt = try DateValue.decodeIfPresent(from: c, forKey: .endsAt)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? ""
        createdAt = try DateValue.decodeIfPresent(from: c, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: c, forKey: .updatedAt)
    }

    public func isActive(now: Date) -> Bool {
        guard let startsAt, let endsAt else { return false }
        return startsAt <= now && now < endsAt
    }
}

/// The body of `POST /api/maintenance-windows`. The upsert validates every
/// field, so ending a window re-sends it whole with only `endsAt` changed.
public struct MaintenanceWindowInput: Encodable, Equatable, Sendable {
    public var id: String?
    public var name: String
    public var reason: String?
    public var nodeIDs: [String]?
    public var groupIDs: [String]?
    /// Absent starts now (a new window) or keeps the start (an edit).
    public var startsAt: Date?
    public var endsAt: Date

    public init(id: String? = nil, name: String, reason: String? = nil, nodeIDs: [String]? = nil, groupIDs: [String]? = nil, startsAt: Date? = nil, endsAt: Date) {
        self.id = id
        self.name = name
        self.reason = reason
        self.nodeIDs = nodeIDs
        self.groupIDs = groupIDs
        self.startsAt = startsAt
        self.endsAt = endsAt
    }

    /// The stored window with only `ends_at` replaced (End now, section 3.2).
    public init(ending window: MaintenanceWindow, at endsAt: Date) {
        self.init(
            id: window.id,
            name: window.name,
            reason: window.reason.isEmpty ? nil : window.reason,
            nodeIDs: window.nodeIDs.isEmpty ? nil : window.nodeIDs,
            groupIDs: window.groupIDs.isEmpty ? nil : window.groupIDs,
            startsAt: window.startsAt,
            endsAt: endsAt
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, name, reason
        case nodeIDs = "node_ids"
        case groupIDs = "group_ids"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
    }
}

/// `GET /api/incidents`.
public struct IncidentListResponse: Decodable, Equatable, Sendable {
    public var incidents: [Incident]
    /// Active maintenance windows the caller may see.
    public var windows: [MaintenanceWindow]
    public var durable: Bool
    public var now: Date?

    enum CodingKeys: String, CodingKey { case incidents, windows, durable, now }

    public init(incidents: [Incident], windows: [MaintenanceWindow] = [], durable: Bool = true, now: Date? = nil) {
        self.incidents = incidents
        self.windows = windows
        self.durable = durable
        self.now = now
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        incidents = try c.decodeIfPresent([Incident].self, forKey: .incidents) ?? []
        windows = try c.decodeIfPresent([MaintenanceWindow].self, forKey: .windows) ?? []
        durable = try c.decodeIfPresent(Bool.self, forKey: .durable) ?? false
        now = try DateValue.decodeIfPresent(from: c, forKey: .now)
    }
}

/// `GET /api/maintenance-windows`.
public struct MaintenanceWindowsResponse: Decodable, Equatable, Sendable {
    public var windows: [MaintenanceWindow]
    public var now: Date?

    enum CodingKeys: String, CodingKey { case windows, now }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windows = try c.decodeIfPresent([MaintenanceWindow].self, forKey: .windows) ?? []
        now = try DateValue.decodeIfPresent(from: c, forKey: .now)
    }
}

/// The console's incident filters (`incidentsModel.ts`), applied on device to
/// one unfiltered fetch. `Active` is the default scope.
public enum IncidentFilter: String, Sendable, Hashable, CaseIterable {
    case active, open, acknowledged, snoozed, pending, resolved, all

    public static func isActive(_ incident: Incident) -> Bool {
        incident.state == "open" || incident.state == "acknowledged"
    }

    /// `isSnoozed`: an active incident flagged snoozed or snoozed into the future.
    public static func isSnoozed(_ incident: Incident, now: Date) -> Bool {
        guard isActive(incident) else { return false }
        if incident.snoozed { return true }
        guard let until = incident.snoozedUntil else { return false }
        return until > now
    }

    /// `matchesFilter`.
    public func matches(_ incident: Incident, now: Date) -> Bool {
        switch self {
        case .active: Self.isActive(incident)
        case .open: incident.state == "open" && !Self.isSnoozed(incident, now: now)
        case .acknowledged: incident.state == "acknowledged"
        case .snoozed: Self.isSnoozed(incident, now: now)
        case .pending: incident.state == "pending"
        case .resolved: incident.state == "resolved"
        case .all: true
        }
    }
}

/// The T1 actions an incident row offers (`incidentActions`).
public struct IncidentActions: Sendable, Hashable {
    public var acknowledge: Bool
    public var snooze: Bool
    public var endSnooze: Bool

    public init(acknowledge: Bool, snooze: Bool, endSnooze: Bool) {
        self.acknowledge = acknowledge
        self.snooze = snooze
        self.endSnooze = endSnooze
    }

    public static let none = IncidentActions(acknowledge: false, snooze: false, endSnooze: false)

    /// Acknowledge only while open; nothing for derived `pending:` ids or
    /// without `monitor:admin`.
    public static func of(_ incident: Incident, now: Date, canAdmin: Bool) -> IncidentActions {
        guard canAdmin, IncidentFilter.isActive(incident), !incident.isDerivedPending else { return .none }
        return IncidentActions(
            acknowledge: incident.state == "open",
            snooze: true,
            endSnooze: IncidentFilter.isSnoozed(incident, now: now)
        )
    }
}

private struct IncidentSnoozeBody: Encodable {
    var id: String
    var minutes: Int
}

public extension LatticeClient {
    /// `GET /api/incidents`. No states returns all four, default limit 500.
    func listIncidents(states: [IncidentServerState] = [], nodeID: String? = nil, limit: Int? = nil) async throws -> IncidentListResponse {
        var query: [URLQueryItem] = []
        if !states.isEmpty {
            query.append(URLQueryItem(name: "state", value: states.map(\.rawValue).joined(separator: ",")))
        }
        if let nodeID, !nodeID.isEmpty { query.append(URLQueryItem(name: "node_id", value: nodeID)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await perform(IncidentListResponse.self, path: "/api/incidents", query: query)
    }

    func acknowledgeIncident(id: String) async throws -> Incident {
        try await perform(Incident.self, path: "/api/incidents/ack", method: "POST", body: IDBody(id: id))
    }

    /// 409 once the incident closed.
    func unacknowledgeIncident(id: String) async throws -> Incident {
        try await perform(Incident.self, path: "/api/incidents/unack", method: "POST", body: IDBody(id: id))
    }

    /// `minutes: 0` ends a snooze.
    func snoozeIncident(id: String, minutes: Int) async throws -> Incident {
        try await perform(Incident.self, path: "/api/incidents/snooze", method: "POST", body: IncidentSnoozeBody(id: id, minutes: minutes))
    }

    func listMaintenanceWindows() async throws -> MaintenanceWindowsResponse {
        try await perform(MaintenanceWindowsResponse.self, path: "/api/maintenance-windows")
    }

    func upsertMaintenanceWindow(_ input: MaintenanceWindowInput) async throws -> MaintenanceWindow {
        try await perform(MaintenanceWindow.self, path: "/api/maintenance-windows", method: "POST", body: input)
    }

    func deleteMaintenanceWindow(id: String) async throws {
        try await performVoid(path: "/api/maintenance-windows/delete", body: IDBody(id: id))
    }
}
