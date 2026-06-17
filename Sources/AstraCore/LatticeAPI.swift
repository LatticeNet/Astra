import Foundation

// MARK: - Generic request plumbing

extension LatticeClient {
    /// Shared encoder. Dates are emitted as RFC3339, matching Go's `time.Time`
    /// JSON marshalling on the server.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Build a request that carries a JSON body and optional query items, reusing
    /// the authenticated `buildRequest` so the bearer token / session cookie +
    /// `X-Lattice-CSRF` header are always applied.
    func buildJSONRequest(
        path: String,
        method: String,
        bodyData: Data?,
        query: [URLQueryItem]
    ) throws -> URLRequest {
        var request = try buildRequest(path: path, method: method)
        if !query.isEmpty,
           let url = request.url,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            request.url = components.url
        }
        if let bodyData {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }
        return request
    }

    /// Execute and validate, returning the raw response body.
    func performData(
        path: String,
        method: String = "GET",
        body: (any Encodable)? = nil,
        query: [URLQueryItem] = []
    ) async throws -> Data {
        let bodyData: Data?
        if let body {
            bodyData = try Self.makeEncoder().encode(AnyEncodable(body))
        } else {
            bodyData = nil
        }
        let request = try buildJSONRequest(path: path, method: method, bodyData: bodyData, query: query)
        let (data, response) = try await transport.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    /// Execute, validate, and decode a `Decodable` response.
    func perform<T: Decodable>(
        _ type: T.Type = T.self,
        path: String,
        method: String = "GET",
        body: (any Encodable)? = nil,
        query: [URLQueryItem] = []
    ) async throws -> T {
        let data = try await performData(path: path, method: method, body: body, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LatticeAPIError.invalidResponse
        }
    }

    /// Execute and discard the body (used for `{"ok": true}` style responses).
    @discardableResult
    func performVoid(
        path: String,
        method: String = "POST",
        body: (any Encodable)? = nil,
        query: [URLQueryItem] = []
    ) async throws -> Data {
        try await performData(path: path, method: method, body: body, query: query)
    }
}

/// Type-erasing box so heterogeneous `Encodable` request payloads can be encoded
/// through a single code path.
struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void
    init(_ wrapped: any Encodable) {
        encodeClosure = wrapped.encode
    }
    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}

// MARK: - Response envelope wrappers

private struct RulesEnvelope: Decodable { var rules: [NotifyRule] }
private struct SourcesEnvelope: Decodable { var sources: [LogSource] }
private struct StatsEnvelope: Decodable { var stats: [LogSourceStats] }
private struct ResultsEnvelope: Decodable { var results: [NodeGeoResolveResult] }
private struct FiredEnvelope: Decodable { var fired: [RenewalReminderFire] }

/// `GET /api/audit` with query params returns this; without params it is a bare
/// array. The client always sends a limit, so it always sees this shape.
public struct AuditQueryResponse: Decodable, Sendable {
    public var events: [AuditEvent]
    public var total: Int
    public var limit: Int
    public var offset: Int

    public init(events: [AuditEvent] = [], total: Int = 0, limit: Int = 0, offset: Int = 0) {
        self.events = events
        self.total = total
        self.limit = limit
        self.offset = offset
    }

    enum CodingKeys: String, CodingKey { case events, total, limit, offset }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = try container.decodeIfPresent([AuditEvent].self, forKey: .events) ?? []
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? 0
        offset = try container.decodeIfPresent(Int.self, forKey: .offset) ?? 0
    }
}

public struct LogQueryResponse: Decodable, Sendable {
    public var lines: [LogLine]
    public var truncated: Bool
    public var nextBeforeSeq: UInt64?

    public init(lines: [LogLine] = [], truncated: Bool = false, nextBeforeSeq: UInt64? = nil) {
        self.lines = lines
        self.truncated = truncated
        self.nextBeforeSeq = nextBeforeSeq
    }

    enum CodingKeys: String, CodingKey {
        case lines, truncated
        case nextBeforeSeq = "next_before_seq"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lines = try container.decodeIfPresent([LogLine].self, forKey: .lines) ?? []
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        nextBeforeSeq = try container.decodeIfPresent(UInt64.self, forKey: .nextBeforeSeq)
    }
}

public struct LogSourceStats: Identifiable, Decodable, Equatable, Hashable, Sendable {
    public var sourceID: String
    public var nodeID: String
    public var name: String
    public var path: String
    public var enabled: Bool
    public var lines: UInt64
    public var bytes: UInt64
    public var firstAt: Date?
    public var lastAt: Date?
    public var lastIngestAt: Date?

    public var id: String { sourceID }

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case nodeID = "node_id"
        case name, path, enabled, lines, bytes
        case firstAt = "first_at"
        case lastAt = "last_at"
        case lastIngestAt = "last_ingest_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID) ?? ""
        nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        lines = try container.decodeIfPresent(UInt64.self, forKey: .lines) ?? 0
        bytes = try container.decodeIfPresent(UInt64.self, forKey: .bytes) ?? 0
        firstAt = try DateValue.decodeIfPresent(from: container, forKey: .firstAt)
        lastAt = try DateValue.decodeIfPresent(from: container, forKey: .lastAt)
        lastIngestAt = try DateValue.decodeIfPresent(from: container, forKey: .lastIngestAt)
    }
}

public struct NodeGeoResolveResult: Identifiable, Decodable, Equatable, Hashable, Sendable {
    public var nodeID: String
    public var ip: String
    public var status: String
    public var message: String
    public var geo: NodeGeoInfo?

    public var id: String { nodeID }

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case ip, status, message, geo
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        ip = try container.decodeIfPresent(String.self, forKey: .ip) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        geo = try container.decodeIfPresent(NodeGeoInfo.self, forKey: .geo)
    }
}

public struct RenewalReminderFire: Identifiable, Decodable, Equatable, Hashable, Sendable {
    public var machineID: String
    public var nodeID: String
    public var nodeName: String
    public var offsetDays: Int
    public var nextRenewal: String

    public var id: String { "\(machineID).\(offsetDays)" }

    enum CodingKeys: String, CodingKey {
        case machineID = "machine_id"
        case nodeID = "node_id"
        case nodeName = "node_name"
        case offsetDays = "offset_days"
        case nextRenewal = "next_renewal"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        machineID = try container.decodeIfPresent(String.self, forKey: .machineID) ?? ""
        nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        nodeName = try container.decodeIfPresent(String.self, forKey: .nodeName) ?? ""
        offsetDays = try container.decodeIfPresent(Int.self, forKey: .offsetDays) ?? 0
        nextRenewal = try container.decodeIfPresent(String.self, forKey: .nextRenewal) ?? ""
    }
}

/// One-time credential responses (`token` is shown once and never again).
public struct NodeTokenResponse: Decodable, Sendable, Identifiable {
    public var nodeID: String
    public var token: String
    public var serverURL: String?
    public var command: String?

    public var id: String { token }

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case token
        case serverURL = "server_url"
        case command
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        serverURL = try container.decodeIfPresent(String.self, forKey: .serverURL)
        command = try container.decodeIfPresent(String.self, forKey: .command)
    }
}

public struct CreatedTokenResponse: Decodable, Sendable, Identifiable {
    public var id: String
    public var token: String
    public var view: LatticeToken?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CreatedTokenResponse.CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        view = try container.decodeIfPresent(LatticeToken.self, forKey: .view)
    }

    enum CodingKeys: String, CodingKey { case id, token, view }
}

public struct AuditChainStatus: Decodable, Sendable {
    public var enabled: Bool
    public var ok: Bool
    public var count: Int
    public var error: String?

    public init(enabled: Bool = false, ok: Bool = false, count: Int = 0, error: String? = nil) {
        self.enabled = enabled
        self.ok = ok
        self.count = count
        self.error = error
    }

    enum CodingKeys: String, CodingKey { case enabled, ok, count, error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 0
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

// MARK: - Request payloads (must match server structs; unknown fields are rejected)

struct NodeDisableRequest: Encodable {
    var nodeID: String
    var disabled: Bool
    enum CodingKeys: String, CodingKey { case nodeID = "node_id", disabled }
}

struct NodeIDRequest: Encodable {
    var nodeID: String
    enum CodingKeys: String, CodingKey { case nodeID = "node_id" }
}

struct EnrollNodeRequest: Encodable {
    var nodeID: String
    var name: String
    var tags: [String]
    var role: String
    var wireGuardIP: String
    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id", name, tags, role
        case wireGuardIP = "wireguard_ip"
    }
}

struct CreateTokenRequest: Encodable {
    var name: String
    var scopes: [String]
    var serverAllowlist: [String]
    enum CodingKeys: String, CodingKey {
        case name, scopes
        case serverAllowlist = "server_allowlist"
    }
}

struct RevokeTokenRequest: Encodable {
    var tokenID: String
    enum CodingKeys: String, CodingKey { case tokenID = "token_id" }
}

struct MonitorCreateRequest: Encodable {
    var name: String
    var type: String
    var target: String
    var intervalSec: Int
    var timeoutSec: Int
    var assignAll: Bool
    var nodeIDs: [String]
    enum CodingKeys: String, CodingKey {
        case name, type, target
        case intervalSec = "interval_sec"
        case timeoutSec = "timeout_sec"
        case assignAll = "assign_all"
        case nodeIDs = "node_ids"
    }
}

struct NotifyChannelRequest: Encodable {
    var id: String
    var name: String
    var kind: String
    var config: [String: String]
    var enabled: Bool
}

struct NotifyRuleRequest: Encodable {
    var id: String
    var name: String
    var eventTypes: [String]
    var channelIDs: [String]
    var titleTemplate: String
    var bodyTemplate: String
    var enabled: Bool
    enum CodingKeys: String, CodingKey {
        case id, name, enabled
        case eventTypes = "event_types"
        case channelIDs = "channel_ids"
        case titleTemplate = "title_template"
        case bodyTemplate = "body_template"
    }
}

struct NotifyTestRequest: Encodable {
    var channel: String
    var config: [String: String]
    var title: String
    var body: String
}

struct MachineDeleteRequest: Encodable {
    var id: String
}

struct MachineRenewRequest: Encodable {
    var id: String
    var nextRenewal: Date
    enum CodingKeys: String, CodingKey {
        case id
        case nextRenewal = "next_renewal"
    }
}

/// Mirrors the server `machineProfileRequest`. Only the fields the edit form
/// owns are sent; the server forces `id = ""` on create.
public struct MachineProfileRequest: Encodable, Sendable {
    public var id: String
    public var nodeID: String
    public var label: String
    public var vendor: String
    public var consoleURL: String
    public var detailURL: String
    public var clearConsoleURL: Bool
    public var clearDetailURL: Bool
    public var region: String
    public var notes: String
    public var priceCents: Int64
    public var currency: String
    public var renewalCycle: String
    public var cycleDays: Int
    public var nextRenewal: Date?
    public var autoRoll: Bool
    public var remindDaysBefore: [Int]
    public var remindersEnabled: Bool

    public init(
        id: String = "",
        nodeID: String = "",
        label: String = "",
        vendor: String = "",
        consoleURL: String = "",
        detailURL: String = "",
        clearConsoleURL: Bool = false,
        clearDetailURL: Bool = false,
        region: String = "",
        notes: String = "",
        priceCents: Int64 = 0,
        currency: String = "",
        renewalCycle: String = "",
        cycleDays: Int = 0,
        nextRenewal: Date? = nil,
        autoRoll: Bool = false,
        remindDaysBefore: [Int] = [],
        remindersEnabled: Bool = false
    ) {
        self.id = id
        self.nodeID = nodeID
        self.label = label
        self.vendor = vendor
        self.consoleURL = consoleURL
        self.detailURL = detailURL
        self.clearConsoleURL = clearConsoleURL
        self.clearDetailURL = clearDetailURL
        self.region = region
        self.notes = notes
        self.priceCents = priceCents
        self.currency = currency
        self.renewalCycle = renewalCycle
        self.cycleDays = cycleDays
        self.nextRenewal = nextRenewal
        self.autoRoll = autoRoll
        self.remindDaysBefore = remindDaysBefore
        self.remindersEnabled = remindersEnabled
    }

    enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case label, vendor
        case consoleURL = "console_url"
        case detailURL = "detail_url"
        case clearConsoleURL = "clear_console_url"
        case clearDetailURL = "clear_detail_url"
        case region, notes
        case priceCents = "price_cents"
        case currency
        case renewalCycle = "renewal_cycle"
        case cycleDays = "cycle_days"
        case nextRenewal = "next_renewal"
        case autoRoll = "auto_roll"
        case remindDaysBefore = "remind_days_before"
        case remindersEnabled = "reminders_enabled"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(nodeID, forKey: .nodeID)
        try container.encode(label, forKey: .label)
        try container.encode(vendor, forKey: .vendor)
        try container.encode(consoleURL, forKey: .consoleURL)
        try container.encode(detailURL, forKey: .detailURL)
        try container.encode(clearConsoleURL, forKey: .clearConsoleURL)
        try container.encode(clearDetailURL, forKey: .clearDetailURL)
        try container.encode(region, forKey: .region)
        try container.encode(notes, forKey: .notes)
        try container.encode(priceCents, forKey: .priceCents)
        try container.encode(currency, forKey: .currency)
        try container.encode(renewalCycle, forKey: .renewalCycle)
        try container.encode(cycleDays, forKey: .cycleDays)
        try container.encodeIfPresent(nextRenewal, forKey: .nextRenewal)
        try container.encode(autoRoll, forKey: .autoRoll)
        try container.encode(remindDaysBefore, forKey: .remindDaysBefore)
        try container.encode(remindersEnabled, forKey: .remindersEnabled)
    }
}

struct NodeGeoInput: Encodable {
    var country: String
    var region: String
    var city: String
    var lat: Double
    var lon: Double
    var asOrg: String
    var provider: String
    enum CodingKeys: String, CodingKey {
        case country, region, city, lat, lon, provider
        case asOrg = "as_org"
    }
}

struct NodeGeoSetRequest: Encodable {
    var nodeID: String
    var geo: NodeGeoInput
    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case geo
    }
}

struct NodeGeoResolveRequest: Encodable {
    var nodeID: String?
    var all: Bool
    var missingOnly: Bool
    var overwrite: Bool
    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case all
        case missingOnly = "missing_only"
        case overwrite
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(nodeID, forKey: .nodeID)
        try container.encode(all, forKey: .all)
        try container.encode(missingOnly, forKey: .missingOnly)
        try container.encode(overwrite, forKey: .overwrite)
    }
}

// MARK: - Typed endpoints

public extension LatticeClient {
    // Identity & server
    func fetchIdentity() async throws -> LatticeIdentity {
        try await perform(LatticeIdentity.self, path: "/api/me")
    }

    func fetchServerVersion() async throws -> LatticeServerVersion {
        try await perform(LatticeServerVersion.self, path: "/api/version")
    }

    // Nodes — actions
    @discardableResult
    func setNodeDisabled(nodeID: String, disabled: Bool) async throws -> Data {
        try await performVoid(
            path: "/api/nodes/disable",
            body: NodeDisableRequest(nodeID: nodeID, disabled: disabled),
            query: [URLQueryItem(name: "node_id", value: nodeID)]
        )
    }

    func rotateNodeToken(nodeID: String) async throws -> NodeTokenResponse {
        try await perform(
            NodeTokenResponse.self,
            path: "/api/nodes/rotate-token",
            method: "POST",
            body: NodeIDRequest(nodeID: nodeID),
            query: [URLQueryItem(name: "node_id", value: nodeID)]
        )
    }

    func enrollNode(nodeID: String, name: String, tags: [String] = [], role: String = "", wireGuardIP: String = "") async throws -> NodeTokenResponse {
        try await perform(
            NodeTokenResponse.self,
            path: "/api/nodes/enroll-token",
            method: "POST",
            body: EnrollNodeRequest(nodeID: nodeID, name: name, tags: tags, role: role, wireGuardIP: wireGuardIP)
        )
    }

    // Tokens
    func listTokens() async throws -> [LatticeToken] {
        try await perform([LatticeToken].self, path: "/api/tokens")
    }

    func createToken(name: String, scopes: [String], serverAllowlist: [String] = []) async throws -> CreatedTokenResponse {
        try await perform(
            CreatedTokenResponse.self,
            path: "/api/tokens",
            method: "POST",
            body: CreateTokenRequest(name: name, scopes: scopes, serverAllowlist: serverAllowlist)
        )
    }

    func revokeToken(tokenID: String) async throws {
        try await performVoid(path: "/api/tokens/revoke", body: RevokeTokenRequest(tokenID: tokenID))
    }

    // Machine inventory
    func listMachines() async throws -> [MachineProfile] {
        try await perform([MachineProfile].self, path: "/api/machines")
    }

    func createMachine(_ request: MachineProfileRequest) async throws -> MachineProfile {
        var req = request
        req.id = ""
        return try await perform(MachineProfile.self, path: "/api/machines", method: "POST", body: req)
    }

    func updateMachine(_ request: MachineProfileRequest) async throws -> MachineProfile {
        try await perform(MachineProfile.self, path: "/api/machines/update", method: "POST", body: request)
    }

    func deleteMachine(id: String) async throws {
        try await performVoid(path: "/api/machines/delete", body: MachineDeleteRequest(id: id))
    }

    func renewMachine(id: String, nextRenewal: Date) async throws -> MachineProfile {
        try await perform(
            MachineProfile.self,
            path: "/api/machines/renew",
            method: "POST",
            body: MachineRenewRequest(id: id, nextRenewal: nextRenewal)
        )
    }

    @discardableResult
    func runRenewalReminders() async throws -> [RenewalReminderFire] {
        let data = try await performData(path: "/api/machines/reminders/run", method: "POST")
        let envelope = (try? JSONDecoder().decode(FiredEnvelope.self, from: data)) ?? FiredEnvelope(fired: [])
        return envelope.fired
    }

    // Monitors
    func listMonitors() async throws -> [Monitor] {
        try await perform([Monitor].self, path: "/api/monitors")
    }

    func createMonitor(name: String, type: MonitorType, target: String, intervalSec: Int, timeoutSec: Int, assignAll: Bool, nodeIDs: [String]) async throws {
        try await performVoid(
            path: "/api/monitors",
            body: MonitorCreateRequest(
                name: name, type: type.rawValue, target: target,
                intervalSec: intervalSec, timeoutSec: timeoutSec,
                assignAll: assignAll, nodeIDs: nodeIDs
            )
        )
    }

    func deleteMonitor(id: String) async throws {
        try await performVoid(path: "/api/monitors/delete", body: MachineDeleteRequest(id: id))
    }

    func monitorResults(monitorID: String) async throws -> [MonitorResult] {
        try await perform(
            [MonitorResult].self,
            path: "/api/monitors/results",
            query: [URLQueryItem(name: "monitor_id", value: monitorID)]
        )
    }

    // Notifications
    func listNotifyChannels() async throws -> [NotifyChannel] {
        try await perform([NotifyChannel].self, path: "/api/notify/channels")
    }

    func listNotifyRules() async throws -> [NotifyRule] {
        let data = try await performData(path: "/api/notify/rules")
        let envelope = (try? JSONDecoder().decode(RulesEnvelope.self, from: data)) ?? RulesEnvelope(rules: [])
        return envelope.rules
    }

    func deleteNotifyChannel(id: String) async throws {
        try await performVoid(path: "/api/notify/channels/delete", body: MachineDeleteRequest(id: id))
    }

    func deleteNotifyRule(id: String) async throws {
        try await performVoid(path: "/api/notify/rules/delete", body: MachineDeleteRequest(id: id))
    }

    func testNotifyChannel(channelID: String, title: String, body: String) async throws {
        try await performVoid(
            path: "/api/notify/test",
            body: NotifyTestRequest(channel: channelID, config: [:], title: title, body: body)
        )
    }

    // Audit
    func fetchAudit(limit: Int = 200, offset: Int = 0, action: String? = nil, decision: String? = nil, nodeID: String? = nil) async throws -> AuditQueryResponse {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        if let action, !action.isEmpty { query.append(URLQueryItem(name: "action", value: action)) }
        if let decision, !decision.isEmpty { query.append(URLQueryItem(name: "decision", value: decision)) }
        if let nodeID, !nodeID.isEmpty { query.append(URLQueryItem(name: "node_id", value: nodeID)) }
        return try await perform(AuditQueryResponse.self, path: "/api/audit", query: query)
    }

    func verifyAuditChain() async throws -> AuditChainStatus {
        try await perform(AuditChainStatus.self, path: "/api/audit/verify")
    }

    // Tasks
    func listTasks() async throws -> [LatticeTask] {
        try await perform([LatticeTask].self, path: "/api/tasks")
    }

    func listTaskResults() async throws -> [LatticeTaskResult] {
        try await perform([LatticeTaskResult].self, path: "/api/task-results")
    }

    // Logs
    func listLogSources() async throws -> [LogSource] {
        let data = try await performData(path: "/api/logs/sources")
        let envelope = (try? JSONDecoder().decode(SourcesEnvelope.self, from: data)) ?? SourcesEnvelope(sources: [])
        return envelope.sources
    }

    func logStats(sourceID: String? = nil) async throws -> [LogSourceStats] {
        var query: [URLQueryItem] = []
        if let sourceID, !sourceID.isEmpty { query.append(URLQueryItem(name: "source_id", value: sourceID)) }
        let data = try await performData(path: "/api/logs/stats", query: query)
        let envelope = (try? JSONDecoder().decode(StatsEnvelope.self, from: data)) ?? StatsEnvelope(stats: [])
        return envelope.stats
    }

    func queryLogs(sourceID: String, search: String? = nil, limit: Int = 200, beforeSeq: UInt64? = nil) async throws -> LogQueryResponse {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "source_id", value: sourceID),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let search, !search.isEmpty { query.append(URLQueryItem(name: "q", value: search)) }
        if let beforeSeq { query.append(URLQueryItem(name: "before_seq", value: String(beforeSeq))) }
        return try await perform(LogQueryResponse.self, path: "/api/logs/query", query: query)
    }

    // Geo / fleet map
    func fetchNodeGeo() async throws -> [NodeGeoView] {
        try await perform([NodeGeoView].self, path: "/api/nodes/geo")
    }

    func setNodeGeo(nodeID: String, country: String, region: String, city: String, lat: Double, lon: Double, asOrg: String = "", provider: String = "") async throws -> NodeGeoView {
        try await perform(
            NodeGeoView.self,
            path: "/api/nodes/geo",
            method: "POST",
            body: NodeGeoSetRequest(
                nodeID: nodeID,
                geo: NodeGeoInput(country: country, region: region, city: city, lat: lat, lon: lon, asOrg: asOrg, provider: provider)
            )
        )
    }

    @discardableResult
    func resolveNodeGeo(nodeID: String? = nil, all: Bool = false, missingOnly: Bool = true, overwrite: Bool = false) async throws -> [NodeGeoResolveResult] {
        let data = try await performData(
            path: "/api/nodes/geo/resolve",
            method: "POST",
            body: NodeGeoResolveRequest(nodeID: nodeID, all: all, missingOnly: missingOnly, overwrite: overwrite)
        )
        let envelope = (try? JSONDecoder().decode(ResultsEnvelope.self, from: data)) ?? ResultsEnvelope(results: [])
        return envelope.results
    }
}
