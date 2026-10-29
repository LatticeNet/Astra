import Foundation

/// Response of `GET /api/me`. Decoded tolerantly because the server may grow the
/// shape over time; unknown fields are ignored and missing fields fall back to
/// safe defaults so an older or newer server never breaks the session view.
public struct LatticeIdentity: Codable, Equatable, Hashable, Sendable {
    public var actorID: String
    public var username: String
    public var scopes: [String]
    public var totpEnabled: Bool
    public var authKind: String?
    /// The nodes this credential is confined to; empty means unconfined.
    public var serverAllowlist: [String]

    public init(
        actorID: String = "",
        username: String = "",
        scopes: [String] = [],
        totpEnabled: Bool = false,
        authKind: String? = nil,
        serverAllowlist: [String] = []
    ) {
        self.actorID = actorID
        self.username = username
        self.scopes = scopes
        self.totpEnabled = totpEnabled
        self.authKind = authKind
        self.serverAllowlist = serverAllowlist
    }

    /// The scope set this identity holds, for `ScopeSet` evaluation.
    public var scopeSet: ScopeSet {
        ScopeSet(scopes: scopes, serverAllowlist: serverAllowlist)
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
        case serverAllowlist = "server_allowlist"
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
        serverAllowlist = try container.decodeIfPresent([String].self, forKey: .serverAllowlist) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(actorID, forKey: .actorID)
        try container.encode(username, forKey: .username)
        try container.encode(scopes, forKey: .scopes)
        try container.encode(totpEnabled, forKey: .totpEnabled)
        try container.encodeIfPresent(authKind, forKey: .authKind)
        try container.encode(serverAllowlist, forKey: .serverAllowlist)
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

public extension LatticeClient {
    // Identity & server
    func fetchIdentity() async throws -> LatticeIdentity {
        try await perform(LatticeIdentity.self, path: "/api/me")
    }

    func fetchServerVersion() async throws -> LatticeServerVersion {
        try await perform(LatticeServerVersion.self, path: "/api/version")
    }
}

/// `GET /api/health`.
public struct ServerHealth: Codable, Equatable, Hashable, Sendable {
    public var status: String

    public init(status: String) {
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LatticeCodingKey.self)
        status = try container.decodeIfPresent(String.self, forKey: LatticeCodingKey("status")) ?? ""
    }

    public var isOK: Bool { status.lowercased() == "ok" }
}

/// `GET /api/plugin-trust`: whether non-official or unsigned plugins run.
public struct PluginTrust: Codable, Equatable, Hashable, Sendable {
    public var nonOfficial: Bool
    public var publishers: [String]
    public var allowUnsignedHostRisk: Bool

    public init(nonOfficial: Bool = false, publishers: [String] = [], allowUnsignedHostRisk: Bool = false) {
        self.nonOfficial = nonOfficial
        self.publishers = publishers
        self.allowUnsignedHostRisk = allowUnsignedHostRisk
    }

    enum CodingKeys: String, CodingKey {
        case publishers
        case nonOfficial = "non_official"
        case allowUnsignedHostRisk = "allow_unsigned_host_risk"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nonOfficial = try c.decodeIfPresent(Bool.self, forKey: .nonOfficial) ?? false
        publishers = try c.decodeIfPresent([String].self, forKey: .publishers) ?? []
        allowUnsignedHostRisk = try c.decodeIfPresent(Bool.self, forKey: .allowUnsignedHostRisk) ?? false
    }

    /// Inbox shows the trust row only when this is true.
    public var warns: Bool { nonOfficial || allowUnsignedHostRisk }
}

public extension LatticeClient {
    func fetchHealth() async throws -> ServerHealth {
        try await perform(ServerHealth.self, path: "/api/health")
    }

    func fetchPluginTrust() async throws -> PluginTrust {
        try await perform(PluginTrust.self, path: "/api/plugin-trust")
    }
}
