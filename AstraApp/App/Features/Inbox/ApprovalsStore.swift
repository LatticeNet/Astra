import Foundation

/// Activity > Approvals data (M1-04): the pending rows grouped into console
/// events, the stuck rows, and the paged history.
@MainActor @Observable
final class ApprovalsStore {
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog

    private(set) var needs: ResourceState<InboxApprovalsPage> = .idle
    private(set) var stuck: ResourceState<[Approval]> = .idle
    private(set) var history: PagedListLoader<Approval>
    private(set) var historyLoadedAt: Date?
    var range: TimeRangeSelection = .lastWeek {
        didSet { if range != oldValue { restartHistory() } }
    }
    /// The status, plugin and node the History listing asks the server for.
    var historyRequest = InboxHistoryRequest() {
        didSet { if historyRequest != oldValue { restartHistory() } }
    }
    @ObservationIgnored private var generation = -1
    @ObservationIgnored private var planCache = ApprovalsPlanCache()

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
        history = Self.makeHistory(session: session, range: .lastWeek, request: InboxHistoryRequest())
    }

    /// The listing needs `network:plan` plus a plugin read scope; a token
    /// that can list no plugin at all sees the denied screen.
    var denied: Bool {
        guard let scopes = session.tokenScopes else { return false }
        return !scopes.allows("network:plan") && ApprovalVisibility.hiddenPlugins(scopes: scopes).count == ApprovalVisibility.knownPlugins.count
    }

    var hiddenPlugins: [String] {
        guard let scopes = session.tokenScopes, !denied else { return [] }
        return ApprovalVisibility.hiddenPlugins(scopes: scopes)
    }

    /// One server query per page (console `historyRequest`). Pages are
    /// returned as the server sent them, so the loader's offset and end
    /// follow the server; the server takes no `until`, so a custom range's
    /// end applies when rows are shown. `since` is fixed per loader, and a
    /// reload builds a new loader, so it moves with the clock.
    private static func makeHistory(session: SessionStore, range: TimeRangeSelection, request: InboxHistoryRequest) -> PagedListLoader<Approval> {
        let since = range.since(now: Date())
        return PagedListLoader(pageSize: 50) { [weak session] offset, limit in
            guard let client = await session?.client else { throw LatticeAPIError.unauthorized(message: "") }
            let query = ApprovalQuery(
                status: request.statuses.joined(separator: ","), plugin: request.plugin, nodeID: request.nodeID,
                // Section 5.2 M1-04: History always sends include_dismissed=1;
                // the status list still decides which rows come back.
                since: since, includeDismissed: true, limit: limit, offset: offset
            )
            return try await client.listApprovals(query: query).approvals
        }
    }

    private func restartHistory() {
        history = Self.makeHistory(session: session, range: range, request: historyRequest)
        historyLoadedAt = nil
    }

    /// Whether a History row falls inside the range's end, when it has one.
    func inRange(_ approval: Approval) -> Bool {
        guard let until = range.until else { return true }
        return (approval.updatedAt ?? approval.createdAt ?? .distantPast) <= until
    }

    private func resetIfNeeded() {
        guard generation != session.generation else { return }
        generation = session.generation
        needs = .idle
        stuck = .idle
        planCache = ApprovalsPlanCache()
        restartHistory()
    }

    @discardableResult
    func refreshNeeds() async -> Bool {
        resetIfNeeded()
        guard let client = session.client else { return false }
        if denied {
            needs = .denied(scope: "network:plan")
            return true
        }
        needs = needs.reloading
        do {
            let (page, cache) = try await client.approvalsPendingPage(cache: planCache)
            planCache = cache
            needs = .loaded(InboxApprovalsPage(approvals: page.approvals.filter(\.isHumanPending), total: page.total, limit: page.limit), at: Date())
            return true
        } catch {
            needs = needs.failing(LatticeAPIError(error), surface: "Approvals", missingScope: "network:plan")
            return false
        }
    }

    @discardableResult
    func refreshStuck() async -> Bool {
        resetIfNeeded()
        guard let client = session.client else { return false }
        if denied {
            stuck = .denied(scope: "network:plan")
            return true
        }
        stuck = stuck.reloading
        do {
            let page = try await client.listApprovals(query: ApprovalQuery(status: "approved", limit: 100))
            stuck = .loaded(page.approvals.filter { $0.waiting?.blocked == true }, at: Date())
            return true
        } catch {
            stuck = stuck.failing(LatticeAPIError(error), surface: "Approvals", missingScope: "network:plan")
            return false
        }
    }

    /// History pages by offset; a poll keeps the pages already loaded and
    /// only pull to refresh, a new range or a new query starts again.
    @discardableResult
    func refreshHistory(force: Bool = false) async -> Bool {
        resetIfNeeded()
        guard !denied else { return true }
        if !force, historyLoadedAt != nil { return history.error == nil }
        // A poll that lands while the first page is loading does not start it again.
        if !force, history.isLoading { return true }
        restartHistory()
        await history.reload()
        if history.error == nil { historyLoadedAt = Date() }
        return history.error == nil
    }

    func refresh(_ scope: ApprovalsScope, force: Bool = false) async -> Bool {
        switch scope {
        case .needs: await refreshNeeds()
        case .history: await refreshHistory(force: force)
        case .stuck: await refreshStuck()
        }
    }
}

/// What History asks the server (console `historyRequest`): the `status:`,
/// `plugin:` and `node:` tokens the listing can filter on. Free words and
/// tokens it cannot express stay on device, on top of this narrower query.
struct InboxHistoryRequest: Equatable {
    /// Decided and deciding plans. Approved plans still applying belong
    /// here: no other scope lists them while they are not blocked.
    static let defaultStatuses = ["approved", "applied", "rejected", "dismissed"]

    var statuses = InboxHistoryRequest.defaultStatuses
    var plugin: String?
    var nodeID: String?

    init() {}

    /// `resolveNode` maps a `node:` value to a node id when it names exactly one node.
    init(_ filter: InboxApprovalFilter, resolveNode: (String) -> String?) {
        var wanted: [String] = []
        for token in filter.statuses {
            for status in Self.serverStatuses(for: token) where !wanted.contains(status) {
                wanted.append(status)
            }
        }
        if !wanted.isEmpty { statuses = wanted }
        if filter.plugins.count == 1, let token = filter.plugins.first {
            let matches = ApprovalVisibility.knownPlugins.filter { $0 == token || ApprovalVisibility.displayName(plugin: $0).lowercased() == token }
            if matches.count == 1 { plugin = matches[0] }
        }
        if filter.nodes.count == 1, let token = filter.nodes.first {
            nodeID = resolveNode(token)
        }
    }

    /// The listing statuses a `status:` word can mean, from the server's
    /// own statuses and the status words of section 4.2.
    static func serverStatuses(for token: String) -> [String] {
        switch token {
        case "pending", "approved", "applied", "rejected", "dismissed": [token]
        case "needs": ["pending"]
        case "failed": ["rejected"]
        case "waiting", "applying": ["approved"]
        case "stale": ["pending", "rejected"]
        default: []
        }
    }
}
