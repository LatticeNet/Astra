import Foundation

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

public struct MonitorStats: Equatable, Sendable {
    public var sampleCount: Int
    public var successCount: Int
    public var averageLatencyMs: Double?
    public var lastResult: MonitorResult?

    public init(results: [MonitorResult]) {
        sampleCount = results.count
        successCount = results.filter(\.success).count

        let latencies = results.filter(\.success).map(\.latencyMs)
        averageLatencyMs = latencies.isEmpty ? nil : latencies.reduce(0, +) / Double(latencies.count)
        lastResult = results.max { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
    }

    public var uptimeFraction: Double? {
        guard sampleCount > 0 else { return nil }
        return Double(successCount) / Double(sampleCount)
    }
}
