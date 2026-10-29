import Foundation

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
