import Foundation

// Pure derivations behind the Fleet screens, kept out of the views so the
// checks can pin them.

/// How the Nodes list groups its rows (the toolbar Group menu).
public enum FleetNodeGroupBy: String, Sendable, Hashable, CaseIterable, Codable {
    case none, status, region, provider, group, tag

    public var title: String {
        switch self {
        case .none: "None"
        case .status: "Status"
        case .region: "Region"
        case .provider: "Provider"
        case .group: "Group"
        case .tag: "Tag"
        }
    }
}

public struct FleetNodeSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// The honesty state when the list groups by status.
    public var honesty: NodeHonesty?
    public var records: [FleetNodeRecord]

    public init(id: String, title: String, honesty: NodeHonesty? = nil, records: [FleetNodeRecord]) {
        self.id = id
        self.title = title
        self.honesty = honesty
        self.records = records
    }
}

public enum FleetNodeGrouping {
    /// Worst first, then by name, the order every node list uses inside a section.
    public static func ordered(_ records: [FleetNodeRecord]) -> [FleetNodeRecord] {
        records.sorted { a, b in
            let ra = a.node.honesty.severityRank, rb = b.node.honesty.severityRank
            if ra != rb { return ra < rb }
            return a.node.displayName.localizedStandardCompare(b.node.displayName) == .orderedAscending
        }
    }

    public static func statusTitle(_ honesty: NodeHonesty) -> String {
        switch honesty {
        case .offline: "Offline"
        case .degraded: "Degraded"
        case .neverReported: "Never reported"
        case .online: "Online"
        case .disabled: "Disabled"
        }
    }

    /// Sections for a grouping. Status sections run worst first (offline,
    /// degraded, never reported, online, disabled); other groupings run by
    /// name with the "no value" section last. A node with several tags or
    /// groups appears under each.
    public static func sections(_ records: [FleetNodeRecord], by groupBy: FleetNodeGroupBy,
                                groupName: (String) -> String? = { _ in nil }) -> [FleetNodeSection] {
        switch groupBy {
        case .none:
            return records.isEmpty ? [] : [FleetNodeSection(id: "all", title: "Nodes", records: ordered(records))]
        case .status:
            let byState = Dictionary(grouping: records, by: { $0.node.honesty })
            return NodeHonesty.allCases.sorted { $0.severityRank < $1.severityRank }.compactMap { honesty in
                guard let members = byState[honesty], !members.isEmpty else { return nil }
                return FleetNodeSection(id: honesty.rawValue, title: statusTitle(honesty), honesty: honesty, records: ordered(members))
            }
        case .region:
            return keyed(records, missing: "No location") { record in
                [record.node.geo?.city ?? record.node.geo?.region].compactMap { $0 }.filter { !$0.isEmpty }
            }
        case .provider:
            return keyed(records, missing: "No provider") { record in
                [record.facts.provider.isEmpty ? record.facts.asOrg : record.facts.provider].filter { !$0.isEmpty }
            }
        case .group:
            return keyed(records, missing: "No group") { record in
                record.node.groupIDs.map { groupName($0) ?? $0 }
            }
        case .tag:
            return keyed(records, missing: "No tags") { $0.node.tags }
        }
    }

    private static func keyed(_ records: [FleetNodeRecord], missing: String, keys: (FleetNodeRecord) -> [String]) -> [FleetNodeSection] {
        var buckets: [String: [FleetNodeRecord]] = [:]
        var none: [FleetNodeRecord] = []
        for record in records {
            let values = keys(record)
            if values.isEmpty { none.append(record) }
            for value in Set(values) { buckets[value, default: []].append(record) }
        }
        var sections = buckets.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
            FleetNodeSection(id: "k:\(key)", title: key, records: ordered(buckets[key] ?? []))
        }
        if !none.isEmpty { sections.append(FleetNodeSection(id: "none", title: missing, records: ordered(none))) }
        return sections
    }
}

/// The Nodes header row: "35 nodes, 33 online", or for a token with a node
/// allowlist "Confined to 12 nodes, 11 online" (section 6.12).
public enum FleetHeader {
    public static func sentence(_ nodes: [LatticeNode], allowlist: [String]) -> String {
        let online = nodes.filter { $0.honesty == .online }.count
        let count = nodes.count == 1 ? "1 node" : "\(nodes.count) nodes"
        if !allowlist.isEmpty {
            let confined = allowlist.count == 1 ? "1 node" : "\(allowlist.count) nodes"
            return "Confined to \(confined). \(online) of \(nodes.count) visible nodes online"
        }
        return "\(count), \(online) online"
    }

    /// "2 possible duplicate nodes"
    public static func duplicates(_ count: Int) -> String {
        count == 1 ? "1 possible duplicate node" : "\(count) possible duplicate nodes"
    }
}

/// How far a node's agent is behind. There is no agent target in the M2
/// reads (agent update releases belong to M7), so "behind" counts the newer
/// agent versions running elsewhere in the fleet.
public enum FleetAgentVersion {
    public static func newer(than version: String?, in fleet: [String?]) -> Int {
        guard let version, !version.isEmpty else { return 0 }
        let distinct = Set(fleet.compactMap { $0 }.filter { !$0.isEmpty })
        return distinct.filter { LatticeQueryValues.compareVersions($0, version) > 0 }.count
    }

    public static func newest(in fleet: [String?]) -> String? {
        fleet.compactMap { $0 }.filter { !$0.isEmpty }.max { LatticeQueryValues.compareVersions($0, $1) < 0 }
    }
}

/// The node delete dry run, grouped by consequence (M2-09).
public enum FleetDeleteReport {
    /// Counters by group, each with its label, in display order.
    public static let groups: [(group: String, counters: [(key: String, label: String)])] = [
        ("Services", [
            ("managed_lines", "Managed lines"),
            ("line_chain_definitions_deleted", "Line-chain definitions"),
            ("line_chain_attempts_released", "Line-chain attempts released"),
            ("line_chain_targets_drifted", "Line-chain targets that drift"),
            ("line_chain_lease_conflicts", "Line-chain lease conflicts"),
            ("tunnels", "Tunnels"),
            ("dns_deployments", "DNS deployments"),
            ("geo_routing_deleted", "Geo routes deleted"),
            ("geo_routing_stripped", "Geo routes changed"),
            ("ddns_profiles", "DDNS profiles"),
            ("proxy_node_profiles", "Proxy node profiles"),
            ("terminal_sessions", "Open terminal sessions"),
        ]),
        ("Configuration", [
            ("net_policies", "Net policies"),
            ("net_peer_rules_stripped", "Peer rules removed"),
            ("group_policy_rules_stripped", "Group policy rules removed"),
            ("group_policy_scopes_stripped", "Group policy targets removed"),
            ("approvals", "Approvals"),
            ("machine_profiles", "Machine profiles"),
            ("monitors_stripped", "Monitors"),
            ("groups", "Group memberships"),
            ("agent_update_policies", "Agent update policies"),
            ("log_sources", "Log sources"),
            ("nft_inputs", "Firewall inputs"),
            ("guard_bindings", "Firewall bindings"),
            ("singbox_liveness", "sing-box liveness records"),
            ("proxy_drift_cleared", "Proxy drift records"),
        ]),
        ("History", [
            ("tasks_deleted", "Tasks deleted"),
            ("tasks_stripped", "Tasks this node leaves"),
            ("task_results", "Task results"),
            ("monitor_results", "Check results"),
            ("proxy_usage_snapshots", "Proxy usage snapshots"),
            ("guard_reality_snapshots", "Firewall snapshots"),
        ]),
    ]

    /// Counters that mean other services depend on the node; any of them
    /// makes the operator type the node name.
    public static let dependencyKeys = [
        "dns_deployments", "geo_routing_deleted", "geo_routing_stripped", "tunnels",
        "managed_lines", "line_chain_definitions_deleted",
    ]

    public static func requiresTypedName(_ summary: FleetNodeDeleteSummary) -> Bool {
        dependencyKeys.contains { summary[$0] > 0 }
    }

    /// Every non-zero counter, then the history the delete always purges.
    public static func lines(_ summary: FleetNodeDeleteSummary) -> [DetailLine] {
        var lines: [DetailLine] = []
        var known = Set<String>()
        for (group, counters) in groups {
            for (key, label) in counters {
                known.insert(key)
                let value = summary[key]
                if value > 0 { lines.append(DetailLine(label: label, value: String(value), group: group)) }
            }
        }
        // A counter this app does not know yet is still shown, by its key.
        let deleteOnly: Set<String> = ["log_store_purged", "log_store_purge_errs", "metrics_series_purged"]
        for key in summary.counters.keys.sorted() where !known.contains(key) && !deleteOnly.contains(key) && summary[key] > 0 {
            lines.append(DetailLine(label: key.replacingOccurrences(of: "_", with: " "), value: String(summary[key]), group: "Other"))
        }
        if summary["log_sources"] > 0 {
            lines.append(DetailLine(label: "Logs", value: "Purged from this node's log sources", group: "History"))
        }
        lines.append(DetailLine(label: "Metrics", value: "Purged with the node", group: "History"))
        return lines
    }

    /// The counters, in key order: a change between the review and the
    /// send stops the write.
    public static func fingerprint(_ summary: FleetNodeDeleteSummary) -> String {
        let deleteOnly: Set<String> = ["log_store_purged", "log_store_purge_errs", "metrics_series_purged"]
        return summary.counters.keys.sorted().filter { !deleteOnly.contains($0) }.map { "\($0)=\(summary[$0])" }.joined(separator: ",")
    }

    public static func report(_ summary: FleetNodeDeleteSummary) -> DryRunReport {
        DryRunReport(lines: lines(summary), blocking: !summary.found, fingerprint: fingerprint(summary))
    }

    /// The outcome of a delete that answered: a purge failure is partial.
    public static func outcome(_ summary: FleetNodeDeleteSummary, node: ObjectRef) -> WriteOutcome {
        let errors = summary.logStorePurgeErrors
        guard errors > 0 else { return .done("Deleted node \(node.name)") }
        let stores = errors == 1 ? "1 log store" : "\(errors) log stores"
        let failure = ObjectFailure(object: ObjectRef(kind: "log store", id: "\(node.id):logs", name: "Log stores of \(node.name)"),
                                    reason: "\(stores) could not be purged")
        return .partial(succeeded: [node], failed: [failure], message: "Node deleted; \(stores) could not be purged")
    }
}

/// The worst paths a node takes part in, for its Overview.
public enum FleetPathPick {
    static func rank(_ state: PathDisplayState) -> Int {
        switch state {
        case .down: 0
        case .degraded: 1
        case .unknown: 2
        case .paused: 3
        case .up: 4
        }
    }

    public static func worst(_ response: PathsResponse, nodeID: String, limit: Int = 5) -> [PathView] {
        let mine = response.paths.filter { $0.source == nodeID || $0.targetNode == nodeID }
        return Array(mine.sorted { a, b in
            let ra = rank(a.displayState(judgesDegraded: response.judgesDegraded))
            let rb = rank(b.displayState(judgesDegraded: response.judgesDegraded))
            if ra != rb { return ra < rb }
            return (a.loss ?? 0) > (b.loss ?? 0)
        }.prefix(limit))
    }

    public static func count(_ response: PathsResponse, nodeID: String) -> Int {
        response.paths.filter { $0.source == nodeID || $0.targetNode == nodeID }.count
    }
}

/// One cell of a node's status strip.
public enum FleetStatusCell: String, Sendable, Hashable {
    case online, offline, unknown
}

public enum FleetStatusStrip {
    /// The state over each of `count` equal buckets of [since, until]. A
    /// bucket that saw any offline time is offline, else any unknown time
    /// unknown, else online, so a short outage never disappears.
    public static func cells(_ history: FleetNodeStatusHistory, since: Date, until: Date, count: Int) -> [FleetStatusCell] {
        guard count > 0, until > since else { return [] }
        var spans: [(start: Date, end: Date, state: String)] = []
        var state = history.initial
        var at = since
        for event in history.events {
            guard let time = event.at else { continue }
            if time > at { spans.append((at, min(time, until), state)) }
            state = event.to
            at = max(at, time)
        }
        if until > at { spans.append((at, until, state)) }
        let width = until.timeIntervalSince(since) / Double(count)
        return (0..<count).map { index in
            let start = since.addingTimeInterval(Double(index) * width)
            let end = start.addingTimeInterval(width)
            let overlapping = spans.filter { $0.start < end && $0.end > start }.map(\.state)
            if overlapping.contains("offline") { return .offline }
            if overlapping.contains(where: { $0 != "online" }) || overlapping.isEmpty { return .unknown }
            return .online
        }
    }
}

/// Health of a group's members from the node list, for member rows.
public enum FleetGroupHealth {
    public static func members(_ group: FleetGroupView, nodes: [String: LatticeNode]) -> [LatticeNode] {
        FleetNodeGrouping.ordered(group.resolvedMembers.compactMap { nodes[$0] }.map { FleetNodeRecord(node: $0) }).map(\.node)
    }

    /// Nodes the static list can still take: readable, not already a static member.
    public static func candidates(_ group: FleetGroupView, nodes: [LatticeNode]) -> [LatticeNode] {
        let members = Set(group.members)
        return nodes.filter { !members.contains($0.id) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

/// Short words for the capability states a node row shows (M2-06).
public enum FleetCapabilityState {
    /// "Enrolled", "Excluded", "In scope" (derived from configuration), "Not decided".
    public static func word(_ capability: NodeCapabilityEffective) -> String {
        switch capability.state {
        case "enrolled": return "Enrolled"
        case "excluded": return "Excluded"
        default: return capability.allowed ? "In scope" : "Not decided"
        }
    }

    /// The explanation the console gives under the word.
    public static func detail(_ capability: NodeCapabilityEffective) -> String {
        if !capability.enforced { return "Recorded, but this capability is not gated yet." }
        switch capability.state {
        case "enrolled": return "Enrolled on this node."
        case "excluded": return capability.recordReason.isEmpty ? "Excluded from this node." : "Excluded: \(capability.recordReason)"
        default:
            return capability.allowed
                ? "In scope because this node is already configured for it."
                : "Out of scope: this node is not configured for it."
        }
    }

    /// Whether the gate would let it act on the node right now.
    public static func admits(_ capability: NodeCapabilityEffective) -> Bool { capability.allowed }
}

/// One sentence for a query the engine refused, shown under the search
/// field so a typo never reads as an empty fleet.
public enum FleetQueryMessage {
    public static func sentence(_ error: LatticeQueryError) -> String {
        let field = error.params["field"] ?? ""
        let suggestion = error.params["suggestion"].flatMap { $0.isEmpty ? nil : $0 }
        let hint = suggestion.map { " Did you mean \($0)?" } ?? ""
        switch error.code {
        case .unknownField: return "There is no field \(field).\(hint)"
        case .unknownValue:
            let values = error.params["values"].map { " Use one of \($0)." } ?? ""
            return "\(field) has no value \(error.params["value"] ?? "").\(values)"
        case .unknownFlag: return "There is no flag is:\(error.params["flag"] ?? "").\(hint)"
        case .unknownSort: return "Cannot sort by \(field).\(hint)"
        case .emptyValue: return "\(field) needs a value."
        case .noCompare: return "\(field) cannot be compared with < or >."
        case .needsCompare: return "\(field) needs a comparison, such as \(error.params["example"] ?? "\(field)>1")."
        case .badNumber: return "\(field) needs a number."
        case .badDuration: return "\(field) needs a duration, such as 10m."
        case .badTime: return "\(field) needs a time or an age, such as 1h."
        case .badBool: return "\(field) needs yes or no."
        case .badVersion: return "\(field) needs a version, such as 0.3.10."
        case .unclosedQuote: return "A quote is not closed."
        case .unclosedParen, .unexpectedParen: return "Parentheses do not match."
        case .danglingOperator, .nothingToNegate, .emptyGroup, .notArity, .callArity, .sortNested:
            return "The query is incomplete."
        }
    }
}
