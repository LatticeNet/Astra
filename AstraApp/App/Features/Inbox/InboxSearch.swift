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
        return rows
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
