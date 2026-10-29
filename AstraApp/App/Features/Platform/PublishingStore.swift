import Foundation

/// Publishing and the store's bucket lists (M8-04 to M8-08), created by
/// StoreRegistry and read from the environment. Each section is gated by
/// the scope the server's handler checks: routes per origin by the server
/// itself, buckets and bindings by `<kind>:read`, storage tokens by
/// `<kind>:admin`, shares by an unconfined `proxy:admin`.
@MainActor @Observable
final class PublishingStore {
    /// Publishing opens with any one of these (section 5.9).
    nonisolated static let requirement = ScopeRequirement.anyOf("kv:read", "static:read", "proxy:admin")
    /// Store opens with either read scope.
    nonisolated static let storeRequirement = ScopeRequirement.anyOf("kv:read", "static:read")
    nonisolated static let shareScope = "proxy:admin"

    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog

    private(set) var records: ResourceState<PlatformPublishingList> = .idle
    private(set) var shares: ResourceState<[PlatformShare]> = .idle
    private(set) var buckets: [PlatformStorageKind: ResourceState<PlatformBucketList>] = [:]
    private(set) var bindings: [PlatformStorageKind: ResourceState<[PlatformStorageBinding]>] = [:]
    private(set) var tokens: [PlatformStorageKind: ResourceState<[PlatformStorageToken]>] = [:]

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    // MARK: Gates

    /// The scope a requirement lacks, or nil when held or not known yet.
    func missing(_ requirement: ScopeRequirement, on kind: ClientKind = .primary) -> String? {
        guard let missing = session.missing(requirement, on: kind), !missing.isEmpty else { return nil }
        return missing.joined(separator: " or ")
    }

    var screenMissing: String? {
        missing(Self.requirement).map { _ in "kv:read, static:read or proxy:admin" }
    }

    var storeMissing: String? {
        missing(Self.storeRequirement).map { _ in "kv:read or static:read" }
    }

    var isConfined: Bool { session.primaryIdentity?.scopeSet.isConfined ?? false }

    /// Share reads and writes refuse a node-confined token (`requireGlobalProxyScope`).
    var shareMissing: String? {
        if let missing = missing(ScopeRequirement(Self.shareScope)) { return missing }
        return isConfined ? "a token without a node allowlist" : nil
    }

    /// The reveal runs on the session, so only the session's scopes gate it;
    /// without a session the reveal flow offers sign in.
    var revealMissing: String? {
        missing(ScopeRequirement(Self.shareScope), on: .session)
    }

    func readMissing(_ kind: PlatformStorageKind) -> String? { missing(ScopeRequirement(kind.readScope)) }
    func adminMissing(_ kind: PlatformStorageKind) -> String? { missing(ScopeRequirement(kind.adminScope)) }

    // MARK: Lookups

    func share(id: String) -> PlatformShare? { shares.value?.first { $0.id == id } }

    func binding(id: String) -> PlatformStorageBinding? {
        PlatformStorageKind.allCases.lazy.compactMap { self.bindings[$0]?.value?.first { $0.id == id } }.first
    }

    func token(id: String) -> PlatformStorageToken? {
        PlatformStorageKind.allCases.lazy.compactMap { self.tokens[$0]?.value?.first { $0.id == id } }.first
    }

    func bucket(kind: PlatformStorageKind, name: String) -> PlatformBucketInventoryEntry? {
        buckets[kind]?.value?.allBuckets.first { $0.name == name }
    }

    func registeredBucket(kind: PlatformStorageKind, name: String) -> PlatformStorageBucket? {
        buckets[kind]?.value?.buckets.first { $0.name == name }
    }

    /// Share slugs by id, so a share route names its slug.
    var shareSlugs: [String: String] {
        Dictionary((shares.value ?? []).map { ($0.id, $0.slug) }, uniquingKeysWith: { first, _ in first })
    }

    /// Live tokens that can write a bucket from outside the console; nil when unknown.
    func tokenWriters(kind: PlatformStorageKind, bucket: String) -> [PlatformStorageToken]? {
        tokens[kind]?.value?.filter { PlatformStorageTokens.writes($0, bucket: bucket, kind: kind.rawValue) }
    }

    // MARK: Reads

    /// Every Publishing read the token allows, in parallel.
    @discardableResult
    func refresh() async -> Bool {
        guard let client = session.client else { return false }
        async let recordsOK = refreshRecords(client)
        async let sharesOK = refreshShares(client)
        async let storageOK = refreshStorage(client)
        let results = await [recordsOK, sharesOK, storageOK]
        return !results.contains(false)
    }

    /// Bucket lists only, for Store.
    @discardableResult
    func refreshBuckets() async -> Bool {
        guard let client = session.client else { return false }
        return await refreshStorage(client)
    }

    private func refreshRecords(_ client: LatticeClient) async -> Bool {
        if screenMissing != nil {
            records = .denied(scope: "kv:read, static:read or proxy:admin")
            return true
        }
        records = records.reloading
        do {
            records = .loaded(try await client.platformPublishingRecords(), at: Date())
            return true
        } catch {
            records = records.failing(LatticeAPIError(error), surface: "Publishing routes")
            return false
        }
    }

    private func refreshShares(_ client: LatticeClient) async -> Bool {
        if let missing = shareMissing {
            shares = .denied(scope: missing)
            return true
        }
        shares = shares.reloading
        do {
            shares = .loaded(try await client.platformShares(), at: Date())
            return true
        } catch {
            let apiError = LatticeAPIError(error)
            shares = shares.failing(apiError, surface: "Shares", missingScope: Self.shareScope)
            if case .forbidden = apiError { session.noteForbidden() }
            return false
        }
    }

    private func refreshStorage(_ client: LatticeClient) async -> Bool {
        var ok = true
        for kind in PlatformStorageKind.allCases {
            async let bucketsOK = refreshBuckets(kind, client)
            async let bindingsOK = refreshBindings(kind, client)
            async let tokensOK = refreshTokens(kind, client)
            if !(await bucketsOK) { ok = false }
            if !(await bindingsOK) { ok = false }
            if !(await tokensOK) { ok = false }
        }
        return ok
    }

    private func refreshBuckets(_ kind: PlatformStorageKind, _ client: LatticeClient) async -> Bool {
        if let missing = readMissing(kind) {
            buckets[kind] = .denied(scope: missing)
            return true
        }
        let current = buckets[kind] ?? .idle
        buckets[kind] = current.reloading
        do {
            buckets[kind] = .loaded(try await client.platformBuckets(kind: kind), at: Date())
            return true
        } catch {
            buckets[kind] = current.failing(LatticeAPIError(error), surface: "\(kind.title) buckets", missingScope: kind.readScope)
            return false
        }
    }

    private func refreshBindings(_ kind: PlatformStorageKind, _ client: LatticeClient) async -> Bool {
        if let missing = readMissing(kind) {
            bindings[kind] = .denied(scope: missing)
            return true
        }
        let current = bindings[kind] ?? .idle
        bindings[kind] = current.reloading
        do {
            bindings[kind] = .loaded(try await client.platformBindings(kind: kind), at: Date())
            return true
        } catch {
            bindings[kind] = current.failing(LatticeAPIError(error), surface: "\(kind.title) bindings", missingScope: kind.readScope)
            return false
        }
    }

    private func refreshTokens(_ kind: PlatformStorageKind, _ client: LatticeClient) async -> Bool {
        if let missing = adminMissing(kind) {
            tokens[kind] = .denied(scope: missing)
            return true
        }
        let current = tokens[kind] ?? .idle
        tokens[kind] = current.reloading
        do {
            tokens[kind] = .loaded(try await client.platformStorageTokens(kind: kind), at: Date())
            return true
        } catch {
            tokens[kind] = current.failing(LatticeAPIError(error), surface: "\(kind.title) storage tokens", missingScope: kind.adminScope)
            return false
        }
    }

    // MARK: Combined states

    /// Both kinds' bindings as one state, for Binding detail.
    var bindingsState: ResourceState<[PlatformStorageBinding]> { Self.combined(bindings) }

    /// Both kinds' tokens as one state, for Storage token detail.
    var tokensState: ResourceState<[PlatformStorageToken]> { Self.combined(tokens) }

    /// Loaded when either kind loaded; denied only when both are; otherwise
    /// the first kind's loading, failed or behind state.
    private static func combined<Item: Sendable>(_ states: [PlatformStorageKind: ResourceState<[Item]>]) -> ResourceState<[Item]> {
        let all = PlatformStorageKind.allCases.map { states[$0] ?? .idle }
        let values = all.compactMap(\.value)
        if !values.isEmpty {
            return .loaded(values.flatMap { $0 }, at: all.compactMap(\.loadedAt).max() ?? Date())
        }
        let denied = all.compactMap { state -> String? in
            if case .denied(let scope) = state { return scope }
            return nil
        }
        if denied.count == all.count { return .denied(scope: denied.joined(separator: " or ")) }
        return all.first { if case .denied = $0 { return false } else { return true } } ?? .idle
    }

    // MARK: Freshness

    /// The newest load time across the sections a screen shows.
    var loadedAt: Date? {
        ([records.loadedAt, shares.loadedAt] + PlatformStorageKind.allCases.flatMap { [buckets[$0]?.loadedAt, tokens[$0]?.loadedAt] })
            .compactMap { $0 }.max()
    }

    var anyLoading: Bool {
        records.isLoading || shares.isLoading || PlatformStorageKind.allCases.contains { buckets[$0]?.isLoading == true || tokens[$0]?.isLoading == true }
    }

    var anyFailed: Bool {
        func failed<V>(_ state: ResourceState<V>?) -> Bool {
            if case .failed? = state { return true }
            return false
        }
        return failed(records) || failed(shares) || PlatformStorageKind.allCases.contains { failed(buckets[$0]) || failed(tokens[$0]) || failed(bindings[$0]) }
    }
}
