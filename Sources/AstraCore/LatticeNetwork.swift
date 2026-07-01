import Foundation
import CryptoKit

// MARK: - Plan hashing (TOCTOU defense for approvals)

/// Computes the SHA-256 hex digest the server expects in `plan_sha256` when
/// approving a high-risk plan. It binds the approval to the exact plan text the
/// reviewer saw, so a plan that changed between review and approval is rejected.
public enum PlanHasher {
    public static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Network policy

public struct NetEndpoint: Codable, Equatable, Hashable, Sendable {
    public var kind: String
    public var nodeID: String
    public var cidr: String
    public var domain: String

    public init(kind: String = "", nodeID: String = "", cidr: String = "", domain: String = "") {
        self.kind = kind
        self.nodeID = nodeID
        self.cidr = cidr
        self.domain = domain
    }

    /// Human-readable target, e.g. "node:edge-1", "cidr:10.0.0.0/8", "domain:x.com", "any".
    public var displayText: String {
        switch kind {
        case "node": return nodeID.isEmpty ? "node" : "node:\(nodeID)"
        case "cidr": return cidr.isEmpty ? "cidr" : cidr
        case "domain": return domain.isEmpty ? "domain" : domain
        case "any", "": return "any"
        default: return kind
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind, cidr, domain
        case nodeID = "node_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        cidr = try c.decodeIfPresent(String.self, forKey: .cidr) ?? ""
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? ""
    }
}

public struct NetRule: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var comment: String
    public var action: String       // "allow" | "deny"
    public var direction: String    // "egress" | "ingress"
    public var proto: String        // "tcp" | "udp" | "any"
    public var ports: [Int]
    public var remote: NetEndpoint
    public var disabled: Bool

    public init(id: String, comment: String = "", action: String = "", direction: String = "", proto: String = "", ports: [Int] = [], remote: NetEndpoint = NetEndpoint(), disabled: Bool = false) {
        self.id = id
        self.comment = comment
        self.action = action
        self.direction = direction
        self.proto = proto
        self.ports = ports
        self.remote = remote
        self.disabled = disabled
    }

    public var isAllow: Bool { action.lowercased() == "allow" }

    public var portsText: String {
        ports.isEmpty ? "all ports" : ports.map(String.init).joined(separator: ", ")
    }

    enum CodingKeys: String, CodingKey {
        case id, comment, action, direction, ports, remote, disabled
        case proto = "protocol"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        direction = try c.decodeIfPresent(String.self, forKey: .direction) ?? ""
        proto = try c.decodeIfPresent(String.self, forKey: .proto) ?? ""
        ports = try c.decodeIfPresent([Int].self, forKey: .ports) ?? []
        remote = try c.decodeIfPresent(NetEndpoint.self, forKey: .remote) ?? NetEndpoint()
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
    }
}

/// Server `netPolicyView`.
public struct NetPolicy: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var targetNodeID: String
    public var targetNodeName: String
    public var rules: [NetRule]
    public var enabled: Bool
    public var lastPlanSHA: String
    public var lastAppliedAt: Date?
    public var lastError: String
    public var updatedAt: Date?

    public init(id: String, targetNodeID: String = "", targetNodeName: String = "", rules: [NetRule] = [], enabled: Bool = false, lastPlanSHA: String = "", lastAppliedAt: Date? = nil, lastError: String = "", updatedAt: Date? = nil) {
        self.id = id
        self.targetNodeID = targetNodeID
        self.targetNodeName = targetNodeName
        self.rules = rules
        self.enabled = enabled
        self.lastPlanSHA = lastPlanSHA
        self.lastAppliedAt = lastAppliedAt
        self.lastError = lastError
        self.updatedAt = updatedAt
    }

    public var displayName: String { targetNodeName.isEmpty ? targetNodeID : targetNodeName }
    public var activeRules: [NetRule] { rules.filter { !$0.disabled } }

    enum CodingKeys: String, CodingKey {
        case id, rules, enabled
        case targetNodeID = "target_node_id"
        case targetNodeName = "target_node_name"
        case lastPlanSHA = "last_plan_sha"
        case lastAppliedAt = "last_applied_at"
        case lastError = "last_error"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        targetNodeID = try c.decodeIfPresent(String.self, forKey: .targetNodeID) ?? ""
        targetNodeName = try c.decodeIfPresent(String.self, forKey: .targetNodeName) ?? ""
        rules = try c.decodeIfPresent([NetRule].self, forKey: .rules) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        lastPlanSHA = try c.decodeIfPresent(String.self, forKey: .lastPlanSHA) ?? ""
        lastAppliedAt = try DateValue.decodeIfPresent(from: c, forKey: .lastAppliedAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError) ?? ""
        updatedAt = try DateValue.decodeIfPresent(from: c, forKey: .updatedAt)
    }
}

// MARK: - Reachability graph

public struct NetGraphNode: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var online: Bool

    public var displayName: String { name.isEmpty ? id : name }

    enum CodingKeys: String, CodingKey { case id, name, online }

    public init(id: String, name: String = "", online: Bool = false) {
        self.id = id
        self.name = name
        self.online = online
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
    }
}

public struct NetGraphEdge: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var from: String
    public var to: String
    public var action: String
    public var proto: String
    public var ports: [Int]
    public var direction: String
    public var ruleID: String

    public var id: String { "\(ruleID).\(from)->\(to)" }
    public var isAllow: Bool { action.lowercased() == "allow" }

    enum CodingKeys: String, CodingKey {
        case from, to, action, ports, direction
        case proto = "protocol"
        case ruleID = "rule_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
        to = try c.decodeIfPresent(String.self, forKey: .to) ?? ""
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        proto = try c.decodeIfPresent(String.self, forKey: .proto) ?? ""
        ports = try c.decodeIfPresent([Int].self, forKey: .ports) ?? []
        direction = try c.decodeIfPresent(String.self, forKey: .direction) ?? ""
        ruleID = try c.decodeIfPresent(String.self, forKey: .ruleID) ?? ""
    }
}

public struct NetGraphExternal: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var targetNodeID: String
    public var action: String
    public var remote: String
    public var proto: String
    public var ports: [Int]
    public var direction: String
    public var ruleID: String

    public var id: String { "\(ruleID).\(targetNodeID).\(remote)" }
    public var isAllow: Bool { action.lowercased() == "allow" }

    enum CodingKeys: String, CodingKey {
        case action, remote, ports, direction
        case targetNodeID = "target_node_id"
        case proto = "protocol"
        case ruleID = "rule_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targetNodeID = try c.decodeIfPresent(String.self, forKey: .targetNodeID) ?? ""
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        remote = try c.decodeIfPresent(String.self, forKey: .remote) ?? ""
        proto = try c.decodeIfPresent(String.self, forKey: .proto) ?? ""
        ports = try c.decodeIfPresent([Int].self, forKey: .ports) ?? []
        direction = try c.decodeIfPresent(String.self, forKey: .direction) ?? ""
        ruleID = try c.decodeIfPresent(String.self, forKey: .ruleID) ?? ""
    }
}

public struct NetGraph: Codable, Equatable, Sendable {
    public var nodes: [NetGraphNode]
    public var edges: [NetGraphEdge]
    public var externals: [NetGraphExternal]

    public init(nodes: [NetGraphNode] = [], edges: [NetGraphEdge] = [], externals: [NetGraphExternal] = []) {
        self.nodes = nodes
        self.edges = edges
        self.externals = externals
    }

    enum CodingKeys: String, CodingKey { case nodes, edges, externals }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try c.decodeIfPresent([NetGraphNode].self, forKey: .nodes) ?? []
        edges = try c.decodeIfPresent([NetGraphEdge].self, forKey: .edges) ?? []
        externals = try c.decodeIfPresent([NetGraphExternal].self, forKey: .externals) ?? []
    }

    public var isEmpty: Bool { nodes.isEmpty && edges.isEmpty && externals.isEmpty }
}

// MARK: - nftables baseline inputs

public struct NFTInputs: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var nodeID: String
    public var nodeName: String
    public var interfaceName: String
    public var wireGuardCIDR: String
    public var publicTCP: [Int]
    public var publicUDP: [Int]
    public var wireGuardTCP: [Int]
    public var wireGuardUDP: [Int]
    public var updatedAt: Date?

    public init(id: String, nodeID: String = "", nodeName: String = "", interfaceName: String = "", wireGuardCIDR: String = "", publicTCP: [Int] = [], publicUDP: [Int] = [], wireGuardTCP: [Int] = [], wireGuardUDP: [Int] = [], updatedAt: Date? = nil) {
        self.id = id
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.interfaceName = interfaceName
        self.wireGuardCIDR = wireGuardCIDR
        self.publicTCP = publicTCP
        self.publicUDP = publicUDP
        self.wireGuardTCP = wireGuardTCP
        self.wireGuardUDP = wireGuardUDP
        self.updatedAt = updatedAt
    }

    public var displayName: String { nodeName.isEmpty ? nodeID : nodeName }

    public static func portList(_ ports: [Int]) -> String {
        ports.isEmpty ? "—" : ports.map(String.init).joined(separator: ", ")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case nodeName = "node_name"
        case interfaceName = "interface_name"
        case wireGuardCIDR = "wireguard_cidr"
        case publicTCP = "public_tcp"
        case publicUDP = "public_udp"
        case wireGuardTCP = "wireguard_tcp"
        case wireGuardUDP = "wireguard_udp"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        nodeName = try c.decodeIfPresent(String.self, forKey: .nodeName) ?? ""
        interfaceName = try c.decodeIfPresent(String.self, forKey: .interfaceName) ?? ""
        wireGuardCIDR = try c.decodeIfPresent(String.self, forKey: .wireGuardCIDR) ?? ""
        publicTCP = try c.decodeIfPresent([Int].self, forKey: .publicTCP) ?? []
        publicUDP = try c.decodeIfPresent([Int].self, forKey: .publicUDP) ?? []
        wireGuardTCP = try c.decodeIfPresent([Int].self, forKey: .wireGuardTCP) ?? []
        wireGuardUDP = try c.decodeIfPresent([Int].self, forKey: .wireGuardUDP) ?? []
        updatedAt = try DateValue.decodeIfPresent(from: c, forKey: .updatedAt)
    }
}

// MARK: - Tunnels

public struct TunnelIngress: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var hostname: String
    public var service: String
    public var path: String

    public var id: String { "\(hostname).\(service).\(path)" }

    public init(hostname: String = "", service: String = "", path: String = "") {
        self.hostname = hostname
        self.service = service
        self.path = path
    }

    enum CodingKeys: String, CodingKey { case hostname, service, path }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        service = try c.decodeIfPresent(String.self, forKey: .service) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
    }
}

/// Server `tunnelView`.
public struct TunnelProfile: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var nodeID: String
    public var tunnelID: String
    public var ingress: [TunnelIngress]
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(id: String, name: String = "", nodeID: String = "", tunnelID: String = "", ingress: [TunnelIngress] = [], createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.nodeID = nodeID
        self.tunnelID = tunnelID
        self.ingress = ingress
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayName: String { name.isEmpty ? id : name }

    enum CodingKeys: String, CodingKey {
        case id, name, ingress
        case nodeID = "node_id"
        case tunnelID = "tunnel_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        tunnelID = try c.decodeIfPresent(String.self, forKey: .tunnelID) ?? ""
        ingress = try c.decodeIfPresent([TunnelIngress].self, forKey: .ingress) ?? []
        createdAt = try DateValue.decodeIfPresent(from: c, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: c, forKey: .updatedAt)
    }
}

// MARK: - Approvals

/// Server `approvalView`. `plan` is the full reviewed text whose SHA-256 must be
/// echoed back when approving high-risk changes.
public struct Approval: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var nodeID: String
    public var plugin: String
    public var action: String
    public var plan: String
    public var status: String
    public var reason: String
    public var stale: Bool
    public var staleCode: String
    public var actorID: String
    public var approvedBy: String
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        id: String,
        nodeID: String = "",
        plugin: String = "",
        action: String = "",
        plan: String = "",
        status: String = "",
        reason: String = "",
        stale: Bool = false,
        staleCode: String = "",
        actorID: String = "",
        approvedBy: String = "",
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.nodeID = nodeID
        self.plugin = plugin
        self.action = action
        self.plan = plan
        self.status = status
        self.reason = reason
        self.stale = stale
        self.staleCode = staleCode
        self.actorID = actorID
        self.approvedBy = approvedBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isPending: Bool { status.lowercased() == "pending" }
    public var isStale: Bool { stale || !staleCode.isEmpty }
    public var isApprovable: Bool { isPending && !isStale }

    /// SHA-256 hex of the plan text, for the `plan_sha256` approval field.
    public var planHash: String { PlanHasher.sha256Hex(plan) }

    enum CodingKeys: String, CodingKey {
        case id, plugin, action, plan, status, reason, stale
        case nodeID = "node_id"
        case staleCode = "stale_code"
        case actorID = "actor_id"
        case approvedBy = "approved_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        plugin = try c.decodeIfPresent(String.self, forKey: .plugin) ?? ""
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        plan = try c.decodeIfPresent(String.self, forKey: .plan) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
        staleCode = try c.decodeIfPresent(String.self, forKey: .staleCode) ?? ""
        actorID = try c.decodeIfPresent(String.self, forKey: .actorID) ?? ""
        approvedBy = try c.decodeIfPresent(String.self, forKey: .approvedBy) ?? ""
        createdAt = try DateValue.decodeIfPresent(from: c, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: c, forKey: .updatedAt)
    }
}

// MARK: - Request / envelopes

private struct PoliciesEnvelope: Decodable { var policies: [NetPolicy] }
private struct NFTInputsEnvelope: Decodable { var inputs: [NFTInputs] }

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

// MARK: - Typed endpoints

public extension LatticeClient {
    /// `GET /api/netpolicy` → `{"policies":[...]}`.
    func listNetPolicies() async throws -> [NetPolicy] {
        let data = try await performData(path: "/api/netpolicy")
        let envelope = try JSONDecoder().decode(PoliciesEnvelope.self, from: data)
        return envelope.policies
    }

    /// `GET /api/netpolicy/graph` → `{nodes,edges,externals}`.
    func netPolicyGraph() async throws -> NetGraph {
        try await perform(NetGraph.self, path: "/api/netpolicy/graph")
    }

    /// `GET /api/network/nft/inputs` → `{"inputs":[...]}`.
    func listNFTInputs() async throws -> [NFTInputs] {
        let data = try await performData(path: "/api/network/nft/inputs")
        let envelope = try JSONDecoder().decode(NFTInputsEnvelope.self, from: data)
        return envelope.inputs
    }

    /// `GET /api/tunnels` → bare array.
    func listTunnels() async throws -> [TunnelProfile] {
        try await perform([TunnelProfile].self, path: "/api/tunnels")
    }

    /// `GET /api/network/approvals` → bare array.
    func listApprovals() async throws -> [Approval] {
        try await perform([Approval].self, path: "/api/network/approvals")
    }

    /// `POST /api/network/approvals/approve`. Always sends `plan_sha256` computed
    /// over the reviewed plan so the server can reject a plan that changed since
    /// review. `queueApply` queues the apply task on approval.
    @discardableResult
    func approveApproval(approvalID: String, queueApply: Bool, planSHA256: String) async throws -> Approval {
        try await perform(
            Approval.self,
            path: "/api/network/approvals/approve",
            method: "POST",
            body: ApproveRequest(approvalID: approvalID, queueApply: queueApply, planSHA256: planSHA256)
        )
    }
}
