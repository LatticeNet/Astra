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
    /// A poll that reorders, inserts or removes rows while the list is busy
    /// or VoiceOver runs waits here behind the "updates" row (stable lists, 5.0).
    private(set) var held: [FleetNodeRecord]?
    /// VoiceOver holds until the operator taps Show; a busy list lets go once idle.
    private(set) var heldForVoiceOver = false
    /// A dialog, confirmation, write or edit mode is up: the list is not idle.
    @ObservationIgnored var interactionBusy = false
    @ObservationIgnored private var lastInteraction = Date.distantPast
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    @ObservationIgnored private var groupsTask: Task<Void, Never>?
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

    /// A node allowlist confines the token; ["*"] does not (ScopeSet.isConfined).
    var isConfined: Bool { session.primaryIdentity?.scopeSet.isConfined ?? false }

    func groupName(_ id: String) -> String? { groups?.name(for: id) }

    func record(id: String) -> FleetNodeRecord? { nodes.value?.first { $0.id == id } }

    var allNodes: [LatticeNode] { nodes.value?.map(\.node) ?? [] }

    // MARK: Refresh

    /// Polls hold reorders while the list is busy or VoiceOver runs; pull to refresh applies at once.
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

    /// Takes a node list another Fleet read already fetched, when this store
    /// has none yet, and loads the group names it needs to label them.
    /// Group names load even while a list read is in flight: a cold deep link
    /// otherwise showed raw group ids until the next poll.
    func adopt(_ records: [FleetNodeRecord]) {
        if nodes.value == nil, !nodes.isLoading {
            nodes = .loaded(records, at: Date())
        }
        guard groups == nil, groupsTask == nil, let client = session.client else { return }
        groupsTask = Task {
            groups = await groupsIfReadable(client) ?? groups
            groupsTask = nil
        }
    }

    private func groupsIfReadable(_ client: LatticeClient) async -> FleetGroupsResponse? {
        guard can("group:read") else { return nil }
        return try? await client.fleetGroups()
    }

    /// A touch, scroll or swipe on the list; reorders wait two seconds past the last one.
    func noteInteraction() {
        lastInteraction = Date()
    }

    private var isIdle: Bool {
        !interactionBusy && Date().timeIntervalSince(lastInteraction) >= 2
    }

    private func apply(_ fresh: [FleetNodeRecord], fromPoll: Bool) {
        let previous = nodes.value
        let voiceOver = UIAccessibility.isVoiceOverRunning
        if fromPoll, voiceOver || !isIdle, let previous,
           previous.map(\.id) != fresh.map(\.id) || previous.map(\.node.honesty) != fresh.map(\.node.honesty) {
            // Values inside existing rows apply at once; order and membership wait.
            held = fresh
            heldForVoiceOver = voiceOver
            let byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let kept = previous.map { old in
                guard var row = byID[old.id] else { return old }
                row.node.status = old.node.status
                return row
            }
            nodes = .loaded(kept, at: Date())
            if !voiceOver { releaseWhenIdle() }
        } else {
            held = nil
            releaseTask?.cancel()
            nodes = .loaded(fresh, at: Date())
        }
    }

    private func releaseWhenIdle() {
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.held != nil, !self.heldForVoiceOver else { return }
                if self.isIdle {
                    self.showHeld()
                    return
                }
            }
        }
    }

    func showHeld() {
        guard let held else { return }
        self.held = nil
        releaseTask?.cancel()
        nodes = .loaded(held, at: Date())
    }

    /// The count of rows a held update would move, add or remove.
    var heldCount: Int {
        guard let held, let current = nodes.value else { return 0 }
        let now = Dictionary(current.map { ($0.id, $0.node.honesty) }, uniquingKeysWith: { first, _ in first })
        let changed = held.filter { now[$0.id] != nil && now[$0.id] != $0.node.honesty }.count
        let inserted = held.filter { now[$0.id] == nil }.count
        let removed = Set(current.map(\.id)).subtracting(held.map(\.id)).count
        return max(1, changed + inserted + removed)
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
