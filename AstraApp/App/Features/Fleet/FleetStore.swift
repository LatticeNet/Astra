import SwiftUI

/// The Fleet list store: nodes with their Fleet facts, the duplicate report,
/// group names for grouping and search, and the map's geo and path reads.
/// Created by StoreRegistry and read from the environment.
@MainActor @Observable
final class FleetStore {
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog

    private(set) var nodes: ResourceState<[FleetNodeRecord]> = .idle
    private(set) var duplicates: [FleetDuplicateGroup] = []
    private(set) var groups: FleetGroupsResponse?
    /// A poll that reorders, inserts or removes rows while VoiceOver runs
    /// waits here behind the "updates" row (stable lists, section 5.0).
    private(set) var held: [FleetNodeRecord]?
    private(set) var geo: ResourceState<[NodeGeoView]> = .idle
    private(set) var paths: ResourceState<PathsResponse> = .idle

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    // MARK: Scopes

    /// Nil while scopes are unknown (the server then decides), otherwise the missing scopes joined.
    func missing(_ scopes: String...) -> String? {
        guard let missing = session.missing(ScopeRequirement(groups: scopes.map { [$0] })), !missing.isEmpty else { return nil }
        return missing.joined(separator: " and ")
    }

    func can(_ scopes: String...) -> Bool {
        guard let missing = session.missing(ScopeRequirement(groups: scopes.map { [$0] })) else { return true }
        return missing.isEmpty
    }

    var allowlist: [String] { session.primaryIdentity?.serverAllowlist ?? [] }

    func groupName(_ id: String) -> String? { groups?.name(for: id) }

    func record(id: String) -> FleetNodeRecord? { nodes.value?.first { $0.id == id } }

    var allNodes: [LatticeNode] { nodes.value?.map(\.node) ?? [] }

    // MARK: Refresh

    /// Polls hold reorders while VoiceOver runs; pull to refresh applies at once.
    @discardableResult
    func refresh(fromPoll: Bool = false) async -> Bool {
        if let missing = missing("node:read") {
            nodes = .denied(scope: missing)
            return true
        }
        guard let client = session.client else { return false }
        nodes = nodes.reloading
        async let readGroups = groupsIfReadable(client)
        async let readDuplicates = try? client.fleetDuplicates()
        do {
            let fresh = try await client.fleetFetchNodeRecords()
            groups = await readGroups ?? groups
            duplicates = await readDuplicates?.groups ?? duplicates
            apply(fresh, fromPoll: fromPoll)
            return true
        } catch {
            _ = await readGroups
            _ = await readDuplicates
            nodes = nodes.failing(LatticeAPIError(error), surface: "Nodes", missingScope: "node:read")
            return false
        }
    }

    private func groupsIfReadable(_ client: LatticeClient) async -> FleetGroupsResponse? {
        guard can("group:read") else { return nil }
        return try? await client.fleetGroups()
    }

    private func apply(_ fresh: [FleetNodeRecord], fromPoll: Bool) {
        let previous = nodes.value
        if fromPoll, UIAccessibility.isVoiceOverRunning, let previous, previous.map(\.id) != fresh.map(\.id) || previous.map(\.node.honesty) != fresh.map(\.node.honesty) {
            // Value changes inside existing rows apply at once; order and membership wait.
            held = fresh
            let byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let kept = previous.map { old in
                guard var row = byID[old.id] else { return old }
                row.node.status = old.node.status
                return row
            }
            nodes = .loaded(kept, at: Date())
        } else {
            held = nil
            nodes = .loaded(fresh, at: Date())
        }
    }

    func showHeld() {
        guard let held else { return }
        self.held = nil
        nodes = .loaded(held, at: Date())
    }

    /// The count of rows a held update would move, add or remove.
    var heldCount: Int {
        guard let held, let current = nodes.value else { return 0 }
        let now = Dictionary(current.map { ($0.id, $0.node.honesty) }, uniquingKeysWith: { first, _ in first })
        let changed = held.filter { now[$0.id] != $0.node.honesty }.count
        let removed = Set(current.map(\.id)).subtracting(held.map(\.id)).count
        return max(1, changed + removed)
    }

    // MARK: Map

    @discardableResult
    func refreshMap(window: MonitorWindow, withPaths: Bool) async -> Bool {
        if let missing = missing("node:read") {
            geo = .denied(scope: missing)
            return true
        }
        guard let client = session.client else { return false }
        geo = geo.reloading
        do {
            geo = .loaded(try await client.fetchNodeGeo(), at: Date())
        } catch {
            geo = geo.failing(LatticeAPIError(error), surface: "Map", missingScope: "node:read")
            return false
        }
        guard withPaths else { return true }
        if let missing = missing("monitor:read") {
            paths = .denied(scope: missing)
            return true
        }
        paths = paths.reloading
        do {
            paths = .loaded(try await client.fetchPaths(window: window), at: Date())
        } catch {
            paths = paths.failing(LatticeAPIError(error), surface: "Paths", missingScope: "monitor:read")
        }
        return true
    }
}
