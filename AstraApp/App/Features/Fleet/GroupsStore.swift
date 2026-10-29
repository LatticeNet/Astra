import Foundation

/// The node groups list (M2-10), created by StoreRegistry.
@MainActor @Observable
final class GroupsStore {
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog

    private(set) var groups: ResourceState<FleetGroupsResponse> = .idle

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    func group(id: String) -> FleetGroupView? { groups.value?.groups.first { $0.id == id } }

    var canAdmin: Bool {
        guard let missing = session.missing(ScopeRequirement("group:admin")) else { return true }
        return missing.isEmpty
    }

    @discardableResult
    func refresh() async -> Bool {
        if let missing = session.missing(ScopeRequirement("group:read")), !missing.isEmpty {
            groups = .denied(scope: missing.joined(separator: " and "))
            return true
        }
        guard let client = session.client else { return false }
        groups = groups.reloading
        do {
            groups = .loaded(try await client.fleetGroups(), at: Date())
            return true
        } catch {
            groups = groups.failing(LatticeAPIError(error), surface: "Groups", missingScope: "group:read")
            return false
        }
    }
}
