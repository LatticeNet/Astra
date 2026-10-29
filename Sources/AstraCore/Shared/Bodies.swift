import Foundation

/// `{"id": ...}`, the body of most single-object writes.
public struct IDBody: Encodable, Equatable, Sendable {
    public var id: String
    public init(id: String) { self.id = id }
}

/// `{"node_id": ...}`.
public struct NodeIDBody: Encodable, Equatable, Sendable {
    public var nodeID: String
    public init(nodeID: String) { self.nodeID = nodeID }
    enum CodingKeys: String, CodingKey { case nodeID = "node_id" }
}

/// `{"approval_id": ...}`.
public struct ApprovalIDBody: Encodable, Equatable, Sendable {
    public var approvalID: String
    public init(approvalID: String) { self.approvalID = approvalID }
    enum CodingKeys: String, CodingKey { case approvalID = "approval_id" }
}

/// `{"ok": true}`, the answer of writes that return nothing else.
public struct OKResponse: Decodable, Equatable, Sendable {
    public var ok: Bool
    public init(ok: Bool) { self.ok = ok }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LatticeCodingKey.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: LatticeCodingKey("ok")) ?? false
    }
}
