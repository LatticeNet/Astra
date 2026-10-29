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
        didSet { if range != oldValue { history = Self.makeHistory(session: session, range: range) } }
    }
    @ObservationIgnored private var generation = -1

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
        history = Self.makeHistory(session: session, range: .lastWeek)
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

    private static func makeHistory(session: SessionStore, range: TimeRangeSelection) -> PagedListLoader<Approval> {
        let since = range.since(now: Date())
        let until = range.until
        return PagedListLoader(pageSize: 50) { [weak session] offset, limit in
            guard let client = await session?.client else { throw LatticeAPIError.unauthorized(message: "") }
            let query = ApprovalQuery(status: "applied,rejected,dismissed", since: since, includeDismissed: true, limit: limit, offset: offset)
            let page = try await client.listApprovals(query: query)
            // The server takes no `until`; a custom range filters on device.
            guard let until else { return page.approvals }
            return page.approvals.filter { ($0.updatedAt ?? $0.createdAt ?? .distantPast) <= until }
        }
    }

    private func resetIfNeeded() {
        guard generation != session.generation else { return }
        generation = session.generation
        needs = .idle
        stuck = .idle
        history = Self.makeHistory(session: session, range: range)
        historyLoadedAt = nil
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
            let page = try await client.approvalsListPage(query: ApprovalQuery(status: "pending", limit: 100), includePlan: true)
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
    /// only pull to refresh or a new range starts again.
    @discardableResult
    func refreshHistory(force: Bool = false) async -> Bool {
        resetIfNeeded()
        guard !denied else { return true }
        if !force, historyLoadedAt != nil { return history.error == nil }
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
