import Foundation

/// The account lists (section 8.4, M11 row): users, tokens and SSO providers
/// on the primary client, and the signed-in operator's passkeys on the
/// session. Created by StoreRegistry; detail screens read from these lists,
/// because the server has no by-id read for any of them.
///
/// Users need user:admin, tokens token:admin and providers oidc:admin, none
/// of which a phone preset carries, so a phone token usually sees the denied
/// state. Passkeys need a signed-in session: the server refuses API tokens.
@MainActor @Observable
final class AccessStore {
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog
    @ObservationIgnored private var generation = -1
    @ObservationIgnored private var sessionKey = ""

    private(set) var users: ResourceState<[AccessUser]> = .idle
    private(set) var tokens: ResourceState<[LatticeToken]> = .idle
    private(set) var providers: ResourceState<[AccessSSOProvider]> = .idle
    private(set) var passkeys: ResourceState<[AccessPasskey]> = .idle
    /// `/api/me` on the session, for the two-factor state. Kept here rather
    /// than read from SessionStore so a failed re-read keeps the last value
    /// and the screen can say it is stale.
    private(set) var identity: ResourceState<LatticeIdentity> = .idle

    static let usersRequirement = ScopeRequirement(AccessIntents.userScope)
    static let tokensRequirement = ScopeRequirement(AccessIntents.tokenScope)
    static let ssoRequirement = ScopeRequirement(AccessIntents.ssoScope)

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    // MARK: Access

    /// The missing scope on the primary client, or nil when it is held or
    /// the scopes are not known yet (the server then decides).
    func missing(_ requirement: ScopeRequirement) -> String? {
        session.missing(requirement)?.first
    }

    var tokensMissing: String? { missing(Self.tokensRequirement) }
    var usersMissing: String? { missing(Self.usersRequirement) }
    var ssoMissing: String? { missing(Self.ssoRequirement) }

    /// Passkeys and two-factor state are read on the signed-in session only.
    var hasSession: Bool { session.revealClient != nil && !session.sessionExpired }

    /// The identity of the session, for the two-factor state: the last one
    /// this store read, else the one the session loaded at sign-in.
    var sessionIdentity: LatticeIdentity? { identity.value ?? session.sessionIdentity }

    /// Whether `token` is known to be the one this iPhone's primary client carries.
    func isOwn(_ token: LatticeToken) -> Bool {
        ownership(of: token) == .own
    }

    func ownership(of token: LatticeToken) -> AccessTokenOwnership {
        AccessTokens.ownership(token, credentialIsToken: session.credentialKind == .token, identity: session.primaryIdentity)
    }

    /// Ownership for a write: an unread `/api/me` is read once more first,
    /// and if it still fails the token counts as possibly this iPhone's.
    func ownershipForWrite(of token: LatticeToken) async -> AccessTokenOwnership {
        if ownership(of: token) == .unknown { await session.refreshIdentity() }
        return ownership(of: token)
    }

    /// After a revoke the server confirmed, whether this iPhone's token is
    /// gone: known to be its own, or unknown and `/api/me` now answers 401.
    func revokedOwnToken(_ ownership: AccessTokenOwnership) async -> Bool {
        switch ownership {
        case .own: return true
        case .other: return false
        case .unknown:
            await session.refreshIdentity()
            if case .unauthorized = session.identityError { return true }
            return false
        }
    }

    /// The account the credentials on this iPhone belong to.
    var actorID: String? {
        session.sessionIdentity?.actorID ?? session.primaryIdentity?.actorID
    }

    func token(id: String) -> LatticeToken? { tokens.value?.first { $0.id == id } }
    func user(id: String) -> AccessUser? { users.value?.first { $0.id == id } }
    func provider(id: String) -> AccessSSOProvider? { providers.value?.first { $0.id == id } }
    func passkey(id: String) -> AccessPasskey? { passkeys.value?.first { $0.id == id } }

    // MARK: Refresh

    @discardableResult
    func refreshTokens() async -> Bool {
        resetIfCredentialChanged()
        return await load(\.tokens, surface: "Access tokens", requirement: Self.tokensRequirement) { try await $0.listTokens() }
    }

    @discardableResult
    func refreshUsers() async -> Bool {
        resetIfCredentialChanged()
        return await load(\.users, surface: "Users", requirement: Self.usersRequirement) { try await $0.accessListUsers() }
    }

    @discardableResult
    func refreshProviders() async -> Bool {
        resetIfCredentialChanged()
        return await load(\.providers, surface: "SSO providers", requirement: Self.ssoRequirement) { try await $0.accessListSSOProviders() }
    }

    /// The passkeys on the session client. Without a session nothing is read
    /// and the screen explains why.
    @discardableResult
    func refreshPasskeys() async -> Bool {
        resetIfCredentialChanged()
        guard let client = session.revealClient, !session.sessionExpired else {
            passkeys = .idle
            return true
        }
        let before = passkeys
        passkeys = before.reloading
        do {
            passkeys = .loaded(try await client.accessListPasskeys(), at: Date())
            return true
        } catch {
            if Self.isCancellation(error) {
                passkeys = before
                return true
            }
            let apiError = LatticeAPIError(error)
            if case .invalidResponse = apiError {
                session.markCompanionBehind("Passkeys")
                passkeys = .companionBehind(surface: "Passkeys")
                return false
            }
            // Not a scope: any interactive session may list its own passkeys.
            passkeys = .failed(apiError, last: before.value, lastAt: before.loadedAt)
            return false
        }
    }

    /// Re-reads `/api/me` on the session client. A failure keeps the last
    /// identity, so the two-factor state shows as stale, never blank.
    @discardableResult
    func refreshIdentity() async -> Bool {
        resetIfCredentialChanged()
        guard let client = session.revealClient, !session.sessionExpired else {
            identity = .idle
            return true
        }
        let before = identity
        identity = before.reloading
        do {
            identity = .loaded(try await client.fetchIdentity(), at: Date())
            return true
        } catch {
            if Self.isCancellation(error) {
                identity = before
                return true
            }
            let apiError = LatticeAPIError(error)
            if case .invalidResponse = apiError {
                session.markCompanionBehind("Two-factor state")
                identity = .companionBehind(surface: "Two-factor state")
                return false
            }
            identity = .failed(apiError, last: before.value ?? session.sessionIdentity, lastAt: before.loadedAt)
            return false
        }
    }

    // MARK: Loading

    private func load<Value: Sendable>(
        _ keyPath: ReferenceWritableKeyPath<AccessStore, ResourceState<Value>>,
        surface: String,
        requirement: ScopeRequirement,
        fetch: @Sendable (LatticeClient) async throws -> Value
    ) async -> Bool {
        let scope = requirement.groups.first?.first ?? ""
        if let missing = missing(requirement) {
            self[keyPath: keyPath] = .denied(scope: missing)
            return true
        }
        guard let client = session.client else { return false }
        let before = self[keyPath: keyPath]
        self[keyPath: keyPath] = before.reloading
        do {
            self[keyPath: keyPath] = .loaded(try await fetch(client), at: Date())
            return true
        } catch {
            if Self.isCancellation(error) {
                self[keyPath: keyPath] = before
                return true
            }
            let apiError = LatticeAPIError(error)
            if case .invalidResponse = apiError { session.markCompanionBehind(surface) }
            if case .forbidden = apiError { session.noteForbidden() }
            self[keyPath: keyPath] = self[keyPath: keyPath].failing(apiError, surface: surface, missingScope: scope)
            return false
        }
    }

    /// A new credential or a new session drops what the old one read.
    private func resetIfCredentialChanged() {
        // The session's own values, set together with its client, so loading
        // its identity later does not count as a new session.
        let key = session.revealSession.map { "\($0.actorID ?? "")|\($0.csrfToken)" } ?? (session.revealClient == nil ? "" : "session")
        if session.generation != generation {
            generation = session.generation
            users = .idle
            tokens = .idle
            providers = .idle
            passkeys = .idle
            identity = .idle
        }
        if key != sessionKey {
            sessionKey = key
            passkeys = .idle
            identity = .idle
        }
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        if case .transport(.cancelled) = LatticeAPIError(error) { return true }
        return false
    }
}
