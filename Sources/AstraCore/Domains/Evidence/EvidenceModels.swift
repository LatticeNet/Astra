import Foundation

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
