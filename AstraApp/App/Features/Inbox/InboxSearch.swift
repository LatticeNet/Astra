import SwiftUI

/// M1's contribution to Browse search (section 8.5): pending approvals,
/// fetched once per search session (60 s) and filtered on device. A result
/// opens Activity > Approvals filtered to that approval.
enum InboxSearch: SearchProvider {
    @MainActor private static var cache: (at: Date, generation: Int, rows: [Approval])?

    static func results(for query: LatticeQuery, context: SearchContext) async -> [SearchResult] {
        let text = query.source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let rows = await pending(context: context) else { return [] }
        let filter = InboxApprovalFilter(text)
        return systemAction(text, rows: rows, context: context) + rows
            .filter { filter.matches($0, nodeName: context.nodes.name(for: $0.nodeID)) }
            .map { approval in
                SearchResult(
                    kind: "Approvals",
                    id: approval.id,
                    title: ApprovalEvents.title(for: approval),
                    detail: [context.nodes.name(for: approval.nodeID).inboxNonEmpty, ApprovalVisibility.displayName(plugin: approval.plugin)].compactMap { $0 }.joined(separator: ", "),
                    style: StatusStyle.approval(approval.displayState),
                    target: .tab(.activity, scope: ActivityScope.approvals.rawValue, query: "id:\(approval.id)")
                )
            }
    }

    /// Words that find the palette's batch row, as the console's
    /// "Approve system events" entry is found by its label.
    private static let systemTerms = ["review", "system", "server", "plans", "approve", "approvals", "events", "batch"]

    /// The console palette's batch action (section 3.3): one row that opens
    /// BatchReviewSheet over every server-filed pending plan. The sheet
    /// re-reads each plan and binds the decision to the hashes it shows.
    @MainActor
    private static func systemAction(_ text: String, rows: [Approval], context: SearchContext) -> [SearchResult] {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace)
        guard words.allSatisfy({ word in systemTerms.contains { $0.hasPrefix(word) } }),
              context.session.missing(ScopeRequirement("network:apply")) == nil else { return [] }
        let system = ApprovalEvents.pendingSystem(rows)
        guard !system.isEmpty else { return [] }
        return [SearchResult(
            kind: "Actions",
            id: "action:review-system-plans",
            title: system.count == 1 ? "Review 1 system plan" : "Review \(system.count) system plans",
            detail: "Filed by lattice-server",
            target: .review(.batch(groupKey: ApprovalEvents.systemWriter, ids: system.map(\.id))),
            symbol: "checklist"
        )]
    }

    @MainActor
    private static func pending(context: SearchContext) async -> [Approval]? {
        let session = context.session
        if let cache, cache.generation == session.generation, Date().timeIntervalSince(cache.at) < 60 { return cache.rows }
        guard let client = session.client,
              let page = try? await client.approvalsListPage(query: ApprovalQuery(status: "pending", limit: 100), includePlan: false) else { return nil }
        let rows = page.approvals.filter(\.isHumanPending)
        cache = (Date(), session.generation, rows)
        return rows
    }
}
