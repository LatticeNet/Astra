import Foundation

/// Pure rules of the Audit screens, ported from the console's
/// `views/operations/auditModel.ts` and `traceModel.ts`.
public enum AuditModel {
    /// Rows per page of the list (section 5.5, M4-04).
    public static let pageSize = 100
    /// The page a lookup by id walks with (section 2.5).
    public static let lookupPageSize = 100
    /// The server's largest page (`maxAuditLimit`).
    public static let maxPageSize = 500

    /// Node reachability flips: the noise Changes hides.
    public static let nodeFlipActions = ["node.online", "node.offline"]

    /// node, actor, action, decision, scope and trace, plus free text sent as
    /// `q`. `action` matches exactly unless it ends in `*` (the server's rule).
    public static let grammar = TasksTokenGrammar(fields: [
        TasksTokenField(key: "node", resolve: "node"),
        TasksTokenField(key: "actor"),
        TasksTokenField(key: "action"),
        TasksTokenField(key: "decision"),
        TasksTokenField(key: "scope"),
        TasksTokenField(key: "trace"),
    ])

    /// What Changes hides, given what was asked: a question about node flips
    /// or about observe events is answered, not contradicted.
    public static func changesExclusions(_ tokens: TasksParsedTokens) -> (excludeAction: String?, excludeDecision: String?) {
        let action = tokens.values["action"] ?? ""
        let decision = tokens.values["decision"] ?? ""
        let excludeAction = action.hasPrefix("node.") || action == "node*" ? nil : nodeFlipActions.joined(separator: ",")
        let excludeDecision = decision == "observe" ? nil : "observe"
        return (excludeAction, excludeDecision)
    }

    /// The one `GET /api/audit` a layer, a question and a window mean (`auditRequest`).
    public static func request(layer: AuditLayer, tokens: TasksParsedTokens, from: Date?, to: Date?, offset: Int, limit: Int = pageSize) -> AuditQuery {
        var query = AuditQuery(
            action: tokens.values["action"],
            actorID: tokens.values["actor"],
            atFrom: from,
            atTo: to,
            correlationID: tokens.values["trace"],
            decision: tokens.values["decision"],
            nodeID: tokens.values["node"],
            scope: tokens.values["scope"],
            text: tokens.text.isEmpty ? nil : tokens.text,
            limit: limit,
            offset: offset
        )
        if layer == .changes {
            let exclusions = changesExclusions(tokens)
            query.excludeAction = exclusions.excludeAction
            query.excludeDecision = exclusions.excludeDecision
        }
        return query
    }

    /// The footer under the list: "412 events", "Scanned 10 000 events; refine
    /// to see older" when the server's scan cap stopped the walk.
    public static func scanLine(_ page: AuditPage, locale: Locale = Locale(identifier: "en_US")) -> String {
        let total = page.total.formatted(.number.locale(locale))
        if page.isPartial {
            let scanned = (page.scanned ?? page.total).formatted(.number.locale(locale))
            return "At least \(total) events. Scanned \(scanned) events; refine to see older."
        }
        return page.total == 1 ? "1 event" : "\(total) events"
    }

    // MARK: Trace

    /// Oldest first; ties break by id (`orderTimeline`).
    public static func orderTimeline(_ events: [AuditEvent]) -> [AuditEvent] {
        events.sorted { a, b in
            let ta = a.at ?? .distantPast, tb = b.at ?? .distantPast
            return ta != tb ? ta < tb : a.id < b.id
        }
    }

    /// Distinct approval ids referenced across the events, first seen first.
    public static func referencedApprovalIDs(_ events: [AuditEvent]) -> [String] {
        distinct(events, key: "approval_id")
    }

    /// Distinct task ids referenced across the events, first seen first.
    public static func referencedTaskIDs(_ events: [AuditEvent]) -> [String] {
        distinct(events, key: "task_id")
    }

    private static func distinct(_ events: [AuditEvent], key: String) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for event in events {
            guard let id = event.metadata[key]?.trimmingCharacters(in: .whitespaces), !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(id)
        }
        return out
    }

    /// Headline counts for the trace (`summarize`).
    public static func summarize(_ events: [AuditEvent]) -> AuditTraceSummary {
        let ordered = orderTimeline(events)
        let nodes = Set(events.map(\.nodeID).filter { !$0.isEmpty })
        return AuditTraceSummary(
            total: events.count,
            denied: events.filter { $0.decision == "deny" }.count,
            firstAt: ordered.first?.at,
            lastAt: ordered.last?.at,
            nodes: nodes.sorted()
        )
    }

    // MARK: Event

    /// The decision as symbol-ready state: deny is the only problem word.
    public static func decision(of event: AuditEvent) -> AuditDecision {
        switch event.decision.lowercased() {
        case "deny", "denied": .deny
        case "observe": .observe
        case "warn": .warn
        case "dismiss": .dismiss
        case "", "allow": .allow
        default: .other(event.decision)
        }
    }

    /// The object an event touched, from the metadata keys the server writes,
    /// in the order an operator looks for them.
    public static func object(of event: AuditEvent) -> String? {
        for key in ["task_id", "approval_id", "incident_id", "window_id", "token_id", "monitor_id", "machine_id", "group_id", "plugin"] {
            if let value = event.metadata[key], !value.isEmpty { return value }
        }
        return nil
    }

    /// The approval an event references, when it names one.
    public static func approvalID(of event: AuditEvent) -> String? {
        event.metadata["approval_id"].flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func taskID(of event: AuditEvent) -> String? {
        event.metadata["task_id"].flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The three views of the Audit page (console `?view=`).
public enum AuditLayer: String, Sendable, Hashable, CaseIterable {
    case changes, all, integrity

    public var title: String {
        switch self {
        case .changes: "Changes"
        case .all: "All"
        case .integrity: "Integrity"
        }
    }
}

public enum AuditDecision: Sendable, Hashable {
    case allow, deny, observe, warn, dismiss
    case other(String)

    public var word: String {
        switch self {
        case .allow: "allowed"
        case .deny: "denied"
        case .observe: "observed"
        case .warn: "warned"
        case .dismiss: "dismissed"
        case .other(let word): word
        }
    }
}

public struct AuditTraceSummary: Sendable, Hashable {
    public var total: Int
    public var denied: Int
    public var firstAt: Date?
    public var lastAt: Date?
    /// Distinct nodes the trace touched.
    public var nodes: [String]
}
