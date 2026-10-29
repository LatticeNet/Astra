import Foundation

/// A port of the console's `lib/query/nodeFields.ts` and the agent
/// capability words of `lib/nodeFilterExpressions.ts`: the node fields every
/// node list shares. Metrics are read only from a node that is reporting,
/// so `cpu>80` never finds an offline node by a number nobody can see.
public enum FleetNodeQuery {
    /// What an agent may do, as the `cap:` field and the bare word name it.
    public static let capabilities = ["exec", "root", "terminal", "stream", "poll", "singbox", "singbox-drift", "no-source"]

    static let capabilityAliases: [String: String] = [
        "sing-box": "singbox",
        "sing-box-drift": "singbox-drift",
        "drift": "singbox-drift",
        "nosource": "no-source",
    ]

    /// Statuses in the attention order the console sorts by: never reported first, online last.
    public static let statusOrder = ["never_reported", "offline", "degraded", "disabled", "online"]

    public static func capabilityWord(_ word: String) -> String? {
        let lower = word.trimmingCharacters(in: .whitespaces).lowercased()
        let canonical = capabilityAliases[lower] ?? lower
        return capabilities.contains(canonical) ? canonical : nil
    }

    /// `nodeHasAgentCapability`.
    public static func hasCapability(_ record: FleetNodeRecord, _ token: String) -> Bool {
        let cap = capabilityAliases[token.lowercased()] ?? token.lowercased()
        let profile = record.facts.agentRuntime
        switch cap {
        case "exec": return profile.map { $0.allowExec && !$0.noExec } ?? false
        case "root": return profile.map { $0.allowExec && $0.allowRootExec && !$0.noExec } ?? false
        case "terminal": return profile.map { $0.allowTerminal && !$0.noExec } ?? false
        case "stream": return profile.map { $0.allowTerminal && $0.terminalTransport == "stream" && !$0.noExec } ?? false
        case "poll": return profile.map { $0.allowTerminal && $0.terminalTransport != "stream" && !$0.noExec } ?? false
        case "singbox": return profile?.singBoxDiscover == true
        case "singbox-drift": return singBoxDrift(record)
        case "no-source": return record.facts.agentSourceAllowlist.isEmpty
        default: return false
        }
    }

    /// Launch profile and runtime report disagree about sing-box discovery;
    /// either side missing is not drift.
    public static func singBoxDrift(_ record: FleetNodeRecord) -> Bool {
        guard let launch = record.facts.launchSingBoxDiscover, let runtime = record.facts.agentRuntime?.singBoxDiscover else { return false }
        return launch != runtime
    }

    public static func nodeCapabilities(_ record: FleetNodeRecord) -> [String] {
        capabilities.filter { hasCapability(record, $0) }
    }

    /// The agent is in contact: online or degraded.
    public static func isReporting(_ node: LatticeNode) -> Bool {
        node.honesty == .online || node.honesty == .degraded
    }

    /// The percent a cell prints, so a filter and a sort agree with the screen.
    static func shown(_ value: Double?) -> Double? {
        guard let value, !value.isNaN else { return nil }
        return min(100, max(0, value)).rounded()
    }

    static func ratio(_ used: UInt64, _ total: UInt64) -> Double? {
        guard total > 0 else { return nil }
        return shown(Double(used) / Double(total) * 100)
    }

    /// The words a bare search looks at: name, id, role, addresses, host facts and tags.
    public static func text(_ record: FleetNodeRecord) -> [String] {
        let node = record.node
        let values: [String?] = [
            node.name, node.id, node.role, node.publicIP, node.publicIPv6, node.internalIP, node.internalIPv6,
            node.hostFacts.hostname, node.hostFacts.arch, node.hostFacts.os, node.hostFacts.platform,
        ] + node.tags.map(Optional.some)
        return values.compactMap { $0 }.filter { !$0.isEmpty }
    }

    /// A bare capability word finds the nodes that have it.
    public static func bare(_ record: FleetNodeRecord, _ word: String) -> Bool {
        guard let cap = capabilityWord(word) else { return false }
        return hasCapability(record, cap)
    }

    private static func strings(_ values: [String?]) -> LatticeQueryFieldValue {
        .strings(values.compactMap { $0 }.filter { !$0.isEmpty })
    }

    private static func live(_ record: FleetNodeRecord, _ read: (LatticeNode) -> Double?) -> LatticeQueryFieldValue {
        guard isReporting(record.node), let value = read(record.node) else { return .none }
        return .number(value)
    }

    /// The fields, with group names resolved through `groupName` when the query runs.
    public static func fields(groupName: @escaping @Sendable (String) -> String? = { _ in nil }) -> [LatticeQueryField<FleetNodeRecord>] {
        func status(_ want: String) -> @Sendable (FleetNodeRecord) -> LatticeQueryFieldValue {
            { .bool($0.node.honestyWord == want) }
        }
        return [
            LatticeQueryField(key: "name", type: .string, get: { .string($0.node.displayName) }),
            LatticeQueryField(key: "id", type: .string, get: { .string($0.node.id) }),
            LatticeQueryField(key: "ip", aliases: ["address", "addr"], type: .list, get: {
                strings([$0.node.publicIP, $0.node.publicIPv6, $0.node.internalIP, $0.node.internalIPv6])
            }),
            LatticeQueryField(key: "tag", aliases: ["tags", "role"], type: .list, get: {
                strings([$0.node.role] + $0.node.tags.map(Optional.some))
            }),
            LatticeQueryField(key: "group", aliases: ["groups"], type: .list, get: { record in
                .strings(record.node.groupIDs.map { groupName($0) ?? $0 })
            }),
            LatticeQueryField(key: "provider", aliases: ["isp", "asn"], type: .list, get: {
                strings([$0.facts.provider, $0.facts.asOrg, $0.facts.asn > 0 ? "AS\($0.facts.asn)" : nil])
            }),
            LatticeQueryField(key: "country", aliases: ["cc"], type: .string, get: {
                $0.node.geo?.country.map { .string($0) } ?? .none
            }),
            LatticeQueryField(key: "region", aliases: ["city", "geo"], type: .list, get: {
                strings([$0.node.geo?.country, $0.node.geo?.region, $0.node.geo?.city])
            }),
            LatticeQueryField(key: "os", aliases: ["platform"], type: .list, get: {
                strings([$0.node.hostFacts.os, $0.node.hostFacts.platform, $0.node.hostFacts.platformVersion, $0.node.hostFacts.arch])
            }),
            LatticeQueryField(key: "arch", type: .string, get: {
                $0.node.hostFacts.arch.map { .string($0) } ?? .none
            }),
            LatticeQueryField(key: "agent", aliases: ["version"], type: .version, get: {
                $0.node.agentVersion.map { .string($0) } ?? .none
            }, match: { record, value, _ in
                guard let cap = capabilityWord(value) else { return nil }
                return hasCapability(record, cap)
            }),
            LatticeQueryField(key: "cap", aliases: ["caps", "capability", "config"], type: .enumeration,
                              values: capabilities, valueAliases: capabilityAliases, get: {
                .strings(nodeCapabilities($0))
            }),
            LatticeQueryField(key: "status", type: .enumeration, values: statusOrder,
                              valueAliases: ["never": "never_reported", "unreported": "never_reported", "never-reported": "never_reported"],
                              get: { .string($0.node.honestyWord) }),
            LatticeQueryField(key: "online", type: .bool, flag: true, sortable: false, get: status("online")),
            LatticeQueryField(key: "offline", type: .bool, flag: true, sortable: false, get: status("offline")),
            LatticeQueryField(key: "degraded", type: .bool, flag: true, sortable: false, get: status("degraded")),
            LatticeQueryField(key: "disabled", type: .bool, flag: true, sortable: false, get: status("disabled")),
            LatticeQueryField(key: "never", aliases: ["never_reported", "unreported"], type: .bool, flag: true, sortable: false, get: status("never_reported")),
            LatticeQueryField(key: "reporting", type: .bool, flag: true, sortable: false, get: { .bool(isReporting($0.node)) }),
            LatticeQueryField(key: "drift", type: .bool, flag: true, sortable: false, get: { .bool(singBoxDrift($0)) }),
            LatticeQueryField(key: "cpu", type: .number, unit: .percent, get: { live($0) { shown($0.metrics.cpuPercent) } }),
            LatticeQueryField(key: "mem", aliases: ["memory"], type: .number, unit: .percent, get: {
                live($0) { ratio($0.metrics.memoryUsed, $0.metrics.memoryTotal) }
            }),
            LatticeQueryField(key: "disk", type: .number, unit: .percent, get: {
                live($0) { ratio($0.metrics.diskUsed, $0.metrics.diskTotal) }
            }),
            LatticeQueryField(key: "load", aliases: ["load1"], type: .number, get: { live($0) { $0.metrics.load1 } }),
            LatticeQueryField(key: "rx", type: .number, unit: .rate, get: { live($0) { $0.metrics.netRxSpeed } }),
            LatticeQueryField(key: "tx", type: .number, unit: .rate, get: { live($0) { $0.metrics.netTxSpeed } }),
            LatticeQueryField(key: "last_seen", aliases: ["seen", "lastseen"], type: .time, get: {
                $0.node.lastSeen.map { .time($0) } ?? .none
            }),
            LatticeQueryField(key: "uptime", type: .duration, get: { live($0) { Double($0.metrics.uptimeSeconds) } }),
        ]
    }

    /// Compiles a Nodes query; an error names the field and position, as the console does.
    public static func compile(_ input: String, groupName: @escaping @Sendable (String) -> String? = { _ in nil })
        -> Result<LatticeCompiledQuery<FleetNodeRecord>, LatticeQueryError> {
        LatticeQueryEngine.compile(input, fields: fields(groupName: groupName), text: text, bare: bare)
    }

    /// Filters and orders records with a query; an invalid query keeps every record.
    public static func apply(_ input: String, to records: [FleetNodeRecord], now: Date,
                             groupName: @escaping @Sendable (String) -> String? = { _ in nil }) -> [FleetNodeRecord] {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, case .success(let query) = compile(trimmed, groupName: groupName) else { return records }
        return LatticeQueryEngine.apply(query, to: records, now: now)
    }
}
