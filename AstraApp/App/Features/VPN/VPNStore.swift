import Foundation

/// The VPN identities and lines (M13-01, M13-03), created by StoreRegistry.
/// Detail screens read their row from here and own what only they need
/// (the link status, path states).
///
/// Every read needs vpncore:read, which proxy:read also satisfies, with a
/// token that has no node allowlist: vpn-core identities and lines are
/// fleet-wide objects (`requireGlobalProxyScope`, `pluginGatewayScopeAllowed`).
/// Line chains are M3's call, behind proxy:read too.
@MainActor @Observable
final class VPNStore {
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog
    @ObservationIgnored private var generation = -1

    private(set) var users: ResourceState<VPNUserListing> = .idle
    private(set) var lines: ResourceState<[VPNLineGroup]> = .idle
    /// M3's chain rows; a failure here never hides the lines.
    private(set) var chains: ResourceState<[MonitoringLineChain]> = .idle

    static let readRequirement = ScopeRequirement.anyOf(VPNIntents.readScope, "proxy:read")
    static let usersSurface = "VPN users"
    static let linesSurface = "VPN lines"

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    // MARK: Gates

    private var isConfined: Bool { session.primaryIdentity?.scopeSet.isConfined ?? false }

    private func missing(_ requirement: ScopeRequirement, on kind: ClientKind = .primary, named: String) -> String? {
        guard let missing = session.missing(requirement, on: kind), !missing.isEmpty else { return nil }
        return named
    }

    /// Why the token cannot read identities or lines; nil when it can or its scopes are not known yet.
    var readMissing: String? {
        if let scope = missing(Self.readRequirement, named: "proxy:read") { return scope }
        return isConfined ? ScopeRequirement.unconfinedPhrase : nil
    }

    /// Link status, rotate and revoke: vpncore:admin (or proxy:admin), unconfined.
    var linkMissing: String? {
        if let scope = missing(ScopeRequirement(VPNIntents.linkScope), named: "vpncore:admin or proxy:admin") { return scope }
        return isConfined ? ScopeRequirement.unconfinedPhrase : nil
    }

    /// Reveals run on the session, so only its scopes and allowlist gate
    /// them; without a session the reveal flow offers to sign in. A confined
    /// session is refused after the code is spent, so it is gated here.
    var revealLinkMissing: String? {
        if let scope = missing(ScopeRequirement(VPNIntents.linkScope), on: .session, named: "vpncore:admin or proxy:admin") { return scope }
        return isSessionConfined ? ScopeRequirement.unconfinedPhrase : nil
    }

    var credentialsMissing: String? {
        if let scope = missing(ScopeRequirement(VPNIntents.credentialsScope), on: .session, named: VPNIntents.credentialsScope) { return scope }
        return isSessionConfined ? ScopeRequirement.unconfinedPhrase : nil
    }

    private var isSessionConfined: Bool { session.sessionIdentity?.scopeSet.isConfined ?? false }

    var hasRevealSession: Bool { session.revealClient != nil }

    // MARK: Lookups

    func user(id: String) -> VPNUser? {
        users.value?.user(id: id)
    }

    func line(id: String) -> VPNLineEntry? {
        lines.value.flatMap { VPNLineEntry.find(id, in: $0) }
    }

    // MARK: Refresh

    private func resetIfCredentialChanged() {
        guard session.generation != generation else { return }
        generation = session.generation
        users = .idle
        lines = .idle
        chains = .idle
    }

    @discardableResult
    func refreshUsers() async -> Bool {
        resetIfCredentialChanged()
        if let missing = readMissing {
            users = .denied(scope: missing)
            return true
        }
        guard let client = session.client else { return false }
        let before = users
        users = before.reloading
        do {
            users = .loaded(try await client.vpnListUsers(), at: Date())
            return true
        } catch {
            if Self.isCancellation(error) {
                users = before
                return true
            }
            users = fail(users, error, surface: Self.usersSurface)
            return false
        }
    }

    /// Lines and their chains, read together.
    @discardableResult
    func refreshLines() async -> Bool {
        resetIfCredentialChanged()
        if let missing = readMissing {
            lines = .denied(scope: missing)
            chains = .denied(scope: missing)
            return true
        }
        guard let client = session.client else { return false }
        let beforeLines = lines, beforeChains = chains
        lines = beforeLines.reloading
        chains = beforeChains.reloading
        async let chainRows = Self.result { try await client.monitoringLineChains() }
        async let lineRows = Self.result { try await client.vpnListLines() }
        let (chainResult, lineResult) = await (chainRows, lineRows)
        switch chainResult {
        case .success(let rows): chains = .loaded(rows, at: Date())
        case .failure(let error): chains = Self.isCancellation(error) ? beforeChains : fail(chains, error, surface: "Line chains")
        }
        switch lineResult {
        case .success(let groups):
            lines = .loaded(groups, at: Date())
            return true
        case .failure(let error):
            if Self.isCancellation(error) {
                lines = beforeLines
                return true
            }
            lines = fail(lines, error, surface: Self.linesSurface)
            return false
        }
    }

    private func fail<Value>(_ state: ResourceState<Value>, _ error: Error, surface: String) -> ResourceState<Value> {
        let apiError = LatticeAPIError(error)
        if case .invalidResponse = apiError { session.markCompanionBehind(surface) }
        if case .forbidden = apiError { session.noteForbidden() }
        return state.failing(apiError, surface: surface, missingScope: readMissing ?? "proxy:read")
    }

    nonisolated private static func result<Value: Sendable>(_ work: @Sendable () async throws -> Value) async -> Result<Value, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        if case .transport(.cancelled) = LatticeAPIError(error) { return true }
        return false
    }
}
