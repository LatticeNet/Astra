import Foundation

struct CreateTokenRequest: Encodable {
    var name: String
    var scopes: [String]
    var serverAllowlist: [String]
    enum CodingKeys: String, CodingKey {
        case name, scopes
        case serverAllowlist = "server_allowlist"
    }
}

/// `{token_id}`, the body of both `/api/tokens/revoke` and `/api/tokens/delete`.
struct RevokeTokenRequest: Encodable {
    var tokenID: String
    enum CodingKeys: String, CodingKey { case tokenID = "token_id" }
}

/// `{id, name}` for `/api/security/webauthn/credentials/rename`.
public struct AccessPasskeyRenameRequest: Encodable, Sendable, Equatable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// `{id}`, or `{id, step_up_grant}` when the account has two-factor on, as the console sends it.
public struct AccessPasskeyDeleteRequest: Encodable, Sendable, Equatable {
    public var id: String
    public var stepUpGrant: String?

    public init(id: String, stepUpGrant: String?) {
        self.id = id
        self.stepUpGrant = stepUpGrant
    }

    enum CodingKeys: String, CodingKey {
        case id
        case stepUpGrant = "step_up_grant"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if let stepUpGrant, !stepUpGrant.isEmpty {
            try container.encode(stepUpGrant, forKey: .stepUpGrant)
        }
    }
}

public extension LatticeClient {
    // MARK: Tokens (token:admin)

    /// `GET /api/tokens`, a bare array. A confined caller sees only the tokens
    /// whose node allowlist is a subset of its own.
    func listTokens() async throws -> [LatticeToken] {
        try await perform([LatticeToken].self, path: "/api/tokens")
    }

    /// Kept from v2. The phone never mints tokens: a new secret belongs at a desk.
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

    /// `POST /api/tokens/revoke {token_id}`, answered with the token's view.
    /// Revoking a revoked token is a no-op that answers the same view.
    func accessRevokeToken(id: String) async throws -> LatticeToken {
        try await perform(LatticeToken.self, path: "/api/tokens/revoke", method: "POST", body: RevokeTokenRequest(tokenID: id))
    }

    /// `POST /api/tokens/delete {token_id}`. The server answers 409 for a
    /// token that is not revoked yet.
    func accessDeleteToken(id: String) async throws {
        try await performVoid(path: "/api/tokens/delete", body: RevokeTokenRequest(tokenID: id))
    }

    // MARK: Users (user:admin) and SSO (oidc:admin)

    func accessListUsers() async throws -> [AccessUser] {
        try await perform(AccessUsersResponse.self, path: "/api/users").users
    }

    func accessListSSOProviders() async throws -> [AccessSSOProvider] {
        try await perform(AccessSSOProvidersResponse.self, path: "/api/auth/oidc/providers").providers
    }

    // MARK: Passkeys (signed-in session only)

    /// The signed-in operator's own passkeys. The server refuses API tokens
    /// ("passkey management requires an interactive session").
    func accessListPasskeys() async throws -> [AccessPasskey] {
        try await perform(AccessPasskeysResponse.self, path: "/api/security/webauthn/credentials").credentials
    }

    func accessRenamePasskey(id: String, name: String) async throws -> AccessPasskey {
        try await perform(
            AccessPasskeyResponse.self,
            path: "/api/security/webauthn/credentials/rename",
            method: "POST",
            body: AccessPasskeyRenameRequest(id: id, name: name)
        ).credential
    }

    /// Deleting needs a fresh step-up grant when the account has two-factor on.
    func accessDeletePasskey(id: String, stepUpGrant: String?) async throws {
        try await performVoid(path: "/api/security/webauthn/credentials/delete", body: AccessPasskeyDeleteRequest(id: id, stepUpGrant: stepUpGrant))
    }
}
