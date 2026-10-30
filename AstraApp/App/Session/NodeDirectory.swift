import Foundation

/// The node list keyed by id, for name lookup across modules (section 8.4),
/// and the group names beside it so no module prints a raw group id.
@MainActor @Observable
final class NodeDirectory {
    private(set) var nodes: [String: LatticeNode] = [:]
    private(set) var loadedAt: Date?
    private(set) var groupNames: [String: String] = [:]
    @ObservationIgnored private var groupsLoadedAt: Date?
    @ObservationIgnored private var groupsInFlight: Task<Void, Never>?
    /// Why the last refresh failed; nil after a success. The list keeps its
    /// last good rows, so a caller that needs fresh data checks `loadedAt`.
    private(set) var lastError: LatticeAPIError?
    private let session: SessionStore
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    init(session: SessionStore) {
        self.session = session
    }

    /// "fra-2" for an id, or the id itself when the node is unknown.
    func name(for id: String) -> String {
        nodes[id]?.displayName ?? id
    }

    /// "Home lab" for a group id, or the id itself when the group is unknown
    /// or the token cannot read groups.
    func groupName(for id: String) -> String {
        groupNames[id] ?? id
    }

    /// Refetches when the list is older than `seconds`; concurrent callers share one request.
    /// Group names ride along, so callers keep one call.
    func refreshIfOlder(than seconds: TimeInterval) async {
        async let groups: Void = refreshGroupsIfOlder(than: seconds)
        await refreshNodesIfOlder(than: seconds)
        await groups
    }

    private func refreshNodesIfOlder(than seconds: TimeInterval) async {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < seconds { return }
        if let inFlight { return await inFlight.value }
        guard let client = session.client else { return }
        let task = Task {
            do {
                let list = try await client.fetchNodes()
                nodes = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                loadedAt = Date()
                lastError = nil
            } catch {
                lastError = LatticeAPIError(error)
            }
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// A failed or denied read keeps the last names; rows then show ids.
    private func refreshGroupsIfOlder(than seconds: TimeInterval) async {
        if let groupsLoadedAt, Date().timeIntervalSince(groupsLoadedAt) < seconds { return }
        if let groupsInFlight { return await groupsInFlight.value }
        guard let client = session.client else { return }
        if let missing = session.missing(ScopeRequirement(groups: [["group:read"]])), !missing.isEmpty { return }
        let task = Task {
            if let response = try? await client.fleetGroups() {
                groupNames = Dictionary(response.groups.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
                groupsLoadedAt = Date()
            }
        }
        groupsInFlight = task
        await task.value
        groupsInFlight = nil
    }

    func reset() {
        nodes = [:]
        loadedAt = nil
        lastError = nil
        groupNames = [:]
        groupsLoadedAt = nil
    }
}
