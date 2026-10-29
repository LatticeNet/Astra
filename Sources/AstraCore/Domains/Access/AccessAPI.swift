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

struct RevokeTokenRequest: Encodable {
    var tokenID: String
    enum CodingKeys: String, CodingKey { case tokenID = "token_id" }
}

public extension LatticeClient {
    // Tokens
    func listTokens() async throws -> [LatticeToken] {
        try await perform([LatticeToken].self, path: "/api/tokens")
    }

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
}
