import Foundation

/// The Monitor tab's list data (section 8.4): the path matrix for the
/// current window, checks and definitions, incidents with their maintenance
/// windows, and line chains. Created by StoreRegistry and read from the
/// environment; detail screens own their own models.
@MainActor @Observable
final class MonitoringStore {
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog
    @ObservationIgnored private var generation = -1

    private(set) var paths: ResourceState<PathsResponse> = .idle
    /// The window `paths` was asked for.
    private(set) var pathsWindow: MonitorWindow?
    private(set) var monitors: ResourceState<[Monitor]> = .idle
    private(set) var definitions: ResourceState<MonitoringDefinitionList> = .idle
    private(set) var incidents: ResourceState<IncidentListResponse> = .idle
    private(set) var windows: ResourceState<MaintenanceWindowsResponse> = .idle
    private(set) var chains: ResourceState<[MonitoringLineChain]> = .idle

    static let readRequirement = ScopeRequirement("monitor:read")
    static let adminScope = "monitor:admin"
    static let chainsRequirement = ScopeRequirement("proxy:read")

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    // MARK: Refresh

    /// `GET /api/monitors/paths?window=`.
    @discardableResult
    func refreshPaths(window: MonitorWindow) async -> Bool {
        resetIfCredentialChanged()
        if pathsWindow != window { pathsWindow = window }
        return await load(\.paths, surface: "Paths", requirement: Self.readRequirement) { try await $0.fetchPaths(window: window) }
    }

    /// Checks and their definitions.
    @discardableResult
    func refreshChecks() async -> Bool {
        resetIfCredentialChanged()
        let defs = Task { await self.load(\.definitions, surface: "Check definitions", requirement: Self.readRequirement) { try await $0.monitoringDefinitions() } }
        let checks = await load(\.monitors, surface: "Checks", requirement: Self.readRequirement) { try await $0.listMonitors() }
        let defsOK = await defs.value
        return defsOK && checks
    }

    /// Every incident (no `state`, the server's four states) and the windows.
    @discardableResult
    func refreshIncidents() async -> Bool {
        resetIfCredentialChanged()
        let held = Task { await self.load(\.windows, surface: "Maintenance windows", requirement: Self.readRequirement) { try await $0.listMaintenanceWindows() } }
        let list = await load(\.incidents, surface: "Incidents", requirement: Self.readRequirement) { try await $0.listIncidents() }
        let heldOK = await held.value
        return heldOK && list
    }

    @discardableResult
    func refreshChains() async -> Bool {
        resetIfCredentialChanged()
        return await load(\.chains, surface: "Line chains", requirement: Self.chainsRequirement) { try await $0.monitoringLineChains() }
    }

    /// Everything Overview reads.
    @discardableResult
    func refreshOverview(window: MonitorWindow) async -> Bool {
        let checks = Task { await self.refreshChecks() }
        let incidents = Task { await self.refreshIncidents() }
        let paths = await refreshPaths(window: window)
        let checksOK = await checks.value
        let incidentsOK = await incidents.value
        return checksOK && incidentsOK && paths
    }

    // MARK: Lookups

    func pathItems(nodeName: (String) -> String?) -> [MonitoringPathItem] {
        guard let response = paths.value else { return [] }
        return MonitoringPaths.items(response, nodeName: nodeName)
    }

    func incident(id: String) -> Incident? {
        incidents.value?.incidents.first { $0.id == id }
    }

    func monitor(id: String) -> Monitor? {
        monitors.value?.first { $0.id == id }
    }

    /// Active and upcoming windows: the listing's, plus any the incidents read carried.
    var maintenanceWindows: [MaintenanceWindow] {
        var seen: Set<String> = []
        var list: [MaintenanceWindow] = []
        for window in (windows.value?.windows ?? []) + (incidents.value?.windows ?? []) where !seen.contains(window.id) {
            seen.insert(window.id)
            list.append(window)
        }
        let now = Date()
        return list.filter { ($0.endsAt ?? .distantFuture) > now }.sorted { ($0.startsAt ?? .distantPast) < ($1.startsAt ?? .distantPast) }
    }

    func window(id: String) -> MaintenanceWindow? {
        ((windows.value?.windows ?? []) + (incidents.value?.windows ?? [])).first { $0.id == id }
    }

    /// True when the token may write monitoring (unknown scopes let the server decide).
    var canAdmin: Bool {
        session.missing(ScopeRequirement(Self.adminScope))?.isEmpty ?? true
    }

    func missing(_ requirement: ScopeRequirement) -> [String] {
        session.missing(requirement) ?? []
    }

    // MARK: Loading

    /// A request abandoned because its view disappeared, not a failure.
    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        if case .transport(.cancelled) = LatticeAPIError(error) { return true }
        return Task.isCancelled
    }

    private func resetIfCredentialChanged() {
        guard generation != session.generation else { return }
        generation = session.generation
        paths = .idle
        pathsWindow = nil
        monitors = .idle
        definitions = .idle
        incidents = .idle
        windows = .idle
        chains = .idle
    }

    /// Loads one resource: denied without the scope, the last good value
    /// kept on failure, companion behind on an undecodable body (section 5.0).
    private func load<Value: Sendable>(
        _ keyPath: ReferenceWritableKeyPath<MonitoringStore, ResourceState<Value>>,
        surface: String,
        requirement: ScopeRequirement,
        fetch: @escaping @Sendable (LatticeClient) async throws -> Value
    ) async -> Bool {
        if let missing = session.missing(requirement), !missing.isEmpty {
            self[keyPath: keyPath] = .denied(scope: missing.joined(separator: " and "))
            return true
        }
        guard let client = session.client else { return false }
        let before = self[keyPath: keyPath]
        self[keyPath: keyPath] = before.reloading
        do {
            let value = try await fetch(client)
            self[keyPath: keyPath] = .loaded(value, at: Date())
            return true
        } catch {
            if Self.isCancellation(error) {
                // The screen went away mid-request: nothing failed.
                self[keyPath: keyPath] = before
                return true
            }
            let apiError = LatticeAPIError(error)
            if case .invalidResponse = apiError { session.markCompanionBehind(surface) }
            if case .forbidden = apiError { session.noteForbidden() }
            self[keyPath: keyPath] = self[keyPath: keyPath].failing(apiError, surface: surface, missingScope: requirement.groups.first?.first)
            return false
        }
    }
}
