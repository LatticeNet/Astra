import Foundation

// The display-state enums `StatusStyle` maps to symbol, word and color
// (section 4.2). Domain models expose a `displayState` of one of these, so the
// vocabulary is finished before any module exists.

/// A node's honesty word (server `status`).
public enum NodeHonesty: String, Sendable, Hashable, CaseIterable {
    case online
    case degraded
    case offline
    case neverReported = "never_reported"
    case disabled

    /// The server word, falling back to offline for anything unknown, so an
    /// unrecognized state never reads as healthy.
    public init(serverValue: String) {
        self = NodeHonesty(rawValue: serverValue) ?? .offline
    }

    /// Worst first, the order lists group by.
    public var severityRank: Int {
        switch self {
        case .offline: 0
        case .degraded: 1
        case .neverReported: 2
        case .online: 3
        case .disabled: 4
        }
    }
}

/// A path reason code with its sentence (`pathsModel.ts` `reasonCode`).
public struct PathReason: Sendable, Hashable, RawRepresentable {
    /// The canonical code after aliases are resolved, or the raw text when unknown.
    public var rawValue: String

    public init(rawValue: String) {
        // `reasonCode`: runs of spaces and hyphens become one underscore.
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"[\s-]+"#, with: "_", options: .regularExpression)
        if Self.sentences[normalized] != nil {
            self.rawValue = normalized
        } else if let alias = Self.aliases[normalized] {
            self.rawValue = alias
        } else {
            self.rawValue = rawValue
        }
    }

    /// True for the reasons that read as "paused" rather than "unknown".
    /// Section 4.2 adds `packet_budget`, which the console counts as skipped.
    public var isPause: Bool {
        Self.pauseReasons.contains(rawValue)
    }

    /// The operator's own choice (`pathsModel.ts` `CHOSEN`): listed, never a problem.
    public var isChosen: Bool {
        Self.chosenReasons.contains(rawValue)
    }

    /// A pair its check skips (`pathsModel.ts` `SKIPPED`): configuration, not health.
    public var isSkip: Bool {
        Self.skipReasons.contains(rawValue)
    }

    static let chosenReasons: Set<String> = ["source_paused", "path_paused", "path_set_paused", "check_paused"]

    static let skipReasons: Set<String> = [
        "not_probeable", "no_tcp_line", "udp_only", "no_public_address", "no_inventory", "agent_too_old",
        "icmp_not_permitted", "packet_budget", "beacon_not_enabled", "firewall_pending", "beacon_source_pending",
        "refused_by_node",
    ]

    /// The sentence for this reason; anything unknown is shown as sent.
    public var sentence: String {
        Self.sentences[rawValue] ?? rawValue
    }

    public static func sentence(for raw: String) -> String {
        PathReason(rawValue: raw).sentence
    }

    static let pauseReasons: Set<String> = ["path_paused", "path_set_paused", "check_paused", "source_paused", "packet_budget"]

    static let sentences: [String: String] = [
        "agent_offline": "source offline",
        "source_unavailable": "source unavailable",
        "not_probeable": "cannot be probed",
        "no_data": "no data yet",
        "no_tcp_line": "no TCP line",
        "udp_only": "UDP only",
        "no_public_address": "no public address",
        "no_inventory": "not in inventory",
        "no_results": "no results",
        "results_stopped": "results stopped",
        "agent_too_old": "agent too old",
        "icmp_not_permitted": "ICMP not permitted",
        "destination_refused": "destination refused",
        "method_refused": "method refused",
        "icmp_filtered": "ICMP filtered",
        "beacon_not_enabled": "beacon not enabled",
        "firewall_pending": "firewall change pending",
        "beacon_source_pending": "beacon source pending",
        "refused_by_node": "refused by the node",
        "beacon_not_listening": "beacon not listening",
        "beacon_filtered": "beacon filtered",
        "beacon_stale": "beacon stale",
        "beacon_unknown_epoch": "beacon epoch unknown",
        "beacon_rate_limited": "beacon rate limited",
        "beacon_no_key": "beacon has no key",
        "packet_budget": "paused to stay under the packet budget",
        "path_paused": "path paused",
        "path_set_paused": "path set paused",
        "check_paused": "check paused",
        "source_paused": "source paused",
        "degraded_loss": "loss above trigger",
        "degraded_latency": "latency above trigger",
        "degraded_loss_latency": "loss and latency above trigger",
    ]

    static let aliases: [String: String] = [
        "offline": "agent_offline",
        "node_offline": "agent_offline",
        "source_offline": "agent_offline",
        "paused": "path_paused",
        "pair_off": "path_paused",
        "pair_paused": "path_paused",
        "pairs_off": "path_paused",
        "disabled_pair": "path_paused",
        "config_off": "path_set_paused",
        "monitor_paused": "check_paused",
        "check_disabled": "check_paused",
        "disabled": "check_paused",
        "unknown_node": "source_unavailable",
        "node_disabled": "source_unavailable",
        "no_source": "source_unavailable",
        "never_reported": "no_results",
        "stale": "results_stopped",
        "quiet": "results_stopped",
        "method_unsupported": "agent_too_old",
        "unsupported_method": "agent_too_old",
        "beacon_off": "beacon_not_enabled",
    ]
}

/// A path's state as the console reads it (`pathsModel.ts` `normalizeState`).
public enum PathDisplayState: Sendable, Hashable {
    case up
    case degraded(PathReason?)
    case down
    case paused(PathReason)
    case unknown(PathReason?)

    /// `degraded` counts only from a server that judges it (`degraded_at`
    /// present on the response); anything unrecognized is unknown, never up.
    public init(state: String, reason: String?, judgesDegraded: Bool) {
        let reason = reason.flatMap { $0.isEmpty ? nil : PathReason(rawValue: $0) }
        switch state {
        case "up": self = .up
        case "down": self = .down
        case "degraded" where judgesDegraded: self = .degraded(reason)
        default:
            if let reason, reason.isPause {
                self = .paused(reason)
            } else {
                self = .unknown(reason)
            }
        }
    }

    /// Whether the path is measured, skipped by its check, or paused
    /// (`pathsModel.ts` `pathMeasure`). Skipped and paused paths are never
    /// counted as problems or shown by the default views.
    public var measure: PathMeasure {
        let reason: PathReason?
        switch self {
        case .up, .down, .degraded: return .measured
        case .paused(let paused): reason = paused
        case .unknown(let unknown): reason = unknown
        }
        guard let reason else { return .measured }
        if reason.isSkip { return .skipped }
        if reason.isChosen { return .paused }
        return .measured
    }

    /// Worst first, the `topologyModel` order: down, degraded, unknown, paused, up.
    public var severityRank: Int {
        switch self {
        case .down: 0
        case .degraded: 1
        case .unknown: 2
        case .paused: 3
        case .up: 4
        }
    }
}

/// `pathsModel.ts` `PathMeasure`.
public enum PathMeasure: String, Sendable, Hashable, CaseIterable {
    case measured, skipped, paused
}

/// An incident's display state. Precedence when several apply: held, then
/// snoozed, then acknowledged, then the severity of open.
public enum IncidentDisplayState: Sendable, Hashable {
    case openCritical
    case openWarning
    case openInfo
    case acknowledged
    case snoozed(until: Date?)
    case held(window: String)
    case pending(opensAt: Date?)
    case resolved

    /// Worst first.
    public var severityRank: Int {
        switch self {
        case .openCritical: 0
        case .openWarning: 1
        case .openInfo: 2
        case .pending: 3
        case .acknowledged: 4
        case .snoozed: 5
        case .held: 6
        case .resolved: 7
        }
    }
}

/// A task run's state (`lib/taskLease.ts`). `leased` reads as "running".
public enum TaskRunState: String, Sendable, Hashable, CaseIterable {
    case pending
    case queued
    case leased
    case finished
    case failed
    case stalled
    case expired
    case cancelled

    /// The server word, with `running` read as leased; unknown words read as queued.
    public init(serverValue: String) {
        switch serverValue {
        case "running": self = .leased
        case "canceled": self = .cancelled
        default: self = TaskRunState(rawValue: serverValue) ?? .queued
        }
    }

    public var isSettled: Bool {
        switch self {
        case .finished, .failed, .expired, .cancelled: true
        case .pending, .queued, .leased, .stalled: false
        }
    }
}

/// An approval's display state (section 4.2).
public enum ApprovalDisplayState: Sendable, Hashable, CaseIterable {
    case needsYou
    case stale
    case waiting
    case applying
    case applied
    case failed
    case rejected
    case dismissed
    /// Auto-approved `singbox-linemeta` rows: history only, never badged.
    case auto
}

/// SSH Guard coverage, from `SSHGuardBoard.coverageBucket` (section 4.2).
public enum SSHGuardCoverage: Sendable, Hashable {
    case confirmed
    case armPending
    /// The revert timer is running when `deadline` is in the future.
    case reverting(deadline: Date?)
    case open
    case failed
    case excluded

    /// The console's coverage filter name.
    public var filterName: String {
        switch self {
        case .confirmed: "confirmed"
        case .armPending: "armPending"
        case .reverting: "reverting"
        case .open: "open"
        case .failed: "failed"
        case .excluded: "excluded"
        }
    }
}

/// SSH Guard posture, from the server's `posture` object.
public enum SSHGuardPostureState: String, Sendable, Hashable, CaseIterable {
    case secured
    case passwordOpen = "password_open"
    case partial
    case unknown

    public init(serverValue: String) {
        self = SSHGuardPostureState(rawValue: serverValue) ?? .unknown
    }
}
