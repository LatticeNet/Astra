import Foundation

struct ApproveRequest: Encodable {
    var approvalID: String
    var queueApply: Bool
    var planSHA256: String
    enum CodingKeys: String, CodingKey {
        case approvalID = "approval_id"
        case queueApply = "queue_apply"
        case planSHA256 = "plan_sha256"
    }
}

struct ApprovalIDRequest: Encodable {
    var approvalID: String
    enum CodingKeys: String, CodingKey { case approvalID = "approval_id" }
}

struct DismissApprovalRequest: Encodable {
    var approvalID: String
    var note: String
    enum CodingKeys: String, CodingKey {
        case approvalID = "approval_id"
        case note
    }
}

public extension LatticeClient {
    /// `POST /api/network/approvals/approve`. `planSHA256` must be the hash of
    /// the reviewed plan body, never of an empty listing row.
    @discardableResult
    func approveApproval(approvalID: String, queueApply: Bool, planSHA256: String) async throws -> Approval {
        try await perform(
            Approval.self,
            path: "/api/network/approvals/approve",
            method: "POST",
            body: ApproveRequest(approvalID: approvalID, queueApply: queueApply, planSHA256: planSHA256)
        )
    }

    /// Approve from a loaded review row. Refuses if the plan body is missing
    /// or does not hash to `plan_sha256`.
    @discardableResult
    func approveReviewed(_ approval: Approval, queueApply: Bool) async throws -> Approval {
        let hash = try approval.reviewedPlanSHA256()
        return try await approveApproval(approvalID: approval.id, queueApply: queueApply, planSHA256: hash)
    }

    @discardableResult
    func rejectApproval(approvalID: String) async throws -> Approval {
        try await perform(
            Approval.self,
            path: "/api/network/approvals/reject",
            method: "POST",
            body: ApprovalIDRequest(approvalID: approvalID)
        )
    }

    @discardableResult
    func dismissApproval(approvalID: String, note: String) async throws -> Approval {
        try await perform(
            Approval.self,
            path: "/api/network/approvals/dismiss",
            method: "POST",
            body: DismissApprovalRequest(approvalID: approvalID, note: note)
        )
    }
}

public extension LatticeClient {
    /// `GET /api/network/approvals` with filters, in the envelope form, and
    /// with `include=plan` when asked. Inbox groups agent updates by the
    /// version transition in the plan text (section 6.2), so its pending
    /// listing carries the bodies; they are parsed for grouping, never shown
    /// or hashed, and Review still loads each approval by id.
    func approvalsListPage(query: ApprovalQuery, includePlan: Bool) async throws -> ApprovalPage {
        var query = query
        query.includePlan = includePlan
        return try await listApprovals(query: query)
    }
}

/// Agent-update plan bodies by approval id, kept while the row's
/// `plan_sha256` is unchanged. Grouping and node names need those bodies;
/// no other listing row does, since Review and BatchReview load every body
/// by id (the console's `planCache`, ApprovalsView.vue).
public struct ApprovalsPlanCache: Sendable {
    private var entries: [String: (sha: String, plan: String)] = [:]

    public init() {}

    /// Whether any agent-update row lacks a cached body for its current hash.
    public func needsBodies(_ rows: [Approval]) -> Bool {
        rows.contains { $0.plugin == "agentupdate" && entries[$0.id]?.sha != $0.planSHA256 }
    }

    /// Remembers the agent-update bodies in `rows`, dropping ids no longer listed.
    public mutating func store(_ rows: [Approval], keeping listed: [Approval]) {
        let live = Set(listed.map(\.id))
        entries = entries.filter { live.contains($0.key) }
        for row in rows where row.plugin == "agentupdate" && row.hasPlanBody {
            entries[row.id] = (row.planSHA256, row.plan)
        }
    }

    /// `rows` with each agent-update body filled in from the cache.
    public func hydrate(_ rows: [Approval]) -> [Approval] {
        rows.map { row in
            guard row.plugin == "agentupdate", !row.hasPlanBody, let entry = entries[row.id], entry.sha == row.planSHA256 else { return row }
            var row = row
            row.plan = entry.plan
            return row
        }
    }
}

public extension LatticeClient {
    /// The pending page without plan bodies, then, only when an agent-update
    /// row is not cached, one narrow read of agent-update bodies
    /// (`status=pending&plugin=agentupdate&include=plan`). Returns the page
    /// with those bodies filled in and the updated cache.
    func approvalsPendingPage(limit: Int = 100, cache: ApprovalsPlanCache) async throws -> (ApprovalPage, ApprovalsPlanCache) {
        var page = try await approvalsListPage(query: ApprovalQuery(status: "pending", limit: limit), includePlan: false)
        var cache = cache
        if cache.needsBodies(page.approvals) {
            let bodies = try await approvalsListPage(query: ApprovalQuery(status: "pending", plugin: "agentupdate", limit: limit), includePlan: true)
            cache.store(bodies.approvals, keeping: page.approvals)
        } else {
            cache.store([], keeping: page.approvals)
        }
        page.approvals = cache.hydrate(page.approvals)
        return (page, cache)
    }
}
