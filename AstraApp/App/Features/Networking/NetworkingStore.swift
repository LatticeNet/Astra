import Foundation

/// The Networking lists (M6), created by StoreRegistry and read from the
/// environment. Each screen refreshes only the surfaces it shows; each
/// surface is gated by the scope the server's route and handler check.
@MainActor @Observable
final class NetworkingStore {
    nonisolated static let policyRead = "netpolicy:read"
    nonisolated static let dnsRead = "dns:admin"
    nonisolated static let ddnsRead = "ddns:admin"
    nonisolated static let geoRead = "geo:read"
    nonisolated static let tunnelRead = "tunnel:admin"
    nonisolated static let guardRead = "netguard:read"

    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog

    private(set) var netPolicies: ResourceState<[NetPolicy]> = .idle
    private(set) var groupPolicies: ResourceState<[NetworkingGroupPolicy]> = .idle
    private(set) var matrices: [String: ResourceState<NetworkingMatrix>] = [:]
    private(set) var deployments: ResourceState<[NetworkingDNSDeployment]> = .idle
    private(set) var ddns: ResourceState<[DDNSProfile]> = .idle
    private(set) var geo: ResourceState<[NetworkingGeoRouting]> = .idle
    private(set) var tunnels: ResourceState<[TunnelProfile]> = .idle
    private(set) var guardGroups: ResourceState<[NetworkingSecurityGroup]> = .idle
    private(set) var guardZones: ResourceState<[NetworkingGuardZone]> = .idle
    private(set) var guardNodes: ResourceState<[NetworkingNodeGuard]> = .idle
    private(set) var nodeGroupBindings: ResourceState<[NetworkingNodeGroupBinding]> = .idle
    /// Node group names by id, for targets and remotes; empty without group:read.
    private(set) var groupNames: [String: String] = [:]

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    // MARK: Scopes

    /// "Needs dns:admin and network:plan", or nil when the token holds every scope.
    func blocked(_ scopes: [String], on kind: ClientKind = .primary) -> String? {
        guard let missing = session.missing(ScopeRequirement(groups: scopes.map { [$0] }), on: kind), !missing.isEmpty else { return nil }
        return "Needs \(ListFormatter.localizedString(byJoining: missing))"
    }

    var isConfined: Bool { session.primaryIdentity?.scopeSet.isConfined ?? false }
    var allowlistCount: Int { session.primaryIdentity?.serverAllowlist.count ?? 0 }

    /// Measuring a certificate creates fleet-wide checks: the server refuses a confined token.
    var measureBlocked: String? {
        blocked(NetworkingIntents.measureScopes) ?? (isConfined ? "Needs a token without a node allowlist" : nil)
    }

    private func missing(_ scope: String) -> String? {
        guard let missing = session.missing(ScopeRequirement(scope)), !missing.isEmpty else { return nil }
        return missing.joined(separator: " and ")
    }

    // MARK: Outbound policy

    @discardableResult
    func refreshPolicies() async -> Bool {
        if let missing = missing(Self.policyRead) {
            netPolicies = .denied(scope: missing)
            groupPolicies = .denied(scope: missing)
            return true
        }
        guard let client = session.client else { return false }
        netPolicies = netPolicies.reloading
        groupPolicies = groupPolicies.reloading
        async let docs = Self.read { try await client.listNetPolicies() }
        async let outbound = Self.read { try await client.networkingGroupPolicies() }
        async let names = readGroupNames(client)
        let ok1 = apply(await docs, to: \.netPolicies, surface: "Node outbound policies", scope: Self.policyRead)
        let ok2 = apply(await outbound, to: \.groupPolicies, surface: "Outbound policies", scope: Self.policyRead)
        if let names = await names { groupNames = names }
        return ok1 && ok2
    }

    func matrix(_ direction: String) -> ResourceState<NetworkingMatrix> {
        matrices[direction] ?? .idle
    }

    @discardableResult
    func refreshMatrix(_ direction: String) async -> Bool {
        if let missing = missing(Self.policyRead) {
            matrices[direction] = .denied(scope: missing)
            return true
        }
        guard let client = session.client else { return false }
        matrices[direction] = matrix(direction).reloading
        async let names = readGroupNames(client)
        let result = await Self.read { try await client.networkingMatrix(direction: direction) }
        if let names = await names { groupNames = names }
        switch result {
        case .success(let value):
            matrices[direction] = .loaded(value, at: Date())
            return true
        case .failure(let error):
            matrices[direction] = matrix(direction).failing(error, surface: "The policy matrix", missingScope: Self.policyRead)
            if case .forbidden = error { session.noteForbidden() }
            return false
        }
    }

    // MARK: DNS, DDNS, geo routing, tunnels

    @discardableResult
    func refreshDNS() async -> Bool {
        await refresh(\.deployments, scope: Self.dnsRead, surface: "Self-host DNS") { try await $0.networkingDNSDeployments() }
    }

    @discardableResult
    func refreshDDNS() async -> Bool {
        await refresh(\.ddns, scope: Self.ddnsRead, surface: "DDNS") { try await $0.listDDNS() }
    }

    @discardableResult
    func refreshGeo() async -> Bool {
        await refresh(\.geo, scope: Self.geoRead, surface: "Geo-Routing") { try await $0.networkingGeoRoutings() }
    }

    @discardableResult
    func refreshTunnels() async -> Bool {
        await refresh(\.tunnels, scope: Self.tunnelRead, surface: "Tunnels") { try await $0.listTunnels() }
    }

    // MARK: Inbound firewall

    /// Groups, zones and node-group bindings are fleet-wide objects the
    /// server answers only to an unconfined token; nodes are filtered per node.
    @discardableResult
    func refreshFirewall() async -> Bool {
        if let missing = missing(Self.guardRead) {
            guardGroups = .denied(scope: missing)
            guardZones = .denied(scope: missing)
            guardNodes = .denied(scope: missing)
            nodeGroupBindings = .denied(scope: missing)
            return true
        }
        guard let client = session.client else { return false }
        let globals = !isConfined
        let missingGroup = missing("group:read")
        guardNodes = guardNodes.reloading
        if globals {
            guardGroups = guardGroups.reloading
            guardZones = guardZones.reloading
            if missingGroup == nil { nodeGroupBindings = nodeGroupBindings.reloading }
        }
        async let nodesRead = Self.read { try await client.networkingGuardNodes() }
        async let groupsRead = globals ? Self.read { try await client.networkingGuardGroups() } : nil
        async let zonesRead = globals ? Self.read { try await client.networkingGuardZones() } : nil
        async let bindingsRead = globals && missingGroup == nil ? Self.read { try await client.networkingNodeGroupBindings() } : nil
        var ok = apply(await nodesRead, to: \.guardNodes, surface: "Firewall nodes", scope: Self.guardRead)
        if let result = await groupsRead { ok = apply(result, to: \.guardGroups, surface: "Security groups", scope: Self.guardRead) && ok }
        if let result = await zonesRead { ok = apply(result, to: \.guardZones, surface: "Zones", scope: Self.guardRead) && ok }
        if let result = await bindingsRead {
            ok = apply(result, to: \.nodeGroupBindings, surface: "Node-group bindings", scope: Self.guardRead) && ok
        } else if globals, let missingGroup {
            nodeGroupBindings = .denied(scope: missingGroup)
        }
        if !globals {
            guardGroups = .idle
            guardZones = .idle
            nodeGroupBindings = .idle
        }
        return ok
    }

    // MARK: Helpers

    private static func read<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Result<T, LatticeAPIError> {
        do {
            return .success(try await work())
        } catch {
            return .failure(LatticeAPIError(error))
        }
    }

    private func refresh<T: Sendable>(
        _ path: ReferenceWritableKeyPath<NetworkingStore, ResourceState<T>>,
        scope: String, surface: String,
        fetch: @escaping @Sendable (LatticeClient) async throws -> T
    ) async -> Bool {
        if let missing = missing(scope) {
            self[keyPath: path] = .denied(scope: missing)
            return true
        }
        guard let client = session.client else { return false }
        self[keyPath: path] = self[keyPath: path].reloading
        let result = await Self.read { try await fetch(client) }
        return apply(result, to: path, surface: surface, scope: scope)
    }

    @discardableResult
    private func apply<T: Sendable>(_ result: Result<T, LatticeAPIError>, to path: ReferenceWritableKeyPath<NetworkingStore, ResourceState<T>>, surface: String, scope: String) -> Bool {
        switch result {
        case .success(let value):
            self[keyPath: path] = .loaded(value, at: Date())
            return true
        case .failure(let error):
            self[keyPath: path] = self[keyPath: path].failing(error, surface: surface, missingScope: scope)
            if case .forbidden = error { session.noteForbidden() }
            if case .invalidResponse = error { session.markCompanionBehind(surface) }
            return false
        }
    }

    private func readGroupNames(_ client: LatticeClient) async -> [String: String]? {
        guard session.missing(ScopeRequirement("group:read"))?.isEmpty ?? true,
              let groups = try? await client.fleetGroups() else { return nil }
        return Dictionary(groups.groups.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }
}
