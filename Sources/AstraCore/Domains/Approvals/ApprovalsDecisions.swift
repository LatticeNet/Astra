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
        var items = query.queryItems
        if includePlan { items.insert(URLQueryItem(name: "include", value: "plan"), at: min(1, items.count)) }
        let response = try await perform(ApprovalsQueryResponse.self, path: "/api/network/approvals", query: items)
        return ApprovalPage(approvals: response.approvals, total: response.total, limit: response.limit, offset: response.offset)
    }
}
