import Foundation

// Node groups: `GET /api/groups` (server_groups.go `groupView`), `GET
// /api/groups/used-by`, and the member and delete writes.

/// A dynamic group's selector. Populated dimensions AND together; values
/// within a dimension OR together (groups/resolve.go `selectorMatches`).
public struct FleetGroupSelector: Codable, Equatable, Hashable, Sendable {
    public var matchTagsAny: [String]
    public var matchRoles: [String]
    public var matchCountry: [String]
    public var matchContinent: [String]

    public init(matchTagsAny: [String] = [], matchRoles: [String] = [], matchCountry: [String] = [], matchContinent: [String] = []) {
        self.matchTagsAny = matchTagsAny
        self.matchRoles = matchRoles
        self.matchCountry = matchCountry
        self.matchContinent = matchContinent
    }

    enum CodingKeys: String, CodingKey {
        case matchTagsAny = "match_tags_any", matchRoles = "match_roles"
        case matchCountry = "match_country", matchContinent = "match_continent"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matchTagsAny = try c.decodeIfPresent([String].self, forKey: .matchTagsAny) ?? []
        matchRoles = try c.decodeIfPresent([String].self, forKey: .matchRoles) ?? []
        matchCountry = try c.decodeIfPresent([String].self, forKey: .matchCountry) ?? []
        matchContinent = try c.decodeIfPresent([String].self, forKey: .matchContinent) ?? []
    }

    public var isEmpty: Bool { matchTagsAny.isEmpty && matchRoles.isEmpty && matchCountry.isEmpty && matchContinent.isEmpty }

    /// "tag edge or asia, and role relay", the selector as one sentence.
    public var sentence: String {
        var parts: [String] = []
        func clause(_ noun: String, _ values: [String]) {
            guard !values.isEmpty else { return }
            parts.append("\(noun) \(values.joined(separator: " or "))")
        }
        clause(matchTagsAny.count == 1 ? "tag" : "any tag of", matchTagsAny)
        clause("role", matchRoles)
        clause("country", matchCountry)
        clause("continent", matchContinent)
        return parts.isEmpty ? "matches no nodes" : parts.joined(separator: ", and ")
    }
}

/// How many resolved members are in each state (`groupRollup`). Degraded
/// counts as online; never reported counts as offline.
public struct FleetGroupRollup: Decodable, Equatable, Hashable, Sendable {
    public var total: Int
    public var online: Int
    public var offline: Int
    public var disabled: Int

    public init(total: Int = 0, online: Int = 0, offline: Int = 0, disabled: Int = 0) {
        self.total = total
        self.online = online
        self.offline = offline
        self.disabled = disabled
    }

    enum CodingKeys: String, CodingKey { case total, online, offline, disabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        online = try c.decodeIfPresent(Int.self, forKey: .online) ?? 0
        offline = try c.decodeIfPresent(Int.self, forKey: .offline) ?? 0
        disabled = try c.decodeIfPresent(Int.self, forKey: .disabled) ?? 0
    }

    /// "12 nodes, 1 offline", or "Empty".
    public var sentence: String {
        guard total > 0 else { return "No members" }
        var parts = [total == 1 ? "1 node" : "\(total) nodes"]
        if offline > 0 { parts.append("\(offline) offline") }
        if disabled > 0 { parts.append("\(disabled) disabled") }
        return parts.joined(separator: ", ")
    }
}

public struct FleetGroupView: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var slug: String
    public var description: String
    public var color: String
    public var parentID: String
    public var order: Int
    /// Static members the caller may read.
    public var members: [String]
    public var selector: FleetGroupSelector?
    public var system: Bool
    public var resolvedMembers: [String]
    public var rollup: FleetGroupRollup

    public init(id: String, name: String, members: [String] = [], selector: FleetGroupSelector? = nil,
                resolvedMembers: [String] = [], rollup: FleetGroupRollup = FleetGroupRollup(), system: Bool = false) {
        self.id = id
        self.name = name
        self.slug = ""
        self.description = ""
        self.color = ""
        self.parentID = ""
        self.order = 0
        self.members = members
        self.selector = selector
        self.system = system
        self.resolvedMembers = resolvedMembers
        self.rollup = rollup
    }

    enum CodingKeys: String, CodingKey {
        case id, name, slug, description, color, order, members, selector, system, rollup
        case parentID = "parent_id", resolvedMembers = "resolved_members"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? ""
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID) ?? ""
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        members = try c.decodeIfPresent([String].self, forKey: .members) ?? []
        selector = try c.decodeIfPresent(FleetGroupSelector.self, forKey: .selector)
        system = try c.decodeIfPresent(Bool.self, forKey: .system) ?? false
        resolvedMembers = try c.decodeIfPresent([String].self, forKey: .resolvedMembers) ?? []
        rollup = try c.decodeIfPresent(FleetGroupRollup.self, forKey: .rollup) ?? FleetGroupRollup()
    }

    public var displayName: String { name.isEmpty ? id : name }

    /// A group with a selector resolves its members; one without is static.
    public var kind: FleetGroupKind {
        switch (selector.map { !$0.isEmpty } ?? false, !members.isEmpty) {
        case (true, true): .mixed
        case (true, false): .selector
        default: .staticMembers
        }
    }

    /// Static members can be added and removed from the phone; selector
    /// members follow the selector and change on web.
    public var acceptsStaticMembers: Bool { kind != .selector }
}

public enum FleetGroupKind: String, Sendable, Hashable {
    case selector, staticMembers = "static", mixed

    public var word: String {
        switch self {
        case .selector: "selector"
        case .staticMembers: "static"
        case .mixed: "selector and static"
        }
    }
}

public struct FleetGroupsResponse: Decodable, Equatable, Sendable {
    public var groups: [FleetGroupView]
    public var ungroupedMembers: [String]
    public var ungroupedRollup: FleetGroupRollup

    public init(groups: [FleetGroupView], ungroupedMembers: [String] = [], ungroupedRollup: FleetGroupRollup = FleetGroupRollup()) {
        self.groups = groups
        self.ungroupedMembers = ungroupedMembers
        self.ungroupedRollup = ungroupedRollup
    }

    private struct Ungrouped: Decodable {
        var resolvedMembers: [String]?
        var rollup: FleetGroupRollup?
        enum CodingKeys: String, CodingKey { case rollup, resolvedMembers = "resolved_members" }
    }

    enum CodingKeys: String, CodingKey { case groups, ungrouped }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([FleetGroupView].self, forKey: .groups) ?? []
        let ungrouped = try c.decodeIfPresent(Ungrouped.self, forKey: .ungrouped)
        ungroupedMembers = ungrouped?.resolvedMembers ?? []
        ungroupedRollup = ungrouped?.rollup ?? FleetGroupRollup()
    }

    public func name(for id: String) -> String? {
        groups.first { $0.id == id }?.displayName
    }
}

/// One object that names a group (`groupUse`).
public struct FleetGroupUse: Decodable, Equatable, Hashable, Sendable, Identifiable {
    /// `outbound_policy`, `check` or `security_group_binding`.
    public var kind: String
    public var id: String
    public var label: String
    /// `target`, `remote`, `source` or `source_and_target`.
    public var role: String

    public init(kind: String, id: String, label: String, role: String) {
        self.kind = kind
        self.id = id
        self.label = label
        self.role = role
    }

    enum CodingKeys: String, CodingKey { case kind, id, label, role }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
    }

    public var kindTitle: String {
        switch kind {
        case "outbound_policy": "Outbound policy"
        case "check": "Check"
        case "security_group_binding": "Security group binding"
        default: kind.replacingOccurrences(of: "_", with: " ")
        }
    }

    public var roleWord: String {
        switch role {
        case "target": "applies to this group"
        case "remote": "a rule points at this group"
        case "source": "runs from this group"
        case "source_and_target": "runs from and to this group"
        default: role
        }
    }
}

public struct FleetGroupUsedBy: Decodable, Equatable, Sendable {
    public var groupID: String
    public var usedBy: [FleetGroupUse]
    /// Uses of kinds this token cannot read, counted only.
    public var hidden: Int

    public init(groupID: String, usedBy: [FleetGroupUse], hidden: Int = 0) {
        self.groupID = groupID
        self.usedBy = usedBy
        self.hidden = hidden
    }

    enum CodingKeys: String, CodingKey { case hidden, groupID = "group_id", usedBy = "used_by" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID) ?? ""
        usedBy = try c.decodeIfPresent([FleetGroupUse].self, forKey: .usedBy) ?? []
        hidden = try c.decodeIfPresent(Int.self, forKey: .hidden) ?? 0
    }

    /// The server refuses to delete a group anything still names.
    public var blocksDelete: Bool { !usedBy.isEmpty || hidden > 0 }
}

/// `POST /api/groups/members`: ids to add and remove from the static list.
public struct FleetGroupMembersRequest: Encodable, Equatable, Sendable {
    public var groupID: String
    public var add: [String]
    public var remove: [String]

    public init(groupID: String, add: [String] = [], remove: [String] = []) {
        self.groupID = groupID
        self.add = add
        self.remove = remove
    }

    enum CodingKeys: String, CodingKey { case add, remove, groupID = "group_id" }
}

struct FleetGroupDeleteRequest: Encodable {
    var id: String
}
