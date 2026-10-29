import Foundation

/// Demo routes for the Access domain, owned by the Access module (section 8.6).
///
/// The token list holds the one this iPhone uses (`tok_demo0001phone`, the
/// `token_id` the Shared `/api/me` answers), so the own-token warning can be
/// shown. The demo operator (`u-demo-ops`) has two-factor on, so deleting
/// one of its passkeys needs a step-up grant, exactly as the server asks.
///
/// Session state, through `DemoState`:
///
/// - `access.tokens.revoked` and `access.tokens.deleted` (sets of token ids).
/// - `access.passkeys.deleted` (a set of ids) and `access.passkey.name.<id>`.
public enum AccessFixtures {
    public static var routes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/tokens", body: "[]", emptyBody: "[]") { request, state in
                .json(await tokensBody(request, state: state))
            }.requiring(tokenScope),
            DemoRoute(method: "POST", pathPattern: "/api/tokens/revoke") { request, state in
                await revokeToken(request, state: state)
            }.requiring(tokenScope),
            DemoRoute(method: "POST", pathPattern: "/api/tokens/delete") { request, state in
                await deleteToken(request, state: state)
            }.requiring(tokenScope),
            DemoRoute(pathPattern: "/api/users", body: usersBody, emptyBody: #"{"users":[]}"#).requiring("user:admin"),
            DemoRoute(pathPattern: "/api/auth/oidc/providers", body: providersBody, emptyBody: #"{"providers":[]}"#).requiring("oidc:admin"),
            DemoRoute(pathPattern: "/api/security/webauthn/credentials", body: #"{"credentials":[]}"#, emptyBody: #"{"credentials":[]}"#) { request, state in
                if let refusal = interactiveRefusal(request) { return refusal }
                return .json(await passkeysBody(state))
            },
            DemoRoute(method: "POST", pathPattern: "/api/security/webauthn/credentials/rename") { request, state in
                await renamePasskey(request, state: state)
            },
            DemoRoute(method: "POST", pathPattern: "/api/security/webauthn/credentials/delete") { request, state in
                await deletePasskey(request, state: state)
            },
        ]
    }

    static let tokenScope = "token:admin"
    static let revokedSet = "access.tokens.revoked"
    static let deletedSet = "access.tokens.deleted"
    static let deletedPasskeysSet = "access.passkeys.deleted"
    /// The grant the Shared step-up fixture hands out.
    static let demoGrant = "grant_demo_notasecret"

    // MARK: Tokens

    public struct Token: Sendable {
        public var id: String
        public var name: String
        public var actorID: String
        public var scopes: [String]
        public var allowlist: [String]
        public var created: String
        public var revoked: String?
    }

    /// The token this iPhone uses, as `/api/me` names it.
    public static let phoneTokenID = "tok_demo0001phone"

    public static let tokens: [Token] = [
        Token(id: phoneTokenID, name: "Lattice iPhone", actorID: DemoWorld.actorID, scopes: TokenPresets.operator.scopes, allowlist: [], created: "-41d"),
        Token(id: "tok_demo0002ci", name: "CI deploy", actorID: DemoWorld.actorID, scopes: ["node:read", "task:read", "task:run", "network:plan"], allowlist: [], created: "-128d"),
        Token(id: "tok_demo0003grafana", name: "Grafana exporter", actorID: "u-demo-alice", scopes: ["monitor:read", "node:read", "inventory:read"], allowlist: [], created: "-203d"),
        Token(id: "tok_demo0004asia", name: "Asia on-call", actorID: "u-demo-alice", scopes: TokenPresets.triage.scopes, allowlist: DemoWorld.confinedNodeIDs, created: "-16d"),
        Token(id: "tok_demo0005backup", name: "Backup uploader", actorID: DemoWorld.actorID, scopes: ["kv:read", "kv:write", "static:read", "static:write"], allowlist: [], created: "-62d"),
        Token(id: "tok_demo0006bootstrap", name: "Bootstrap admin", actorID: DemoWorld.actorID, scopes: ["*"], allowlist: [], created: "-402d"),
        Token(id: "tok_demo0007laptop", name: "Old laptop", actorID: DemoWorld.actorID, scopes: ["node:read", "node:admin", "token:admin"], allowlist: [], created: "-310d", revoked: "-33d"),
    ]

    static func tokenJSON(_ token: Token, revokedNow: Bool) -> DemoJSON {
        let revoked: DemoJSON? = revokedNow ? .time() : token.revoked.map { .time($0) }
        return .object([
            "id": .string(token.id),
            "name": .string(token.name),
            "actor_id": .string(token.actorID),
            "scopes": .strings(token.scopes),
            "server_allowlist": .strings(token.allowlist),
            "created_at": .time(token.created),
            "revoked_at": revoked,
        ])
    }

    /// A confined caller sees only the tokens whose allowlist is a subset of
    /// its own (`handleTokens`).
    static func tokensBody(_ request: DemoRequest, state: DemoState) async -> String {
        let caller = DemoTransport.scopes(for: request.identity, scenario: request.scenario)
        let revoked = await state.members(of: revokedSet)
        let deleted = await state.members(of: deletedSet)
        let visible = tokens.filter { token in
            guard !deleted.contains(token.id) else { return false }
            guard caller.isConfined else { return true }
            return !token.allowlist.isEmpty && Set(token.allowlist).isSubset(of: Set(caller.serverAllowlist))
        }
        return DemoJSON.array(visible.map { tokenJSON($0, revokedNow: revoked.contains($0.id) && $0.revoked == nil) }).text
    }

    static func token(_ request: DemoRequest, state: DemoState) async -> Token? {
        guard let id = request.bodyStrings["token_id"], !(await state.contains(id, in: deletedSet)) else { return nil }
        return tokens.first { $0.id == id }
    }

    static func revokeToken(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        guard let token = await token(request, state: state) else {
            return .error(status: 404, code: "not_found", message: "token not found")
        }
        if token.revoked == nil { await state.insert(token.id, into: revokedSet) }
        return .json(tokenJSON(token, revokedNow: token.revoked == nil).text)
    }

    static func deleteToken(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        guard let token = await token(request, state: state) else {
            return .error(status: 404, code: "not_found", message: "token not found")
        }
        let revokedThisSession = await state.contains(token.id, in: revokedSet)
        guard token.revoked != nil || revokedThisSession else {
            return .error(status: 409, code: "conflict", message: "token must be revoked before deletion")
        }
        await state.insert(token.id, into: deletedSet)
        return .json(#"{"ok":true}"#)
    }

    // MARK: Users

    static var usersBody: String {
        DemoJSON.object([
            ("users", .array([
                user("u-demo-ops", DemoWorld.username, scopes: ["*"], totp: true, password: true, created: "-402d"),
                user("u-demo-alice", "alice@example.org", scopes: TokenPresets.operator.scopes, totp: true, password: true, created: "-210d"),
                user("u-demo-bob", "bob@example.org", scopes: TokenPresets.triage.scopes, totp: false, password: false, created: "-95d"),
                user("u-demo-asia", "oncall-asia@example.org", scopes: TokenPresets.triage.scopes, allowlist: DemoWorld.confinedNodeIDs, totp: false, password: true, created: "-17d"),
            ])),
        ]).text
    }

    static func user(_ id: String, _ username: String, scopes: [String], allowlist: [String] = [], totp: Bool, password: Bool, created: String) -> DemoJSON {
        .object([
            "id": .string(id),
            "username": .string(username),
            "scopes": .strings(scopes),
            "server_allowlist": .strings(allowlist),
            "totp_enabled": .bool(totp),
            "has_password": .bool(password),
            "created_at": .time(created),
        ])
    }

    // MARK: SSO providers

    static var providersBody: String {
        DemoJSON.object([
            ("providers", .array([
                .object([
                    "id": "oidc_demo_workspace",
                    "display_name": "Example Workspace",
                    "issuer": "https://accounts.example.com",
                    "client_id": "lattice-console.apps.example.com",
                    "has_secret": true,
                    "scopes": .strings(["openid", "profile", "email"]),
                    "allowed_domains": .strings(["example.org"]),
                    "enabled": true,
                    "skip_local_totp": false,
                ]),
                .object([
                    "id": "oidc_demo_lab",
                    "display_name": "Lab Keycloak",
                    "issuer": "https://sso.lab.example.net/realms/ops",
                    "client_id": "lattice",
                    "has_secret": false,
                    "scopes": .strings(["openid", "email"]),
                    "enabled": false,
                    "skip_local_totp": true,
                ]),
            ])),
        ]).text
    }

    // MARK: Passkeys

    public struct Passkey: Sendable {
        public var id: String
        public var name: String
        public var created: String
        public var lastUsed: String?
        public var backedUp: Bool
        public var transports: [String]
    }

    public static let passkeys: [Passkey] = [
        Passkey(id: "pk_demo_iphone", name: "iPhone", created: "-88d", lastUsed: "-2h", backedUp: true, transports: ["internal", "hybrid"]),
        Passkey(id: "pk_demo_key", name: "Security key", created: "-205d", lastUsed: "-12d", backedUp: false, transports: ["usb", "nfc"]),
        Passkey(id: "pk_demo_mac", name: "MacBook", created: "-29d", lastUsed: nil, backedUp: true, transports: ["internal"]),
    ]

    /// The server manages passkeys only on an interactive session (`requireInteractiveUser`).
    static func interactiveRefusal(_ request: DemoRequest) -> DemoResponse? {
        guard request.identity != .session else { return nil }
        return .error(status: 403, code: "forbidden", message: "passkey management requires an interactive session")
    }

    static func passkeyJSON(_ passkey: Passkey, name: String) -> DemoJSON {
        .object([
            "id": .string(passkey.id),
            "name": .string(name),
            "created_at": .time(passkey.created),
            "last_used_at": passkey.lastUsed.map { .time($0) },
            "backed_up": .bool(passkey.backedUp),
            "transports": .strings(passkey.transports),
        ])
    }

    static func passkeysBody(_ state: DemoState) async -> String {
        let deleted = await state.members(of: deletedPasskeysSet)
        var items: [DemoJSON] = []
        for passkey in passkeys where !deleted.contains(passkey.id) {
            items.append(passkeyJSON(passkey, name: await state.value(for: "access.passkey.name.\(passkey.id)") ?? passkey.name))
        }
        return DemoJSON.object([("credentials", .array(items))]).text
    }

    static func passkey(_ request: DemoRequest, state: DemoState) async -> Passkey? {
        guard let id = request.bodyStrings["id"], !(await state.contains(id, in: deletedPasskeysSet)) else { return nil }
        return passkeys.first { $0.id == id }
    }

    static func renamePasskey(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        if let refusal = interactiveRefusal(request) { return refusal }
        let name = (request.bodyStrings["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .error(status: 400, code: "bad_request", message: "name is required") }
        guard let passkey = await passkey(request, state: state) else {
            return .error(status: 404, code: "not_found", message: "passkey not found")
        }
        await state.setValue(name, for: "access.passkey.name.\(passkey.id)")
        return .json(DemoJSON.object([("credential", passkeyJSON(passkey, name: name))]).text)
    }

    /// The demo operator has two-factor on, so the grant is required (`handleWebAuthnDelete`).
    static func deletePasskey(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        if let refusal = interactiveRefusal(request) { return refusal }
        guard request.bodyStrings["step_up_grant"] == demoGrant else {
            return .error(status: 403, code: "forbidden", message: "second-factor step-up required")
        }
        guard let passkey = await passkey(request, state: state) else {
            return .error(status: 404, code: "not_found", message: "passkey not found")
        }
        await state.insert(passkey.id, into: deletedPasskeysSet)
        return .json(#"{"ok":true}"#)
    }
}
