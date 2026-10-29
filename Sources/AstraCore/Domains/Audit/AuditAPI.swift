import Foundation

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

public extension LatticeClient {
    func verifyAuditChain() async throws -> AuditChainStatus {
        try await perform(AuditChainStatus.self, path: "/api/audit/verify")
    }
}
