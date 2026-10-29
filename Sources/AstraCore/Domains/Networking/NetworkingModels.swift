import Foundation

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
