import Foundation

/// `tokenView` (`server.go`): the safe projection of a personal access token.
/// It never carries the hash or the secret, and the server records no last use.
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

    /// The name, or the id for a token minted without one.
    public var displayName: String { name.isEmpty ? id : name }

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
        // Older servers serialized an active token's zero time ("0001-01-01T00:00:00Z")
        // instead of omitting it; the console treats that as active, and so does this.
        revokedAt = try DateValue.decodeIfPresent(from: container, forKey: .revokedAt).flatMap(AccessDates.real)
        createdAt = try DateValue.decodeIfPresent(from: container, forKey: .createdAt).flatMap(AccessDates.real)
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

/// Go's zero time and other pre-epoch stamps mean "not set".
enum AccessDates {
    static func real(_ date: Date) -> Date? {
        date.timeIntervalSince1970 > 0 ? date : nil
    }
}

// MARK: Users

/// `userView` (`server_users.go`): an operator account, never its password hash.
public struct AccessUser: Identifiable, Decodable, Equatable, Hashable, Sendable {
    public var id: String
    public var username: String
    public var scopes: [String]
    /// Empty means every node.
    public var serverAllowlist: [String]
    public var totpEnabled: Bool
    /// False for an SSO-only account, which cannot sign in with a password.
    public var hasPassword: Bool
    public var createdAt: Date?

    public init(id: String, username: String, scopes: [String] = [], serverAllowlist: [String] = [], totpEnabled: Bool = false, hasPassword: Bool = true, createdAt: Date? = nil) {
        self.id = id
        self.username = username
        self.scopes = scopes
        self.serverAllowlist = serverAllowlist
        self.totpEnabled = totpEnabled
        self.hasPassword = hasPassword
        self.createdAt = createdAt
    }

    public var displayName: String { username.isEmpty ? id : username }

    enum CodingKeys: String, CodingKey {
        case id, username, scopes
        case serverAllowlist = "server_allowlist"
        case totpEnabled = "totp_enabled"
        case hasPassword = "has_password"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        scopes = try container.decodeIfPresent([String].self, forKey: .scopes) ?? []
        serverAllowlist = try container.decodeIfPresent([String].self, forKey: .serverAllowlist) ?? []
        totpEnabled = try container.decodeIfPresent(Bool.self, forKey: .totpEnabled) ?? false
        hasPassword = try container.decodeIfPresent(Bool.self, forKey: .hasPassword) ?? false
        createdAt = try DateValue.decodeIfPresent(from: container, forKey: .createdAt).flatMap(AccessDates.real)
    }
}

/// `GET /api/users`: `{users: [...]}`.
public struct AccessUsersResponse: Decodable, Sendable {
    public var users: [AccessUser]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        users = try container.decodeIfPresent([AccessUser].self, forKey: .users) ?? []
    }

    enum CodingKeys: String, CodingKey { case users }
}

// MARK: SSO providers

/// `oidcProviderView` (`server_oidc.go`). The client secret is write-only:
/// the server says only whether one is stored. It keeps no test result.
public struct AccessSSOProvider: Identifiable, Decodable, Equatable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var issuer: String
    public var clientID: String
    public var hasSecret: Bool
    public var scopes: [String]
    /// Empty means any verified email domain.
    public var allowedDomains: [String]
    public var enabled: Bool
    /// A sign-in through this provider stands in for the local authenticator code.
    public var skipLocalTOTP: Bool

    public init(id: String, displayName: String = "", issuer: String = "", clientID: String = "", hasSecret: Bool = false, scopes: [String] = [], allowedDomains: [String] = [], enabled: Bool = false, skipLocalTOTP: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.issuer = issuer
        self.clientID = clientID
        self.hasSecret = hasSecret
        self.scopes = scopes
        self.allowedDomains = allowedDomains
        self.enabled = enabled
        self.skipLocalTOTP = skipLocalTOTP
    }

    /// The display name, else the issuer, as the console labels it.
    public var title: String {
        if !displayName.isEmpty { return displayName }
        return issuer.isEmpty ? id : issuer
    }

    enum CodingKeys: String, CodingKey {
        case id, issuer, scopes, enabled
        case displayName = "display_name"
        case clientID = "client_id"
        case hasSecret = "has_secret"
        case allowedDomains = "allowed_domains"
        case skipLocalTOTP = "skip_local_totp"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        issuer = try container.decodeIfPresent(String.self, forKey: .issuer) ?? ""
        clientID = try container.decodeIfPresent(String.self, forKey: .clientID) ?? ""
        hasSecret = try container.decodeIfPresent(Bool.self, forKey: .hasSecret) ?? false
        scopes = try container.decodeIfPresent([String].self, forKey: .scopes) ?? []
        allowedDomains = try container.decodeIfPresent([String].self, forKey: .allowedDomains) ?? []
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        // Absent from servers that predate it: off unless the server says on (`skipLocalTotpOf`).
        skipLocalTOTP = try container.decodeIfPresent(Bool.self, forKey: .skipLocalTOTP) ?? false
    }
}

/// `GET /api/auth/oidc/providers`: `{providers: [...]}`.
public struct AccessSSOProvidersResponse: Decodable, Sendable {
    public var providers: [AccessSSOProvider]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decodeIfPresent([AccessSSOProvider].self, forKey: .providers) ?? []
    }

    enum CodingKeys: String, CodingKey { case providers }
}

// MARK: Passkeys

/// `webAuthnCredentialView` (`server_webauthn.go`): one of the signed-in
/// operator's passkeys, secret-free (the public key stays on the server).
public struct AccessPasskey: Identifiable, Decodable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date?
    /// Absent when the passkey has never signed in.
    public var lastUsedAt: Date?
    /// Synced by a passkey provider (iCloud Keychain and the like) rather than bound to one device.
    public var backedUp: Bool
    public var transports: [String]
    public var aaguid: String

    public init(id: String, name: String, createdAt: Date? = nil, lastUsedAt: Date? = nil, backedUp: Bool = false, transports: [String] = [], aaguid: String = "") {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.backedUp = backedUp
        self.transports = transports
        self.aaguid = aaguid
    }

    public var displayName: String { name.isEmpty ? "Unnamed passkey" : name }

    enum CodingKeys: String, CodingKey {
        case id, name, transports, aaguid
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case backedUp = "backed_up"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        createdAt = try DateValue.decodeIfPresent(from: container, forKey: .createdAt).flatMap(AccessDates.real)
        lastUsedAt = try DateValue.decodeIfPresent(from: container, forKey: .lastUsedAt).flatMap(AccessDates.real)
        backedUp = try container.decodeIfPresent(Bool.self, forKey: .backedUp) ?? false
        transports = try container.decodeIfPresent([String].self, forKey: .transports) ?? []
        aaguid = try container.decodeIfPresent(String.self, forKey: .aaguid) ?? ""
    }
}

/// `GET /api/security/webauthn/credentials`: `{credentials: [...]}`.
public struct AccessPasskeysResponse: Decodable, Sendable {
    public var credentials: [AccessPasskey]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        credentials = try container.decodeIfPresent([AccessPasskey].self, forKey: .credentials) ?? []
    }

    enum CodingKeys: String, CodingKey { case credentials }
}

/// `POST /api/security/webauthn/credentials/rename`: `{credential: {...}}`.
public struct AccessPasskeyResponse: Decodable, Sendable {
    public var credential: AccessPasskey
}

/// `{ok: true}` from the token and passkey deletes.
public struct AccessOKResponse: Decodable, Sendable {
    public var ok: Bool

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
    }

    enum CodingKeys: String, CodingKey { case ok }
}
