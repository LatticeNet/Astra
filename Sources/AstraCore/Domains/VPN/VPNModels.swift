import Foundation

// vpn-core identities and lines, read through `callPlugin` (section 8.9),
// with the legacy proxy users as the fallback when vpn-core is not active,
// and the identity link endpoints (`identity_link_api.go`). Shapes follow
// the server's views: `vpnUserUsageView` (usage_history.go), `vpnUserView`
// (vpnusers.go), `identityLinkStatusView`, `linkRevealView`, `proxyUserView`
// and `Line` (lines.go). Fields the server omits when empty decode to empty
// values; the fields that make a row what it is (ids, the users and groups
// arrays) are required, so a body the app cannot read is companion behind.

/// The plugin and services the phone calls (`server_vpncore.go`).
public enum VPNService {
    public static let pluginID = "latticenet.vpn-core"
    public static let users = "latticenet.vpn-core/users"
    public static let lines = "latticenet.vpn-core/lines"
}

// MARK: Identities

/// One per-protocol credential as views carry it: never the secret.
public struct VPNCredentialView: Codable, Equatable, Hashable, Sendable {
    public var `protocol`: String
    public var flow: String
    public var method: String
    public var security: String
    public var hasSecret: Bool

    enum CodingKeys: String, CodingKey {
        case `protocol`, flow, method, security
        case hasSecret = "has_secret"
    }

    public init(protocol: String, flow: String = "", method: String = "", security: String = "", hasSecret: Bool = true) {
        self.protocol = `protocol`
        self.flow = flow
        self.method = method
        self.security = security
        self.hasSecret = hasSecret
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        `protocol` = try c.decode(String.self, forKey: .protocol)
        flow = try c.decodeIfPresent(String.self, forKey: .flow) ?? ""
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? ""
        security = try c.decodeIfPresent(String.self, forKey: .security) ?? ""
        hasSecret = try c.decodeIfPresent(Bool.self, forKey: .hasSecret) ?? false
    }
}

/// A binding of an identity to a line, by the line's stable hash id.
public struct VPNBinding: Codable, Equatable, Hashable, Sendable {
    public var lineHashID: String
    public var enabled: Bool
    public var flowOverride: String
    /// `lineBindingCredentialState`: current, stale, none or unknown; empty
    /// from a view that does not resolve lines.
    public var credential: String

    enum CodingKeys: String, CodingKey {
        case enabled, credential
        case lineHashID = "line_hash_id"
        case flowOverride = "flow_override"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lineHashID = try c.decode(String.self, forKey: .lineHashID)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        flowOverride = try c.decodeIfPresent(String.self, forKey: .flowOverride) ?? ""
        credential = try c.decodeIfPresent(String.self, forKey: .credential) ?? ""
    }
}

/// The identity's subscription link as a list shows it: route facts, never the token.
public struct VPNLinkSummary: Codable, Equatable, Hashable, Sendable {
    public var slug: String
    public var enabled: Bool
    public var issuedAt: Date?
    public var rotatedAt: Date?
    public var expiresAt: Date?
    public var updateIntervalHours: Int

    enum CodingKeys: String, CodingKey {
        case slug, enabled
        case issuedAt = "issued_at"
        case rotatedAt = "rotated_at"
        case expiresAt = "expires_at"
        case updateIntervalHours = "update_interval_hours"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        // The console reads a missing flag as on (`raw.enabled !== false`).
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        issuedAt = try DateValue.decodeIfPresent(from: c, forKey: .issuedAt)
        rotatedAt = try DateValue.decodeIfPresent(from: c, forKey: .rotatedAt)
        expiresAt = try DateValue.decodeIfPresent(from: c, forKey: .expiresAt)
        let hours = try c.decodeIfPresent(Int.self, forKey: .updateIntervalHours) ?? 0
        updateIntervalHours = hours > 0 ? hours : 2
    }
}

/// The figures a quota decision used (`vpnUserQuotaView`).
public struct VPNPolicyQuota: Codable, Equatable, Hashable, Sendable {
    public var limitBytes: Int64
    public var usedBytes: Int64
    public var proofBytes: Int64?
    /// proof or inferred, once the quota is reached.
    public var evidence: String
    /// monthly or lifetime.
    public var period: String
    public var periodStart: Date?
    public var periodEnd: Date?

    enum CodingKeys: String, CodingKey {
        case evidence, period
        case limitBytes = "limit_bytes"
        case usedBytes = "used_bytes"
        case proofBytes = "proof_bytes"
        case periodStart = "period_start"
        case periodEnd = "period_end"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limitBytes = try c.decodeIfPresent(Int64.self, forKey: .limitBytes) ?? 0
        usedBytes = try c.decodeIfPresent(Int64.self, forKey: .usedBytes) ?? 0
        proofBytes = try c.decodeIfPresent(Int64.self, forKey: .proofBytes)
        evidence = try c.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        period = try c.decodeIfPresent(String.self, forKey: .period) ?? ""
        periodStart = try DateValue.decodeIfPresent(from: c, forKey: .periodStart)
        periodEnd = try DateValue.decodeIfPresent(from: c, forKey: .periodEnd)
    }
}

/// The server's decision for an identity (`vpnUserPolicyView`): active,
/// disabled, expired or over_quota, with why it is suspended.
public struct VPNPolicy: Codable, Equatable, Hashable, Sendable {
    public var status: String
    /// disabled, operator, expiry or quota; empty while active.
    public var reason: String
    public var suspendedBy: String
    public var suspendedSince: Date?
    public var quota: VPNPolicyQuota?

    enum CodingKeys: String, CodingKey {
        case status, reason, quota
        case suspendedBy = "suspended_by"
        case suspendedSince = "suspended_since"
    }

    public init(status: String, reason: String = "") {
        self.status = status
        self.reason = reason
        suspendedBy = ""
        suspendedSince = nil
        quota = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        suspendedBy = try c.decodeIfPresent(String.self, forKey: .suspendedBy) ?? ""
        suspendedSince = try DateValue.decodeIfPresent(from: c, forKey: .suspendedSince)
        quota = try c.decodeIfPresent(VPNPolicyQuota.self, forKey: .quota)
    }
}

/// One line an identity's traffic is allocated to (`allocatedLineView`).
public struct VPNAllocatedLine: Codable, Equatable, Hashable, Sendable {
    public var lineHashID: String
    public var tag: String
    /// relay, exit or entry, as the attribution context names it.
    public var role: String
    /// binding, substore or relay.
    public var allocation: String
    public var periodUplink: Int64
    public var periodDownlink: Int64
    public var lastSeenAt: Date?
    public var counted: Bool
    public var estimate: Bool
    public var viaRelay: Bool

    enum CodingKeys: String, CodingKey {
        case tag, role, allocation, counted, estimate
        case lineHashID = "line_hash_id"
        case periodUplink = "period_uplink"
        case periodDownlink = "period_downlink"
        case lastSeenAt = "last_seen_at"
        case viaRelay = "via_relay"
    }

    public var periodBytes: Int64 { periodUplink + periodDownlink }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lineHashID = try c.decode(String.self, forKey: .lineHashID)
        tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        allocation = try c.decodeIfPresent(String.self, forKey: .allocation) ?? ""
        periodUplink = try c.decodeIfPresent(Int64.self, forKey: .periodUplink) ?? 0
        periodDownlink = try c.decodeIfPresent(Int64.self, forKey: .periodDownlink) ?? 0
        lastSeenAt = try DateValue.decodeIfPresent(from: c, forKey: .lastSeenAt)
        counted = try c.decodeIfPresent(Bool.self, forKey: .counted) ?? false
        estimate = try c.decodeIfPresent(Bool.self, forKey: .estimate) ?? false
        viaRelay = try c.decodeIfPresent(Bool.self, forKey: .viaRelay) ?? false
    }
}

/// The nodes an identity's lines sit on (`allocatedNodeView`).
public struct VPNAllocatedNode: Codable, Equatable, Hashable, Sendable {
    public var nodeID: String
    public var nodeName: String
    /// ok, error, stats_off or no_collector.
    public var collectorState: String
    public var lines: [VPNAllocatedLine]

    enum CodingKeys: String, CodingKey {
        case lines
        case nodeID = "node_id"
        case nodeName = "node_name"
        case collectorState = "collector_state"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decode(String.self, forKey: .nodeID)
        nodeName = try c.decodeIfPresent(String.self, forKey: .nodeName) ?? ""
        collectorState = try c.decodeIfPresent(String.self, forKey: .collectorState) ?? ""
        lines = try c.decodeIfPresent([VPNAllocatedLine].self, forKey: .lines) ?? []
    }
}

/// The usage figures the users read model adds to an identity. Absent as a
/// whole from a server older than usage attribution, which is a different
/// claim from zero bytes (`usersModel.ts` `usageReported`).
public struct VPNUsage: Equatable, Hashable, Sendable {
    public var usedTotalBytes: Int64
    public var usedTotalFrom: Date?
    public var usedTotalTruncated: Bool
    /// Counted in the current quota period, or the retained total when none.
    public var usedPeriodBytes: Int64
    /// Present only for a monthly quota.
    public var periodStart: Date?
    public var periodEnd: Date?
    /// Seven daily totals, index 6 is today.
    public var last7d: [Int64]
    public var lastSeenAt: Date?
    public var allocatedNodes: [VPNAllocatedNode]
}

/// Where a listed identity came from: the vpn-core identity model, or the
/// legacy proxy users read when vpn-core is not active.
public enum VPNUserSource: String, Sendable, Hashable, Codable {
    case vpnCore
    case legacyProxyUser
}

/// One identity as the users list and `get` answer it (`vpnUserUsageView`),
/// or a legacy proxy user mapped onto the same shape.
public struct VPNUser: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var email: String
    public var name: String
    public var enabled: Bool
    public var credentials: [VPNCredentialView]
    public var bindings: [VPNBinding]
    public var quotaBytes: Int64
    /// "" (lifetime) or monthly.
    public var quotaPeriod: String
    public var quotaResetDay: Int
    public var expiresAt: Date?
    public var group: String
    public var comment: String
    public var migrated: Bool
    public var link: VPNLinkSummary?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var usage: VPNUsage?
    public var policy: VPNPolicy?
    public var source: VPNUserSource
    /// The legacy model's own status word, for a legacy proxy user only.
    public var legacyStatus: String

    enum CodingKeys: String, CodingKey {
        case id, email, name, enabled, credentials, bindings, group, comment, migrated, link, policy
        case quotaBytes = "quota_bytes"
        case quotaPeriod = "quota_period"
        case quotaResetDay = "quota_reset_day"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case usedTotalBytes = "used_total_bytes"
        case usedTotalFrom = "used_total_from"
        case usedTotalTruncated = "used_total_truncated"
        case usedPeriodBytes = "used_period_bytes"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case last7d = "last_7d"
        case lastSeenAt = "last_seen_at"
        case allocatedNodes = "allocated_nodes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        credentials = try c.decodeIfPresent([VPNCredentialView].self, forKey: .credentials) ?? []
        bindings = try c.decodeIfPresent([VPNBinding].self, forKey: .bindings) ?? []
        quotaBytes = try c.decodeIfPresent(Int64.self, forKey: .quotaBytes) ?? 0
        quotaPeriod = try c.decodeIfPresent(String.self, forKey: .quotaPeriod) ?? ""
        quotaResetDay = try c.decodeIfPresent(Int.self, forKey: .quotaResetDay) ?? 0
        expiresAt = try DateValue.decodeIfPresent(from: c, forKey: .expiresAt)
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        migrated = try c.decodeIfPresent(Bool.self, forKey: .migrated) ?? false
        link = try c.decodeIfPresent(VPNLinkSummary.self, forKey: .link)
        createdAt = try DateValue.decodeIfPresent(from: c, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: c, forKey: .updatedAt)
        policy = try c.decodeIfPresent(VPNPolicy.self, forKey: .policy)
        if c.contains(.usedPeriodBytes) || c.contains(.allocatedNodes) {
            usage = VPNUsage(
                usedTotalBytes: try c.decodeIfPresent(Int64.self, forKey: .usedTotalBytes) ?? 0,
                usedTotalFrom: try DateValue.decodeIfPresent(from: c, forKey: .usedTotalFrom),
                usedTotalTruncated: try c.decodeIfPresent(Bool.self, forKey: .usedTotalTruncated) ?? false,
                usedPeriodBytes: try c.decodeIfPresent(Int64.self, forKey: .usedPeriodBytes) ?? 0,
                periodStart: try DateValue.decodeIfPresent(from: c, forKey: .periodStart),
                periodEnd: try DateValue.decodeIfPresent(from: c, forKey: .periodEnd),
                last7d: try c.decodeIfPresent([Int64].self, forKey: .last7d) ?? [],
                lastSeenAt: try DateValue.decodeIfPresent(from: c, forKey: .lastSeenAt),
                allocatedNodes: try c.decodeIfPresent([VPNAllocatedNode].self, forKey: .allocatedNodes) ?? []
            )
        } else {
            usage = nil
        }
        source = .vpnCore
        legacyStatus = ""
    }

    /// A legacy proxy user in the identity shape. It has no bindings or link;
    /// its status word is the server's own.
    public init(legacy user: VPNProxyUser) {
        id = user.id
        email = user.name
        name = user.name
        enabled = user.enabled
        credentials = (user.hasUUID ? [VPNCredentialView(protocol: "vless")] : [])
            + (user.hasPassword ? [VPNCredentialView(protocol: "trojan")] : [])
        bindings = []
        quotaBytes = user.trafficLimitBytes
        quotaPeriod = ""
        quotaResetDay = 0
        expiresAt = user.expiresAt
        group = ""
        comment = ""
        migrated = false
        link = nil
        createdAt = user.createdAt
        updatedAt = user.updatedAt
        usage = VPNUsage(usedTotalBytes: user.usedBytes, usedTotalFrom: nil, usedTotalTruncated: false, usedPeriodBytes: user.usedBytes,
                         periodStart: nil, periodEnd: nil, last7d: [], lastSeenAt: user.lastSeenAt, allocatedNodes: [])
        policy = user.status.isEmpty ? nil : VPNPolicy(status: user.status)
        source = .legacyProxyUser
        legacyStatus = user.status
    }

    /// The name an operator recognizes: the email, or the id for a row with none.
    public var displayName: String { email.isEmpty ? (name.isEmpty ? id : name) : email }
}

/// `users.list`: `{users, count}`.
public struct VPNUserList: Decodable, Equatable, Sendable {
    public var users: [VPNUser]
    public var count: Int

    enum CodingKeys: String, CodingKey { case users, count }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        users = try c.decode([VPNUser].self, forKey: .users)
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? users.count
    }
}

/// `users.get`: `{user}`.
public struct VPNUserEnvelope: Decodable, Equatable, Sendable {
    public var user: VPNUser
}

/// The users list with where it came from.
public struct VPNUserListing: Equatable, Sendable {
    public var users: [VPNUser]
    public var source: VPNUserSource

    public init(users: [VPNUser], source: VPNUserSource) {
        self.users = users
        self.source = source
    }

    public func user(id: String) -> VPNUser? {
        users.first { $0.id == id }
    }
}

/// `GET /api/proxy/users` row (`proxyUserView`), the legacy substrate.
public struct VPNProxyUser: Decodable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var hasUUID: Bool
    public var hasPassword: Bool
    public var inboundIDs: [String]
    public var trafficLimitBytes: Int64
    public var expiresAt: Date?
    public var usedBytes: Int64
    public var lastSeenAt: Date?
    /// active, expired, over_quota or disabled.
    public var status: String
    public var createdAt: Date?
    public var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, status
        case hasUUID = "has_uuid"
        case hasPassword = "has_password"
        case inboundIDs = "inbound_ids"
        case trafficLimitBytes = "traffic_limit_bytes"
        case expiresAt = "expires_at"
        case usedBytes = "used_bytes"
        case lastSeenAt = "last_seen_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        hasUUID = try c.decodeIfPresent(Bool.self, forKey: .hasUUID) ?? false
        hasPassword = try c.decodeIfPresent(Bool.self, forKey: .hasPassword) ?? false
        inboundIDs = try c.decodeIfPresent([String].self, forKey: .inboundIDs) ?? []
        trafficLimitBytes = try c.decodeIfPresent(Int64.self, forKey: .trafficLimitBytes) ?? 0
        expiresAt = try DateValue.decodeIfPresent(from: c, forKey: .expiresAt)
        usedBytes = try c.decodeIfPresent(Int64.self, forKey: .usedBytes) ?? 0
        lastSeenAt = try DateValue.decodeIfPresent(from: c, forKey: .lastSeenAt)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        createdAt = try DateValue.decodeIfPresent(from: c, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: c, forKey: .updatedAt)
    }
}

/// `{users}` from `/api/proxy/users`.
public struct VPNProxyUserList: Decodable, Equatable, Sendable {
    public var users: [VPNProxyUser]
}

// MARK: Identity link

/// One bound line as the link status reports it (`identityLinkLine`).
public struct VPNLinkLine: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var lineHashID: String
    public var nodeID: String
    public var nodeName: String
    public var lineName: String
    public var `protocol`: String
    /// Why a line is left out, and the action that would bring it in.
    public var reason: String
    public var fix: String
    /// What a reason needs spelled out, never a value.
    public var detail: String

    public var id: String { lineHashID }

    enum CodingKeys: String, CodingKey {
        case reason, fix, detail, `protocol`
        case lineHashID = "line_hash_id"
        case nodeID = "node_id"
        case nodeName = "node_name"
        case lineName = "line_name"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lineHashID = try c.decode(String.self, forKey: .lineHashID)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        nodeName = try c.decodeIfPresent(String.self, forKey: .nodeName) ?? ""
        lineName = try c.decodeIfPresent(String.self, forKey: .lineName) ?? ""
        `protocol` = try c.decodeIfPresent(String.self, forKey: .protocol) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        fix = try c.decodeIfPresent(String.self, forKey: .fix) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }
}

/// Which client documents the link serves (`identityLinkFormatsView`).
public struct VPNLinkFormats: Decodable, Equatable, Hashable, Sendable {
    public var native: [String]
    public var converted: [String]
    public var convertAvailable: Bool
    public var fallback: String

    enum CodingKeys: String, CodingKey {
        case native, converted, fallback
        case convertAvailable = "convert_available"
    }

    public static let none = VPNLinkFormats(native: [], converted: [], convertAvailable: false, fallback: "")

    init(native: [String], converted: [String], convertAvailable: Bool, fallback: String) {
        self.native = native
        self.converted = converted
        self.convertAvailable = convertAvailable
        self.fallback = fallback
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        native = try c.decodeIfPresent([String].self, forKey: .native) ?? []
        converted = try c.decodeIfPresent([String].self, forKey: .converted) ?? []
        convertAvailable = try c.decodeIfPresent(Bool.self, forKey: .convertAvailable) ?? false
        fallback = try c.decodeIfPresent(String.self, forKey: .fallback) ?? ""
    }
}

/// The last fetch since the server started (`identityLinkFetchSeen`).
public struct VPNLinkFetch: Decodable, Equatable, Hashable, Sendable {
    public var at: Date
    public var uaClass: String
    public var answer: String

    enum CodingKeys: String, CodingKey {
        case at, answer
        case uaClass = "ua_class"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let at = try DateValue.decodeIfPresent(from: c, forKey: .at) else {
            throw DecodingError.dataCorruptedError(forKey: .at, in: c, debugDescription: "a fetch without a time")
        }
        self.at = at
        let ua = try c.decodeIfPresent(String.self, forKey: .uaClass) ?? ""
        uaClass = ua.isEmpty ? "other" : ua
        let answer = try c.decodeIfPresent(String.self, forKey: .answer) ?? ""
        self.answer = answer.isEmpty ? "nodes" : answer
    }
}

/// `GET /api/vpn/users/{id}/link`, and the answer of rotate and revoke
/// (`identityLinkStatusView`): what a fetch gets now, never the token.
public struct VPNLinkStatus: Decodable, Equatable, Hashable, Sendable {
    public var identityID: String
    public var issued: Bool
    public var link: VPNLinkSummary?
    /// nodes, placeholder or decoy.
    public var answer: String
    /// active, no_lines, transient_empty, disabled, operator, expiry, quota,
    /// link_disabled, link_expired or not_issued.
    public var answerReason: String
    public var placeholder: String
    public var subscriptionUserinfo: String
    public var included: [VPNLinkLine]
    public var excluded: [VPNLinkLine]
    public var formats: VPNLinkFormats
    public var lastFetch: VPNLinkFetch?

    enum CodingKeys: String, CodingKey {
        case issued, link, answer, placeholder, included, excluded, formats
        case identityID = "identity_id"
        case answerReason = "answer_reason"
        case subscriptionUserinfo = "subscription_userinfo"
        case lastFetch = "last_fetch"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `parseLinkStatus`: without an identity and the issued flag it is not a status at all.
        identityID = try c.decode(String.self, forKey: .identityID)
        issued = try c.decode(Bool.self, forKey: .issued)
        link = issued ? try c.decodeIfPresent(VPNLinkSummary.self, forKey: .link) : nil
        let answer = try c.decodeIfPresent(String.self, forKey: .answer) ?? ""
        self.answer = answer.isEmpty ? "decoy" : answer
        let reason = try c.decodeIfPresent(String.self, forKey: .answerReason) ?? ""
        answerReason = reason.isEmpty ? (issued ? "active" : "not_issued") : reason
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder) ?? ""
        subscriptionUserinfo = try c.decodeIfPresent(String.self, forKey: .subscriptionUserinfo) ?? ""
        included = try c.decodeIfPresent([VPNLinkLine].self, forKey: .included) ?? []
        excluded = try c.decodeIfPresent([VPNLinkLine].self, forKey: .excluded) ?? []
        formats = try c.decodeIfPresent(VPNLinkFormats.self, forKey: .formats) ?? .none
        lastFetch = try? c.decodeIfPresent(VPNLinkFetch.self, forKey: .lastFetch)
    }
}

/// `POST .../link/reveal` (`linkRevealView`). Holds the bearer token: it
/// goes straight into the one-time value step and is never stored.
public struct VPNLinkReveal: Decodable, Sendable {
    public var kind: String
    public var id: String
    public var slug: String
    public var token: String
    /// `/sub/<slug>/<token>`.
    public var path: String
    /// `path` under the server's public base, absent when it has none.
    public var url: String

    enum CodingKeys: String, CodingKey { case kind, id, slug, token, path, url }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "identity"
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        token = try c.decode(String.self, forKey: .token)
        path = try c.decode(String.self, forKey: .path)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        // `parseLinkReveal`: a link path and a token, or not a reveal.
        guard path.hasPrefix("/sub/"), !token.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: c, debugDescription: "not a link reveal")
        }
    }

    /// `revealedUrl`: the server's URL, else the path on the console's origin.
    public func fullURL(origin: URL?) -> String {
        if !url.isEmpty { return url }
        guard let origin else { return path }
        var base = origin.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return base + path
    }
}

/// One credential with its secret, as `reveal-credentials` answers it.
public struct VPNCredentialSecret: Decodable, Sendable {
    public var `protocol`: String
    public var uuid: String
    public var password: String
    public var flow: String
    public var method: String
    public var security: String

    enum CodingKeys: String, CodingKey { case `protocol`, uuid, password, flow, method, security }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        `protocol` = try c.decode(String.self, forKey: .protocol)
        uuid = try c.decodeIfPresent(String.self, forKey: .uuid) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        flow = try c.decodeIfPresent(String.self, forKey: .flow) ?? ""
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? ""
        security = try c.decodeIfPresent(String.self, forKey: .security) ?? ""
    }
}

/// `POST /api/proxy/users/reveal-credentials`: `{ok, user, credentials}`.
public struct VPNCredentialsReveal: Decodable, Sendable {
    public var ok: Bool
    public var user: VPNUser
    public var credentials: [VPNCredentialSecret]

    enum CodingKeys: String, CodingKey { case ok, user, credentials }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        user = try c.decode(VPNUser.self, forKey: .user)
        credentials = try c.decode([VPNCredentialSecret].self, forKey: .credentials)
    }

    /// The value the one-time step shows: one line per secret, labelled by
    /// protocol and kind, so nothing has to be guessed when it is pasted.
    public var text: String {
        credentials.flatMap { credential -> [String] in
            var lines: [String] = []
            if !credential.uuid.isEmpty { lines.append("\(credential.protocol) uuid: \(credential.uuid)") }
            if !credential.password.isEmpty { lines.append("\(credential.protocol) password: \(credential.password)") }
            return lines
        }.joined(separator: "\n")
    }
}

// MARK: Lines

/// One line as the vpn-core read model reports it (`Line` in lines.go).
public struct VPNLine: Decodable, Equatable, Hashable, Sendable, Identifiable {
    /// Equal to `lineHashID`, the stable handle.
    public var id: String
    public var lineHashID: String
    public var lineID: String
    public var nodeID: String
    /// The durable control-plane identity chains are keyed by.
    public var lineUUID: String
    public var downstreamLineUUID: String
    /// sing-box, xray or mihomo.
    public var core: String
    /// managed, discovered or imported.
    public var source: String
    public var managed: Bool
    public var name: String
    public var tag: String
    public var namedUsers: Int
    public var unnamedUsers: Int
    public var parkedUsers: Int
    public var parkedError: String
    /// The protocol.
    public var type: String
    public var transport: String
    public var security: String
    public var listenHost: String
    public var listenPort: Int
    public var publicHost: String
    public var publicPort: Int
    public var domain: String
    public var outboundRef: String
    public var outboundServer: String
    public var outboundPort: Int
    /// The line hash ids this line relays to.
    public var jumpEdges: [String]
    public var declaredJumpEdges: [String]
    public var overlay: Bool
    public var overlayStatus: String
    public var overlayUser: String
    public var userCount: Int
    /// False for a discovered line whose users were not inspected yet.
    public var userKnown: Bool
    /// ok, pending, error or stale: whether the configuration checks out.
    public var status: String
    public var lastError: String
    /// running, down, restarting or unknown: what the service is doing.
    public var serviceState: String
    public var serviceCheckedAt: Date?
    public var serviceNote: String

    enum CodingKeys: String, CodingKey {
        case id, core, source, managed, name, tag, type, transport, security, domain, overlay, status
        case lineHashID = "line_hash_id"
        case lineID = "line_id"
        case nodeID = "node_id"
        case lineUUID = "line_uuid"
        case downstreamLineUUID = "downstream_line_uuid"
        case namedUsers = "named_users"
        case unnamedUsers = "unnamed_users"
        case parkedUsers = "parked_users"
        case parkedError = "parked_error"
        case listenHost = "listen_host"
        case listenPort = "listen_port"
        case publicHost = "public_host"
        case publicPort = "public_port"
        case outboundRef = "outbound_ref"
        case outboundServer = "outbound_server"
        case outboundPort = "outbound_port"
        case jumpEdges = "jump_edges"
        case declaredJumpEdges = "declared_jump_edges"
        case overlayStatus = "overlay_status"
        case overlayUser = "overlay_user"
        case userCount = "user_count"
        case userKnown = "user_known"
        case lastError = "last_error"
        case serviceState = "service_state"
        case serviceCheckedAt = "service_checked_at"
        case serviceNote = "service_note"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lineHashID = try c.decode(String.self, forKey: .lineHashID)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? lineHashID
        lineID = try c.decodeIfPresent(String.self, forKey: .lineID) ?? ""
        nodeID = try c.decode(String.self, forKey: .nodeID)
        lineUUID = try c.decodeIfPresent(String.self, forKey: .lineUUID) ?? ""
        downstreamLineUUID = try c.decodeIfPresent(String.self, forKey: .downstreamLineUUID) ?? ""
        core = try c.decodeIfPresent(String.self, forKey: .core) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        managed = try c.decodeIfPresent(Bool.self, forKey: .managed) ?? false
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? ""
        namedUsers = try c.decodeIfPresent(Int.self, forKey: .namedUsers) ?? 0
        unnamedUsers = try c.decodeIfPresent(Int.self, forKey: .unnamedUsers) ?? 0
        parkedUsers = try c.decodeIfPresent(Int.self, forKey: .parkedUsers) ?? 0
        parkedError = try c.decodeIfPresent(String.self, forKey: .parkedError) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        transport = try c.decodeIfPresent(String.self, forKey: .transport) ?? ""
        security = try c.decodeIfPresent(String.self, forKey: .security) ?? ""
        listenHost = try c.decodeIfPresent(String.self, forKey: .listenHost) ?? ""
        listenPort = try c.decodeIfPresent(Int.self, forKey: .listenPort) ?? 0
        publicHost = try c.decodeIfPresent(String.self, forKey: .publicHost) ?? ""
        publicPort = try c.decodeIfPresent(Int.self, forKey: .publicPort) ?? 0
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? ""
        outboundRef = try c.decodeIfPresent(String.self, forKey: .outboundRef) ?? ""
        outboundServer = try c.decodeIfPresent(String.self, forKey: .outboundServer) ?? ""
        outboundPort = try c.decodeIfPresent(Int.self, forKey: .outboundPort) ?? 0
        jumpEdges = try c.decodeIfPresent([String].self, forKey: .jumpEdges) ?? []
        declaredJumpEdges = try c.decodeIfPresent([String].self, forKey: .declaredJumpEdges) ?? []
        overlay = try c.decodeIfPresent(Bool.self, forKey: .overlay) ?? false
        overlayStatus = try c.decodeIfPresent(String.self, forKey: .overlayStatus) ?? ""
        overlayUser = try c.decodeIfPresent(String.self, forKey: .overlayUser) ?? ""
        userCount = try c.decodeIfPresent(Int.self, forKey: .userCount) ?? 0
        userKnown = try c.decodeIfPresent(Bool.self, forKey: .userKnown) ?? false
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError) ?? ""
        serviceState = try c.decodeIfPresent(String.self, forKey: .serviceState) ?? ""
        serviceCheckedAt = try DateValue.decodeIfPresent(from: c, forKey: .serviceCheckedAt)
        serviceNote = try c.decodeIfPresent(String.self, forKey: .serviceNote) ?? ""
    }

    /// The name a row shows: the line's name, else its tag, else its handle.
    public var displayName: String {
        if !name.isEmpty { return name }
        return tag.isEmpty ? lineHashID : tag
    }
}

/// The lines on one node (`LineGroup`).
public struct VPNLineGroup: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var nodeID: String
    public var nodeName: String
    public var lines: [VPNLine]

    public var id: String { nodeID }

    enum CodingKeys: String, CodingKey {
        case lines
        case nodeID = "node_id"
        case nodeName = "node_name"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decode(String.self, forKey: .nodeID)
        nodeName = try c.decodeIfPresent(String.self, forKey: .nodeName) ?? ""
        lines = try c.decodeIfPresent([VPNLine].self, forKey: .lines) ?? []
    }
}

/// `lines.list`: `{groups, count}`. A server with no lines answers `null` groups.
public struct VPNLineList: Decodable, Equatable, Sendable {
    public var groups: [VPNLineGroup]
    public var count: Int

    enum CodingKeys: String, CodingKey { case groups, count }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.groups) else {
            throw DecodingError.keyNotFound(CodingKeys.groups, .init(codingPath: c.codingPath, debugDescription: "no groups"))
        }
        groups = try c.decodeIfPresent([VPNLineGroup].self, forKey: .groups) ?? []
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? groups.reduce(0) { $0 + $1.lines.count }
    }
}

// MARK: Request bodies

/// `users.get` payload: `{id}` (`decodeIDRequest`).
public struct VPNUserGetRequest: Encodable, Equatable, Sendable {
    public var id: String
    public init(id: String) { self.id = id }
}

/// `{step_up_grant}` for `POST .../link/reveal`.
public struct VPNLinkRevealRequest: Encodable, Equatable, Sendable {
    public var stepUpGrant: String

    enum CodingKeys: String, CodingKey { case stepUpGrant = "step_up_grant" }

    public init(stepUpGrant: String) { self.stepUpGrant = stepUpGrant }
}

/// `{id, step_up_grant}` for `POST /api/proxy/users/reveal-credentials`.
public struct VPNCredentialsRevealRequest: Encodable, Equatable, Sendable {
    public var id: String
    public var stepUpGrant: String

    enum CodingKeys: String, CodingKey {
        case id
        case stepUpGrant = "step_up_grant"
    }

    public init(id: String, stepUpGrant: String) {
        self.id = id
        self.stepUpGrant = stepUpGrant
    }
}
