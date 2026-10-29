import Foundation

// Outbound policy (design 32 D3): group policies, the per-node documents
// they expand into, the group-pair matrix, and the plan and convert answers.

/// A target selector (`model.TargetSelector`): named nodes, node groups, the
/// whole fleet, and nodes left out.
public struct NetworkingTargetSelector: Decodable, Hashable, Sendable {
    public var nodes: [String]
    public var groups: [String]
    public var all: Bool
    public var exclude: [String]

    public init(nodes: [String] = [], groups: [String] = [], all: Bool = false, exclude: [String] = []) {
        self.nodes = nodes
        self.groups = groups
        self.all = all
        self.exclude = exclude
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        nodes = c.networkingStrings("nodes")
        groups = c.networkingStrings("groups")
        all = c.networkingBool("all")
        exclude = c.networkingStrings("exclude")
    }

    public var isEmpty: Bool { nodes.isEmpty && groups.isEmpty && !all }
}

/// One outbound policy (`groupPolicyView`).
public struct NetworkingGroupPolicy: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var scopeGroupID: String
    public var scopeGroupName: String
    public var rules: [NetRule]
    public var enabled: Bool
    public var priority: Int
    public var version: Int
    public var groupRuleCount: Int
    /// The effective target: the stored scope, or the one group `scope_group_id` stands for.
    public var target: NetworkingTargetSelector
    /// The target resolved now, limited to nodes this credential may read.
    public var targetNodeIDs: [String]
    /// The name, or a description of the target.
    public var label: String
    /// Named or excluded nodes a confined credential is not shown.
    public var hiddenTargetNodes: Int
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        id = try c.networkingRequired("id")
        name = c.networkingString("name")
        scopeGroupID = c.networkingString("scope_group_id")
        scopeGroupName = c.networkingString("scope_group_name")
        rules = try c.networkingList(NetRule.self, "rules")
        enabled = c.networkingBool("enabled")
        priority = c.networkingInt("priority")
        version = c.networkingInt("version")
        groupRuleCount = c.networkingInt("group_rule_count")
        let stored = try c.networkingObject(NetworkingTargetSelector.self, "scope")
        let target = try c.networkingObject(NetworkingTargetSelector.self, "target")
        self.target = target ?? stored ?? NetworkingTargetSelector(groups: scopeGroupID.isEmpty ? [] : [scopeGroupID])
        targetNodeIDs = c.networkingStrings("target_node_ids")
        label = c.networkingString("label")
        hiddenTargetNodes = c.networkingInt("hidden_target_nodes")
        createdAt = c.networkingDate("created_at")
        updatedAt = c.networkingDate("updated_at")
    }

    public var displayName: String {
        if !label.isEmpty { return label }
        return name.isEmpty ? id : name
    }

    public var activeRules: [NetRule] { rules.filter { !$0.disabled } }
}

/// How a node's outbound document came about.
public enum NetworkingNodePolicyKind: String, Sendable, Hashable, CaseIterable {
    /// Built from outbound policies by the group plan.
    case outbound
    /// Authored for this node alone; it can be converted.
    case manual
    /// No document: nothing filters this node's egress.
    case none

    public var word: String {
        switch self {
        case .outbound: "from outbound policies"
        case .manual: "manual policy"
        case .none: "no policy"
        }
    }

    public static func of(_ policy: NetPolicy?) -> NetworkingNodePolicyKind {
        guard let policy else { return .none }
        return policy.groupDerived ? .outbound : .manual
    }
}

/// Where a node's document stands against what is on the node.
public enum NetworkingPolicyState: String, Sendable, Hashable, CaseIterable {
    /// The last apply reported an error.
    case failed
    /// A plan exists that has not applied yet.
    case planned
    /// The last plan applied.
    case applied
    /// Never planned.
    case notPlanned
    /// The document is disabled.
    case off

    public var word: String {
        switch self {
        case .failed: "apply failed"
        case .planned: "planned, not applied"
        case .applied: "applied"
        case .notPlanned: "not planned yet"
        case .off: "disabled"
        }
    }

    /// The console's reading of a `netPolicyView`: an error first, then the
    /// enabled flag, then whether the last plan reached the node.
    public static func of(_ policy: NetPolicy) -> NetworkingPolicyState {
        if !policy.lastError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .failed }
        if !policy.enabled { return .off }
        if policy.lastPlanSHA.isEmpty { return .notPlanned }
        guard let applied = policy.lastAppliedAt else { return .planned }
        if let updated = policy.updatedAt, updated > applied.addingTimeInterval(1) { return .planned }
        return .applied
    }
}

/// One node on the Nodes view: its document (or none) and where it stands.
public struct NetworkingNodePolicyRow: Identifiable, Hashable, Sendable {
    public var nodeID: String
    public var nodeName: String
    public var policy: NetPolicy?

    public init(nodeID: String, nodeName: String, policy: NetPolicy?) {
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.policy = policy
    }

    public var id: String { nodeID }
    public var kind: NetworkingNodePolicyKind { NetworkingNodePolicyKind.of(policy) }
    public var state: NetworkingPolicyState? { policy.map(NetworkingPolicyState.of) }

    /// Every node with a document, then every other node the credential sees,
    /// so "no policy" is listed and not left out. Failed rows lead.
    public static func rows(policies: [NetPolicy], nodes: [(id: String, name: String)]) -> [NetworkingNodePolicyRow] {
        let byNode = Dictionary(policies.map { ($0.targetNodeID, $0) }, uniquingKeysWith: { first, _ in first })
        var names = Dictionary(nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for policy in policies where names[policy.targetNodeID] == nil {
            names[policy.targetNodeID] = policy.displayName
        }
        let rows = names.map { NetworkingNodePolicyRow(nodeID: $0.key, nodeName: $0.value, policy: byNode[$0.key]) }
        return rows.sorted { lhs, rhs in
            let left = rank(lhs), right = rank(rhs)
            if left != right { return left < right }
            return lhs.nodeName.localizedStandardCompare(rhs.nodeName) == .orderedAscending
        }
    }

    private static func rank(_ row: NetworkingNodePolicyRow) -> Int {
        switch row.state {
        case .failed: 0
        case .planned, .notPlanned: 1
        case .applied: 2
        case .off: 3
        case nil: 4
        }
    }
}

// MARK: Matrix

public struct NetworkingMatrixGroup: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var slug: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        id = try c.networkingRequired("id")
        name = c.networkingString("name")
        slug = c.networkingString("slug")
    }

    public var displayName: String { name.isEmpty ? id : name }
}

/// One group pair: what the rules from `from` to `to` say in this direction.
public struct NetworkingMatrixCell: Decodable, Hashable, Sendable {
    public var from: String
    public var to: String
    /// "allow" or "deny"; a pair with both is `mixed` and reads allow here.
    public var action: String
    public var protocols: [String]
    public var ports: [Int]
    public var ruleCount: Int
    public var mixed: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        from = c.networkingString("from")
        to = c.networkingString("to")
        action = c.networkingString("action")
        protocols = c.networkingStrings("protocols")
        ports = c.networkingInts("ports")
        ruleCount = c.networkingInt("rule_count")
        mixed = c.networkingBool("mixed")
    }

    public var allows: Bool { action.lowercased() == "allow" || mixed }

    /// "tcp 443, 8443", "any protocol, all ports".
    public var trafficText: String {
        let named = protocols.filter { $0 != "any" }
        guard !named.isEmpty else { return "any protocol" }
        let protos = named.joined(separator: "/")
        return ports.isEmpty ? "\(protos), all ports" : "\(protos) \(ports.map(String.init).joined(separator: ", "))"
    }
}

public struct NetworkingMatrixExternal: Decodable, Hashable, Sendable {
    public var from: String
    public var ruleCount: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        from = c.networkingString("from")
        ruleCount = c.networkingInt("rule_count")
    }
}

public struct NetworkingMatrixExcludedNode: Decodable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        id = c.networkingString("id")
        name = c.networkingString("name")
    }

    public var displayName: String { name.isEmpty ? id : name }
}

/// The members one policy leaves out of a row.
public struct NetworkingMatrixExclusion: Decodable, Hashable, Sendable {
    public var from: String
    public var policyID: String
    public var label: String
    public var nodes: [NetworkingMatrixExcludedNode]
    public var hidden: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        from = c.networkingString("from")
        policyID = c.networkingString("policy_id")
        label = c.networkingString("label")
        nodes = try c.networkingList(NetworkingMatrixExcludedNode.self, "nodes")
        hidden = c.networkingInt("hidden")
    }
}

public struct NetworkingMatrixFleetRow: Decodable, Hashable, Sendable {
    public var cells: [NetworkingMatrixCell]
    public var external: Int
    public var exclusions: [NetworkingMatrixExclusion]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        cells = try c.networkingList(NetworkingMatrixCell.self, "cells")
        external = c.networkingInt("external")
        exclusions = try c.networkingList(NetworkingMatrixExclusion.self, "exclusions")
    }
}

/// `GET /api/netpolicy/matrix?direction=` (`NetPolicyMatrix`).
public struct NetworkingMatrix: Decodable, Hashable, Sendable {
    public var direction: String
    public var groups: [NetworkingMatrixGroup]
    public var cells: [NetworkingMatrixCell]
    public var external: [NetworkingMatrixExternal]
    public var exclusions: [NetworkingMatrixExclusion]
    public var fleet: NetworkingMatrixFleetRow?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        direction = c.networkingString("direction")
        groups = try c.networkingList(NetworkingMatrixGroup.self, "groups")
        cells = try c.networkingList(NetworkingMatrixCell.self, "cells")
        external = try c.networkingList(NetworkingMatrixExternal.self, "external")
        exclusions = try c.networkingList(NetworkingMatrixExclusion.self, "exclusions")
        fleet = try c.networkingObject(NetworkingMatrixFleetRow.self, "fleet")
    }

    /// The matrix as a list, one row per source: the whole fleet first when
    /// a policy targets it, then each group a policy targets, by name.
    public var rows: [NetworkingMatrixRow] {
        let names = Dictionary(groups.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        var out: [NetworkingMatrixRow] = []
        if let fleet {
            out.append(NetworkingMatrixRow(sourceID: nil, sourceName: "Whole fleet", cells: fleet.cells, externalRules: fleet.external,
                                           exclusions: fleet.exclusions, groupCount: groups.count, names: names))
        }
        let sources = Set(cells.map(\.from) + external.map(\.from) + exclusions.map(\.from)).filter { !$0.isEmpty }
        let groupRows = sources.map { source in
            NetworkingMatrixRow(
                sourceID: source, sourceName: names[source] ?? source,
                cells: cells.filter { $0.from == source },
                externalRules: external.filter { $0.from == source }.reduce(0) { $0 + $1.ruleCount },
                exclusions: exclusions.filter { $0.from == source },
                groupCount: groups.count, names: names
            )
        }.sorted { $0.sourceName.localizedStandardCompare($1.sourceName) == .orderedAscending }
        return out + groupRows
    }
}

/// One source on the matrix list: "Asia edge can reach 3 of 5 groups".
public struct NetworkingMatrixRow: Identifiable, Hashable, Sendable {
    public struct Destination: Hashable, Sendable {
        public var groupID: String
        public var name: String
        public var cell: NetworkingMatrixCell
    }

    /// nil for the whole-fleet row.
    public var sourceID: String?
    public var sourceName: String
    public var destinations: [Destination]
    public var externalRules: Int
    public var exclusions: [NetworkingMatrixExclusion]
    public var groupCount: Int

    init(sourceID: String?, sourceName: String, cells: [NetworkingMatrixCell], externalRules: Int,
         exclusions: [NetworkingMatrixExclusion], groupCount: Int, names: [String: String]) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.destinations = cells.map { Destination(groupID: $0.to, name: names[$0.to] ?? $0.to, cell: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.externalRules = externalRules
        self.exclusions = exclusions
        self.groupCount = groupCount
    }

    public var id: String { sourceID ?? "_fleet" }
    public var reachable: Int { destinations.filter(\.cell.allows).count }
    public var excludedCount: Int { exclusions.reduce(0) { $0 + $1.nodes.count + $1.hidden } }

    /// "can reach 3 of 5 groups" (egress) or "is reached from 3 of 5 groups" (ingress).
    public func reachSentence(direction: String) -> String {
        let groups = groupCount == 1 ? "1 group" : "\(groupCount) groups"
        return direction == "ingress" ? "admits \(reachable) of \(groups)" : "can reach \(reachable) of \(groups)"
    }
}

// MARK: Plan and convert answers

/// `POST /api/group-policies/plan` (`GroupPolicyPlanResult`).
public struct NetworkingGroupPlanResult: Decodable, Hashable, Sendable {
    public struct Affected: Decodable, Hashable, Sendable {
        public var nodeID: String
        public var approvalID: String
        public var planSHA: String

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: LatticeCodingKey.self)
            nodeID = c.networkingString("node_id")
            approvalID = c.networkingString("approval_id")
            planSHA = c.networkingString("plan_sha")
        }
    }

    public struct Conflict: Decodable, Hashable, Sendable {
        public var nodeID: String
        public var reason: String

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: LatticeCodingKey.self)
            nodeID = c.networkingString("node_id")
            reason = c.networkingString("reason")
        }
    }

    public struct SelectorImpact: Decodable, Hashable, Sendable {
        public var groupID: String
        public var groupName: String
        public var uses: [String]
        public var policyIDs: [String]
        public var explicitMemberIDs: [String]
        public var selectorMemberIDs: [String]
        public var resolvedMemberIDs: [String]

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: LatticeCodingKey.self)
            groupID = c.networkingString("group_id")
            groupName = c.networkingString("group_name")
            uses = c.networkingStrings("uses")
            policyIDs = c.networkingStrings("policy_ids")
            explicitMemberIDs = c.networkingStrings("explicit_member_ids")
            selectorMemberIDs = c.networkingStrings("selector_member_ids")
            resolvedMemberIDs = c.networkingStrings("resolved_member_ids")
        }
    }

    public var affected: [Affected]
    public var conflicts: [Conflict]
    public var orphaned: [String]
    public var selectorImpacts: [SelectorImpact]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        affected = try c.networkingList(Affected.self, "affected")
        conflicts = try c.networkingList(Conflict.self, "conflicts")
        orphaned = c.networkingStrings("orphaned")
        selectorImpacts = try c.networkingList(SelectorImpact.self, "selector_impacts")
    }

    public static let orphanReason = "No enabled outbound policy covers this node any more. Its group-built policy was left in place; delete it on the web."

    /// The filing outcome: approvals filed, and every conflict and orphan as
    /// the refused half, so any of them reads as partial and never green.
    public func outcome(name: (String) -> String) -> WriteOutcome {
        let refused = conflicts.map { ObjectFailure(object: ObjectRef(kind: "node", id: $0.nodeID, name: name($0.nodeID)), reason: $0.reason) }
            + orphaned.map { ObjectFailure(object: ObjectRef(kind: "node", id: $0, name: name($0)), reason: Self.orphanReason) }
        if affected.isEmpty && refused.isEmpty {
            return .done("Nothing to file: no node is covered by an enabled outbound policy")
        }
        var parts = [affected.count == 1 ? "1 plan filed" : "\(affected.count) plans filed"]
        if !conflicts.isEmpty { parts.append(conflicts.count == 1 ? "1 conflict" : "\(conflicts.count) conflicts") }
        if !orphaned.isEmpty { parts.append(orphaned.count == 1 ? "1 orphaned node" : "\(orphaned.count) orphaned nodes") }
        var notes = [parts.joined(separator: ", ")]
        for impact in selectorImpacts {
            let group = impact.groupName.isEmpty ? impact.groupID : impact.groupName
            let members = impact.resolvedMemberIDs.count == 1 ? "1 member" : "\(impact.resolvedMemberIDs.count) members"
            notes.append("\(group) matches by selector (\(members) now). If a node's tags, role or location change, plan again before approving.")
        }
        return .filed(approvalIDs: affected.map(\.approvalID).filter { !$0.isEmpty }, refused: refused, notes: notes)
    }
}

/// `POST /api/netpolicy/convert` (`NetPolicyConvertResult`).
public struct NetworkingConvertResult: Decodable, Sendable {
    public var groupPolicy: NetworkingGroupPolicy
    /// nil when the converted policy is disabled, so nothing was planned.
    public var approval: Approval?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        guard let policy = try c.networkingObject(NetworkingGroupPolicy.self, "group_policy") else {
            throw DecodingError.keyNotFound(LatticeCodingKey("group_policy"), .init(codingPath: c.codingPath, debugDescription: "group_policy is required"))
        }
        groupPolicy = policy
        approval = try c.networkingObject(Approval.self, "approval")
    }
}
