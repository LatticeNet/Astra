import Foundation

// Query schemas for the Paths, Checks and Incidents lists (section 6.14),
// following the console's pathsQuerySchema, monitoringQuery.ts and
// incidentsModel.ts field names.

/// `pathsQuerySchema`: `source:`, `target:`, `method:`, `state:`, `reason:`,
/// `region:`, `check:`, `path:`, `p50`, `loss`.
public enum MonitoringPathQueryFields: QueryFieldProvider {
    public typealias Row = MonitoringPathItem

    public static let states = ["down", "degraded", "unknown", "paused", "skipped", "up"]
    public static let methods = ["tcp", "http", "tls", "icmp", "beacon", "dns"]

    public static var fields: [LatticeQueryField<MonitoringPathItem>] {
        [
            LatticeQueryField(key: "target", aliases: ["to"], type: .string, get: { item in
                item.path.targetNode.isEmpty ? .strings([item.targetName, item.path.target]) : .string(item.targetName)
            }),
            LatticeQueryField(key: "path", type: .string, sortable: false, get: { .string($0.key) }),
            LatticeQueryField(key: "source", aliases: ["from"], type: .string, get: { .string($0.sourceName) }),
            LatticeQueryField(
                key: "state", aliases: ["status"], type: .enumeration, values: states,
                valueAliases: ["failing": "down", "failed": "down", "ok": "up", "healthy": "up", "stopped": "paused", "slow": "degraded", "unmeasured": "skipped"],
                get: { .string($0.stateWord) }
            ),
            LatticeQueryField(key: "reason", aliases: ["why"], type: .list, sortable: false, get: { item in
                guard let reason = item.reason else { return .none }
                return .strings([item.path.reason, reason.rawValue, reason.sentence].filter { !$0.isEmpty })
            }),
            LatticeQueryField(key: "region", type: .string, get: { .string($0.region) }),
            LatticeQueryField(key: "country", type: .string, get: { .string($0.country) }),
            LatticeQueryField(key: "method", type: .enumeration, values: methods, get: { .string($0.path.method) }),
            LatticeQueryField(key: "check", type: .string, get: { item in
                .strings([item.path.checkDefinitionID, item.path.monitorID].filter { !$0.isEmpty })
            }),
            LatticeQueryField(key: "p50", type: .number, get: { item in
                item.measuresNow ? item.path.p50Ms.map { .number($0) } ?? .none : .none
            }),
            LatticeQueryField(key: "p95", type: .number, get: { item in
                item.measuresNow ? item.path.p95Ms.map { .number($0) } ?? .none : .none
            }),
            LatticeQueryField(key: "loss", type: .number, unit: .percent, get: { item in
                guard item.measuresNow, item.path.samples > 0, let loss = item.path.loss else { return .none }
                return .number(loss * 100)
            }),
        ]
    }

    public static func text(_ item: MonitoringPathItem) -> [String] {
        [item.targetName, item.sourceName, item.country, item.path.method, item.path.target, item.reason?.sentence ?? ""]
    }
}

/// One check as the Checks list holds it: the monitor, its health and the
/// names of the nodes it runs on.
public struct MonitoringCheckItem: Sendable, Hashable, Identifiable {
    public var monitor: Monitor
    public var health: MonitoringHealth
    public var nodeNames: [String]

    public init(monitor: Monitor, health: MonitoringHealth, nodeNames: [String]) {
        self.monitor = monitor
        self.health = health
        self.nodeNames = nodeNames
    }

    public var id: String { monitor.id }

    /// The word the list shows and `state:` matches.
    public var stateWord: String {
        switch health {
        case .disabled: "paused"
        case .unread: "unread"
        case .none: "no results"
        case .failing: "failing"
        case .stale: "stale"
        case .unmeasured: "unmeasured"
        case .degraded: "degraded"
        case .up: "up"
        }
    }
}

/// `monitoringQuerySchema`: `type:`, `node:`, `state:`, `name:`, `target:`.
public enum MonitoringCheckQueryFields: QueryFieldProvider {
    public typealias Row = MonitoringCheckItem

    public static let states = ["failing", "degraded", "stale", "unmeasured", "none", "unread", "up", "disabled"]

    public static var fields: [LatticeQueryField<MonitoringCheckItem>] {
        [
            LatticeQueryField(key: "type", aliases: ["kind"], type: .enumeration, values: MonitorType.allCases.map(\.rawValue), get: { .string($0.monitor.typeWord) }),
            LatticeQueryField(key: "node", aliases: ["source"], type: .list, get: { item in
                .strings(item.nodeNames + item.monitor.nodeIDs + item.monitor.latest.map(\.nodeID).filter { !$0.isEmpty })
            }),
            LatticeQueryField(
                key: "state", aliases: ["status"], type: .enumeration, values: states,
                valueAliases: ["paused": "disabled", "off": "disabled", "down": "failing", "failed": "failing", "ok": "up", "healthy": "up"],
                get: { item in
                    switch item.health {
                    case .disabled: .string("disabled")
                    case .none: .string("none")
                    default: .string(item.stateWord)
                    }
                }
            ),
            LatticeQueryField(key: "name", type: .string, get: { .string($0.monitor.displayName) }),
            LatticeQueryField(key: "target", type: .string, get: { .string($0.monitor.target) }),
            LatticeQueryField(key: "generated", type: .bool, flag: true, get: { .bool($0.monitor.isGenerated) }),
        ]
    }

    public static func text(_ item: MonitoringCheckItem) -> [String] {
        [item.monitor.displayName, item.monitor.target, item.monitor.typeWord, item.monitor.id] + item.nodeNames
    }
}

/// One incident as the Incidents list filters it, with its state words
/// worked out once against `now`.
public struct MonitoringIncidentItem: Sendable, Hashable, Identifiable {
    public var incident: Incident
    /// Every state word the incident answers to: its server state, and
    /// `open` only while open and not snoozed (the console's Open chip).
    public var stateWords: [String]

    public init(incident: Incident, now: Date) {
        self.incident = incident
        var words: [String] = []
        for filter in IncidentFilter.allCases where filter != .all && filter.matches(incident, now: now) {
            words.append(filter.rawValue)
        }
        if !incident.maintenance.isEmpty, IncidentFilter.isActive(incident) { words.append("held") }
        stateWords = words
    }

    public var id: String { incident.id }
}

/// `kind:`, `node:`, `state:`, `severity:`.
public enum MonitoringIncidentQueryFields: QueryFieldProvider {
    public typealias Row = MonitoringIncidentItem

    public static let states = ["open", "acknowledged", "snoozed", "held", "pending", "resolved", "active"]

    public static var fields: [LatticeQueryField<MonitoringIncidentItem>] {
        [
            LatticeQueryField(key: "kind", aliases: ["type"], type: .string, get: { .string($0.incident.kind) }),
            LatticeQueryField(key: "node", type: .list, get: { item in
                .strings([item.incident.nodeName, item.incident.nodeID].filter { !$0.isEmpty })
            }),
            LatticeQueryField(key: "state", aliases: ["status"], type: .list, values: states, sortable: false, get: { .strings($0.stateWords) }),
            LatticeQueryField(key: "severity", type: .enumeration, values: ["critical", "warning", "info"], get: { .string($0.incident.severity) }),
        ]
    }

    public static func text(_ item: MonitoringIncidentItem) -> [String] {
        [item.incident.displayTitle, item.incident.subject, item.incident.nodeName, item.incident.kind, item.incident.detail]
    }
}

public enum MonitoringQuery {
    /// Applies a query string to rows; an invalid query keeps every row and
    /// returns its error so the screen can show it.
    public static func filter<Provider: QueryFieldProvider>(_ rows: [Provider.Row], query: String, provider: Provider.Type, now: Date) -> (rows: [Provider.Row], error: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (rows, nil) }
        switch LatticeQueryEngine.compile(trimmed, provider: provider) {
        case .success(let compiled):
            return (LatticeQueryEngine.apply(compiled, to: rows, now: now), nil)
        case .failure(let error):
            return (rows, describe(error))
        }
    }

    /// "Query not understood: unknown field (stauts)".
    public static func describe(_ error: LatticeQueryError) -> String {
        var words = ""
        for character in error.code.rawValue {
            if character.isUppercase { words += " " }
            words += character.lowercased()
        }
        let detail = error.params.sorted { $0.key < $1.key }.map(\.value).filter { !$0.isEmpty }.joined(separator: ", ")
        return "Query not understood: \(words)" + (detail.isEmpty ? "" : " (\(detail))")
    }
}
