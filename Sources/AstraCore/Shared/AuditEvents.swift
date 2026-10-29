import Foundation

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
    /// The event exactly as the server sent it, for the NDJSON export.
    /// Filled by `fetchAudit(query:)`; empty for events built any other way.
    public var rawJSON: String = ""

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

public extension LatticeClient {
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
}

/// Filters for `GET /api/audit` (section 8.9). There is no id filter; a
/// detail opened by id pages through the list.
public struct AuditQuery: Sendable, Hashable {
    public var action: String?
    public var actorID: String?
    public var atFrom: Date?
    public var atTo: Date?
    public var correlationID: String?
    public var decision: String?
    public var excludeAction: String?
    public var excludeDecision: String?
    public var nodeID: String?
    public var scope: String?
    public var tokenID: String?
    public var text: String?
    public var limit: Int
    public var offset: Int

    public init(
        action: String? = nil,
        actorID: String? = nil,
        atFrom: Date? = nil,
        atTo: Date? = nil,
        correlationID: String? = nil,
        decision: String? = nil,
        excludeAction: String? = nil,
        excludeDecision: String? = nil,
        nodeID: String? = nil,
        scope: String? = nil,
        tokenID: String? = nil,
        text: String? = nil,
        limit: Int = 100,
        offset: Int = 0
    ) {
        self.action = action
        self.actorID = actorID
        self.atFrom = atFrom
        self.atTo = atTo
        self.correlationID = correlationID
        self.decision = decision
        self.excludeAction = excludeAction
        self.excludeDecision = excludeDecision
        self.nodeID = nodeID
        self.scope = scope
        self.tokenID = tokenID
        self.text = text
        self.limit = limit
        self.offset = offset
    }

    public var queryItems: [URLQueryItem] {
        let pairs: [(String, String?)] = [
            ("action", action), ("actor_id", actorID),
            ("at_from", atFrom.map(AstraDateParser.string(from:))), ("at_to", atTo.map(AstraDateParser.string(from:))),
            ("correlation_id", correlationID), ("decision", decision),
            ("exclude_action", excludeAction), ("exclude_decision", excludeDecision),
            ("node_id", nodeID), ("scope", scope), ("token_id", tokenID), ("q", text),
        ]
        var items = pairs.compactMap { name, value in
            value.flatMap { $0.isEmpty ? nil : URLQueryItem(name: name, value: $0) }
        }
        items.append(URLQueryItem(name: "limit", value: String(limit)))
        items.append(URLQueryItem(name: "offset", value: String(offset)))
        return items
    }
}

public extension LatticeClient {
    /// `GET /api/audit` with filters. Each event keeps its raw JSON slice,
    /// so the NDJSON export writes the server's bytes, not a re-encoding.
    func fetchAudit(query: AuditQuery) async throws -> AuditQueryResponse {
        let data = try await performData(path: "/api/audit", query: query.queryItems)
        var response: AuditQueryResponse
        do {
            if let events = try? JSONDecoder().decode([AuditEvent].self, from: data) {
                response = AuditQueryResponse(events: events, total: events.count, limit: query.limit, offset: query.offset)
            } else {
                response = try JSONDecoder().decode(AuditQueryResponse.self, from: data)
            }
        } catch {
            throw LatticeAPIError.invalidResponse
        }
        if let slices = JSONArraySlicer.elements(of: data, key: "events"), slices.count == response.events.count {
            for index in response.events.indices {
                response.events[index].rawJSON = String(decoding: slices[index], as: UTF8.self)
            }
        }
        return response
    }
}
