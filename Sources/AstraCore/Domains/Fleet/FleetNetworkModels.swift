import Foundation

// `GET /api/nodes/network?node_id=&rules=1` (server_node_network.go): one
// read that answers "what applies to this node". Each section is refused
// whole, naming the scope, when the caller cannot read it.

/// A section's readability: `ok` or `refused` with the missing scope.
public struct FleetNetworkSectionState: Equatable, Hashable, Sendable {
    public var state: String
    public var scope: String
    public var reason: String

    public init(state: String = "ok", scope: String = "", reason: String = "") {
        self.state = state
        self.scope = scope
        self.reason = reason
    }

    public var isRefused: Bool { state == "refused" }
}

private struct SectionFields: Decodable {
    var state: String?
    var scope: String?
    var reason: String?
}

public struct FleetNetworkRef: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String = "") {
        self.id = id
        self.name = name
    }

    public var displayName: String { name.isEmpty ? id : name }

    enum CodingKeys: String, CodingKey { case id, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

public struct FleetNetworkSecurityGroup: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var rules: Int
    public var via: FleetNetworkRef?
    public var state: String
    public var reason: String

    public var displayName: String { name.isEmpty ? id : name }

    enum CodingKeys: String, CodingKey { case id, name, rules, via, state, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        rules = try c.decodeIfPresent(Int.self, forKey: .rules) ?? 0
        via = try c.decodeIfPresent(FleetNetworkRef.self, forKey: .via)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

/// A port another feature opens in the inbound table (self-host DNS, beacon).
public struct FleetNetworkPort: Decodable, Equatable, Hashable, Sendable {
    public var source: String
    public var label: String
    public var protocols: [String]
    public var port: Int
    public var exposure: String

    enum CodingKeys: String, CodingKey { case source, label, protocols, port, exposure }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        protocols = try c.decodeIfPresent([String].self, forKey: .protocols) ?? []
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        exposure = try c.decodeIfPresent(String.self, forKey: .exposure) ?? ""
    }
}

public struct FleetNetworkInbound: Decodable, Equatable, Sendable {
    public var section: FleetNetworkSectionState
    /// Who writes the inbound table here: `netguard`, `legacy` or `none`.
    public var firewall: String
    public var binding: String
    public var zones: [FleetNetworkRef]
    public var securityGroups: [FleetNetworkSecurityGroup]
    public var derivedSecurityGroups: [FleetNetworkSecurityGroup]
    public var extraPorts: [FleetNetworkPort]
    public var driftState: String

    enum CodingKeys: String, CodingKey {
        case firewall, binding, zones
        case securityGroups = "security_groups", derivedSecurityGroups = "derived_security_groups"
        case extraPorts = "extra_ports", driftState = "drift_state"
    }

    public init(from decoder: Decoder) throws {
        let fields = try SectionFields(from: decoder)
        section = FleetNetworkSectionState(state: fields.state ?? "ok", scope: fields.scope ?? "", reason: fields.reason ?? "")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firewall = try c.decodeIfPresent(String.self, forKey: .firewall) ?? ""
        binding = try c.decodeIfPresent(String.self, forKey: .binding) ?? ""
        zones = try c.decodeIfPresent([FleetNetworkRef].self, forKey: .zones) ?? []
        securityGroups = try c.decodeIfPresent([FleetNetworkSecurityGroup].self, forKey: .securityGroups) ?? []
        derivedSecurityGroups = try c.decodeIfPresent([FleetNetworkSecurityGroup].self, forKey: .derivedSecurityGroups) ?? []
        extraPorts = try c.decodeIfPresent([FleetNetworkPort].self, forKey: .extraPorts) ?? []
        driftState = try c.decodeIfPresent(String.self, forKey: .driftState) ?? ""
    }

    /// "NetGuard", "Legacy firewall" or "No inbound firewall".
    public var firewallTitle: String {
        switch firewall {
        case "netguard": "NetGuard"
        case "legacy": "Legacy firewall"
        case "", "none": "No inbound firewall"
        default: firewall
        }
    }
}

/// One outbound policy whose target names the node.
public struct FleetNetworkPolicy: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var label: String
    public var priority: Int
    public var enabled: Bool
    /// `named`, `group` or `fleet`.
    public var reach: String
    public var viaGroups: [FleetNetworkRef]
    /// `applies`, `disabled`, `excluded`, `blocked` or empty.
    public var state: String
    public var rules: Int
    public var allow: Int
    public var deny: Int

    public var displayName: String { [name, label, id].first { !$0.isEmpty } ?? id }

    enum CodingKeys: String, CodingKey {
        case id, name, label, priority, enabled, reach, state, rules, allow, deny
        case viaGroups = "via_groups"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        reach = try c.decodeIfPresent(String.self, forKey: .reach) ?? ""
        viaGroups = try c.decodeIfPresent([FleetNetworkRef].self, forKey: .viaGroups) ?? []
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        rules = try c.decodeIfPresent(Int.self, forKey: .rules) ?? 0
        allow = try c.decodeIfPresent(Int.self, forKey: .allow) ?? 0
        deny = try c.decodeIfPresent(Int.self, forKey: .deny) ?? 0
    }

    /// "Applies through group Asia edge", in row words.
    public var reachSentence: String {
        switch reach {
        case "named": "Names this node"
        case "group":
            viaGroups.isEmpty ? "Through a node group" : "Through \(viaGroups.map(\.displayName).joined(separator: ", "))"
        case "fleet": "Whole fleet"
        default: reach
        }
    }
}

public struct FleetNetworkNodePolicy: Decodable, Equatable, Sendable {
    public var enabled: Bool
    public var rules: Int
    public var lastAppliedAt: Date?

    enum CodingKeys: String, CodingKey { case enabled, rules, lastAppliedAt = "last_applied_at" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        rules = try c.decodeIfPresent(Int.self, forKey: .rules) ?? 0
        lastAppliedAt = fleetDate(try DateValue.decodeIfPresent(from: c, forKey: .lastAppliedAt))
    }
}

public struct FleetNetworkOutbound: Decodable, Equatable, Sendable {
    public var section: FleetNetworkSectionState
    /// `policies`, `manual`, `orphan` or `none`.
    public var source: String
    public var defaultDrop: Bool
    public var policies: [FleetNetworkPolicy]
    public var manual: FleetNetworkNodePolicy?
    public var orphan: FleetNetworkNodePolicy?

    enum CodingKeys: String, CodingKey { case source, policies, manual, orphan, defaultDrop = "default_drop" }

    public init(from decoder: Decoder) throws {
        let fields = try SectionFields(from: decoder)
        section = FleetNetworkSectionState(state: fields.state ?? "ok", scope: fields.scope ?? "", reason: fields.reason ?? "")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        defaultDrop = try c.decodeIfPresent(Bool.self, forKey: .defaultDrop) ?? false
        policies = try c.decodeIfPresent([FleetNetworkPolicy].self, forKey: .policies) ?? []
        manual = try c.decodeIfPresent(FleetNetworkNodePolicy.self, forKey: .manual)
        orphan = try c.decodeIfPresent(FleetNetworkNodePolicy.self, forKey: .orphan)
    }

    /// The policy that decides this node's outbound table: the manual
    /// document when there is one, else the applying policies.
    public var effectiveTitle: String {
        switch source {
        case "manual": "Manual node policy"
        case "orphan": "Orphaned group policy"
        case "policies":
            applying.count == 1 ? applying[0].displayName : "\(applying.count) outbound policies"
        default: "No outbound policy"
        }
    }

    public var applying: [FleetNetworkPolicy] { policies.filter { $0.state == "applies" } }

    /// Rules that reach this node from the policies that apply, or the manual document.
    public var ruleCount: Int {
        if source == "manual", let manual { return manual.rules }
        if source == "orphan", let orphan { return orphan.rules }
        return applying.reduce(0) { $0 + $1.rules }
    }
}

public struct FleetNetworkAccess: Decodable, Equatable, Sendable {
    public var section: FleetNetworkSectionState
    public var enrolled: Bool
    public var posture: String
    public var knockRequired: Bool
    public var stage: String
    public var revertArmed: Bool

    enum CodingKeys: String, CodingKey {
        case enrolled, posture, stage
        case knockRequired = "knock_required", revertArmed = "revert_armed"
    }

    public init(from decoder: Decoder) throws {
        let fields = try SectionFields(from: decoder)
        section = FleetNetworkSectionState(state: fields.state ?? "ok", scope: fields.scope ?? "", reason: fields.reason ?? "")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enrolled = try c.decodeIfPresent(Bool.self, forKey: .enrolled) ?? false
        posture = try c.decodeIfPresent(String.self, forKey: .posture) ?? ""
        knockRequired = try c.decodeIfPresent(Bool.self, forKey: .knockRequired) ?? false
        stage = try c.decodeIfPresent(String.self, forKey: .stage) ?? ""
        revertArmed = try c.decodeIfPresent(Bool.self, forKey: .revertArmed) ?? false
    }
}

public struct FleetNetworkMesh: Decodable, Equatable, Sendable {
    public var section: FleetNetworkSectionState
    public var address: String
    public var listenPort: Int
    public var endpoint: String
    public var ready: Bool
    public var missing: [String]
    public var peers: Int
    public var peersRefused: String

    enum CodingKeys: String, CodingKey {
        case address, endpoint, ready, missing, peers
        case listenPort = "listen_port", peersRefused = "peers_refused"
    }

    public init(from decoder: Decoder) throws {
        let fields = try SectionFields(from: decoder)
        section = FleetNetworkSectionState(state: fields.state ?? "ok", scope: fields.scope ?? "", reason: fields.reason ?? "")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        listenPort = try c.decodeIfPresent(Int.self, forKey: .listenPort) ?? 0
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        ready = try c.decodeIfPresent(Bool.self, forKey: .ready) ?? false
        missing = try c.decodeIfPresent([String].self, forKey: .missing) ?? []
        peers = try c.decodeIfPresent(Int.self, forKey: .peers) ?? 0
        peersRefused = try c.decodeIfPresent(String.self, forKey: .peersRefused) ?? ""
    }
}

public struct FleetNetworkGroup: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String

    enum CodingKeys: String, CodingKey { case id, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

public struct FleetNetworkGroups: Decodable, Equatable, Sendable {
    public var section: FleetNetworkSectionState
    public var items: [FleetNetworkGroup]

    enum CodingKeys: String, CodingKey { case items }

    public init(from decoder: Decoder) throws {
        let fields = try SectionFields(from: decoder)
        section = FleetNetworkSectionState(state: fields.state ?? "ok", scope: fields.scope ?? "", reason: fields.reason ?? "")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([FleetNetworkGroup].self, forKey: .items) ?? []
    }
}

/// One column of "Show rules": what would compile now, or what last applied.
public struct FleetNetworkRuleset: Decodable, Equatable, Sendable {
    /// `ok`, `refused`, `none` or `error`.
    public var state: String
    public var composer: String
    public var sha256: String
    public var ruleset: String
    public var scope: String
    public var reason: String

    enum CodingKeys: String, CodingKey { case state, composer, sha256, ruleset, scope, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "none"
        composer = try c.decodeIfPresent(String.self, forKey: .composer) ?? ""
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        ruleset = try c.decodeIfPresent(String.self, forKey: .ruleset) ?? ""
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }

    /// The ruleset's rules, one per line, without blank lines, braces and the chain's hook line.
    public var ruleLines: [String] {
        ruleset.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "}" && !$0.hasSuffix("{") && !$0.hasPrefix("type ") }
    }
}

public struct FleetNetworkOwner: Decodable, Equatable, Hashable, Sendable {
    public var kind: String
    public var state: String

    enum CodingKeys: String, CodingKey { case kind, state }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
    }
}

public struct FleetNetworkTable: Decodable, Equatable, Sendable, Identifiable {
    public var section: FleetNetworkSectionState
    public var table: String
    public var owners: [FleetNetworkOwner]
    public var compileNow: FleetNetworkRuleset?
    public var lastApplied: FleetNetworkRuleset?
    public var replanPending: Bool
    public var rulesWithheld: String

    public var id: String { table }

    enum CodingKeys: String, CodingKey {
        case table, owners
        case compileNow = "compile_now", lastApplied = "last_applied"
        case replanPending = "replan_pending", rulesWithheld = "rules_withheld"
    }

    public init(from decoder: Decoder) throws {
        let fields = try SectionFields(from: decoder)
        section = FleetNetworkSectionState(state: fields.state ?? "ok", scope: fields.scope ?? "", reason: fields.reason ?? "")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        table = try c.decodeIfPresent(String.self, forKey: .table) ?? ""
        owners = try c.decodeIfPresent([FleetNetworkOwner].self, forKey: .owners) ?? []
        compileNow = try c.decodeIfPresent(FleetNetworkRuleset.self, forKey: .compileNow)
        lastApplied = try c.decodeIfPresent(FleetNetworkRuleset.self, forKey: .lastApplied)
        replanPending = try c.decodeIfPresent(Bool.self, forKey: .replanPending) ?? false
        rulesWithheld = try c.decodeIfPresent(String.self, forKey: .rulesWithheld) ?? ""
    }

    /// "Outbound policy" for `inet lattice_policy`, and so on.
    public var title: String {
        switch table {
        case "inet lattice_guard": "Inbound firewall"
        case "inet lattice_policy": "Outbound policy"
        case "inet lattice_knock": "SSH Guard knock"
        default: table
        }
    }
}

public struct FleetNodeNetworkView: Decodable, Equatable, Sendable {
    public var nodeID: String
    public var nodeName: String
    public var generatedAt: Date?
    public var inbound: FleetNetworkInbound?
    public var outbound: FleetNetworkOutbound?
    public var access: FleetNetworkAccess?
    public var mesh: FleetNetworkMesh?
    public var groups: FleetNetworkGroups?
    public var tables: [FleetNetworkTable]

    enum CodingKeys: String, CodingKey {
        case inbound, outbound, access, mesh, groups, tables
        case nodeID = "node_id", nodeName = "node_name", generatedAt = "generated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        nodeName = try c.decodeIfPresent(String.self, forKey: .nodeName) ?? ""
        generatedAt = fleetDate(try DateValue.decodeIfPresent(from: c, forKey: .generatedAt))
        inbound = try c.decodeIfPresent(FleetNetworkInbound.self, forKey: .inbound)
        outbound = try c.decodeIfPresent(FleetNetworkOutbound.self, forKey: .outbound)
        access = try c.decodeIfPresent(FleetNetworkAccess.self, forKey: .access)
        mesh = try c.decodeIfPresent(FleetNetworkMesh.self, forKey: .mesh)
        groups = try c.decodeIfPresent(FleetNetworkGroups.self, forKey: .groups)
        tables = try c.decodeIfPresent([FleetNetworkTable].self, forKey: .tables) ?? []
    }

    /// The outbound table's rules as they would compile now, for the rules list.
    public var outboundRules: [String] {
        tables.first { $0.table == "inet lattice_policy" }?.compileNow?.ruleLines ?? []
    }
}
