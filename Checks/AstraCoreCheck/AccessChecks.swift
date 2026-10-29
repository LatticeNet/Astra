import Foundation
import AstraCore

public func checkAccess() async throws {
    try checkAccessDecoding()
    try await checkAccessRequestBodies()
    try checkAccessScopes()
    try checkAccessTokens()
    try checkAccessQueries()
    try checkAccessUsers()
    try checkAccessSSO()
    try checkAccessPasskeys()
    try await checkAccessIntents()
    try await checkAccessDemo()
}

private let accessBase = "https://lattice.example.com"
private let accessClock = DemoClock(pinned: "2026-10-28T12:00:00Z")!

private func accessMock(_ responses: [String: (Int, Data)]) -> (LatticeClient, MockTransport) {
    let transport = MockTransport(responses: responses)
    let client = LatticeClient(baseURL: URL(string: accessBase)!, credential: LatticeCredential(bearerToken: "lat_check.notasecret"), transport: transport)
    return (client, transport)
}

private func accessDemo(_ identity: DemoIdentity = .pat, _ scenario: DemoScenario = .fullAdmin, state: DemoState = DemoState()) -> LatticeClient {
    let credential = identity == .session
        ? LatticeCredential(sessionCookie: "demo-session", csrfToken: "demo-csrf")
        : LatticeCredential(bearerToken: DemoWorld.token)
    return LatticeClient(baseURL: DemoWorld.baseURL, credential: credential,
                         transport: DemoTransport(identity: identity, scenario: scenario, clock: accessClock, state: state))
}

private struct AccessAuthStub: WriteAuthenticator {
    var outcome: DeviceAuthOutcome = .confirmed
    func authenticate(reason: String) async -> DeviceAuthOutcome { outcome }
}

private func accessCommit(_ intent: WriteIntent, _ client: LatticeClient, auth: AccessAuthStub = AccessAuthStub()) async throws -> WriteOutcome {
    switch await WriteFlow(intent: intent, client: client, authenticator: auth).commit(choices: ConfirmChoices()) {
    case .finished(let outcome): return outcome
    case .cancelled: throw CheckFailure.failed("\(intent.title): cancelled")
    case .authenticationFailed(let message): throw CheckFailure.failed("\(intent.title): \(message)")
    case .dryRunChanged: throw CheckFailure.failed("\(intent.title): dry run changed")
    }
}

private func accessToken(_ id: String, scopes: [String] = ["node:read"], allowlist: [String] = [], revoked: Bool = false, created: TimeInterval = 0) -> LatticeToken {
    LatticeToken(id: id, name: id.uppercased(), actorID: "u1", scopes: scopes, serverAllowlist: allowlist,
                 revokedAt: revoked ? Date(timeIntervalSince1970: 1_800_000_000) : nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + created))
}

// MARK: Decoding

private func checkAccessDecoding() throws {
    let tokens = try JSONDecoder().decode([LatticeToken].self, from: json(#"""
    [{"id":"token_a","name":"CI","actor_id":"u1","scopes":["node:read","task:run"],"server_allowlist":[],"created_at":"2026-09-01T10:00:00Z"},
     {"id":"token_b","name":"","actor_id":"u1","scopes":[],"server_allowlist":["n1","n2"],"created_at":"2026-09-02T10:00:00Z","revoked_at":"2026-10-01T10:00:00Z"},
     {"id":"token_c","name":"Legacy","actor_id":"u1","scopes":null,"server_allowlist":null,"created_at":"2026-09-03T10:00:00Z","revoked_at":"0001-01-01T00:00:00Z"}]
    """#))
    try expectEqual(tokens.count, 3, "three tokens")
    try expect(!tokens[0].isRevoked && tokens[0].scopes == ["node:read", "task:run"], "active token decodes its scopes")
    try expect(tokens[1].isRevoked && tokens[1].displayName == "token_b" && tokens[1].serverAllowlist == ["n1", "n2"], "revoked token, unnamed, confined")
    try expect(!tokens[2].isRevoked, "Go's zero time is not a revocation")
    try expect(tokens[2].scopes.isEmpty && tokens[2].serverAllowlist.isEmpty, "null lists decode empty")

    let revoked = try JSONDecoder().decode(LatticeToken.self, from: json(#"{"id":"token_a","name":"CI","actor_id":"u1","scopes":["node:read"],"server_allowlist":[],"created_at":"2026-09-01T10:00:00Z","revoked_at":"2026-10-28T11:00:00Z"}"#))
    try expect(revoked.isRevoked, "revoke answers the revoked view")

    let created = try JSONDecoder().decode(CreatedTokenResponse.self, from: json(#"{"id":"token_n","token":"token_n.secret","view":{"id":"token_n","name":"new","actor_id":"u1","scopes":["node:read"],"server_allowlist":[],"created_at":"2026-10-28T11:00:00Z"}}"#))
    try expect(created.view?.id == "token_n" && created.token == "token_n.secret", "token create response decodes")

    let users = try JSONDecoder().decode(AccessUsersResponse.self, from: json(#"""
    {"users":[{"id":"user_1","username":"ops","scopes":["*"],"server_allowlist":[],"totp_enabled":true,"has_password":true,"created_at":"2026-01-01T00:00:00Z"},
              {"id":"user_2","username":"sso@example.org","scopes":["node:read"],"server_allowlist":null,"totp_enabled":false,"has_password":false,"created_at":"2026-02-01T00:00:00Z"}]}
    """#)).users
    try expectEqual(users.count, 2, "two users")
    try expect(users[0].totpEnabled && users[0].hasPassword && users[0].scopes == ["*"], "admin user decodes")
    try expect(!users[1].hasPassword && users[1].serverAllowlist.isEmpty, "SSO-only user with a null allowlist decodes")

    let providers = try JSONDecoder().decode(AccessSSOProvidersResponse.self, from: json(#"""
    {"providers":[{"id":"oidc_1","display_name":"Workspace","issuer":"https://accounts.example.com","client_id":"lattice","has_secret":true,"scopes":["openid","email"],"allowed_domains":["example.org"],"enabled":true,"skip_local_totp":true},
                  {"id":"oidc_2","display_name":"","issuer":"https://sso.example.net","client_id":"x","has_secret":false,"enabled":false}]}
    """#)).providers
    try expect(providers[0].skipLocalTOTP && providers[0].allowedDomains == ["example.org"], "provider with every field decodes")
    try expect(!providers[1].skipLocalTOTP && providers[1].scopes.isEmpty && providers[1].title == "https://sso.example.net", "an older provider reads skip off and titles by issuer")

    let passkeys = try JSONDecoder().decode(AccessPasskeysResponse.self, from: json(#"""
    {"credentials":[{"id":"cred_1","name":"iPhone","created_at":"2026-08-01T00:00:00Z","last_used_at":"2026-10-28T10:00:00Z","backed_up":true,"transports":["internal","hybrid"],"aaguid":"00112233"},
                    {"id":"cred_2","name":"","created_at":"2026-09-01T00:00:00Z","backed_up":false}]}
    """#)).credentials
    try expect(passkeys[0].backedUp && passkeys[0].lastUsedAt != nil && passkeys[0].aaguid == "00112233", "synced passkey decodes")
    try expect(passkeys[1].lastUsedAt == nil && passkeys[1].transports.isEmpty && passkeys[1].displayName == "Unnamed passkey", "never-used passkey decodes")

    let renamed = try JSONDecoder().decode(AccessPasskeyResponse.self, from: json(#"{"credential":{"id":"cred_1","name":"Work phone","created_at":"2026-08-01T00:00:00Z","backed_up":true}}"#))
    try expectEqual(renamed.credential.name, "Work phone", "rename answers the credential")
    let ok = try JSONDecoder().decode(AccessOKResponse.self, from: json(#"{"ok":true}"#))
    try expect(ok.ok, "ok decodes")
}

// MARK: Request bodies

private func checkAccessRequestBodies() async throws {
    let (client, transport) = accessMock([
        "\(accessBase)/api/tokens/revoke": (200, json(#"{"id":"token_a","name":"CI","actor_id":"u1","scopes":[],"server_allowlist":[],"created_at":"2026-09-01T10:00:00Z","revoked_at":"2026-10-28T11:00:00Z"}"#)),
        "\(accessBase)/api/tokens/delete": (200, json(#"{"ok":true}"#)),
        "\(accessBase)/api/security/webauthn/credentials/rename": (200, json(#"{"credential":{"id":"cred_1","name":"Work phone","created_at":"2026-08-01T00:00:00Z","backed_up":true}}"#)),
        "\(accessBase)/api/security/webauthn/credentials/delete": (200, json(#"{"ok":true}"#)),
    ])
    _ = try await client.accessRevokeToken(id: "token_a")
    try await client.accessDeleteToken(id: "token_a")
    _ = try await client.accessRenamePasskey(id: "cred_1", name: "Work phone")
    try await client.accessDeletePasskey(id: "cred_1", stepUpGrant: "grant_x")
    let (plain, plainTransport) = accessMock(["\(accessBase)/api/security/webauthn/credentials/delete": (200, json(#"{"ok":true}"#))])
    try await plain.accessDeletePasskey(id: "cred_2", stepUpGrant: nil)
    let bodies = await transport.bodies + plainTransport.bodies
    let methods = await transport.methods + plainTransport.methods
    let urls = await transport.requestURLs + plainTransport.requestURLs
    try expectEqual(methods.compactMap { $0 }, ["POST", "POST", "POST", "POST", "POST"], "every account write is a POST")
    try expectEqual(urls.map { $0.replacingOccurrences(of: accessBase, with: "") }, [
        "/api/tokens/revoke", "/api/tokens/delete", "/api/security/webauthn/credentials/rename",
        "/api/security/webauthn/credentials/delete", "/api/security/webauthn/credentials/delete",
    ], "account write paths")
    try expectEqual(try bodyObject(bodies[0]) as NSDictionary, ["token_id": "token_a"] as NSDictionary, "revoke body is {token_id}")
    try expectEqual(try bodyObject(bodies[1]) as NSDictionary, ["token_id": "token_a"] as NSDictionary, "delete body is {token_id}")
    try expectEqual(try bodyObject(bodies[2]) as NSDictionary, ["id": "cred_1", "name": "Work phone"] as NSDictionary, "rename body is {id, name}")
    try expectEqual(try bodyObject(bodies[3]) as NSDictionary, ["id": "cred_1", "step_up_grant": "grant_x"] as NSDictionary, "delete with two-factor carries the grant")
    try expectEqual(try bodyObject(bodies[4]) as NSDictionary, ["id": "cred_2"] as NSDictionary, "delete without two-factor sends {id} alone")
}

// MARK: Scopes

private func checkAccessScopes() throws {
    try expectEqual(AccessScopes.summary(["*", "node:read"]), "Full administrator", "a wildcard reads as full administrator")
    try expectEqual(AccessScopes.summary([]), "No scopes", "no scopes")
    try expectEqual(AccessScopes.summary(["node:read"]), "1 scope", "one scope")
    try expectEqual(AccessScopes.summary(["node:read", "node:admin"]), "2 scopes", "two scopes")

    let star = AccessScopes.describe("*")
    try expect(star.sensitive && star.known && star.detail.contains("secrets:reveal"), "the wildcard explains the explicit-only exception")
    let area = AccessScopes.describe("node:*")
    try expect(area.sensitive && area.title == "Nodes" && area.detail == "Every node scope.", "an area wildcard names its group")
    let node = AccessScopes.describe("node:read")
    try expect(node.known && !node.sensitive && node.title == "Nodes", "a catalogue scope takes its description")
    try expect(AccessScopes.describe("network:apply").sensitive, "a sensitive catalogue scope stays sensitive")
    let tokenAdmin = AccessScopes.describe("token:admin")
    try expect(tokenAdmin.sensitive && tokenAdmin.known, "token:admin is flagged even when the catalogue lacks it")
    let unknown = AccessScopes.describe("future:thing")
    try expect(!unknown.known && !unknown.sensitive && unknown.title == "Other", "an unknown scope is named as such")

    let lines = AccessScopes.lines(["future:thing", "network:plan", "node:read", "*", "node:read"])
    try expectEqual(lines.map(\.scope), ["*", "node:read", "network:plan", "future:thing"], "scopes in catalogue order, wildcard first, unknown last, no duplicates")

    let risks = AccessScopes.risks(["terminal:open", "node:read", "token:admin"]).map(\.scope)
    try expectEqual(risks, ["token:admin", "terminal:open"], "risks in warning order")
    try expect(AccessScopes.risks(TokenPresets.operator.scopes).isEmpty, "the Operator preset carries no warned scope")

    try expectEqual(AccessAllowlist.summary([]), "All nodes", "empty allowlist")
    try expectEqual(AccessAllowlist.summary(["*", "n1"]), "All nodes", "a star entry is unconfined")
    try expectEqual(AccessAllowlist.summary(["n1"]), "Confined to 1 node", "one node")
    try expectEqual(AccessAllowlist.summary(["n1", "n2"]), "Confined to 2 nodes", "two nodes")
    try expect(AccessAllowlist.isConfined(["n1"]) && !AccessAllowlist.isConfined([]) && !AccessAllowlist.isConfined(["*"]), "confinement")
}

// MARK: Tokens

private func checkAccessTokens() throws {
    let old = accessToken("old", created: 0)
    let new = accessToken("new", created: 100)
    let gone = accessToken("gone", revoked: true, created: 200)
    try expectEqual(AccessTokens.sorted([gone, old, new]).map(\.id), ["new", "old", "gone"], "active first, newest first")
    try expectEqual(AccessTokens.state(gone), .revoked, "revoked state")
    try expectEqual(AccessTokens.state(old), .active, "active state")

    var phone = LatticeIdentity(actorID: "u1", username: "ops", scopes: ["node:read"])
    phone.tokenID = "old"
    try expect(AccessTokens.isOwn(old, identity: phone), "the token /api/me names is this iPhone's")
    try expect(!AccessTokens.isOwn(new, identity: phone), "another token is not")
    try expect(!AccessTokens.isOwn(old, identity: LatticeIdentity(actorID: "u1")), "a session names no token")
    try expect(!AccessTokens.isOwn(old, identity: nil), "unknown identity owns nothing")

    try expectEqual(AccessTokens.summary([old, new, gone]), "3 tokens, 2 active", "token summary")
    try expectEqual(AccessTokens.summary([]), "0 tokens", "empty summary")
    try expect(AccessTokens.deleteBlocker(old) != nil && AccessTokens.deleteBlocker(gone) == nil, "only a revoked token can be deleted")
    try expectEqual(AccessTokens.detail(accessToken("c", scopes: ["a:read", "b:read"], allowlist: ["n1", "n2"])), "2 scopes, confined to 2 nodes", "token row detail")
    try expectEqual(AccessTokens.detail(accessToken("d", scopes: ["*"])), "Full administrator, all nodes", "admin token row detail")
}

private func checkAccessQueries() throws {
    let rows = [
        accessToken("ci", scopes: ["task:run", "node:read"]),
        accessToken("asia", scopes: ["node:read"], allowlist: ["n1"]),
        accessToken("gone", scopes: ["*"], revoked: true),
    ]
    func run(_ query: String) throws -> [String] {
        guard case .success(let compiled) = LatticeQueryEngine.compile(query, provider: AccessTokenQueryFields.self) else {
            throw CheckFailure.failed("token query \(query) did not compile")
        }
        return LatticeQueryEngine.apply(compiled, to: rows, now: Date()).map(\.id)
    }
    try expectEqual(try run("state:revoked"), ["gone"], "state:revoked")
    try expectEqual(try run("is:confined"), ["asia"], "is:confined")
    try expectEqual(try run("-is:revoked"), ["ci", "asia"], "-is:revoked")
    try expectEqual(try run("is:admin"), ["gone"], "is:admin")
    try expectEqual(try run(#"scope:"task:run""#), ["ci"], "scope with a colon, quoted")
    try expectEqual(try run("node:n1"), ["asia"], "node allowlist field")
    try expectEqual(try run("ASIA"), ["asia"], "bare word matches the name")
    if case .success = LatticeQueryEngine.compile("stauts:active", provider: AccessTokenQueryFields.self) {
        throw CheckFailure.failed("a typo in a field name must be an error, never an empty list")
    }

    let users = [
        AccessUser(id: "u1", username: "ops", scopes: ["*"], totpEnabled: true, hasPassword: true),
        AccessUser(id: "u2", username: "bob@example.org", scopes: ["node:read"], totpEnabled: false, hasPassword: false),
    ]
    guard case .success(let sso) = LatticeQueryEngine.compile("login:sso -is:totp", provider: AccessUserQueryFields.self) else {
        throw CheckFailure.failed("user query did not compile")
    }
    try expectEqual(LatticeQueryEngine.apply(sso, to: users, now: Date()).map(\.id), ["u2"], "SSO-only accounts without two-factor")
    guard case .success(let admins) = LatticeQueryEngine.compile("is:admin", provider: AccessUserQueryFields.self) else {
        throw CheckFailure.failed("is:admin did not compile")
    }
    try expectEqual(LatticeQueryEngine.apply(admins, to: users, now: Date()).map(\.id), ["u1"], "full administrators")
}

// MARK: Users

private func checkAccessUsers() throws {
    let ops = AccessUser(id: "u1", username: "ops", scopes: ["*"], totpEnabled: true, hasPassword: true)
    let alice = AccessUser(id: "u2", username: "alice", scopes: ["node:read", "node:admin"], totpEnabled: true, hasPassword: true)
    let bob = AccessUser(id: "u3", username: "bob", scopes: ["node:read"], totpEnabled: false, hasPassword: false)
    try expectEqual(AccessUsers.role(ops), "Full administrator", "admin role")
    try expectEqual(AccessUsers.role(alice), "2 scopes", "scoped role")
    try expectEqual(AccessUsers.signIn(bob), "SSO only", "SSO-only sign-in")
    try expectEqual(AccessUsers.signIn(alice), "Password", "password sign-in")
    try expectEqual(AccessUsers.summary([ops, alice, bob]), "3 users, 1 full administrator, 2 of 3 with two-factor", "user summary")
    try expectEqual(AccessUsers.sorted([alice, ops, bob]).map(\.id), ["u3", "u1", "u2"], "without two-factor first, then administrators")
    try expect(AccessUsers.isSelf(ops, actorID: "u1") && !AccessUsers.isSelf(ops, actorID: nil) && !AccessUsers.isSelf(ops, actorID: ""), "self")
    try expectEqual(AccessUsers.deleteBlocker(ops, users: [ops, alice], actorID: "u2"), "The last full administrator cannot be deleted.", "last admin guard")
    try expectEqual(AccessUsers.deleteBlocker(alice, users: [ops, alice], actorID: "u2"), "This is the account you are signed in with.", "self guard")
    try expect(AccessUsers.deleteBlocker(bob, users: [ops, alice, bob], actorID: "u1") == nil, "an ordinary account has no guard")
}

// MARK: SSO

private func checkAccessSSO() throws {
    let workspace = AccessSSOProvider(id: "a", displayName: "Workspace", issuer: "https://a.example.com", hasSecret: true, enabled: true)
    let lab = AccessSSOProvider(id: "b", displayName: "Lab", issuer: "https://b.example.net", hasSecret: false, enabled: false, skipLocalTOTP: true)
    let skipping = AccessSSOProvider(id: "c", displayName: "Corp", issuer: "https://c.example.org", hasSecret: true, enabled: true, skipLocalTOTP: true)
    try expectEqual(AccessSSO.summary([workspace, lab]), "2 providers, 1 enabled", "a disabled skipping provider is not counted as skipping")
    try expectEqual(AccessSSO.summary([workspace, skipping]), "2 providers, 2 enabled, 1 skips the authenticator code", "enabled skipping provider")
    try expectEqual(AccessSSO.summary([]), "0 providers", "no providers")
    try expect(AccessSSO.notices(workspace).isEmpty, "a sound provider has no notice")
    try expectEqual(AccessSSO.notices(lab).count, 2, "skip and missing secret")
    try expect(AccessSSO.notices(skipping)[0].hasPrefix("Skips the authenticator code: anyone"), "enabled skip states its consequence")
    try expectEqual(AccessSSO.domains(workspace), "Any verified email domain", "no domain list")
    try expectEqual(AccessSSO.sorted([lab, skipping, workspace]).map(\.id), ["c", "a", "b"], "enabled first, then by title")
}

// MARK: Passkeys

private func checkAccessPasskeys() throws {
    let recent = AccessPasskey(id: "p1", name: "iPhone", createdAt: Date(timeIntervalSince1970: 100), lastUsedAt: Date(timeIntervalSince1970: 900), backedUp: true, transports: ["internal", "hybrid"])
    let older = AccessPasskey(id: "p2", name: "Key", createdAt: Date(timeIntervalSince1970: 50), lastUsedAt: Date(timeIntervalSince1970: 500), transports: ["usb", "weird"])
    let unused = AccessPasskey(id: "p3", name: "Mac", createdAt: Date(timeIntervalSince1970: 300))
    try expectEqual(AccessPasskeys.sorted([unused, older, recent]).map(\.id), ["p1", "p2", "p3"], "most recently used first, never used last")
    try expectEqual(AccessPasskeys.storage(recent), "Synced", "synced")
    try expectEqual(AccessPasskeys.storage(older), "This device only", "device-bound")
    try expectEqual(AccessPasskeys.transports(recent), "built in, nearby device", "transport words")
    try expectEqual(AccessPasskeys.transports(older), "USB, weird", "unknown transports shown as sent")
    try expectEqual(AccessPasskeys.transports(unused), "Not reported", "no transports")
    try expectEqual(AccessPasskeys.renameValue("  Work phone ", current: "iPhone"), "Work phone", "rename trims")
    try expect(AccessPasskeys.renameValue("   ", current: "iPhone") == nil, "blank rename refused")
    try expect(AccessPasskeys.renameValue("iPhone", current: "iPhone") == nil, "unchanged rename refused")

    try expectEqual(AccessPasskeyDeletePlan.steps(totpEnabled: true, grantUsable: false), [.code, .confirm, .authenticate, .send], "two-factor without a grant asks for the code")
    try expectEqual(AccessPasskeyDeletePlan.steps(totpEnabled: true, grantUsable: true), [.confirm, .authenticate, .send], "a held grant skips the code")
    try expectEqual(AccessPasskeyDeletePlan.steps(totpEnabled: false, grantUsable: false), [.confirm, .authenticate, .send], "no two-factor, no code")
    try expectEqual(AccessPasskeyDeletePlan.steps(totpEnabled: nil, grantUsable: false), [.confirm, .authenticate, .send], "unknown two-factor waits for the server to ask for a code")
    try expect(AccessPasskeyDeletePlan.sendsGrant(totpEnabled: nil) && !AccessPasskeyDeletePlan.sendsGrant(totpEnabled: false), "a held grant is sent unless two-factor is known off")
    let issued = Date(timeIntervalSince1970: 1_800_000_000)
    let grant = StepUpGrant(grant: "g", expiresAt: issued.addingTimeInterval(60))
    try expect(AccessPasskeyDeletePlan.reusableGrant(grant, now: issued) != nil, "a fresh grant outlasts the confirmation")
    try expect(AccessPasskeyDeletePlan.reusableGrant(grant, now: issued.addingTimeInterval(30)) == nil, "a grant with 30 s left would expire during the confirmation")
    try expect(grant.isUsable(now: issued.addingTimeInterval(30)), "the same grant is still usable for a reveal")
    try expect(AccessPasskeyDeletePlan.reusableGrant(nil, now: issued) == nil, "no grant held")
}

// MARK: Intents

private func checkAccessIntents() async throws {
    let mine = accessToken("tok_mine")
    let own = AccessIntents.revokeToken(mine, isOwn: true)
    try expect(own.tier == .t4 && own.client == .primary && own.scopes == ["token:admin"], "revoke is T4 on the token client")
    try expect(own.consequence.hasSuffix(AccessIntents.ownTokenWarning), "own token revoke warns about sign-out")
    try expectEqual(own.confirmPhrase, mine.displayName, "own token revoke asks for the name")
    let other = AccessIntents.revokeToken(mine, isOwn: false)
    try expect(other.confirmPhrase == nil && !other.consequence.contains("signed out"), "another token's revoke has no sign-out warning")
    try expect(AccessIntents.deleteToken(mine, isOwn: false).tier == .t4, "delete is T4")
    let passkey = AccessPasskey(id: "pk_demo_key", name: "Security key")
    let rename = AccessIntents.renamePasskey(passkey, to: "Desk key")
    try expect(rename.tier == .t2 && rename.client == .session && rename.scopes.isEmpty, "rename is T2 on the session")
    let delete = AccessIntents.deletePasskey(passkey, grant: nil)
    try expect(delete.tier == .t4 && delete.client == .session, "passkey delete is T4 on the session")

    // A cancelled Face ID sends nothing.
    let (mock, transport) = accessMock([:])
    let cancelled = await WriteFlow(intent: own, client: mock, authenticator: AccessAuthStub(outcome: .cancelled)).commit(choices: ConfirmChoices())
    guard case .cancelled = cancelled else { throw CheckFailure.failed("cancelled authentication must cancel") }
    let sent = await transport.requestURLs
    try expectEqual(sent.count, 0, "a cancelled revoke sends zero requests")

    // Tokens against the demo server, as a full administrator.
    let state = DemoState()
    let admin = accessDemo(state: state)
    let deleteActive = try await accessCommit(AccessIntents.deleteToken(accessToken("tok_demo0002ci"), isOwn: false), admin)
    guard case .refused(_, let refusal) = deleteActive, refusal.contains("revoked before deletion") else {
        throw CheckFailure.failed("deleting an active token is refused with the server's reason, got \(deleteActive)")
    }
    let ci = try await expectUnwrapped(admin.listTokens().first { $0.id == "tok_demo0002ci" }, "CI token listed")
    guard case .done(let revokedText, _) = try await accessCommit(AccessIntents.revokeToken(ci, isOwn: false), admin) else {
        throw CheckFailure.failed("revoke lands")
    }
    try expectEqual(revokedText, "Revoked CI deploy", "revoke banner")
    let afterRevoke = try await admin.listTokens()
    try expect(afterRevoke.first { $0.id == ci.id }?.isRevoked == true, "the listing shows the revocation")
    guard case .done(let againText, _) = try await accessCommit(AccessIntents.revokeToken(ci, isOwn: false), admin), againText == "Revoked CI deploy" else {
        throw CheckFailure.failed("revoking twice is idempotent")
    }
    guard case .done = try await accessCommit(AccessIntents.deleteToken(ci, isOwn: false), admin) else {
        throw CheckFailure.failed("deleting a revoked token lands")
    }
    let afterDelete = try await admin.listTokens()
    try expect(!afterDelete.contains { $0.id == ci.id }, "the deleted token is gone")
    let phone = try await expectUnwrapped(admin.listTokens().first { $0.id == AccessFixtures.phoneTokenID }, "phone token listed")
    guard case .done(let ownText, _) = try await accessCommit(AccessIntents.revokeToken(phone, isOwn: true), admin), ownText.hasSuffix("Signing out.") else {
        throw CheckFailure.failed("own token revoke says it signs out")
    }

    // Passkeys on the demo session: the operator has two-factor on.
    let session = accessDemo(.session, .normal, state: state)
    let key = try await expectUnwrapped(session.accessListPasskeys().first { $0.id == "pk_demo_key" }, "security key listed")
    guard case .done(let renamedText, _) = try await accessCommit(AccessIntents.renamePasskey(key, to: "Desk key"), session) else {
        throw CheckFailure.failed("rename lands")
    }
    try expectEqual(renamedText, "Renamed passkey to Desk key", "rename banner")
    let afterRename = try await session.accessListPasskeys()
    try expect(afterRename.contains { $0.id == key.id && $0.name == "Desk key" }, "the listing shows the new name")
    let noGrant = try await accessCommit(AccessIntents.deletePasskey(key, grant: nil), session)
    guard case .refused(.stepUpRequired, let stepText) = noGrant else {
        throw CheckFailure.failed("a delete without a grant is a step-up refusal, got \(noGrant)")
    }
    try expectEqual(stepText, AccessIntents.stepUpExpired(AccessIntents.object(key)), "step-up refusal copy")
    let grant = try await session.stepUp(code: "123456")
    guard case .done = try await accessCommit(AccessIntents.deletePasskey(key, grant: grant), session) else {
        throw CheckFailure.failed("a delete with a grant lands")
    }
    let afterPasskeyDelete = try await session.accessListPasskeys()
    try expect(!afterPasskeyDelete.contains { $0.id == key.id }, "the deleted passkey is gone")
}

// MARK: Demo

private func checkAccessDemo() async throws {
    // The Operator preset holds no token:admin, user:admin or oidc:admin.
    let operatorClient = accessDemo(.pat, .normal)
    for (name, read) in [("tokens", { try await _ = operatorClient.listTokens() }), ("users", { try await _ = operatorClient.accessListUsers() }), ("SSO", { try await _ = operatorClient.accessListSSOProviders() })] as [(String, () async throws -> Void)] {
        do {
            try await read()
            throw CheckFailure.failed("the Operator preset must not read \(name)")
        } catch let error as LatticeAPIError {
            guard case .forbidden = error else { throw CheckFailure.failed("\(name): expected 403, got \(error)") }
        }
    }
    let admin = accessDemo()
    let tokens = try await admin.listTokens()
    try expect(tokens.contains { $0.id == AccessFixtures.phoneTokenID }, "the phone's token is listed")
    try expect(tokens.contains { $0.isRevoked } && tokens.contains { !$0.isRevoked }, "active and revoked tokens")
    try expect(tokens.contains { $0.scopes.contains("*") } && tokens.contains { AccessAllowlist.isConfined($0.serverAllowlist) }, "an admin token and a confined token")
    let users = try await admin.accessListUsers()
    try expectEqual(users.count, 4, "four users")
    let providers = try await admin.accessListSSOProviders()
    try expect(providers.contains { $0.skipLocalTOTP } && providers.contains { !$0.hasSecret } && providers.contains(where: \.enabled), "providers in every state")

    // A confined token reads only the tokens inside its allowlist.
    let confined = accessDemo(.pat, .confinedToken)
    do {
        _ = try await confined.listTokens()
        throw CheckFailure.failed("a confined Operator token holds no token:admin")
    } catch let error as LatticeAPIError {
        guard case .forbidden = error else { throw CheckFailure.failed("confined: expected 403, got \(error)") }
    }

    // Passkeys exist only on a session; a token is refused as the server does.
    do {
        _ = try await admin.accessListPasskeys()
        throw CheckFailure.failed("a token must not read passkeys")
    } catch let error as LatticeAPIError {
        guard case .forbidden(_, let message) = error, message.contains("interactive session") else {
            throw CheckFailure.failed("passkeys on a token: expected the interactive-session refusal, got \(error)")
        }
    }
    let session = accessDemo(.session, .normal)
    let passkeys = try await session.accessListPasskeys()
    try expectEqual(passkeys.count, 3, "three passkeys")
    let empty = accessDemo(.session, .empty)
    let emptyPasskeys = try await empty.accessListPasskeys()
    try expect(emptyPasskeys.isEmpty, "the Empty scenario serves no passkeys")
}
