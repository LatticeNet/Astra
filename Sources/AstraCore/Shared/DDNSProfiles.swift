import Foundation

/// How a DDNS profile is doing, for Inbox attention and the DDNS list.
public enum DDNSHealth: String, Sendable, Hashable, CaseIterable {
    case current
    case failing
    case stale
}

/// One DDNS profile (`GET /api/ddns`, the console's `DDNSView`).
public struct DDNSProfile: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var nodeID: String
    public var provider: String
    public var domains: [String]
    public var enableIPv4: Bool
    public var enableIPv6: Bool
    public var ttl: Int
    /// Seconds between attempts; 0 means the server default.
    public var intervalSeconds: Int
    /// "address" or "cname".
    public var recordType: String
    public var hasCredential: Bool
    public var lastIPv4: String
    public var lastIPv6: String
    public var lastTarget: String
    public var lastRunAt: Date?
    public var lastError: String
    public var createdAt: Date?
    public var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, provider, domains, ttl
        case nodeID = "node_id"
        case enableIPv4 = "enable_ipv4"
        case enableIPv6 = "enable_ipv6"
        case intervalSeconds = "interval_seconds"
        case recordType = "record_type"
        case hasCredential = "has_credential"
        case lastIPv4 = "last_ipv4"
        case lastIPv6 = "last_ipv6"
        case lastTarget = "last_target"
        case lastRunAt = "last_run_at"
        case lastError = "last_error"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        enableIPv4 = try c.decodeIfPresent(Bool.self, forKey: .enableIPv4) ?? false
        enableIPv6 = try c.decodeIfPresent(Bool.self, forKey: .enableIPv6) ?? false
        ttl = try c.decodeIfPresent(Int.self, forKey: .ttl) ?? 0
        intervalSeconds = try c.decodeIfPresent(Int.self, forKey: .intervalSeconds) ?? 0
        recordType = try c.decodeIfPresent(String.self, forKey: .recordType) ?? "address"
        hasCredential = try c.decodeIfPresent(Bool.self, forKey: .hasCredential) ?? false
        lastIPv4 = try c.decodeIfPresent(String.self, forKey: .lastIPv4) ?? ""
        lastIPv6 = try c.decodeIfPresent(String.self, forKey: .lastIPv6) ?? ""
        lastTarget = try c.decodeIfPresent(String.self, forKey: .lastTarget) ?? ""
        lastRunAt = try DateValue.decodeIfPresent(from: c, forKey: .lastRunAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError) ?? ""
        createdAt = try DateValue.decodeIfPresent(from: c, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: c, forKey: .updatedAt)
    }

    /// Current, failing (the last run erred) or stale (no run within its interval).
    public func health(now: Date) -> DDNSHealth {
        // M0a: implement. Port the console's DDNS freshness rule (server default
        // interval, grace) and pin it with a check; this placeholder only reads the last error.
        lastError.isEmpty ? .current : .failing
    }
}

public extension LatticeClient {
    func listDDNS() async throws -> [DDNSProfile] {
        try await perform([DDNSProfile].self, path: "/api/ddns")
    }
}
