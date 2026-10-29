import Foundation

// Server shapes of the notify surface (lattice-server internal/server:
// server.go notifyChannelView, server_notify_outbox.go notifyRuleView and
// notifyChannelHealthView, notify_catalogue.go, server_witness_status.go and
// server_notify_webhook.go). Every field the server may leave out decodes to
// an empty value, so an older server still reads.

private extension KeyedDecodingContainer {
    func string(_ key: Key) throws -> String { try decodeIfPresent(String.self, forKey: key) ?? "" }
    func int(_ key: Key) throws -> Int { try decodeIfPresent(Int.self, forKey: key) ?? 0 }
    func bool(_ key: Key) throws -> Bool { try decodeIfPresent(Bool.self, forKey: key) ?? false }
    func strings(_ key: Key) throws -> [String] { try decodeIfPresent([String].self, forKey: key) ?? [] }
    func date(_ key: Key) throws -> Date? { try DateValue.decodeIfPresent(from: self, forKey: key) }
}

/// A channel's delivery health, decided by the server (`notifyChannelHealthState`).
public struct NotifyChannelHealth: Codable, Equatable, Hashable, Sendable {
    /// unknown, ok, degraded or failing.
    public var state: String
    public var lastAttemptAt: Date?
    public var lastOKAt: Date?
    public var lastFailureAt: Date?
    /// upstream_4xx, upstream_5xx, rate_limited, timeout, network, config_invalid.
    public var lastFailureKind: String
    public var lastStatusCode: Int
    public var consecutiveFailures: Int
    public var failingSince: Date?
    public var lastFallbackAt: Date?
    public var lastFallbackChannelID: String
    public var fallbacks: Int

    public init(state: String, lastAttemptAt: Date? = nil, lastOKAt: Date? = nil, lastFailureAt: Date? = nil, lastFailureKind: String = "", lastStatusCode: Int = 0, consecutiveFailures: Int = 0, failingSince: Date? = nil, lastFallbackAt: Date? = nil, lastFallbackChannelID: String = "", fallbacks: Int = 0) {
        self.state = state
        self.lastAttemptAt = lastAttemptAt
        self.lastOKAt = lastOKAt
        self.lastFailureAt = lastFailureAt
        self.lastFailureKind = lastFailureKind
        self.lastStatusCode = lastStatusCode
        self.consecutiveFailures = consecutiveFailures
        self.failingSince = failingSince
        self.lastFallbackAt = lastFallbackAt
        self.lastFallbackChannelID = lastFallbackChannelID
        self.fallbacks = fallbacks
    }

    enum CodingKeys: String, CodingKey {
        case state, fallbacks
        case lastAttemptAt = "last_attempt_at"
        case lastOKAt = "last_ok_at"
        case lastFailureAt = "last_failure_at"
        case lastFailureKind = "last_failure_kind"
        case lastStatusCode = "last_status_code"
        case consecutiveFailures = "consecutive_failures"
        case failingSince = "failing_since"
        case lastFallbackAt = "last_fallback_at"
        case lastFallbackChannelID = "last_fallback_channel_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.string(.state)
        lastAttemptAt = try c.date(.lastAttemptAt)
        lastOKAt = try c.date(.lastOKAt)
        lastFailureAt = try c.date(.lastFailureAt)
        lastFailureKind = try c.string(.lastFailureKind)
        lastStatusCode = try c.int(.lastStatusCode)
        consecutiveFailures = try c.int(.consecutiveFailures)
        failingSince = try c.date(.failingSince)
        lastFallbackAt = try c.date(.lastFallbackAt)
        lastFallbackChannelID = try c.string(.lastFallbackChannelID)
        fallbacks = try c.int(.fallbacks)
    }
}

public struct NotifyChannel: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// telegram, bark, discord or webhook.
    public var kind: String
    /// The configured keys; the server never returns a value.
    public var configKeys: [String]
    public var enabled: Bool
    public var createdAt: Date?
    public var updatedAt: Date?
    /// Nil on a server older than the outbox, which reports no health.
    public var health: NotifyChannelHealth?
    /// The channel that takes the critical messages this one fails.
    public var fallbackChannelID: String
    /// The event types the server counts as critical for the fallback.
    public var criticalEventTypes: [String]

    public init(id: String, name: String = "", kind: String = "", configKeys: [String] = [], enabled: Bool = false, createdAt: Date? = nil, updatedAt: Date? = nil, health: NotifyChannelHealth? = nil, fallbackChannelID: String = "", criticalEventTypes: [String] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.configKeys = configKeys
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.health = health
        self.fallbackChannelID = fallbackChannelID
        self.criticalEventTypes = criticalEventTypes
    }

    public var displayName: String { name.isEmpty ? id : name }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, enabled, health
        case configKeys = "config_keys"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case fallbackChannelID = "fallback_channel_id"
        case criticalEventTypes = "critical_event_types"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.string(.name)
        kind = try container.string(.kind)
        configKeys = try container.strings(.configKeys)
        enabled = try container.bool(.enabled)
        createdAt = try container.date(.createdAt)
        updatedAt = try container.date(.updatedAt)
        health = try container.decodeIfPresent(NotifyChannelHealth.self, forKey: .health)
        fallbackChannelID = try container.string(.fallbackChannelID)
        criticalEventTypes = try container.strings(.criticalEventTypes)
    }
}

/// A rule's quiet hours: two HH:MM times in an IANA zone; an end not after
/// its start runs past midnight.
public struct NotifyQuietHours: Codable, Equatable, Hashable, Sendable {
    public var start: String
    public var end: String
    public var timeZone: String

    public init(start: String, end: String, timeZone: String) {
        self.start = start
        self.end = end
        self.timeZone = timeZone
    }

    enum CodingKeys: String, CodingKey {
        case start, end
        case timeZone = "time_zone"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.string(.start)
        end = try c.string(.end)
        timeZone = try c.string(.timeZone)
    }
}

public struct NotifyRule: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Empty (or "*") matches every event, as the dispatcher reads it.
    public var eventTypes: [String]
    public var channelIDs: [String]
    public var titleTemplate: String
    public var bodyTemplate: String
    public var enabled: Bool
    public var createdAt: Date?
    public var updatedAt: Date?
    public var fallbackChannelID: String
    public var escalationOff: Bool
    /// The effective delay, default included (30).
    public var escalateAfterMinutes: Int
    /// The effective Bark level, default included (critical).
    public var escalationBarkLevel: String
    public var quietHours: NotifyQuietHours?

    public init(id: String, name: String = "", eventTypes: [String] = [], channelIDs: [String] = [], titleTemplate: String = "", bodyTemplate: String = "", enabled: Bool = false, createdAt: Date? = nil, updatedAt: Date? = nil, fallbackChannelID: String = "", escalationOff: Bool = false, escalateAfterMinutes: Int = 0, escalationBarkLevel: String = "", quietHours: NotifyQuietHours? = nil) {
        self.id = id
        self.name = name
        self.eventTypes = eventTypes
        self.channelIDs = channelIDs
        self.titleTemplate = titleTemplate
        self.bodyTemplate = bodyTemplate
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.fallbackChannelID = fallbackChannelID
        self.escalationOff = escalationOff
        self.escalateAfterMinutes = escalateAfterMinutes
        self.escalationBarkLevel = escalationBarkLevel
        self.quietHours = quietHours
    }

    public var displayName: String { name.isEmpty ? id : name }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled
        case eventTypes = "event_types"
        case channelIDs = "channel_ids"
        case titleTemplate = "title_template"
        case bodyTemplate = "body_template"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case fallbackChannelID = "fallback_channel_id"
        case escalationOff = "escalation_off"
        case escalateAfterMinutes = "escalate_after_minutes"
        case escalationBarkLevel = "escalation_bark_level"
        case quietHours = "quiet_hours"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.string(.name)
        eventTypes = try container.strings(.eventTypes)
        channelIDs = try container.strings(.channelIDs)
        titleTemplate = try container.string(.titleTemplate)
        bodyTemplate = try container.string(.bodyTemplate)
        enabled = try container.bool(.enabled)
        createdAt = try container.date(.createdAt)
        updatedAt = try container.date(.updatedAt)
        fallbackChannelID = try container.string(.fallbackChannelID)
        escalationOff = try container.bool(.escalationOff)
        escalateAfterMinutes = try container.int(.escalateAfterMinutes)
        escalationBarkLevel = try container.string(.escalationBarkLevel)
        quietHours = try container.decodeIfPresent(NotifyQuietHours.self, forKey: .quietHours)
    }
}

// MARK: Catalogue

/// `GET /api/notify/catalogue`: how every event type is presented.
public struct NotifyCatalogue: Decodable, Equatable, Sendable {
    public struct Category: Decodable, Equatable, Hashable, Sendable {
        public var id: String
        public var label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    public struct Entry: Decodable, Equatable, Hashable, Sendable {
        public var type: String
        /// Set on a pattern entry ("plugin.<id>.message").
        public var pattern: String
        public var category: String
        /// info, notice, warning or critical.
        public var severity: String
        public var recovery: Bool
        /// A lucide icon name; the phone draws SF Symbols instead.
        public var icon: String
        /// One English line, the label.
        public var description: String

        public init(type: String, pattern: String = "", category: String, severity: String, recovery: Bool = false, icon: String = "", description: String) {
            self.type = type
            self.pattern = pattern
            self.category = category
            self.severity = severity
            self.recovery = recovery
            self.icon = icon
            self.description = description
        }

        enum CodingKeys: String, CodingKey { case type, pattern, category, severity, recovery, icon, description }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.string(.type)
            pattern = try c.string(.pattern)
            category = try c.string(.category)
            severity = try c.string(.severity)
            recovery = try c.bool(.recovery)
            icon = try c.string(.icon)
            description = try c.string(.description)
        }
    }

    public var categories: [Category]
    public var types: [Entry]
    public var patterns: [Entry]
    public var webhookTypes: [Entry]

    public init(categories: [Category] = [], types: [Entry] = [], patterns: [Entry] = [], webhookTypes: [Entry] = []) {
        self.categories = categories
        self.types = types
        self.patterns = patterns
        self.webhookTypes = webhookTypes
    }

    enum CodingKeys: String, CodingKey {
        case categories, types, patterns
        case webhookTypes = "webhook_types"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        categories = try c.decodeIfPresent([Category].self, forKey: .categories) ?? []
        types = try c.decodeIfPresent([Entry].self, forKey: .types) ?? []
        patterns = try c.decodeIfPresent([Entry].self, forKey: .patterns) ?? []
        webhookTypes = try c.decodeIfPresent([Entry].self, forKey: .webhookTypes) ?? []
    }

    /// The entry for an event type: exact, then a plugin's message, then an
    /// operator webhook's type (`notifyCatalogueLookup`); nil when none claims it.
    public func entry(for eventType: String) -> Entry? {
        if let exact = types.first(where: { $0.type == eventType }) { return exact }
        if NotifyCatalogue.isPluginMessage(eventType), var pattern = patterns.first {
            pattern.type = eventType
            return pattern
        }
        return webhookTypes.first { $0.type == eventType }
    }

    /// The readable label of an event type, or the type itself.
    public func label(for eventType: String) -> String {
        entry(for: eventType)?.description ?? eventType
    }

    /// `plugin.<id>.message`, or `plugin.message` from a host call without an id.
    public static func isPluginMessage(_ eventType: String) -> Bool {
        if eventType == "plugin.message" { return true }
        guard eventType.hasPrefix("plugin."), eventType.hasSuffix(".message") else { return false }
        return eventType.count > "plugin.".count + ".message".count
    }
}

// MARK: Witness

/// The witness status file a node's agent relays on its heartbeat.
public struct NotifyWitnessReport: Decodable, Equatable, Hashable, Sendable {
    public var version: Int
    public var configSHA256: String
    public var startedAt: Date?
    /// starting, watching, failing, down or network_down.
    public var phase: String
    public var healthURL: String
    public var referenceCount: Int
    public var intervalSeconds: Int
    public var holdSeconds: Int
    public var lastCheckAt: Date?
    public var lastCheckOK: Bool
    /// A classified reason ("http 503", "timeout"), never raw error text.
    public var lastCheckDetail: String
    public var lastOKAt: Date?
    public var failingSince: Date?
    public var consecutiveFailures: Int
    public var networkDownSince: Date?
    public var alerted: Bool
    public var alertedAt: Date?
    public var downSince: Date?
    public var lastPushAt: Date?
    /// down or recovery.
    public var lastPushKind: String
    public var lastPushOK: Bool
    public var lastPushError: String
    public var pushes: Int
    public var relayedAt: Date?

    public init(phase: String) {
        self.version = 1
        self.configSHA256 = ""
        self.phase = phase
        self.healthURL = ""
        self.referenceCount = 0
        self.intervalSeconds = 0
        self.holdSeconds = 0
        self.lastCheckOK = false
        self.lastCheckDetail = ""
        self.consecutiveFailures = 0
        self.alerted = false
        self.lastPushKind = ""
        self.lastPushOK = false
        self.lastPushError = ""
        self.pushes = 0
    }

    enum CodingKeys: String, CodingKey {
        case version, phase, alerted, pushes
        case configSHA256 = "config_sha256"
        case startedAt = "started_at"
        case healthURL = "health_url"
        case referenceCount = "reference_count"
        case intervalSeconds = "interval_seconds"
        case holdSeconds = "hold_seconds"
        case lastCheckAt = "last_check_at"
        case lastCheckOK = "last_check_ok"
        case lastCheckDetail = "last_check_detail"
        case lastOKAt = "last_ok_at"
        case failingSince = "failing_since"
        case consecutiveFailures = "consecutive_failures"
        case networkDownSince = "network_down_since"
        case alertedAt = "alerted_at"
        case downSince = "down_since"
        case lastPushAt = "last_push_at"
        case lastPushKind = "last_push_kind"
        case lastPushOK = "last_push_ok"
        case lastPushError = "last_push_error"
        case relayedAt = "relayed_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.int(.version)
        configSHA256 = try c.string(.configSHA256)
        startedAt = try c.date(.startedAt)
        phase = try c.string(.phase)
        healthURL = try c.string(.healthURL)
        referenceCount = try c.int(.referenceCount)
        intervalSeconds = try c.int(.intervalSeconds)
        holdSeconds = try c.int(.holdSeconds)
        lastCheckAt = try c.date(.lastCheckAt)
        lastCheckOK = try c.bool(.lastCheckOK)
        lastCheckDetail = try c.string(.lastCheckDetail)
        lastOKAt = try c.date(.lastOKAt)
        failingSince = try c.date(.failingSince)
        consecutiveFailures = try c.int(.consecutiveFailures)
        networkDownSince = try c.date(.networkDownSince)
        alerted = try c.bool(.alerted)
        alertedAt = try c.date(.alertedAt)
        downSince = try c.date(.downSince)
        lastPushAt = try c.date(.lastPushAt)
        lastPushKind = try c.string(.lastPushKind)
        lastPushOK = try c.bool(.lastPushOK)
        lastPushError = try c.string(.lastPushError)
        pushes = try c.int(.pushes)
        relayedAt = try c.date(.relayedAt)
    }
}

/// The witness approval a node's status is read against.
public struct NotifyWitnessApproval: Decodable, Equatable, Hashable, Sendable {
    public var approvalID: String
    /// configure or remove.
    public var action: String
    public var status: String
    public var reason: String
    public var configSHA256: String
    public var channelID: String
    public var channelName: String
    public var keySHA256Prefix: String
    public var createdAt: Date?
    public var updatedAt: Date?
    public var healthURL: String

    public init(approvalID: String, action: String, status: String, reason: String = "", channelID: String = "", channelName: String = "", healthURL: String = "") {
        self.approvalID = approvalID
        self.action = action
        self.status = status
        self.reason = reason
        self.configSHA256 = ""
        self.channelID = channelID
        self.channelName = channelName
        self.keySHA256Prefix = ""
        self.healthURL = healthURL
    }

    enum CodingKeys: String, CodingKey {
        case action, status, reason
        case approvalID = "approval_id"
        case configSHA256 = "config_sha256"
        case channelID = "channel_id"
        case channelName = "channel_name"
        case keySHA256Prefix = "key_sha256_prefix"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case healthURL = "health_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        approvalID = try c.string(.approvalID)
        action = try c.string(.action)
        status = try c.string(.status)
        reason = try c.string(.reason)
        configSHA256 = try c.string(.configSHA256)
        channelID = try c.string(.channelID)
        channelName = try c.string(.channelName)
        keySHA256Prefix = try c.string(.keySHA256Prefix)
        createdAt = try c.date(.createdAt)
        updatedAt = try c.date(.updatedAt)
        healthURL = try c.string(.healthURL)
    }
}

/// One node's witness: the last applied plan, any plan still waiting, and
/// what the witness itself last reported.
public struct NotifyWitnessNode: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var nodeID: String
    public var nodeName: String
    public var capable: Bool
    public var configured: NotifyWitnessApproval?
    public var pending: NotifyWitnessApproval?
    public var lastFailed: NotifyWitnessApproval?
    public var report: NotifyWitnessReport?
    public var reportedAt: Date?
    public var reportFresh: Bool
    public var checkStale: Bool
    public var configMatches: Bool

    public var id: String { nodeID }

    public init(nodeID: String, nodeName: String, capable: Bool = true, configured: NotifyWitnessApproval? = nil, pending: NotifyWitnessApproval? = nil, lastFailed: NotifyWitnessApproval? = nil, report: NotifyWitnessReport? = nil, reportedAt: Date? = nil, reportFresh: Bool = false, checkStale: Bool = false, configMatches: Bool = false) {
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.capable = capable
        self.configured = configured
        self.pending = pending
        self.lastFailed = lastFailed
        self.report = report
        self.reportedAt = reportedAt
        self.reportFresh = reportFresh
        self.checkStale = checkStale
        self.configMatches = configMatches
    }

    enum CodingKeys: String, CodingKey {
        case capable, configured, pending, report
        case nodeID = "node_id"
        case nodeName = "node_name"
        case lastFailed = "last_failed"
        case reportedAt = "reported_at"
        case reportFresh = "report_fresh"
        case checkStale = "check_stale"
        case configMatches = "config_matches"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.string(.nodeID)
        nodeName = try c.string(.nodeName)
        capable = try c.bool(.capable)
        configured = try c.decodeIfPresent(NotifyWitnessApproval.self, forKey: .configured)
        pending = try c.decodeIfPresent(NotifyWitnessApproval.self, forKey: .pending)
        lastFailed = try c.decodeIfPresent(NotifyWitnessApproval.self, forKey: .lastFailed)
        report = try c.decodeIfPresent(NotifyWitnessReport.self, forKey: .report)
        reportedAt = try c.date(.reportedAt)
        reportFresh = try c.bool(.reportFresh)
        checkStale = try c.bool(.checkStale)
        configMatches = try c.bool(.configMatches)
    }
}

/// `GET /api/notify/witness`.
public struct NotifyWitnessStatus: Decodable, Equatable, Sendable {
    public struct CapableNode: Decodable, Equatable, Hashable, Sendable, Identifiable {
        public var nodeID: String
        public var nodeName: String
        public var online: Bool
        public var id: String { nodeID }

        public init(nodeID: String, nodeName: String, online: Bool) {
            self.nodeID = nodeID
            self.nodeName = nodeName
            self.online = online
        }

        enum CodingKeys: String, CodingKey {
            case online
            case nodeID = "node_id"
            case nodeName = "node_name"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            nodeID = try c.string(.nodeID)
            nodeName = try c.string(.nodeName)
            online = try c.bool(.online)
        }
    }

    public struct Defaults: Decodable, Equatable, Sendable {
        public var referenceURLs: [String]
        public var intervalSeconds: Int
        public var holdSeconds: Int
        public var recoverSeconds: Int
        public var barkLevel: String
        public var barkLevels: [String]
        public var keyFile: String
        public var configFile: String
        public var unit: String

        public init(intervalSeconds: Int = 30, holdSeconds: Int = 180, recoverSeconds: Int = 60, barkLevel: String = "critical") {
            self.referenceURLs = []
            self.intervalSeconds = intervalSeconds
            self.holdSeconds = holdSeconds
            self.recoverSeconds = recoverSeconds
            self.barkLevel = barkLevel
            self.barkLevels = []
            self.keyFile = ""
            self.configFile = ""
            self.unit = ""
        }

        enum CodingKeys: String, CodingKey {
            case unit
            case referenceURLs = "reference_urls"
            case intervalSeconds = "interval_seconds"
            case holdSeconds = "hold_seconds"
            case recoverSeconds = "recover_seconds"
            case barkLevel = "bark_level"
            case barkLevels = "bark_levels"
            case keyFile = "key_file"
            case configFile = "config_file"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            referenceURLs = try c.strings(.referenceURLs)
            intervalSeconds = try c.int(.intervalSeconds)
            holdSeconds = try c.int(.holdSeconds)
            recoverSeconds = try c.int(.recoverSeconds)
            barkLevel = try c.string(.barkLevel)
            barkLevels = try c.strings(.barkLevels)
            keyFile = try c.string(.keyFile)
            configFile = try c.string(.configFile)
            unit = try c.string(.unit)
        }
    }

    /// The control plane's own /readyz, empty when the server has no public URL.
    public var healthURL: String
    /// Why there is no health URL.
    public var healthURLError: String
    public var nodes: [NotifyWitnessNode]
    public var capableNodes: [CapableNode]
    public var defaults: Defaults

    public init(healthURL: String = "", healthURLError: String = "", nodes: [NotifyWitnessNode] = [], capableNodes: [CapableNode] = [], defaults: Defaults = Defaults()) {
        self.healthURL = healthURL
        self.healthURLError = healthURLError
        self.nodes = nodes
        self.capableNodes = capableNodes
        self.defaults = defaults
    }

    enum CodingKeys: String, CodingKey {
        case nodes, defaults
        case healthURL = "health_url"
        case healthURLError = "health_url_error"
        case capableNodes = "capable_nodes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        healthURL = try c.string(.healthURL)
        healthURLError = try c.string(.healthURLError)
        nodes = try c.decodeIfPresent([NotifyWitnessNode].self, forKey: .nodes) ?? []
        capableNodes = try c.decodeIfPresent([CapableNode].self, forKey: .capableNodes) ?? []
        defaults = try c.decodeIfPresent(Defaults.self, forKey: .defaults) ?? Defaults()
    }
}

// MARK: Webhooks

/// An inbound webhook, without its secret: the server returns the secret
/// once, at create and rotate, and both stay on the web.
public struct NotifyWebhook: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var eventType: String
    public var titleTemplate: String
    public var bodyTemplate: String
    public var enabled: Bool
    /// The endpoint path ("/api/hooks/<id>"); the console joins it to its origin.
    public var path: String
    public var lastUsedAt: Date?
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(id: String, name: String, eventType: String, titleTemplate: String = "", bodyTemplate: String = "", enabled: Bool = true, path: String = "", lastUsedAt: Date? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.eventType = eventType
        self.titleTemplate = titleTemplate
        self.bodyTemplate = bodyTemplate
        self.enabled = enabled
        self.path = path
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayName: String { name.isEmpty ? id : name }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, path
        case eventType = "event_type"
        case titleTemplate = "title_template"
        case bodyTemplate = "body_template"
        case lastUsedAt = "last_used_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.string(.name)
        eventType = try c.string(.eventType)
        titleTemplate = try c.string(.titleTemplate)
        bodyTemplate = try c.string(.bodyTemplate)
        enabled = try c.bool(.enabled)
        path = try c.string(.path)
        lastUsedAt = try c.date(.lastUsedAt)
        createdAt = try c.date(.createdAt)
        updatedAt = try c.date(.updatedAt)
    }
}

/// One call against one webhook, kept in a bounded ring per webhook.
public struct NotifyWebhookDelivery: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var webhookID: String
    public var eventType: String
    /// accepted, no_route, rejected, failed or partial.
    public var outcome: String
    /// Fixed server text, never caller-supplied.
    public var reason: String
    public var title: String
    public var body: String
    public var sourceIP: String
    public var fields: Int
    public var bytes: Int
    public var channels: Int
    public var delivered: Int
    public var test: Bool
    public var createdAt: Date?

    public init(id: String, webhookID: String, eventType: String, outcome: String, reason: String = "", channels: Int = 0, delivered: Int = 0, test: Bool = false) {
        self.id = id
        self.webhookID = webhookID
        self.eventType = eventType
        self.outcome = outcome
        self.reason = reason
        self.title = ""
        self.body = ""
        self.sourceIP = ""
        self.fields = 0
        self.bytes = 0
        self.channels = channels
        self.delivered = delivered
        self.test = test
    }

    enum CodingKeys: String, CodingKey {
        case id, outcome, reason, title, body, fields, bytes, channels, delivered, test
        case webhookID = "webhook_id"
        case eventType = "event_type"
        case sourceIP = "source_ip"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        webhookID = try c.string(.webhookID)
        eventType = try c.string(.eventType)
        outcome = try c.string(.outcome)
        reason = try c.string(.reason)
        title = try c.string(.title)
        body = try c.string(.body)
        sourceIP = try c.string(.sourceIP)
        fields = try c.int(.fields)
        bytes = try c.int(.bytes)
        channels = try c.int(.channels)
        delivered = try c.int(.delivered)
        test = try c.bool(.test)
        createdAt = try c.date(.createdAt)
    }
}

// MARK: Write answers and bodies

/// `POST /api/notify/channels/test`: whether the fixed test message went
/// out, the outbox row it left, and the channel's health after it.
public struct NotifyChannelTestResult: Decodable, Equatable, Sendable {
    public var ok: Bool
    public var delivery: NotifyDelivery?
    public var health: NotifyChannelHealth?

    enum CodingKeys: String, CodingKey { case ok, delivery, health }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.bool(.ok)
        delivery = try c.decodeIfPresent(NotifyDelivery.self, forKey: .delivery)
        health = try c.decodeIfPresent(NotifyChannelHealth.self, forKey: .health)
    }
}

/// `POST /api/notify/witness/plan`. The phone files a configure plan with
/// the server's defaults for the watch URL, references, level and timing,
/// or a removal; the full form stays on the web.
public struct NotifyWitnessPlanRequest: Encodable, Equatable, Sendable {
    public var nodeID: String
    public var remove: Bool
    public var channelID: String
    public var barkURL: String

    public static func configure(nodeID: String, channelID: String, barkURL: String) -> NotifyWitnessPlanRequest {
        NotifyWitnessPlanRequest(nodeID: nodeID, remove: false, channelID: channelID, barkURL: barkURL)
    }

    public static func remove(nodeID: String) -> NotifyWitnessPlanRequest {
        NotifyWitnessPlanRequest(nodeID: nodeID, remove: true, channelID: "", barkURL: "")
    }

    enum CodingKeys: String, CodingKey {
        case remove
        case nodeID = "node_id"
        case channelID = "channel_id"
        case barkURL = "bark_url"
    }

    /// Absent fields let the server apply its own defaults, as the console's
    /// request does (`witnessPlanRequest`).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(nodeID, forKey: .nodeID)
        if remove {
            try c.encode(true, forKey: .remove)
            return
        }
        try c.encode(channelID, forKey: .channelID)
        var url = barkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        try c.encode(url, forKey: .barkURL)
    }
}

/// `POST /api/notify/webhooks/test` `{id, data}`.
public struct NotifyWebhookTestBody: Encodable, Equatable, Sendable {
    public var id: String
    public var data: [String: String]

    public init(id: String, data: [String: String] = [:]) {
        self.id = id
        self.data = data
    }
}
