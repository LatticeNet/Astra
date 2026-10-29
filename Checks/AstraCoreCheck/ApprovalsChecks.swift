import Foundation
import AstraCore

public func checkApprovals() async throws {
    try await checkDecisionBodies()
}

/// Approval JSON shared by the Shared listing checks and the decision checks.
enum ApprovalSamples {
    static func pendingList(planHash: String) -> String {
        """
        {"approvals":[
          {"id":"ap1","node_id":"node-a","plugin":"nftpolicy","action":"apply nft",
           "plan_sha256":"\(planHash)","status":"pending","actor_id":"admin",
           "targets":["node-a"],"created_at":"2026-06-17T02:00:00Z"},
          {"id":"ap-linemeta","node_id":"node-a","plugin":"singbox-linemeta","action":"apply-metadata",
           "plan_sha256":"\(planHash)","status":"pending","actor_id":"lattice-server",
           "created_at":"2026-06-17T02:00:01Z"},
          {"id":"ap-stale","node_id":"node-a","plugin":"agentupdate","action":"agent.update",
           "plan_sha256":"deadbeef","status":"pending","actor_id":"admin",
           "reason":"agent update policy changed since this approval was planned; re-plan before approving",
           "stale":true,"stale_code":"agent_update_policy_changed",
           "created_at":"2026-06-17T02:01:00Z"}
        ],"total":3,"limit":100,"offset":0}
        """
    }

    static func byID(planBody: String, planHash: String) -> String {
        """
        {"approval":{"id":"ap1","node_id":"node-a","plugin":"nftpolicy","action":"apply nft",
         "plan":"\(planBody)","plan_sha256":"\(planHash)","status":"pending","actor_id":"admin",
         "plugin_version":"1.2.3","artifact_digest":"sha256:abc","targets":["node-a"],
         "created_at":"2026-06-17T02:00:00Z"}}
        """
    }

    static func waiting(planBody: String, planHash: String) -> String {
        """
        {"approval":{"id":"ap-wait","node_id":"node-a","plugin":"nftpolicy","action":"apply nft",
         "plan":"\(planBody)","plan_sha256":"\(planHash)","status":"approved","actor_id":"admin",
         "approved_by":"admin","targets":["node-a"],
         "waiting":{"code":"node_offline","reason":"node-a has not reported","blocked":true,
                    "node_id":"node-a","node_status":"offline","dismissible":true}}}
        """
    }
}

private func checkDecisionBodies() async throws {
    let planBody = "table inet lattice_guard {}"
    let planHash = PlanHasher.sha256Hex(planBody)
    let rejectJSON = """
    {"id":"ap1","node_id":"node-a","plugin":"nftpolicy","action":"apply nft",
     "plan":"\(planBody)","plan_sha256":"\(planHash)","status":"rejected","actor_id":"admin",
     "rejected_by":"admin","created_at":"2026-06-17T02:00:00Z"}
    """
    let dismissJSON = """
    {"id":"ap-stale","node_id":"node-a","plugin":"agentupdate","action":"agent.update",
     "plan":"target_version: 0.2.7","plan_sha256":"deadbeef","status":"dismissed","actor_id":"admin"}
    """
    let transport = MockTransport(responses: [
        "https://lattice.example.com/api/network/approvals?id=ap1": (200, ApprovalSamples.byID(planBody: planBody, planHash: planHash).data(using: .utf8)!),
        "https://lattice.example.com/api/network/approvals/approve": (
            200,
            """
            {"id":"ap1","node_id":"node-a","plugin":"nftpolicy","action":"apply nft","plan":"\(planBody)","plan_sha256":"\(planHash)","status":"approved","actor_id":"admin","approved_by":"admin"}
            """.data(using: .utf8)!
        ),
        "https://lattice.example.com/api/network/approvals/reject": (200, rejectJSON.data(using: .utf8)!),
        "https://lattice.example.com/api/network/approvals/dismiss": (200, dismissJSON.data(using: .utf8)!),
    ])
    let client = LatticeClient(baseURL: URL(string: "https://lattice.example.com")!, credential: LatticeCredential(sessionCookie: "sid", csrfToken: "csrf-token"), transport: transport)

    let loaded = try await client.fetchApproval(id: "ap1")
    let approved = try await client.approveReviewed(loaded, queueApply: true)
    try expectEqual(approved.status, "approved", "approve returns approved status")
    let approveBody = try await bodyObject(transport.bodies.last ?? nil)
    try expectEqual(Set(approveBody.keys), ["approval_id", "queue_apply", "plan_sha256"], "approve sends exactly the server fields")
    try expectEqual(approveBody["approval_id"] as? String, "ap1", "approve approval_id")
    try expectEqual(approveBody["queue_apply"] as? Bool, true, "approve queue_apply")
    try expectEqual(approveBody["plan_sha256"] as? String, planHash, "approve plan_sha256 matches plan hash")
    try expectEqual(await transport.csrfHeaders.last ?? nil, "csrf-token", "approve carries CSRF header")

    let rejected = try await client.rejectApproval(approvalID: "ap1")
    try expectEqual(rejected.status, "rejected", "reject status")
    try expectEqual(rejected.rejectedBy, "admin", "rejected_by")
    let rejectBody = try await bodyObject(transport.bodies.last ?? nil)
    try expectEqual(rejectBody["approval_id"] as? String, "ap1", "reject approval_id")

    let dismissed = try await client.dismissApproval(approvalID: "ap-stale", note: "superseded")
    try expectEqual(dismissed.status, "dismissed", "dismiss status")
    let dismissBody = try await bodyObject(transport.bodies.last ?? nil)
    try expectEqual(dismissBody["note"] as? String, "superseded", "dismiss note")
}
