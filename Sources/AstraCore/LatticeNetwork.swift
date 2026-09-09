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

/// Why an approved plan has not applied. Present only on `status=approved`
/// rows; omitted everywhere else. Matches server `approvalWaitView`.
public struct ApprovalWaiting: Codable, Equatable, Hashable, Sendable {
    public var code: String
    public var reason: String
    public var blocked: Bool
    public var nodeID: String
    public var nodeName: String
    public var nodeStatus: String
    public var nodeStatusSince: Date?
    public var nodeStatusReason: String
    public var taskID: String
    public var taskStatus: String
    public var supersededBy: String
    public var dismissible: Bool

    public init(
        code: String = "",
        reason: String = "",
        blocked: Bool = false,
        nodeID: String = "",
        nodeName: String = "",
        nodeStatus: String = "",
        nodeStatusSince: Date? = nil,
        nodeStatusReason: String = "",
        taskID: String = "",
        taskStatus: String = "",
        supersededBy: String = "",
        dismissible: Bool = false
    ) {
        self.code = code
        self.reason = reason
        self.blocked = blocked
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.nodeStatus = nodeStatus
        self.nodeStatusSince = nodeStatusSince
        self.nodeStatusReason = nodeStatusReason
        self.taskID = taskID
        self.taskStatus = taskStatus
        self.supersededBy = supersededBy
        self.dismissible = dismissible
    }

    enum CodingKeys: String, CodingKey {
        case code, reason, blocked, dismissible
        case nodeID = "node_id"
        case nodeName = "node_name"
        case nodeStatus = "node_status"
        case nodeStatusSince = "node_status_since"
        case nodeStatusReason = "node_status_reason"
        case taskID = "task_id"
        case taskStatus = "task_status"
        case supersededBy = "superseded_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        blocked = try c.decodeIfPresent(Bool.self, forKey: .blocked) ?? false
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        nodeName = try c.decodeIfPresent(String.self, forKey: .nodeName) ?? ""
        nodeStatus = try c.decodeIfPresent(String.self, forKey: .nodeStatus) ?? ""
        nodeStatusSince = try DateValue.decodeIfPresent(from: c, forKey: .nodeStatusSince)
        nodeStatusReason = try c.decodeIfPresent(String.self, forKey: .nodeStatusReason) ?? ""
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID) ?? ""
        taskStatus = try c.decodeIfPresent(String.self, forKey: .taskStatus) ?? ""
        supersededBy = try c.decodeIfPresent(String.self, forKey: .supersededBy) ?? ""
        dismissible = try c.decodeIfPresent(Bool.self, forKey: .dismissible) ?? false
    }
}

public enum ApprovalReviewError: Error, Equatable, LocalizedError, Sendable {
    case emptyPlan
    case hashMismatch(computed: String, expected: String)

    public var errorDescription: String? {
        switch self {
        case .emptyPlan:
            "This listing row has no plan body. Reload the approval by id before hashing or approving."
        case .hashMismatch(let computed, let expected):
            "Plan hash \(computed.prefix(8))… does not match server plan_sha256 \(expected.prefix(8))…. Reload before approving."
        }
    }
}

/// Server `approvalView`. Listing omits `plan` unless `include=plan`; every row
/// still carries `plan_sha256`. Review must load by id and hash that body.
public struct Approval: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var nodeID: String
    public var plugin: String
    public var action: String
    public var plan: String
    /// Server-computed SHA-256 of the stored plan. Always present, even when
    /// the listing omitted the plan body.
    public var planSHA256: String
    public var status: String
    public var reason: String
    public var stale: Bool
    public var staleCode: String
    public var actorID: String
    public var approvedBy: String
    public var rejectedBy: String
    public var rejectedAt: Date?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var pluginVersion: String
    public var artifactDigest: String
    public var service: String
    public var method: String
    public var targets: [String]
    public var waiting: ApprovalWaiting?

    public init(
        id: String,
        nodeID: String = "",
        plugin: String = "",
        action: String = "",
        plan: String = "",
        planSHA256: String = "",
        status: String = "",
        reason: String = "",
        stale: Bool = false,
        staleCode: String = "",
        actorID: String = "",
        approvedBy: String = "",
        rejectedBy: String = "",
        rejectedAt: Date? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        pluginVersion: String = "",
        artifactDigest: String = "",
        service: String = "",
        method: String = "",
        targets: [String] = [],
        waiting: ApprovalWaiting? = nil
    ) {
        self.id = id
        self.nodeID = nodeID
        self.plugin = plugin
        self.action = action
        self.plan = plan
        self.planSHA256 = planSHA256
        self.status = status
        self.reason = reason
        self.stale = stale
        self.staleCode = staleCode
        self.actorID = actorID
        self.approvedBy = approvedBy
        self.rejectedBy = rejectedBy
        self.rejectedAt = rejectedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pluginVersion = pluginVersion
        self.artifactDigest = artifactDigest
        self.service = service
        self.method = method
        self.targets = targets
        self.waiting = waiting
    }

    public var isPending: Bool { status.lowercased() == "pending" }
    public var isApproved: Bool { status.lowercased() == "approved" }
    public var isDismissed: Bool { status.lowercased() == "dismissed" }
    public var isRejected: Bool { status.lowercased() == "rejected" }
    public var isStale: Bool { stale || !staleCode.isEmpty }
    public var hasPlanBody: Bool { !plan.isEmpty }

    /// System-authored line-metadata syncs auto-approve (KI-6). Inbox is
    /// human-pending only, so those rows never badge.
    public var isAutoApprovedLineMeta: Bool {
        plugin == "singbox-linemeta" && (actorID == "lattice-server" || actorID == "system")
    }

    public var isHumanPending: Bool { isPending && !isAutoApprovedLineMeta }

    public var isApprovable: Bool { isHumanPending && !isStale && hasPlanBody }

    public var isSSHGuardConfirm: Bool { plugin == "sshguard" && action == "sshguard-confirm:v1" }
    public var isSSHGuardArm: Bool { plugin == "sshguard" && action == "sshguard-arm:v1" }

    /// SHA-256 of the local `plan` field. Empty on listing rows that omitted
    /// the body: never send this as `plan_sha256` without loading by id.
    public var planHash: String { PlanHasher.sha256Hex(plan) }

    public var planHashMatchesServer: Bool {
        !planSHA256.isEmpty && planHash.caseInsensitiveCompare(planSHA256) == .orderedSame
    }

    /// Hash of the plan body on screen. Fails closed if this is a listing row
    /// or if the body does not match `plan_sha256`.
    public func reviewedPlanSHA256() throws -> String {
        guard hasPlanBody else { throw ApprovalReviewError.emptyPlan }
        guard planHashMatchesServer else {
            throw ApprovalReviewError.hashMismatch(computed: planHash, expected: planSHA256)
        }
        return planHash
    }

    /// Proof line for Review: `plan a1f3… · 3 targets · waiting on node`.
    public var proofLine: String {
        let hashSource = planSHA256.isEmpty ? planHash : planSHA256
        let prefix = hashSource.isEmpty ? "plan" : "plan \(hashSource.prefix(4))…"
        let targetText: String
        let count = targets.isEmpty ? (nodeID.isEmpty ? 0 : 1) : targets.count
        if count == 1 {
            targetText = "1 target"
        } else {
            targetText = "\(count) targets"
        }
        if let waiting, !waiting.reason.isEmpty {
            return "\(prefix) · \(targetText) · waiting"
        }
        if isStale {
            return "\(prefix) · \(targetText) · stale"
        }
        return "\(prefix) · \(targetText)"
    }

    enum CodingKeys: String, CodingKey {
        case id, plugin, action, plan, status, reason, stale, targets, waiting, service, method
        case planSHA256 = "plan_sha256"
        case nodeID = "node_id"
        case staleCode = "stale_code"
        case actorID = "actor_id"
        case approvedBy = "approved_by"
        case rejectedBy = "rejected_by"
        case rejectedAt = "rejected_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case pluginVersion = "plugin_version"
        case artifactDigest = "artifact_digest"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        plugin = try c.decodeIfPresent(String.self, forKey: .plugin) ?? ""
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        plan = try c.decodeIfPresent(String.self, forKey: .plan) ?? ""
        // Required on the live contract. Missing it is a companion-behind-server
        // failure on Review; listing fixtures must include it.
        planSHA256 = try c.decodeIfPresent(String.self, forKey: .planSHA256) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
        staleCode = try c.decodeIfPresent(String.self, forKey: .staleCode) ?? ""
        actorID = try c.decodeIfPresent(String.self, forKey: .actorID) ?? ""
        approvedBy = try c.decodeIfPresent(String.self, forKey: .approvedBy) ?? ""
        rejectedBy = try c.decodeIfPresent(String.self, forKey: .rejectedBy) ?? ""
        rejectedAt = try DateValue.decodeIfPresent(from: c, forKey: .rejectedAt)
        createdAt = try DateValue.decodeIfPresent(from: c, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: c, forKey: .updatedAt)
        pluginVersion = try c.decodeIfPresent(String.self, forKey: .pluginVersion) ?? ""
        artifactDigest = try c.decodeIfPresent(String.self, forKey: .artifactDigest) ?? ""
        service = try c.decodeIfPresent(String.self, forKey: .service) ?? ""
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? ""
        targets = try c.decodeIfPresent([String].self, forKey: .targets) ?? []
        waiting = try c.decodeIfPresent(ApprovalWaiting.self, forKey: .waiting)
    }
}

/// Fail-closed decode for Review: `id`, `plan_sha256`, and `status` must be
/// present. Additive fields stay optional.
public enum ApprovalReviewDecoder {
    public static func decode(_ data: Data) throws -> Approval {
        let approval = try JSONDecoder().decode(Approval.self, from: data)
        if approval.id.isEmpty || approval.planSHA256.isEmpty || approval.status.isEmpty {
            throw LatticeAPIError.invalidResponse
        }
        return approval
    }

    public static func decodeEnvelope(_ data: Data) throws -> Approval {
        let envelope = try JSONDecoder().decode(ApprovalEnvelope.self, from: data)
        if envelope.approval.id.isEmpty || envelope.approval.planSHA256.isEmpty || envelope.approval.status.isEmpty {
            throw LatticeAPIError.invalidResponse
        }
        return envelope.approval
    }
}

// MARK: - Request / envelopes

private struct PoliciesEnvelope: Decodable { var policies: [NetPolicy] }
private struct NFTInputsEnvelope: Decodable { var inputs: [NFTInputs] }
struct ApprovalEnvelope: Decodable, Sendable { var approval: Approval }

struct ApprovalsQueryResponse: Decodable, Sendable {
    var approvals: [Approval]
    var total: Int
    var limit: Int
    var offset: Int

    enum CodingKeys: String, CodingKey { case approvals, total, limit, offset }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        approvals = try c.decodeIfPresent([Approval].self, forKey: .approvals) ?? []
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 0
        offset = try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0
    }
}

public struct ApprovalCounts: Decodable, Equatable, Sendable {
    public var pending: Int
    public var approved: Int
    public var stale: Int
    public var applied: Int
    public var rejected: Int
    public var dismissed: Int
    public var total: Int

    public init(pending: Int = 0, approved: Int = 0, stale: Int = 0, applied: Int = 0, rejected: Int = 0, dismissed: Int = 0, total: Int = 0) {
        self.pending = pending
        self.approved = approved
        self.stale = stale
        self.applied = applied
        self.rejected = rejected
        self.dismissed = dismissed
        self.total = total
    }

    enum CodingKeys: String, CodingKey {
        case pending, approved, stale, applied, rejected, dismissed, total
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pending = try c.decodeIfPresent(Int.self, forKey: .pending) ?? 0
        approved = try c.decodeIfPresent(Int.self, forKey: .approved) ?? 0
        stale = try c.decodeIfPresent(Int.self, forKey: .stale) ?? 0
        applied = try c.decodeIfPresent(Int.self, forKey: .applied) ?? 0
        rejected = try c.decodeIfPresent(Int.self, forKey: .rejected) ?? 0
        dismissed = try c.decodeIfPresent(Int.self, forKey: .dismissed) ?? 0
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
    }
}

private struct ApprovalCountsEnvelope: Decodable { var counts: ApprovalCounts }

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

    /// `GET /api/network/approvals`. Without filters the server returns a bare
    /// array. With `status`, `limit`, `node_id`, `plugin`, `since`, or `offset`
    /// it returns `{"approvals","total","limit","offset"}`. Listing omits `plan`
    /// unless `includePlan` is true.
    func listApprovals(
        status: String? = nil,
        includePlan: Bool = false,
        includeDismissed: Bool = false,
        nodeID: String? = nil,
        plugin: String? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) async throws -> [Approval] {
        var query: [URLQueryItem] = []
        if let status, !status.isEmpty { query.append(URLQueryItem(name: "status", value: status)) }
        if includePlan { query.append(URLQueryItem(name: "include", value: "plan")) }
        if includeDismissed { query.append(URLQueryItem(name: "include_dismissed", value: "1")) }
        if let nodeID, !nodeID.isEmpty { query.append(URLQueryItem(name: "node_id", value: nodeID)) }
        if let plugin, !plugin.isEmpty { query.append(URLQueryItem(name: "plugin", value: plugin)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let offset { query.append(URLQueryItem(name: "offset", value: String(offset))) }
        let data = try await performData(path: "/api/network/approvals", query: query)
        return try Self.decodeApprovalList(data)
    }

    /// Pending rows that still need a person. Skips system-authored linemeta.
    func listHumanPendingApprovals() async throws -> [Approval] {
        try await listApprovals(status: "pending").filter(\.isHumanPending)
    }

    /// `GET /api/network/approvals?count=1` → `{"counts":{...}}`.
    func countApprovals() async throws -> ApprovalCounts {
        let data = try await performData(
            path: "/api/network/approvals",
            query: [URLQueryItem(name: "count", value: "1")]
        )
        return try JSONDecoder().decode(ApprovalCountsEnvelope.self, from: data).counts
    }

    /// `GET /api/network/approvals?id=` → `{"approval":...}` with the plan body.
    func fetchApproval(id: String) async throws -> Approval {
        let data = try await performData(
            path: "/api/network/approvals",
            query: [URLQueryItem(name: "id", value: id)]
        )
        do {
            return try ApprovalReviewDecoder.decodeEnvelope(data)
        } catch {
            throw LatticeAPIError.invalidResponse
        }
    }

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

    static func decodeApprovalList(_ data: Data) throws -> [Approval] {
        if let envelope = try? JSONDecoder().decode(ApprovalsQueryResponse.self, from: data),
           !envelope.approvals.isEmpty || envelope.total > 0 || envelope.limit > 0 {
            return envelope.approvals
        }
        if let rows = try? JSONDecoder().decode([Approval].self, from: data) {
            return rows
        }
        if let envelope = try? JSONDecoder().decode(ApprovalsQueryResponse.self, from: data) {
            return envelope.approvals
        }
        throw LatticeAPIError.invalidResponse
    }
}
