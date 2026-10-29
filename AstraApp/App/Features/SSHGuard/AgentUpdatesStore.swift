import Foundation

/// Agent Updates (M7-03, M7-04): policies, the latest release, stored
/// artifacts, mirrors and the nodes' running versions, created by
/// StoreRegistry and read from the environment. Each read is its own
/// resource, so a release host that cannot be reached does not blank the
/// policies, and the Nodes view says what it could not read.
@MainActor @Observable
final class AgentUpdatesStore {
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog
    @ObservationIgnored private var generation = -1

    private(set) var nodes: ResourceState<[LatticeNode]> = .idle
    private(set) var policies: ResourceState<[AgentUpdatesPolicy]> = .idle
    private(set) var release: ResourceState<AgentUpdatesReleaseInfo> = .idle
    private(set) var artifacts: ResourceState<AgentUpdatesArtifactListing> = .idle
    private(set) var mirrors: ResourceState<AgentUpdatesMirrorsView> = .idle

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    /// The screen's gate (section 5.8): its only writes need node:admin.
    static let gate = ScopeRequirement("node:admin")
    static let planRequirement = ScopeRequirement(groups: AgentUpdatesPlanning.scopes.map { [$0] })

    var missingGate: [String]? {
        guard let missing = session.missing(Self.gate), !missing.isEmpty else { return nil }
        return missing
    }

    func planBlockReason() -> String? {
        guard let missing = session.missing(Self.planRequirement), !missing.isEmpty else { return nil }
        return "Needs \(missing.joined(separator: " and "))"
    }

    var latest: String? {
        guard let version = release.value?.latestVersion, !version.isEmpty else { return nil }
        return version
    }

    /// Every node with its policy and standing, worst first: behind, unknown, ahead, current.
    var rows: [AgentUpdatesNodeRow] {
        let byNode = Dictionary((policies.value ?? []).map { ($0.nodeID, $0) }, uniquingKeysWith: { first, _ in first })
        let rank: [AgentUpdatesStanding: Int] = [.behind: 0, .unknown: 1, .ahead: 2, .current: 3]
        return (nodes.value ?? [])
            .map { AgentUpdatesNodeRow(node: $0, policy: byNode[$0.id], latest: latest) }
            .sorted { a, b in
                let ra = rank[a.standing] ?? 9
                let rb = rank[b.standing] ?? 9
                return ra != rb ? ra < rb : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// The nodes "Plan all behind" will try, and the behind nodes it skips for lack of a policy.
    var bulk: (plan: [AgentUpdatesNodeRow], skipped: [AgentUpdatesNodeRow]) {
        guard latest != nil, policies.value != nil else { return ([], []) }
        return AgentUpdatesBulk.plan(rows)
    }

    /// The oldest load among the reads, for the freshness footer.
    var loadedAt: Date? {
        [nodes.loadedAt, policies.loadedAt, release.loadedAt].compactMap { $0 }.min()
    }

    var anyFailed: Bool {
        [nodes.isFailed, policies.isFailed, release.isFailed].contains(true)
    }

    @discardableResult
    func refresh() async -> Bool {
        if generation != session.generation {
            generation = session.generation
            nodes = .idle
            policies = .idle
            release = .idle
            artifacts = .idle
            mirrors = .idle
        }
        if let missing = missingGate {
            let scope = missing.joined(separator: " and ")
            nodes = .denied(scope: scope)
            policies = .denied(scope: scope)
            return true
        }
        guard let client = session.client else { return false }
        async let nodesOK = loadNodes(client)
        async let policiesOK = loadPolicies(client)
        async let releaseOK = loadRelease(client)
        async let artifactsOK = loadArtifacts(client)
        async let mirrorsOK = loadMirrors(client)
        let results = await [nodesOK, policiesOK, releaseOK, artifactsOK, mirrorsOK]
        return !results.contains(false)
    }

    private func loadNodes(_ client: LatticeClient) async -> Bool {
        await load(\.nodes, surface: "Nodes") { try await client.fetchNodes() }
    }

    private func loadPolicies(_ client: LatticeClient) async -> Bool {
        await load(\.policies, surface: "Agent update policies") { try await client.agentUpdatesPolicies() }
    }

    private func loadRelease(_ client: LatticeClient) async -> Bool {
        await load(\.release, surface: "Agent releases") { try await client.agentUpdatesReleaseInfo() }
    }

    private func loadArtifacts(_ client: LatticeClient) async -> Bool {
        await load(\.artifacts, surface: "Agent artifacts") { try await client.agentUpdatesArtifacts() }
    }

    private func loadMirrors(_ client: LatticeClient) async -> Bool {
        await load(\.mirrors, surface: "Agent mirrors") { try await client.agentUpdatesMirrors() }
    }

    private func load<Value: Sendable>(
        _ keyPath: ReferenceWritableKeyPath<AgentUpdatesStore, ResourceState<Value>>,
        surface: String,
        fetch: () async throws -> Value
    ) async -> Bool {
        self[keyPath: keyPath] = self[keyPath: keyPath].reloading
        do {
            self[keyPath: keyPath] = .loaded(try await fetch(), at: Date())
            return true
        } catch {
            let apiError = LatticeAPIError(error)
            if case .forbidden = apiError { session.noteForbidden() }
            if apiError == .invalidResponse { session.markCompanionBehind(surface) }
            self[keyPath: keyPath] = self[keyPath: keyPath].failing(apiError, surface: surface, missingScope: "node:read")
            return false
        }
    }
}

private extension ResourceState {
    /// True when the last attempt failed.
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
