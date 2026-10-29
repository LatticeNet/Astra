import Foundation

/// One send attempt of a delivery.
public struct NotifyAttempt: Codable, Equatable, Hashable, Sendable {
    public var at: Date?
    public var ok: Bool
    public var kind: String
    public var status: Int?
    public var durationMs: Int

    enum CodingKeys: String, CodingKey {
        case at, ok, kind, status
        case durationMs = "duration_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try DateValue.decodeIfPresent(from: c, forKey: .at)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        status = try c.decodeIfPresent(Int.self, forKey: .status)
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
    }
}

/// One message to one channel, from the server's notification outbox.
public struct NotifyDelivery: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var eventID: String
    public var eventType: String
    /// server, plugin, webhook or operator.
    public var source: String
    public var sourceID: String
    public var severity: String
    public var ruleID: String
    public var ruleName: String
    public var channelID: String
    public var channelName: String
    public var channelKind: String
    /// primary, fallback or test.
    public var role: String
    /// planned, sent, failed, no_route or suppressed.
    public var outcome: String
    public var reason: String
    public var attempts: [NotifyAttempt]
    public var title: String
    public var body: String
    public var createdAt: Date?
    public var settledAt: Date?
    /// The incidents an incident message reports.
    public var incidentIDs: [String]

    enum CodingKeys: String, CodingKey {
        case id, source, severity, role, outcome, reason, attempts, title, body
        case eventID = "event_id"
        case eventType = "event_type"
        case sourceID = "source_id"
        case ruleID = "rule_id"
        case ruleName = "rule_name"
        case channelID = "channel_id"
        case channelName = "channel_name"
        case channelKind = "channel_kind"
        case createdAt = "created_at"
        case settledAt = "settled_at"
        case incidentIDs = "incident_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        eventID = try c.decodeIfPresent(String.self, forKey: .eventID) ?? ""
        eventType = try c.decodeIfPresent(String.self, forKey: .eventType) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID) ?? ""
        severity = try c.decodeIfPresent(String.self, forKey: .severity) ?? ""
        ruleID = try c.decodeIfPresent(String.self, forKey: .ruleID) ?? ""
        ruleName = try c.decodeIfPresent(String.self, forKey: .ruleName) ?? ""
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID) ?? ""
        channelName = try c.decodeIfPresent(String.self, forKey: .channelName) ?? ""
        channelKind = try c.decodeIfPresent(String.self, forKey: .channelKind) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        attempts = try c.decodeIfPresent([NotifyAttempt].self, forKey: .attempts) ?? []
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        createdAt = try DateValue.decodeIfPresent(from: c, forKey: .createdAt)
        settledAt = try DateValue.decodeIfPresent(from: c, forKey: .settledAt)
        incidentIDs = try c.decodeIfPresent([String].self, forKey: .incidentIDs) ?? []
    }
}

/// `GET /api/notify/deliveries`.
public struct NotifyDeliveriesResponse: Decodable, Equatable, Sendable {
    public var deliveries: [NotifyDelivery]
    public var stored: Int
    public var durable: Bool
    public var max: Int

    enum CodingKeys: String, CodingKey { case deliveries, stored, durable, max }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deliveries = try c.decodeIfPresent([NotifyDelivery].self, forKey: .deliveries) ?? []
        stored = try c.decodeIfPresent(Int.self, forKey: .stored) ?? 0
        durable = try c.decodeIfPresent(Bool.self, forKey: .durable) ?? false
        max = try c.decodeIfPresent(Int.self, forKey: .max) ?? 0
    }
}

/// The deliveries listing's real filter names (`server_notify_outbox.go:346`).
/// Console URL names map onto these here and nowhere else.
public struct DeliveryQuery: Sendable, Hashable {
    public var channelID: String?
    public var eventType: String?
    public var outcome: String?
    public var eventID: String?
    public var source: String?
    public var sourceID: String?
    public var limit: Int?

    public init(channelID: String? = nil, eventType: String? = nil, outcome: String? = nil, eventID: String? = nil, source: String? = nil, sourceID: String? = nil, limit: Int? = nil) {
        self.channelID = channelID
        self.eventType = eventType
        self.outcome = outcome
        self.eventID = eventID
        self.source = source
        self.sourceID = sourceID
        self.limit = limit
    }

    public var queryItems: [URLQueryItem] {
        let pairs: [(String, String?)] = [
            ("channel_id", channelID), ("event_type", eventType), ("outcome", outcome),
            ("event_id", eventID), ("source", source), ("source_id", sourceID),
            ("limit", limit.map(String.init)),
        ]
        return pairs.compactMap { name, value in
            value.flatMap { $0.isEmpty ? nil : URLQueryItem(name: name, value: $0) }
        }
    }
}

public extension LatticeClient {
    func fetchDeliveries(query: DeliveryQuery = DeliveryQuery()) async throws -> NotifyDeliveriesResponse {
        try await perform(NotifyDeliveriesResponse.self, path: "/api/notify/deliveries", query: query.queryItems)
    }
}
