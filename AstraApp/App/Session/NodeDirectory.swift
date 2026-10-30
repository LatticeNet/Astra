import Foundation

/// The node list keyed by id, for name lookup across modules (section 8.4).
@MainActor @Observable
final class NodeDirectory {
    private(set) var nodes: [String: LatticeNode] = [:]
    private(set) var loadedAt: Date?
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

    /// Refetches when the list is older than `seconds`; concurrent callers share one request.
    func refreshIfOlder(than seconds: TimeInterval) async {
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

    func reset() {
        nodes = [:]
        loadedAt = nil
        lastError = nil
    }
}
