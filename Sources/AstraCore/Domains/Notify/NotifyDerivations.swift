import Foundation

// Pure derivations ported from the console (lattice-dashboard
// src/views/platform: notifySentModel.ts, notificationsModel.ts,
// witnessModel.ts, WebhooksView.vue and webhooksModel.ts), so the phone
// words a delivery, a channel's health, a webhook's reach and a witness the
// same way the console does. AstraCoreCheck covers each one.

// MARK: Channel kinds

/// A clock time for a moment today in the display zone, else a date and
/// time, so yesterday's 17:20 never reads as later today.
public enum NotifyClock {
    public static func when(_ date: Date, mode: TimeZoneMode, locale: Locale, now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = mode.timeZone
        return calendar.isDate(date, inSameDayAs: now) ? TimeDisplay.clock(date, mode: mode, locale: locale) : TimeDisplay.dateTime(date, mode: mode, locale: locale)
    }
}

public enum NotifyKind {
    /// The four kinds the server builds (`buildChannel`).
    public static let all = ["telegram", "bark", "discord", "webhook"]

    public static func label(_ kind: String) -> String {
        switch kind {
        case "telegram": "Telegram"
        case "bark": "Bark"
        case "discord": "Discord"
        case "webhook": "Webhook"
        case "": "Unknown kind"
        default: kind
        }
    }
}

// MARK: Failure causes

/// Why a send failed, in words. The server returns a classified kind and a
/// status code, never the transport error, which carries the credential.
public enum NotifyFailureCause: Equatable, Hashable, Sendable {
    case refused(status: Int)
    case serverError(status: Int)
    case rateLimited(status: Int)
    case timeout
    case unreachable
    case configRefused
    case failed

    public static func of(kind: String, status: Int?) -> NotifyFailureCause {
        switch kind {
        case "upstream_4xx": .refused(status: status ?? 0)
        case "upstream_5xx": .serverError(status: status ?? 0)
        case "rate_limited": .rateLimited(status: (status ?? 0) == 0 ? 429 : status ?? 429)
        case "timeout": .timeout
        case "network": .unreachable
        case "config_invalid": .configRefused
        default: .failed
        }
    }

    public var sentence: String {
        switch self {
        case .refused(let status): "the endpoint refused it (HTTP \(status)), so the key, token or chat id is likely wrong"
        case .serverError(let status): "the endpoint answered HTTP \(status)"
        case .rateLimited(let status): "the endpoint is rate limiting (HTTP \(status))"
        case .timeout: "the endpoint did not answer in time"
        case .unreachable: "the endpoint could not be reached"
        case .configRefused: "the channel's settings are refused, such as a private address or a malformed URL"
        case .failed: "the send failed"
        }
    }
}

// MARK: Sent log

/// A delivery's state on the Sent log (`sentState`). Held is a message the
/// server chose not to send yet or at all: a maintenance window, a snooze or
/// flap damping (outcome suppressed), or quiet hours still ahead.
public enum NotifySentState: String, CaseIterable, Sendable, Hashable {
    case sent, failed, retrying, queued
    case notRouted = "not_routed"
    case held

    public static func of(_ delivery: NotifyDelivery, now: Date) -> NotifySentState {
        switch delivery.outcome {
        case "sent": return .sent
        case "failed": return .failed
        case "no_route": return .notRouted
        case "suppressed": return .held
        default:
            let attempted = !delivery.attempts.isEmpty
            if !attempted, let until = delivery.heldUntil, until > now { return .held }
            return attempted ? .retrying : .queued
        }
    }

    public var word: String {
        switch self {
        case .sent: "sent"
        case .failed: "failed"
        case .retrying: "retrying"
        case .queued: "queued"
        case .notRouted: "not routed"
        case .held: "held"
        }
    }

    /// Failed, retrying and queued rows still owe the operator an answer.
    public var isProblem: Bool { self == .failed || self == .retrying || self == .queued }
}

public enum NotifySent {
    /// How long past its due time a queued delivery may wait before it reads
    /// as overdue. The server sends a due row within seconds and gives up on a
    /// send after 15 seconds, so a minute means the outbox is not draining.
    public static let overdueGrace: TimeInterval = 60

    /// A queued delivery that should have gone out by now. A fresh one is
    /// ordinary and stays quiet; this one owes the operator an answer.
    public static func isOverdue(_ delivery: NotifyDelivery, now: Date) -> Bool {
        guard NotifySentState.of(delivery, now: now) == .queued,
              let due = delivery.nextAttemptAt ?? delivery.createdAt else { return false }
        return now.timeIntervalSince(due) > overdueGrace
    }

    /// The latest failed attempt, which is what a row's cause names.
    public static func lastFailedAttempt(_ delivery: NotifyDelivery) -> NotifyAttempt? {
        delivery.attempts.last { !$0.ok }
    }

    /// Why a failed or retrying row has not delivered, from its receipts.
    public static func cause(_ delivery: NotifyDelivery) -> NotifyFailureCause? {
        lastFailedAttempt(delivery).map { NotifyFailureCause.of(kind: $0.kind, status: $0.status) }
    }

    /// How many times a folded no-route row happened, or nil for once.
    public static func occurrences(_ delivery: NotifyDelivery) -> Int? {
        delivery.repeats < 1 ? nil : delivery.repeats + 1
    }

    /// The sender: "The server", "Plugin x", and so on.
    public static func origin(_ delivery: NotifyDelivery) -> String {
        switch delivery.source {
        case "plugin": delivery.sourceID.isEmpty ? "A plugin" : "Plugin \(delivery.sourceID)"
        case "webhook": delivery.sourceID.isEmpty ? "An inbound webhook" : "Inbound webhook \(delivery.sourceID)"
        case "operator": "A test from the console"
        case "server", "": "The server"
        default: "From \(delivery.source)"
        }
    }

    /// The severity word a row opens with for VoiceOver.
    public static func severityWord(_ delivery: NotifyDelivery) -> String {
        if delivery.recovery { return "Recovered" }
        switch delivery.severity {
        case "critical": return "Critical"
        case "warning": return "Warning"
        case "notice": return "Notice"
        default: return "Info"
        }
    }
}

/// A note under a delivery (`sentNote`): a key the phone words, or the
/// server's text when the reason is not one it knows.
public enum NotifySentNote: Equatable, Sendable {
    case noRule, noChannel, noOtherChannel, redriven, interrupted, channelDeleted, channelDisabled
    case withdrawnOpen, withdrawnRecovery, withheldRecovery
    case heldMaintenance(name: String, until: Date?)
    case heldSnoozed(until: Date?)
    case heldFlapping(reopenings: Int)
    case quietHours(until: Date)
    case raw(String)

    private static let known: [String: NotifySentNote] = [
        "no enabled rule routes this event type": .noRule,
        "no enabled channel": .noChannel,
        "no other enabled channel": .noOtherChannel,
        "redriven after restart": .redriven,
        "interrupted by restart, not retried": .interrupted,
        "channel deleted before delivery": .channelDeleted,
        "channel disabled before delivery": .channelDisabled,
        "withdrawn when quiet hours ended: the incident was resolved, acknowledged or snoozed meanwhile": .withdrawnOpen,
        "withdrawn when quiet hours ended: the open message it answers was withdrawn too": .withdrawnRecovery,
        "withheld: the open message it answers never reached this rule": .withheldRecovery,
    ]

    /// Nil when the row needs no note: no reason, or a failure sentence the
    /// row already composes from its receipts.
    public static func of(_ delivery: NotifyDelivery) -> NotifySentNote? {
        let reason = delivery.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if let note = known[reason] { return note }
        if let match = reason.wholeMatch(of: /held by maintenance window "(.*)" until (\S+)/) {
            return .heldMaintenance(name: String(match.1), until: AstraDateParser.date(from: String(match.2)))
        }
        if let match = reason.wholeMatch(of: /snoozed until (\S+)/) {
            return .heldSnoozed(until: AstraDateParser.date(from: String(match.1)))
        }
        if let match = reason.wholeMatch(of: /flapping \((\d+) reopenings within [^)]*\), at most one message an hour/) {
            return .heldFlapping(reopenings: Int(match.1) ?? 0)
        }
        if let until = delivery.heldUntil { return .quietHours(until: until) }
        if reason.isEmpty || isFailureSentence(reason) { return nil }
        return .raw(reason)
    }

    static func isFailureSentence(_ reason: String) -> Bool {
        reason.wholeMatch(of: /(upstream status \d+|timed out|network error|channel config refused|send failed)( after \d+ attempts)?(, retrying)?/) != nil
    }

    public func sentence(mode: TimeZoneMode, locale: Locale) -> String {
        func when(_ date: Date?) -> String {
            date.map { TimeDisplay.dateTime($0, mode: mode, locale: locale) } ?? "later"
        }
        switch self {
        case .noRule: return "No enabled rule routes this event type, so it went to no channel."
        case .noChannel: return "No channel was enabled to carry it."
        case .noOtherChannel: return "No other channel was enabled to carry it."
        case .redriven: return "Sent again after a server restart, so the channel may have received it twice."
        case .interrupted: return "A server restart interrupted it and it was not retried: it was more than 15 minutes old, or a test."
        case .channelDeleted: return "The channel was deleted before it could be sent."
        case .channelDisabled: return "The channel was turned off before it could be sent."
        case .withdrawnOpen: return "Not sent: quiet hours held it, and when they ended the incident was already resolved, acknowledged or snoozed."
        case .withdrawnRecovery: return "Not sent: the down message it answers was withdrawn when quiet hours ended, so this channel never heard about the problem."
        case .withheldRecovery: return "Not sent: this rule never sent the down message it answers, so its channels never heard about the problem."
        case .heldMaintenance(let name, let until): return "Held by maintenance window \"\(name)\", which ends \(when(until))."
        case .heldSnoozed(let until): return "Held because the incident is snoozed until \(when(until))."
        case .heldFlapping(let n): return "Held because the incident keeps reopening (\(n) times): at most one message an hour."
        case .quietHours(let until): return "The rule's quiet hours held it until \(when(until))."
        case .raw(let text): return TimeDisplay.localizingStamps(in: text, mode: mode, locale: locale)
        }
    }
}

/// The outcome filter of the Sent log; "planned" covers retrying and queued.
public enum NotifySentOutcomeFilter: String, CaseIterable, Sendable, Hashable {
    case all, failed, planned, suppressed
    case noRoute = "no_route"
    case sent

    public var title: String {
        switch self {
        case .all: "All outcomes"
        case .failed: "Failed"
        case .planned: "Queued or retrying"
        case .suppressed: "Held"
        case .noRoute: "Not routed"
        case .sent: "Sent"
        }
    }

    public static func titled(_ title: String) -> NotifySentOutcomeFilter {
        allCases.first { $0.title == title } ?? .all
    }
}

/// The Sent log's filters. The server filters the whole outbox, then limits,
/// so the filters go to the server as its own names (`channel_id`,
/// `event_type`, `outcome`), never filtered on the phone.
public struct NotifySentFilters: Hashable, Sendable {
    /// The console's SENT_LIMIT; the outbox holds more.
    public static let limit = 500

    public var outcome: NotifySentOutcomeFilter
    public var channelID: String
    public var eventType: String

    public init(outcome: NotifySentOutcomeFilter = .all, channelID: String = "", eventType: String = "") {
        self.outcome = outcome
        self.channelID = channelID
        self.eventType = eventType
    }

    public var isEmpty: Bool { outcome == .all && channelID.isEmpty && eventType.isEmpty }

    public func query(limit: Int = NotifySentFilters.limit) -> DeliveryQuery {
        DeliveryQuery(
            channelID: channelID.isEmpty ? nil : channelID,
            eventType: eventType.isEmpty ? nil : eventType,
            outcome: outcome == .all ? nil : outcome.rawValue,
            limit: limit
        )
    }
}

/// The search grammar of the Sent log, run on the phone over the rows the
/// server returned: bare words search the title, body, channel and event.
public enum NotifySentQueryFields: QueryFieldProvider {
    public static var fields: [LatticeQueryField<NotifyDelivery>] {
        [
            LatticeQueryField(key: "state", aliases: ["outcome"], type: .enumeration,
                              values: NotifySentState.allCases.map(\.rawValue),
                              valueAliases: ["routed": "sent", "unrouted": "not_routed", "suppressed": "held", "planned": "retrying"]) {
                .string(NotifySentState.of($0, now: Date()).rawValue)
            },
            LatticeQueryField(key: "channel", type: .string) { .strings([$0.channelID, $0.channelName].filter { !$0.isEmpty }) },
            LatticeQueryField(key: "kind", type: .string) { .string($0.channelKind) },
            LatticeQueryField(key: "event", aliases: ["type"], type: .string) { .string($0.eventType) },
            LatticeQueryField(key: "rule", type: .string) { .strings([$0.ruleID, $0.ruleName].filter { !$0.isEmpty }) },
            LatticeQueryField(key: "severity", type: .enumeration, values: ["info", "notice", "warning", "critical"]) { .string($0.severity) },
            LatticeQueryField(key: "source", type: .enumeration, values: ["server", "plugin", "webhook", "operator"]) { .string($0.source) },
            LatticeQueryField(key: "role", type: .enumeration, values: ["primary", "fallback", "test"]) { .string($0.role) },
            LatticeQueryField(key: "incident", type: .list) { .strings($0.incidentIDs) },
            LatticeQueryField(key: "recovery", type: .bool, flag: true) { .bool($0.recovery) },
            LatticeQueryField(key: "time", aliases: ["at"], type: .time) { $0.createdAt.map { .time($0) } ?? .none },
        ]
    }

    public static func text(_ row: NotifyDelivery) -> [String] {
        [row.title, row.body, row.channelName, row.eventType, row.ruleName]
    }
}

// MARK: Channel health

/// One line for a channel's health (`channelHealthLine`).
public struct NotifyChannelHealthLine: Equatable, Sendable {
    public enum State: String, Sendable {
        /// A server older than the outbox, which sends no health.
        case unreported, unknown, ok, degraded, failing

        /// The section 4.2 word a channel row shows for this state.
        public var word: String {
            switch self {
            case .unreported: "health not reported"
            case .unknown: "no sends yet"
            case .ok: "delivering"
            case .degraded: "last send failed"
            case .failing: "failing"
            }
        }
    }

    public var state: State
    /// When the claim dates from: the last success, the last failure, or failing since.
    public var at: Date?
    public var failures: Int
    public var cause: NotifyFailureCause?

    public static func of(_ health: NotifyChannelHealth?) -> NotifyChannelHealthLine {
        guard let health else { return NotifyChannelHealthLine(state: .unreported, failures: 0) }
        let cause = health.lastFailureKind.isEmpty ? nil : NotifyFailureCause.of(kind: health.lastFailureKind, status: health.lastStatusCode)
        switch health.state {
        case "failing":
            return NotifyChannelHealthLine(state: .failing, at: health.failingSince ?? health.lastFailureAt, failures: health.consecutiveFailures, cause: cause)
        case "degraded":
            return NotifyChannelHealthLine(state: .degraded, at: health.lastFailureAt, failures: health.consecutiveFailures, cause: cause)
        case "ok":
            return NotifyChannelHealthLine(state: .ok, at: health.lastOKAt ?? health.lastAttemptAt, failures: 0)
        default:
            return NotifyChannelHealthLine(state: .unknown, failures: 0)
        }
    }
}

public enum NotifyChannels {
    /// Enabled channels the server calls failing, worst first: the longest
    /// run of failures, then the earliest start (`failingChannels`).
    public static func failing(_ channels: [NotifyChannel]) -> [NotifyChannel] {
        channels
            .filter { $0.enabled && $0.health?.state == "failing" }
            .sorted { a, b in
                let fa = a.health?.consecutiveFailures ?? 0, fb = b.health?.consecutiveFailures ?? 0
                if fa != fb { return fa > fb }
                return (a.health?.failingSince ?? .distantFuture) < (b.health?.failingSince ?? .distantFuture)
            }
    }

    /// Bark channels by name, the witness's choices (`barkChannels`).
    public static func bark(_ channels: [NotifyChannel]) -> [NotifyChannel] {
        channels.filter { $0.kind == "bark" }.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    /// Enabled rules that send to this channel.
    public static func rules(routingTo channelID: String, in rules: [NotifyRule]) -> [NotifyRule] {
        rules.filter { $0.channelIDs.contains(channelID) }
    }

    /// Rules and channels that hand their failures to this channel.
    public static func fallbackUsers(of channelID: String, channels: [NotifyChannel], rules: [NotifyRule]) -> (channels: [NotifyChannel], rules: [NotifyRule]) {
        (channels.filter { $0.fallbackChannelID == channelID && $0.id != channelID }, rules.filter { $0.fallbackChannelID == channelID })
    }
}

/// What deleting a channel stops (`channelDeleteImpact`, design 23 section
/// 3.8). Once one enabled rule exists only rules deliver, so an enabled rule
/// whose every other channel is gone or off stops reaching anyone; then the
/// operator types the channel's name. The server also clears every rule's
/// fallback that pointed at the channel, so an enabled rule that loses its
/// fallback asks for the typed name too; the console's model does not say so.
public struct NotifyChannelDeleteImpact: Equatable, Sendable {
    public enum Line: Equatable, Sendable {
        case silenced(rule: String, events: String)
        case kept(rule: String, others: [String])
        case noRules
        case unrouted
        case rulesUnread
        /// An enabled rule whose fallback is the channel; `primary` names its other enabled channels.
        case fallbackLost(rule: String, primary: [String])
        /// An enabled channel that hands its failed critical messages to this one.
        case channelFallbackLost(channel: String)
    }

    public var lines: [Line]
    public var typed: Bool

    public init(lines: [Line], typed: Bool) {
        self.lines = lines
        self.typed = typed
    }

    public static func of(_ target: NotifyChannel, rules: [NotifyRule]?, channels: [NotifyChannel]) -> NotifyChannelDeleteImpact {
        let channelFallbacks: [Line] = channels
            .filter { $0.enabled && $0.id != target.id && $0.fallbackChannelID == target.id }
            .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
            .map { .channelFallbackLost(channel: $0.displayName) }
        guard let rules else { return NotifyChannelDeleteImpact(lines: [.rulesUnread] + channelFallbacks, typed: true) }
        let enabled = rules.filter(\.enabled)
        if enabled.isEmpty { return NotifyChannelDeleteImpact(lines: (target.enabled ? [.noRules] : []) + channelFallbacks, typed: false) }
        var silenced: [Line] = []
        var kept: [Line] = []
        var fallbacks: [Line] = []
        for rule in enabled.sorted(by: { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }) {
            let others = rule.channelIDs
                .filter { $0 != target.id }
                .compactMap { id in channels.first { $0.id == id && $0.enabled } }
                .map(\.displayName)
            if rule.channelIDs.contains(target.id) {
                let events = (rule.eventTypes.isEmpty ? ["*"] : rule.eventTypes).joined(separator: ", ")
                if others.isEmpty {
                    // It reaches no one at all, which already says more than a lost fallback.
                    silenced.append(.silenced(rule: rule.displayName, events: events))
                    continue
                }
                kept.append(.kept(rule: rule.displayName, others: others))
            }
            if rule.fallbackChannelID == target.id, !others.isEmpty {
                fallbacks.append(.fallbackLost(rule: rule.displayName, primary: others))
            }
        }
        let routed = silenced + kept
        return NotifyChannelDeleteImpact(lines: (routed.isEmpty ? [.unrouted] : routed) + fallbacks + channelFallbacks,
                                         typed: !silenced.isEmpty || !fallbacks.isEmpty)
    }

    /// One sentence per line, for the ConfirmSheet.
    public func sentences(channel: String) -> [String] {
        lines.map { line in
            switch line {
            case .silenced(let rule, let events): "Rule \(rule) stops reaching anyone: \(channel) is its only enabled channel (\(events))."
            case .kept(let rule, let others): "Rule \(rule) keeps sending to \(others.joined(separator: ", "))."
            case .noRules: "No rule is enabled, so every channel gets every event; \(channel) simply stops receiving them."
            case .unrouted: "No enabled rule sends to \(channel)."
            case .rulesUnread: "The rules could not be read, so what stops is unknown."
            case .fallbackLost(let rule, let primary): "Rule \(rule) loses its fallback: when \(primary.joined(separator: " or ")) fails, nothing takes over."
            case .channelFallbackLost(let other): "\(other) loses its fallback: critical messages it fails to send go nowhere else."
            }
        }
    }
}

// MARK: Rules

public enum NotifyRules {
    /// lattice-server incidents.go: re-send an unacknowledged critical incident after 30 min at Bark level critical.
    public static let escalateDefaultMinutes = 30
    public static let escalationDefaultLevel = "critical"

    /// True when a rule matches every event type.
    public static func matchesEverything(_ rule: NotifyRule) -> Bool {
        rule.eventTypes.isEmpty || rule.eventTypes.contains("*")
    }

    /// An enabled rule whose channels are all off or gone sends nowhere.
    public static func reachesNoChannel(_ rule: NotifyRule, channels: [NotifyChannel]) -> Bool {
        rule.enabled && !rule.channelIDs.contains { id in channels.contains { $0.id == id && $0.enabled } }
    }

    /// "23:00 to 07:00, Asia/Shanghai", or nil when quiet hours are off.
    public static func quietHoursText(_ rule: NotifyRule) -> String? {
        rule.quietHours.map { "\($0.start) to \($0.end), \($0.timeZone)" }
    }

    /// The escalation sentence (`ruleIncidentSummary`).
    public static func escalationText(_ rule: NotifyRule) -> String {
        if rule.escalationOff { return "Off" }
        let minutes = rule.escalateAfterMinutes == 0 ? escalateDefaultMinutes : rule.escalateAfterMinutes
        let level = rule.escalationBarkLevel.isEmpty ? escalationDefaultLevel : rule.escalationBarkLevel
        let after = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        let text = "Re-sends an unacknowledged critical incident after \(after), at Bark level \(level)"
        return minutes == escalateDefaultMinutes && level == escalationDefaultLevel ? text + " (default)" : text
    }
}

// MARK: Webhooks

public enum NotifyWebhookRouting: Equatable, Sendable {
    case noChannel, noRule, ok
    /// The channels or rules could not be read, so nothing is claimed.
    case unknown

    /// Whether an enabled rule routes an event type; a rule with no event
    /// types matches everything, and with no enabled rule the dispatcher
    /// sends every event to every enabled channel.
    public static func routed(_ eventType: String, rules: [NotifyRule]) -> Bool {
        let enabled = rules.filter(\.enabled)
        if enabled.isEmpty { return true }
        return enabled.contains { NotifyRules.matchesEverything($0) || $0.eventTypes.contains(eventType) }
    }

    /// The routing notice for one webhook (`routingState`).
    public static func of(_ hook: NotifyWebhook, channels: [NotifyChannel]?, rules: [NotifyRule]?) -> NotifyWebhookRouting {
        guard let channels else { return .unknown }
        if !channels.contains(where: \.enabled) { return .noChannel }
        guard let rules else { return .unknown }
        return routed(hook.eventType, rules: rules) ? .ok : .noRule
    }

    /// An enabled webhook no rule routes answers 202 and reaches nobody
    /// (`reachesNobody`); claimed only when the reads landed.
    public static func reachesNobody(_ hook: NotifyWebhook, channels: [NotifyChannel]?, rules: [NotifyRule]?) -> Bool {
        guard hook.enabled else { return false }
        let state = of(hook, channels: channels, rules: rules)
        return state == .noChannel || state == .noRule
    }
}

/// A webhook's health from its newest attempt (`webhookHealth`).
public enum NotifyWebhookHealth: String, Sendable {
    case never, ok
    case noRoute = "no_route"
    case rejecting, failing

    public static func of(_ deliveries: [NotifyWebhookDelivery]) -> NotifyWebhookHealth {
        guard let latest = deliveries.first else { return .never }
        switch latest.outcome {
        case "accepted": return .ok
        case "no_route": return .noRoute
        case "rejected": return .rejecting
        default: return .failing
        }
    }

    public var title: String {
        switch self {
        case .never: "Never called"
        case .ok: "Delivering"
        case .noRoute: "Reaching nobody"
        case .failing: "Delivery failing"
        case .rejecting: "Calls refused"
        }
    }
}

public enum NotifyWebhookAttempt {
    /// The outcome word of one attempt.
    public static func word(_ outcome: String) -> String {
        switch outcome {
        case "accepted": "accepted"
        case "no_route": "reached nobody"
        case "rejected": "refused"
        case "failed": "delivery failed"
        case "partial": "partly delivered"
        default: outcome.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// "delivered to 1 of 2 channels, 3 fields, from 203.0.113.9".
    public static func detail(_ delivery: NotifyWebhookDelivery) -> String {
        let reach: String
        if delivery.channels == 0 {
            reach = "reached no channel"
        } else {
            reach = "delivered to \(delivery.delivered) of \(delivery.channels) \(delivery.channels == 1 ? "channel" : "channels")"
        }
        var parts = [reach, delivery.fields == 1 ? "1 field" : "\(delivery.fields) fields"]
        if !delivery.sourceIP.isEmpty { parts.append("from \(delivery.sourceIP)") }
        return parts.joined(separator: ", ")
    }
}

// MARK: Witness

/// One sentence for a witness node (`witnessLine`).
public struct NotifyWitnessLine: Equatable, Sendable {
    public enum Key: String, Sendable {
        case notConfigured, planned, neverReported, notReporting, stopped, starting, watching, failing, down, networkDown, unknown
    }

    public enum Tone: Sendable { case quiet, warn, fail }

    public var key: Key
    public var tone: Tone
    public var at: Date?
    public var since: Date?
    public var detail: String
    public var failures: Int

    init(_ key: Key, _ tone: Tone, at: Date? = nil, since: Date? = nil, detail: String = "", failures: Int = 0) {
        self.key = key
        self.tone = tone
        self.at = at
        self.since = since
        self.detail = detail
        self.failures = failures
    }

    public static func of(_ node: NotifyWitnessNode) -> NotifyWitnessLine {
        let report = node.report
        if node.configured == nil, !(report != nil && node.reportFresh) {
            if let pending = node.pending { return NotifyWitnessLine(.planned, .quiet, at: pending.createdAt) }
            return NotifyWitnessLine(.notConfigured, .quiet)
        }
        guard let report else { return NotifyWitnessLine(.neverReported, .warn) }
        if !node.reportFresh { return NotifyWitnessLine(.notReporting, .warn, at: node.reportedAt) }
        if node.checkStale { return NotifyWitnessLine(.stopped, .warn, at: report.lastCheckAt ?? report.startedAt) }
        switch report.phase {
        case "watching": return NotifyWitnessLine(.watching, .quiet, at: report.lastCheckAt)
        case "starting": return NotifyWitnessLine(.starting, .quiet, at: report.startedAt)
        case "failing":
            return NotifyWitnessLine(.failing, .warn, at: report.lastCheckAt, since: report.failingSince, detail: report.lastCheckDetail, failures: report.consecutiveFailures)
        case "down":
            return NotifyWitnessLine(.down, .fail, at: report.alertedAt ?? report.lastPushAt, since: report.downSince ?? report.failingSince, detail: report.lastCheckDetail)
        case "network_down":
            return NotifyWitnessLine(.networkDown, .warn, at: report.lastCheckAt, since: report.networkDownSince)
        default:
            return NotifyWitnessLine(.unknown, .warn, at: report.lastCheckAt)
        }
    }

    /// The state word of a witness row.
    public var word: String {
        switch key {
        case .notConfigured: "not configured"
        case .planned: "planned"
        case .neverReported: "never reported"
        case .notReporting: "not reporting"
        case .stopped: "stopped"
        case .starting: "starting"
        case .watching: "watching"
        case .failing: "not answering"
        case .down: "sees it down"
        case .networkDown: "network down"
        case .unknown: "unknown"
        }
    }

    /// The console's sentence for the line.
    public func sentence(mode: TimeZoneMode, locale: Locale, now: Date) -> String {
        func clock(_ date: Date?) -> String {
            guard let date else { return "at an unknown time" }
            return NotifyClock.when(date, mode: mode, locale: locale, now: now)
        }
        func ago(_ date: Date?) -> String {
            guard let date else { return "at an unknown time" }
            return TimeDisplay.relative(date, now: now, locale: locale)
        }
        switch key {
        case .notConfigured: return "No witness is configured on this node."
        case .planned: return "A plan is waiting for approval."
        case .neverReported: return "Applied, but its status has never arrived: the agent may predate the relay, or the unit is not running."
        case .notReporting: return "Last status \(ago(at)). The node or its agent may be down, and the witness with it."
        case .stopped: return "Stopped: last check \(ago(at)). The agent still relays its status, but the witness is not checking; its service may be stopped or stuck."
        case .starting: return "Starting, no check yet (since \(clock(at)))."
        case .watching: return "Watching: the control plane answered \(ago(at))."
        case .failing:
            let checks = failures == 1 ? "1 check" : "\(failures) checks"
            let reason = detail.isEmpty ? "" : " (\(detail))"
            return "Not answering since \(clock(since)), \(checks) in a row\(reason). It pushes once the hold passes."
        case .down: return "Sees the control plane down since \(clock(since)); pushed the alert \(ago(at))."
        case .networkDown: return "This node's own network has been down since \(clock(since)), so it is not judging the control plane."
        case .unknown: return "Reports a state this app does not know."
        }
    }
}

public enum NotifyWitness {
    /// Nodes the witness card lists: anything configured, planned, failed,
    /// or reporting now.
    public static func shownNodes(_ status: NotifyWitnessStatus) -> [NotifyWitnessNode] {
        status.nodes.filter { $0.configured != nil || $0.pending != nil || $0.lastFailed != nil || ($0.report != nil && $0.reportFresh) }
    }

    public static func configuredCount(_ status: NotifyWitnessStatus) -> Int {
        status.nodes.filter { $0.configured != nil }.count
    }

    /// Whether the node runs the config the last applied plan wrote.
    public enum ConfigState: String, Sendable { case matches, differs, unknown }

    public static func configState(_ node: NotifyWitnessNode) -> ConfigState {
        guard node.configured != nil, let report = node.report, node.reportFresh, !report.configSHA256.isEmpty else { return .unknown }
        return node.configMatches ? .matches : .differs
    }

    /// The witness's last push, or nil before any report.
    public static func pushLine(_ report: NotifyWitnessReport?, mode: TimeZoneMode, locale: Locale, now: Date) -> String? {
        guard let report else { return nil }
        let total = report.pushes == 1 ? "1 push in all" : "\(report.pushes) pushes in all"
        guard let at = report.lastPushAt, report.lastPushKind == "down" || report.lastPushKind == "recovery" else {
            return "None yet"
        }
        let result = report.lastPushOK ? "accepted" : (report.lastPushError.isEmpty ? "not accepted" : "not accepted (\(report.lastPushError))")
        let kind = report.lastPushKind == "down" ? "Unreachable alert" : "Recovery"
        return "\(kind), \(result) \(TimeDisplay.relative(at, now: now, locale: locale)). \(total)."
    }

    public static func pushFailed(_ node: NotifyWitnessNode) -> Bool {
        guard node.reportFresh, let report = node.report, report.lastPushAt != nil,
              report.lastPushKind == "down" || report.lastPushKind == "recovery" else { return false }
        return !report.lastPushOK
    }

    /// What about the witness needs the operator, worst first (`witnessAttention`).
    public enum AttentionKind: String, Sendable {
        case down, failing, networkDown, neverReported, notReporting, stopped, pushFailed, planFailed, differs
    }

    public struct Attention: Equatable, Sendable {
        public var kind: AttentionKind
        public var isFailure: Bool
        public var node: NotifyWitnessNode
        public var line: NotifyWitnessLine

        /// The state word of the attention row.
        public var word: String {
            switch kind {
            case .pushFailed: "push failed"
            case .planFailed: "plan failed"
            case .differs: "config differs"
            default: line.word
            }
        }

        public var claim: String {
            let name = node.nodeName
            switch kind {
            case .down: return "The witness on \(name) sees the control plane down."
            case .failing: return "The witness on \(name) cannot reach the control plane."
            case .networkDown: return "The witness on \(name) has lost its own network."
            case .neverReported: return "The witness on \(name) has never reported."
            case .notReporting: return "The witness on \(name) stopped reporting."
            case .stopped: return "The witness on \(name) has stopped checking."
            case .pushFailed: return "The witness on \(name) could not push through its Bark server."
            case .planFailed: return "The last witness plan for \(name) failed."
            case .differs: return "The witness on \(name) runs a config that differs from the last applied plan."
            }
        }
    }

    public static func attention(_ nodes: [NotifyWitnessNode]) -> [Attention] {
        var out: [Attention] = []
        for node in nodes {
            let line = NotifyWitnessLine.of(node)
            let kind: AttentionKind? = switch line.key {
            case .down: .down
            case .failing: .failing
            case .networkDown: .networkDown
            case .neverReported: .neverReported
            case .notReporting: .notReporting
            case .stopped: .stopped
            default: nil
            }
            if let kind { out.append(Attention(kind: kind, isFailure: kind == .down, node: node, line: line)) }
            if pushFailed(node) { out.append(Attention(kind: .pushFailed, isFailure: false, node: node, line: line)) }
            if node.lastFailed != nil { out.append(Attention(kind: .planFailed, isFailure: false, node: node, line: line)) }
            if configState(node) == .differs { out.append(Attention(kind: .differs, isFailure: false, node: node, line: line)) }
        }
        // A stable sort: failures first, the rest in node order.
        return out.enumerated().sorted { a, b in
            a.element.isFailure != b.element.isFailure ? a.element.isFailure : a.offset < b.offset
        }.map(\.element)
    }

    /// What a node's witness watches: its applied plan's URL, else what it
    /// reports, else the server's default (`witnessWatch`).
    public static func watch(_ node: NotifyWitnessNode, defaultURL: String) -> (url: String, custom: Bool)? {
        let url = [node.configured?.healthURL, node.report?.healthURL, defaultURL].compactMap { $0 }.first { !$0.isEmpty }
        guard let url else { return nil }
        return (url, url != defaultURL)
    }

    /// What a plan filed from the phone carries over from the node's current
    /// witness. The phone sends no timing or references, so the server would
    /// put its defaults in their place.
    public struct ChangeBasis: Equatable, Sendable {
        /// The operator's watch URL to send again, or empty for the server's default.
        public var healthURL: String
        /// The witness runs timing or reference URLs other than the defaults,
        /// which a plan from the phone would reset; such a change belongs on the web.
        public var customSettings: Bool

        public init(healthURL: String = "", customSettings: Bool = false) {
            self.healthURL = healthURL
            self.customSettings = customSettings
        }
    }

    public static func changeBasis(_ node: NotifyWitnessNode?, status: NotifyWitnessStatus) -> ChangeBasis {
        guard let node, node.configured != nil || node.report != nil else { return ChangeBasis() }
        let watched = watch(node, defaultURL: status.healthURL)
        var custom = false
        if let report = node.report {
            let d = status.defaults
            // An agent that predates a field reports zero for it, which says nothing.
            if report.intervalSeconds > 0 && report.intervalSeconds != d.intervalSeconds { custom = true }
            if report.holdSeconds > 0 && report.holdSeconds != d.holdSeconds { custom = true }
            if report.referenceCount > 0 && report.referenceCount != d.referenceURLs.count { custom = true }
        }
        return ChangeBasis(healthURL: watched?.custom == true ? watched?.url ?? "" : "", customSettings: custom)
    }

    /// Mirrors the server and the witness: an http(s) base URL on the
    /// node's loopback interface, with no credentials, query or fragment.
    public static func isLoopbackBaseURL(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host?.lowercased(), !host.isEmpty else { return false }
        if components.user != nil || components.password != nil || components.query != nil || components.fragment != nil { return false }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare == "localhost" || bare == "::1" { return true }
        let octets = bare.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { $0.count <= 3 && !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// What keeps the phone's plan from filing, checked as the server does.
    public enum FormProblem: String, Sendable {
        case customSettings, node, channel, barkURL, barkURLLoopback, healthURLRequired

        public var sentence: String {
            switch self {
            case .customSettings: "This witness runs timing or reference URLs set on the web. A plan from the phone would reset them to the server's defaults, so change it on the web."
            case .node: "Choose a node."
            case .channel: "Choose a Bark channel."
            case .barkURL: "Enter the local bark-server URL."
            case .barkURLLoopback: "Use the node's loopback address (127.0.0.1, ::1 or localhost) and no query string."
            case .healthURLRequired: "This server has no public URL, so the witness needs a watch URL. Set it up on the web."
            }
        }
    }

    public static func formProblems(nodeID: String, channelID: String, barkURL: String, defaultHealthURL: String, basis: ChangeBasis = ChangeBasis()) -> [FormProblem] {
        var problems: [FormProblem] = basis.customSettings ? [.customSettings] : []
        if nodeID.isEmpty { problems.append(.node) }
        if channelID.isEmpty { problems.append(.channel) }
        if barkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append(.barkURL)
        } else if !isLoopbackBaseURL(barkURL) {
            problems.append(.barkURLLoopback)
        }
        if defaultHealthURL.isEmpty && basis.healthURL.isEmpty { problems.append(.healthURLRequired) }
        return problems
    }
}
