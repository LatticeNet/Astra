import Foundation

// MARK: - Identity & server

/// Response of `GET /api/me`. Decoded tolerantly because the server may grow the
/// shape over time; unknown fields are ignored and missing fields fall back to
/// safe defaults so an older or newer server never breaks the session view.
public struct LatticeIdentity: Codable, Equatable, Hashable, Sendable {
    public var actorID: String
    public var username: String
    public var scopes: [String]
    public var totpEnabled: Bool
    public var authKind: String?

    public init(actorID: String = "", username: String = "", scopes: [String] = [], totpEnabled: Bool = false, authKind: String? = nil) {
        self.actorID = actorID
        self.username = username
        self.scopes = scopes
        self.totpEnabled = totpEnabled
        self.authKind = authKind
    }

    enum CodingKeys: String, CodingKey {
        case actorID = "actor_id"
        case id
        case username
        case name
        case scopes
        case totpEnabled = "totp_enabled"
        case authKind = "auth_kind"
        case kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actorID = try container.decodeIfPresent(String.self, forKey: .actorID)
            ?? container.decodeIfPresent(String.self, forKey: .id) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username)
            ?? container.decodeIfPresent(String.self, forKey: .name) ?? ""
        scopes = try container.decodeIfPresent([String].self, forKey: .scopes) ?? []
        totpEnabled = try container.decodeIfPresent(Bool.self, forKey: .totpEnabled) ?? false
        authKind = try container.decodeIfPresent(String.self, forKey: .authKind)
            ?? container.decodeIfPresent(String.self, forKey: .kind)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(actorID, forKey: .actorID)
        try container.encode(username, forKey: .username)
        try container.encode(scopes, forKey: .scopes)
        try container.encode(totpEnabled, forKey: .totpEnabled)
        try container.encodeIfPresent(authKind, forKey: .authKind)
    }

    /// True when the identity has the given scope, treating `*` and a matching
    /// domain wildcard (e.g. `node:*`) as granting the specific scope.
    public func hasScope(_ scope: String) -> Bool {
        if scopes.contains("*") || scopes.contains(scope) {
            return true
        }
        if let domain = scope.split(separator: ":").first {
            return scopes.contains("\(domain):*")
        }
        return false
    }

    public var displayName: String {
        if !username.isEmpty { return username }
        if !actorID.isEmpty { return actorID }
        return "Operator"
    }
}

public struct LatticeServerVersion: Codable, Equatable, Hashable, Sendable {
    public var version: String
    public var commit: String
    public var date: String
    public var dashboardRef: String?
    public var dashboardBuilt: String?

    public init(version: String = "", commit: String = "", date: String = "", dashboardRef: String? = nil, dashboardBuilt: String? = nil) {
        self.version = version
        self.commit = commit
        self.date = date
        self.dashboardRef = dashboardRef
        self.dashboardBuilt = dashboardBuilt
    }

    enum CodingKeys: String, CodingKey {
        case version = "server_version"
        case commit = "server_commit"
        case date = "server_date"
        case dashboardRef = "dashboard_ref"
        case dashboardBuilt = "dashboard_built"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        commit = try container.decodeIfPresent(String.self, forKey: .commit) ?? ""
        date = try container.decodeIfPresent(String.self, forKey: .date) ?? ""
        dashboardRef = try container.decodeIfPresent(String.self, forKey: .dashboardRef)
        dashboardBuilt = try container.decodeIfPresent(String.self, forKey: .dashboardBuilt)
    }

    public var shortCommit: String { commit.isEmpty ? "" : String(commit.prefix(8)) }
}

// MARK: - Tokens (personal access tokens)

public struct LatticeToken: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var actorID: String
    public var scopes: [String]
    public var serverAllowlist: [String]
    public var revokedAt: Date?
    public var createdAt: Date?

    public init(id: String, name: String = "", actorID: String = "", scopes: [String] = [], serverAllowlist: [String] = [], revokedAt: Date? = nil, createdAt: Date? = nil) {
        self.id = id
        self.name = name
        self.actorID = actorID
        self.scopes = scopes
        self.serverAllowlist = serverAllowlist
        self.revokedAt = revokedAt
        self.createdAt = createdAt
    }

    public var isRevoked: Bool { revokedAt != nil }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case actorID = "actor_id"
        case scopes
        case serverAllowlist = "server_allowlist"
        case revokedAt = "revoked_at"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        actorID = try container.decodeIfPresent(String.self, forKey: .actorID) ?? ""
        scopes = try container.decodeIfPresent([String].self, forKey: .scopes) ?? []
        serverAllowlist = try container.decodeIfPresent([String].self, forKey: .serverAllowlist) ?? []
        revokedAt = try DateValue.decodeIfPresent(from: container, forKey: .revokedAt)
        createdAt = try DateValue.decodeIfPresent(from: container, forKey: .createdAt)
    }
}

// MARK: - Machine inventory

public enum RenewalCycle: String, Codable, CaseIterable, Sendable {
    case monthly
    case quarterly
    case semiannual
    case annual
    case customDays = "custom_days"

    public var displayName: String {
        switch self {
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        case .semiannual: "Semi-annual"
        case .annual: "Annual"
        case .customDays: "Custom"
        }
    }

    /// Approximate number of days in one cycle, for normalizing cost to monthly.
    public func approximateDays(customDays: Int) -> Int {
        switch self {
        case .monthly: 30
        case .quarterly: 91
        case .semiannual: 182
        case .annual: 365
        case .customDays: max(customDays, 1)
        }
    }
}

/// Operator-authored inventory, cost and renewal metadata bound to a node. This
/// is the secret-free `machineView` returned by the server: console/detail URLs
/// are never sent back, only `hasConsoleURL`/`hasDetailURL` booleans. The
/// write-only `consoleURL`/`detailURL` fields hold values the edit form is about
/// to submit and are always empty when decoded from the server.
public struct MachineProfile: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var nodeID: String
    public var nodeName: String
    public var label: String
    public var online: Bool
    public var hostFacts: LatticeHostFacts
    public var vendor: String
    public var region: String
    public var notes: String
    public var hasConsoleURL: Bool
    public var hasDetailURL: Bool
    public var priceCents: Int64
    public var currency: String
    public var renewalCycleRaw: String
    public var cycleDays: Int
    public var nextRenewal: Date?
    public var serverDaysUntilRenewal: Int
    public var autoRoll: Bool
    public var remindDaysBefore: [Int]
    public var remindersEnabled: Bool
    public var createdAt: Date?
    public var updatedAt: Date?

    // Write-only, never populated by the server; used by the edit form.
    public var consoleURL: String
    public var detailURL: String

    public init(
        id: String,
        nodeID: String = "",
        nodeName: String = "",
        label: String = "",
        online: Bool = false,
        hostFacts: LatticeHostFacts = LatticeHostFacts(),
        vendor: String = "",
        region: String = "",
        notes: String = "",
        hasConsoleURL: Bool = false,
        hasDetailURL: Bool = false,
        priceCents: Int64 = 0,
        currency: String = "",
        renewalCycleRaw: String = "",
        cycleDays: Int = 0,
        nextRenewal: Date? = nil,
        serverDaysUntilRenewal: Int = 0,
        autoRoll: Bool = false,
        remindDaysBefore: [Int] = [],
        remindersEnabled: Bool = false,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        consoleURL: String = "",
        detailURL: String = ""
    ) {
        self.id = id
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.label = label
        self.online = online
        self.hostFacts = hostFacts
        self.vendor = vendor
        self.region = region
        self.notes = notes
        self.hasConsoleURL = hasConsoleURL
        self.hasDetailURL = hasDetailURL
        self.priceCents = priceCents
        self.currency = currency
        self.renewalCycleRaw = renewalCycleRaw
        self.cycleDays = cycleDays
        self.nextRenewal = nextRenewal
        self.serverDaysUntilRenewal = serverDaysUntilRenewal
        self.autoRoll = autoRoll
        self.remindDaysBefore = remindDaysBefore
        self.remindersEnabled = remindersEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.consoleURL = consoleURL
        self.detailURL = detailURL
    }

    public var renewalCycle: RenewalCycle? { RenewalCycle(rawValue: renewalCycleRaw) }

    public var displayLabel: String {
        if !label.isEmpty { return label }
        if !nodeName.isEmpty { return nodeName }
        if !vendor.isEmpty { return vendor }
        return nodeID
    }

    public var priceMajorUnits: Double { Double(priceCents) / 100 }

    /// Cost normalized to a 30-day month, in major currency units.
    public var monthlyCost: Double? {
        guard priceCents > 0, let cycle = renewalCycle else { return nil }
        let days = cycle.approximateDays(customDays: cycleDays)
        return priceMajorUnits * 30 / Double(days)
    }

    public func daysUntilRenewal(now: Date = Date()) -> Int? {
        guard let nextRenewal else { return nil }
        let seconds = nextRenewal.timeIntervalSince(now)
        return Int((seconds / 86_400).rounded(.towardZero))
    }

    enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case nodeName = "node_name"
        case label
        case online
        case hostFacts = "host_facts"
        case vendor
        case region
        case notes
        case hasConsoleURL = "has_console_url"
        case hasDetailURL = "has_detail_url"
        case priceCents = "price_cents"
        case currency
        case renewalCycleRaw = "renewal_cycle"
        case cycleDays = "cycle_days"
        case nextRenewal = "next_renewal"
        case serverDaysUntilRenewal = "days_until_renewal"
        case autoRoll = "auto_roll"
        case remindDaysBefore = "remind_days_before"
        case remindersEnabled = "reminders_enabled"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        nodeName = try container.decodeIfPresent(String.self, forKey: .nodeName) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        online = try container.decodeIfPresent(Bool.self, forKey: .online) ?? false
        hostFacts = try container.decodeIfPresent(LatticeHostFacts.self, forKey: .hostFacts) ?? LatticeHostFacts()
        vendor = try container.decodeIfPresent(String.self, forKey: .vendor) ?? ""
        region = try container.decodeIfPresent(String.self, forKey: .region) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        hasConsoleURL = try container.decodeIfPresent(Bool.self, forKey: .hasConsoleURL) ?? false
        hasDetailURL = try container.decodeIfPresent(Bool.self, forKey: .hasDetailURL) ?? false
        priceCents = try container.decodeIfPresent(Int64.self, forKey: .priceCents) ?? 0
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? ""
        renewalCycleRaw = try container.decodeIfPresent(String.self, forKey: .renewalCycleRaw) ?? ""
        cycleDays = try container.decodeIfPresent(Int.self, forKey: .cycleDays) ?? 0
        nextRenewal = try DateValue.decodeIfPresent(from: container, forKey: .nextRenewal)
        serverDaysUntilRenewal = try container.decodeIfPresent(Int.self, forKey: .serverDaysUntilRenewal) ?? 0
        autoRoll = try container.decodeIfPresent(Bool.self, forKey: .autoRoll) ?? false
        remindDaysBefore = try container.decodeIfPresent([Int].self, forKey: .remindDaysBefore) ?? []
        remindersEnabled = try container.decodeIfPresent(Bool.self, forKey: .remindersEnabled) ?? false
        createdAt = try DateValue.decodeIfPresent(from: container, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: container, forKey: .updatedAt)
        consoleURL = ""
        detailURL = ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(nodeID, forKey: .nodeID)
        try container.encode(label, forKey: .label)
        try container.encode(vendor, forKey: .vendor)
        try container.encode(region, forKey: .region)
        try container.encode(notes, forKey: .notes)
        try container.encode(priceCents, forKey: .priceCents)
        try container.encode(currency, forKey: .currency)
        try container.encode(renewalCycleRaw, forKey: .renewalCycleRaw)
        try container.encode(cycleDays, forKey: .cycleDays)
        try container.encode(autoRoll, forKey: .autoRoll)
        try container.encode(remindDaysBefore, forKey: .remindDaysBefore)
        try container.encode(remindersEnabled, forKey: .remindersEnabled)
    }
}

// MARK: - Monitors (reachability/latency probes)

public enum MonitorType: String, Codable, CaseIterable, Sendable {
    case tcp
    case http
    case icmp

    public var displayName: String {
        switch self {
        case .tcp: "TCP"
        case .http: "HTTP"
        case .icmp: "ICMP"
        }
    }
}

public struct Monitor: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var typeRaw: String
    public var target: String
    public var intervalSec: Int
    public var timeoutSec: Int
    public var assignAll: Bool
    public var nodeIDs: [String]
    public var enabled: Bool
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        id: String,
        name: String = "",
        typeRaw: String = "http",
        target: String = "",
        intervalSec: Int = 60,
        timeoutSec: Int = 10,
        assignAll: Bool = false,
        nodeIDs: [String] = [],
        enabled: Bool = true,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.typeRaw = typeRaw
        self.target = target
        self.intervalSec = intervalSec
        self.timeoutSec = timeoutSec
        self.assignAll = assignAll
        self.nodeIDs = nodeIDs
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var type: MonitorType? { MonitorType(rawValue: typeRaw) }

    public var displayName: String { name.isEmpty ? id : name }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case typeRaw = "type"
        case target
        case intervalSec = "interval_sec"
        case timeoutSec = "timeout_sec"
        case assignAll = "assign_all"
        case nodeIDs = "node_ids"
        case enabled
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        typeRaw = try container.decodeIfPresent(String.self, forKey: .typeRaw) ?? ""
        target = try container.decodeIfPresent(String.self, forKey: .target) ?? ""
        intervalSec = try container.decodeIfPresent(Int.self, forKey: .intervalSec) ?? 0
        timeoutSec = try container.decodeIfPresent(Int.self, forKey: .timeoutSec) ?? 0
        assignAll = try container.decodeIfPresent(Bool.self, forKey: .assignAll) ?? false
        nodeIDs = try container.decodeIfPresent([String].self, forKey: .nodeIDs) ?? []
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        createdAt = try DateValue.decodeIfPresent(from: container, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: container, forKey: .updatedAt)
    }
}

public struct MonitorResult: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var monitorID: String
    public var nodeID: String
    public var at: Date?
    public var success: Bool
    public var latencyMs: Double
    public var error: String?

    public init(monitorID: String, nodeID: String, at: Date? = nil, success: Bool = false, latencyMs: Double = 0, error: String? = nil) {
        self.monitorID = monitorID
        self.nodeID = nodeID
        self.at = at
        self.success = success
        self.latencyMs = latencyMs
        self.error = error
    }

    public var id: String {
        "\(monitorID).\(nodeID).\(at?.timeIntervalSince1970 ?? 0)"
    }

    enum CodingKeys: String, CodingKey {
        case monitorID = "monitor_id"
        case nodeID = "node_id"
        case at
        case success
        case latencyMs = "latency_ms"
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        monitorID = try container.decodeIfPresent(String.self, forKey: .monitorID) ?? ""
        nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        at = try DateValue.decodeIfPresent(from: container, forKey: .at)
        success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? false
        latencyMs = try container.decodeIfPresent(Double.self, forKey: .latencyMs) ?? 0
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

// MARK: - Notifications (server-side channels & rules)

public struct NotifyChannel: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var configKeys: [String]
    public var enabled: Bool
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(id: String, name: String = "", kind: String = "", configKeys: [String] = [], enabled: Bool = false, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.configKeys = configKeys
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayName: String { name.isEmpty ? id : name }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, enabled
        case configKeys = "config_keys"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        configKeys = try container.decodeIfPresent([String].self, forKey: .configKeys) ?? []
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        createdAt = try DateValue.decodeIfPresent(from: container, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: container, forKey: .updatedAt)
    }
}

public struct NotifyRule: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var eventTypes: [String]
    public var channelIDs: [String]
    public var titleTemplate: String
    public var bodyTemplate: String
    public var enabled: Bool
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(id: String, name: String = "", eventTypes: [String] = [], channelIDs: [String] = [], titleTemplate: String = "", bodyTemplate: String = "", enabled: Bool = false, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.eventTypes = eventTypes
        self.channelIDs = channelIDs
        self.titleTemplate = titleTemplate
        self.bodyTemplate = bodyTemplate
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayName: String { name.isEmpty ? id : name }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled
        case eventTypes = "event_types"
        case channelIDs = "channel_ids"
        case titleTemplate = "title_template"
        case bodyTemplate = "body_template"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        eventTypes = try container.decodeIfPresent([String].self, forKey: .eventTypes) ?? []
        channelIDs = try container.decodeIfPresent([String].self, forKey: .channelIDs) ?? []
        titleTemplate = try container.decodeIfPresent(String.self, forKey: .titleTemplate) ?? ""
        bodyTemplate = try container.decodeIfPresent(String.self, forKey: .bodyTemplate) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        createdAt = try DateValue.decodeIfPresent(from: container, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: container, forKey: .updatedAt)
    }
}

// MARK: - Audit

public struct AuditEvent: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var at: Date?
    public var actorID: String
    public var tokenID: String
    public var nodeID: String
    public var action: String
    public var scope: String
    public var decision: String
    public var reason: String
    public var correlationID: String
    public var metadata: [String: String]

    public init(id: String, at: Date? = nil, actorID: String = "", tokenID: String = "", nodeID: String = "", action: String = "", scope: String = "", decision: String = "", reason: String = "", correlationID: String = "", metadata: [String: String] = [:]) {
        self.id = id
        self.at = at
        self.actorID = actorID
        self.tokenID = tokenID
        self.nodeID = nodeID
        self.action = action
        self.scope = scope
        self.decision = decision
        self.reason = reason
        self.correlationID = correlationID
        self.metadata = metadata
    }

    public var isDeny: Bool { decision.lowercased() == "deny" || decision.lowercased() == "denied" }

    enum CodingKeys: String, CodingKey {
        case id, at, action, scope, decision, reason, metadata
        case actorID = "actor_id"
        case tokenID = "token_id"
        case nodeID = "node_id"
        case correlationID = "correlation_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        at = try DateValue.decodeIfPresent(from: container, forKey: .at)
        actorID = try container.decodeIfPresent(String.self, forKey: .actorID) ?? ""
        tokenID = try container.decodeIfPresent(String.self, forKey: .tokenID) ?? ""
        nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        action = try container.decodeIfPresent(String.self, forKey: .action) ?? ""
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? ""
        decision = try container.decodeIfPresent(String.self, forKey: .decision) ?? ""
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        correlationID = try container.decodeIfPresent(String.self, forKey: .correlationID) ?? ""
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }
}

// MARK: - Tasks

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

// MARK: - Logs

public struct LogSource: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var nodeID: String
    public var path: String
    public var enabled: Bool
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(id: String, name: String = "", nodeID: String = "", path: String = "", enabled: Bool = false, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.nodeID = nodeID
        self.path = path
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayName: String { name.isEmpty ? path : name }

    enum CodingKeys: String, CodingKey {
        case id, name, path, enabled
        case nodeID = "node_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        createdAt = try DateValue.decodeIfPresent(from: container, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: container, forKey: .updatedAt)
    }
}

public struct LogLine: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var sourceID: String
    public var nodeID: String
    public var path: String
    public var seq: UInt64
    public var at: Date?
    public var line: String
    public var truncated: Bool

    public init(sourceID: String, nodeID: String = "", path: String = "", seq: UInt64 = 0, at: Date? = nil, line: String = "", truncated: Bool = false) {
        self.sourceID = sourceID
        self.nodeID = nodeID
        self.path = path
        self.seq = seq
        self.at = at
        self.line = line
        self.truncated = truncated
    }

    public var id: String { "\(sourceID).\(seq)" }

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case nodeID = "node_id"
        case path, seq, at, line, truncated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID) ?? ""
        nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        seq = try container.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
        at = try DateValue.decodeIfPresent(from: container, forKey: .at)
        line = try container.decodeIfPresent(String.self, forKey: .line) ?? ""
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

// MARK: - Node geo (full operator metadata)

public struct NodeGeoInfo: Codable, Equatable, Hashable, Sendable {
    public var country: String
    public var region: String
    public var city: String
    public var lat: Double
    public var lon: Double
    public var ip: String
    public var asn: Int
    public var asOrg: String
    public var provider: String
    public var source: String
    public var updatedAt: Date?

    public init(country: String = "", region: String = "", city: String = "", lat: Double = 0, lon: Double = 0, ip: String = "", asn: Int = 0, asOrg: String = "", provider: String = "", source: String = "", updatedAt: Date? = nil) {
        self.country = country
        self.region = region
        self.city = city
        self.lat = lat
        self.lon = lon
        self.ip = ip
        self.asn = asn
        self.asOrg = asOrg
        self.provider = provider
        self.source = source
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case country, region, city, lat, lon, ip, asn, source
        case asOrg = "as_org"
        case provider
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        country = try container.decodeIfPresent(String.self, forKey: .country) ?? ""
        region = try container.decodeIfPresent(String.self, forKey: .region) ?? ""
        city = try container.decodeIfPresent(String.self, forKey: .city) ?? ""
        lat = try container.decodeIfPresent(Double.self, forKey: .lat) ?? 0
        lon = try container.decodeIfPresent(Double.self, forKey: .lon) ?? 0
        ip = try container.decodeIfPresent(String.self, forKey: .ip) ?? ""
        asn = try container.decodeIfPresent(Int.self, forKey: .asn) ?? 0
        asOrg = try container.decodeIfPresent(String.self, forKey: .asOrg) ?? ""
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        updatedAt = try DateValue.decodeIfPresent(from: container, forKey: .updatedAt)
    }
}

/// `nodeGeoView` returned by `GET /api/nodes/geo`: a node plus its map metadata.
public struct NodeGeoView: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var role: String
    public var online: Bool
    public var publicIP: String
    public var publicIPv6: String
    public var geo: NodeGeoInfo?

    public init(id: String, name: String = "", role: String = "", online: Bool = false, publicIP: String = "", publicIPv6: String = "", geo: NodeGeoInfo? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.online = online
        self.publicIP = publicIP
        self.publicIPv6 = publicIPv6
        self.geo = geo
    }

    public var displayName: String { name.isEmpty ? id : name }

    /// Whether this node has a usable map coordinate.
    public var hasCoordinate: Bool {
        guard let geo else { return false }
        return geo.lat != 0 || geo.lon != 0
    }

    enum CodingKeys: String, CodingKey {
        case id, name, role, online, geo
        case publicIP = "public_ip"
        case publicIPv6 = "public_ipv6"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        online = try container.decodeIfPresent(Bool.self, forKey: .online) ?? false
        publicIP = try container.decodeIfPresent(String.self, forKey: .publicIP) ?? ""
        publicIPv6 = try container.decodeIfPresent(String.self, forKey: .publicIPv6) ?? ""
        geo = try container.decodeIfPresent(NodeGeoInfo.self, forKey: .geo)
    }
}
