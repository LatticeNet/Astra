import Foundation

// Inbound firewall (`latticenet.netguard`): security groups, zones, the
// per-node bindings and the node-group bindings, read only on the phone.

public struct NetworkingGuardPortRange: Decodable, Hashable, Sendable {
    public var from: Int
    public var to: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        from = c.networkingInt("from")
        to = c.networkingInt("to")
    }

    public var text: String { to > from ? "\(from)-\(to)" : String(from) }
}

/// One NetGuard rule (`model.GuardRule`): ports are ranges, remotes may be zones.
public struct NetworkingGuardRule: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var comment: String
    public var action: String
    public var direction: String
    /// tcp, udp, icmp, icmpv6 or any.
    public var proto: String
    public var ports: [NetworkingGuardPortRange]
    public var remote: NetEndpoint
    public var log: Bool
    public var disabled: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        id = c.networkingString("id")
        comment = c.networkingString("comment")
        action = c.networkingString("action")
        direction = c.networkingString("direction")
        proto = c.networkingString("protocol")
        ports = try c.networkingList(NetworkingGuardPortRange.self, "ports")
        remote = try c.networkingObject(NetEndpoint.self, "remote") ?? NetEndpoint()
        log = c.networkingBool("log")
        disabled = c.networkingBool("disabled")
    }

    public var isAllow: Bool { action.lowercased() == "allow" }

    /// "tcp 22, 443", "icmp", "any".
    public var trafficText: String {
        let protoText = proto.isEmpty ? "any" : proto
        guard !ports.isEmpty else { return protoText }
        return "\(protoText) \(ports.map(\.text).joined(separator: ", "))"
    }
}

/// `securityGroupView`: a stored group, or a node's legacy baseline the server converts on read.
public struct NetworkingSecurityGroup: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var rules: [NetworkingGuardRule]
    public var version: Int
    /// stored or legacy.
    public var source: String
    /// Set for a node-private legacy group.
    public var nodeID: String
    /// The node group a derived group comes through, when the reader may see it.
    public var viaNodeGroupID: String
    public var viaNodeGroupName: String
    /// A derived group on a node NetGuard does not manage.
    public var inactive: Bool
    /// Stands in for the rules a confined reader may not see.
    public var ruleCount: Int
    public var updatedAt: Date?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        id = try c.networkingRequired("id")
        name = c.networkingString("name")
        description = c.networkingString("description")
        rules = try c.networkingList(NetworkingGuardRule.self, "rules")
        version = c.networkingInt("version")
        source = c.networkingString("source")
        nodeID = c.networkingString("node_id")
        let via = try? c.nestedContainer(keyedBy: LatticeCodingKey.self, forKey: LatticeCodingKey("via_node_group"))
        viaNodeGroupID = via?.networkingString("id") ?? ""
        viaNodeGroupName = via?.networkingString("name") ?? ""
        inactive = c.networkingBool("inactive")
        ruleCount = c.networkingInt("rule_count")
        updatedAt = c.networkingDate("updated_at")
    }

    public var displayName: String { name.isEmpty ? id : name }
    public var isLegacy: Bool { source == "legacy" }
    /// The rules shown, or the count the server gave in their place.
    public var visibleRuleCount: Int { rules.isEmpty ? ruleCount : rules.count }
}

/// A named trust surface (`model.GuardZone`).
public struct NetworkingGuardZone: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var builtin: Bool
    public var interfaces: [String]
    public var cidrs: [String]
    public var description: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        id = try c.networkingRequired("id")
        name = c.networkingString("name")
        builtin = c.networkingBool("builtin")
        interfaces = c.networkingStrings("interfaces")
        cidrs = c.networkingStrings("cidrs")
        description = c.networkingString("description")
    }

    public var displayName: String { name.isEmpty ? id : name }

    /// "lo", "10.8.0.0/24, wg0", or what a built-in zone means on each node.
    public var summary: String {
        let parts = interfaces + cidrs
        if !parts.isEmpty { return parts.joined(separator: ", ") }
        if builtin {
            switch id {
            case "public": return "each node's public interface"
            case "wireguard": return "each node's mesh network"
            case "tailscale": return "each node's tailscale interface"
            default: return "built in"
            }
        }
        return description.isEmpty ? "no interfaces or networks" : description
    }
}

/// `model.NodeGuardBinding`: which groups and zones a node compiles, and its last apply.
public struct NetworkingGuardBinding: Decodable, Hashable, Sendable {
    public var nodeID: String
    public var groupIDs: [String]
    public var overrides: [NetworkingGuardRule]
    public var zoneIDs: [String]
    public var managed: Bool
    public var version: Int
    public var lastPlanSHA: String
    public var lastAppliedAt: Date?
    public var lastError: String
    public var appliedTableSHA: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        nodeID = c.networkingString("node_id")
        groupIDs = c.networkingStrings("group_ids")
        overrides = try c.networkingList(NetworkingGuardRule.self, "overrides")
        zoneIDs = c.networkingStrings("zone_ids")
        managed = c.networkingBool("managed")
        version = c.networkingInt("version")
        lastPlanSHA = c.networkingString("last_plan_sha")
        lastAppliedAt = c.networkingDate("last_applied_at")
        lastError = c.networkingString("last_error")
        appliedTableSHA = c.networkingString("applied_table_sha")
    }
}

/// `nodeGuardView`: one node's binding with its groups resolved.
public struct NetworkingNodeGuard: Decodable, Identifiable, Hashable, Sendable {
    public var nodeID: String
    public var nodeName: String
    /// stored or legacy.
    public var source: String
    public var binding: NetworkingGuardBinding
    public var groups: [NetworkingSecurityGroup]
    public var derivedGroups: [NetworkingSecurityGroup]
    public var zones: [NetworkingGuardZone]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        nodeID = try c.networkingRequired("node_id")
        nodeName = c.networkingString("node_name")
        source = c.networkingString("source")
        guard let binding = try c.networkingObject(NetworkingGuardBinding.self, "binding") else {
            throw DecodingError.keyNotFound(LatticeCodingKey("binding"), .init(codingPath: c.codingPath, debugDescription: "binding is required"))
        }
        self.binding = binding
        groups = try c.networkingList(NetworkingSecurityGroup.self, "groups")
        derivedGroups = try c.networkingList(NetworkingSecurityGroup.self, "derived_groups")
        zones = try c.networkingList(NetworkingGuardZone.self, "zones")
    }

    public var id: String { nodeID }
    public var displayName: String { nodeName.isEmpty ? nodeID : nodeName }
    public var state: NetworkingGuardState { NetworkingGuardState.of(self) }
}

/// Where a node's inbound firewall stands, from its binding.
public enum NetworkingGuardState: String, Hashable, Sendable, CaseIterable {
    /// The last apply reported an error.
    case failed
    /// NetGuard manages the node and a plan has not applied yet.
    case pending
    /// NetGuard manages the node and its last plan applied.
    case enforced
    /// The binding exists but NetGuard does not write the node's ruleset.
    case observing
    /// The node runs a legacy ruleset NetGuard has not adopted.
    case legacy

    public var word: String {
        switch self {
        case .failed: "apply failed"
        case .pending: "plan not applied"
        case .enforced: "enforced"
        case .observing: "observe only"
        case .legacy: "legacy ruleset"
        }
    }

    public static func of(_ node: NetworkingNodeGuard) -> NetworkingGuardState {
        if !node.binding.lastError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .failed }
        if node.source == "legacy" { return .legacy }
        guard node.binding.managed else { return .observing }
        if node.binding.lastAppliedAt == nil || node.binding.appliedTableSHA.isEmpty { return .pending }
        return .enforced
    }
}

public struct NetworkingNodeGroupBindingMember: Decodable, Hashable, Sendable {
    public var nodeID: String
    public var nodeName: String
    /// active or inactive.
    public var state: String
    public var reason: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        nodeID = c.networkingString("node_id")
        nodeName = c.networkingString("node_name")
        state = c.networkingString("state")
        reason = c.networkingString("reason")
    }

    public var displayName: String { nodeName.isEmpty ? nodeID : nodeName }
    public var isActive: Bool { state == "active" }
}

/// Security groups bound to one node group.
public struct NetworkingNodeGroupBinding: Decodable, Identifiable, Hashable, Sendable {
    public var groupID: String
    public var groupName: String
    public var securityGroupIDs: [String]
    public var version: Int
    public var members: [NetworkingNodeGroupBindingMember]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        groupID = try c.networkingRequired("group_id")
        groupName = c.networkingString("group_name")
        securityGroupIDs = c.networkingStrings("security_group_ids")
        version = c.networkingInt("version")
        members = try c.networkingList(NetworkingNodeGroupBindingMember.self, "members")
    }

    public var id: String { groupID }
    public var displayName: String { groupName.isEmpty ? groupID : groupName }
    public var activeCount: Int { members.filter(\.isActive).count }
}

/// Everything the Inbound firewall screen reads, section by section.
public struct NetworkingFirewallSnapshot: Sendable {
    public var groups: [NetworkingSecurityGroup]
    public var zones: [NetworkingGuardZone]
    public var nodes: [NetworkingNodeGuard]
    public var nodeGroupBindings: [NetworkingNodeGroupBinding]

    public init(groups: [NetworkingSecurityGroup], zones: [NetworkingGuardZone], nodes: [NetworkingNodeGuard], nodeGroupBindings: [NetworkingNodeGroupBinding]) {
        self.groups = groups
        self.zones = zones
        self.nodes = nodes
        self.nodeGroupBindings = nodeGroupBindings
    }

    /// The nodes a security group reaches: bound directly, or through a node group.
    public func boundNodes(of groupID: String) -> [NetworkingNodeGuard] {
        nodes.filter { node in
            node.binding.groupIDs.contains(groupID) || node.groups.contains { $0.id == groupID } || node.derivedGroups.contains { $0.id == groupID }
        }
    }

    public func boundNodeGroups(of groupID: String) -> [NetworkingNodeGroupBinding] {
        nodeGroupBindings.filter { $0.securityGroupIDs.contains(groupID) }
    }

    /// A group by id from the catalogue, or from any node that resolves it.
    public func group(id: String) -> NetworkingSecurityGroup? {
        groups.first { $0.id == id }
            ?? nodes.lazy.compactMap { node in (node.groups + node.derivedGroups).first { $0.id == id } }.first
    }
}
