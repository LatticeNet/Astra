import Foundation

/// A lint finding a plan endpoint returns with its approval, or with a 409.
public struct PlanFinding: Codable, Equatable, Hashable, Sendable {
    public var code: String
    /// "block" or "warn".
    public var severity: String
    public var message: String

    public init(code: String, severity: String, message: String) {
        self.code = code
        self.severity = severity
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        severity = try c.decodeIfPresent(String.self, forKey: .severity) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    public var isBlocking: Bool { severity == "block" }
}

/// What a beacon plan does to the node's beacon.
public enum BeaconPlanAction: String, Codable, Sendable, Hashable, CaseIterable {
    case enable, disable, change
}

/// `POST /api/nodes/beacon/plan` (lattice-sdk `model.BeaconPlanRequest`).
public struct BeaconPlanRequest: Encodable, Equatable, Sendable {
    public var nodeID: String
    public var action: BeaconPlanAction
    public var port: Int?
    public var bind: String?
    public var endpoint: String?

    public init(nodeID: String, action: BeaconPlanAction, port: Int? = nil, bind: String? = nil, endpoint: String? = nil) {
        self.nodeID = nodeID
        self.action = action
        self.port = port
        self.bind = bind
        self.endpoint = endpoint
    }

    enum CodingKeys: String, CodingKey {
        case action, port, bind, endpoint
        case nodeID = "node_id"
    }
}

/// The beacon plan answer: the filed approval and its non-blocking findings.
public struct BeaconPlanResponse: Decodable, Equatable, Sendable {
    public var approval: Approval
    public var findings: [PlanFinding]

    enum CodingKeys: String, CodingKey { case approval, findings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        approval = try c.decode(Approval.self, forKey: .approval)
        findings = try c.decodeIfPresent([PlanFinding].self, forKey: .findings) ?? []
    }

    /// The approvals to open in Review after filing.
    public var filedApprovalIDs: [String] { [approval.id] }
}

private struct AgentUpdatePlanBody: Encodable {
    var nodeID: String
    var force: Bool

    enum CodingKeys: String, CodingKey {
        case force
        case nodeID = "node_id"
    }
}

public extension LatticeClient {
    /// Files a beacon plan. A 409 with lint findings surfaces as
    /// `LatticeAPIError.conflict(code:findings:)`; beacon plans have no
    /// acceptance flag, so the findings loop only shows them.
    func planBeacon(_ request: BeaconPlanRequest) async throws -> BeaconPlanResponse {
        try await perform(BeaconPlanResponse.self, path: "/api/nodes/beacon/plan", method: "POST", body: request)
    }

    /// Files an agent update plan for one node; the answer is a bare approval.
    func planAgentUpdate(nodeID: String, force: Bool) async throws -> Approval {
        let data = try await performData(path: "/api/nodes/agent-updates/plan", method: "POST", body: AgentUpdatePlanBody(nodeID: nodeID, force: force))
        return try ApprovalReviewDecoder.decode(data)
    }
}
