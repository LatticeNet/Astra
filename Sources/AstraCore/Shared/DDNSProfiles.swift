import Foundation

/// How a DDNS profile is doing, for Inbox attention and the DDNS list.
public enum DDNSHealth: String, Sendable, Hashable, CaseIterable {
    case current
    case failing
    case stale
}

/// One DDNS profile (`GET /api/ddns`, the console's `DDNSView`).
public struct DDNSProfile: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var nodeID: String
    public var provider: String
    public var domains: [String]
    public var enableIPv4: Bool
    public var enableIPv6: Bool
    public var ttl: Int
    /// Seconds between attempts; 0 means the server default.
    public var intervalSeconds: Int
    /// "address" or "cname".
    public var recordType: String
    public var hasCredential: Bool
    public var lastIPv4: String
    public var lastIPv6: String
    public var lastTarget: String
    public var lastRunAt: Date?
    public var lastError: String
    public var createdAt: Date?
    public var updatedAt: Date?
    public var maxRetries: Int = 0
    public var commentMode: String = ""
    public var recordComment: String = ""
    /// The provider hostname a CNAME profile points at.
    public var cnameTarget: String = ""
    public var webhookURL: String = ""
    public var webhookMethod: String = ""

    enum CodingKeys: String, CodingKey {
        case id, name, provider, domains, ttl
        case nodeID = "node_id"
        case enableIPv4 = "enable_ipv4"
        case enableIPv6 = "enable_ipv6"
        case intervalSeconds = "interval_seconds"
        case recordType = "record_type"
        case hasCredential = "has_credential"
        case lastIPv4 = "last_ipv4"
        case lastIPv6 = "last_ipv6"
        case lastTarget = "last_target"
        case lastRunAt = "last_run_at"
        case lastError = "last_error"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case maxRetries = "max_retries"
        case commentMode = "comment_mode"
        case recordComment = "record_comment"
        case cnameTarget = "cname_target"
        case webhookURL = "webhook_url"
        case webhookMethod = "webhook_method"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        enableIPv4 = try c.decodeIfPresent(Bool.self, forKey: .enableIPv4) ?? false
        enableIPv6 = try c.decodeIfPresent(Bool.self, forKey: .enableIPv6) ?? false
        ttl = try c.decodeIfPresent(Int.self, forKey: .ttl) ?? 0
        intervalSeconds = try c.decodeIfPresent(Int.self, forKey: .intervalSeconds) ?? 0
        recordType = try c.decodeIfPresent(String.self, forKey: .recordType) ?? "address"
        hasCredential = try c.decodeIfPresent(Bool.self, forKey: .hasCredential) ?? false
        lastIPv4 = try c.decodeIfPresent(String.self, forKey: .lastIPv4) ?? ""
        lastIPv6 = try c.decodeIfPresent(String.self, forKey: .lastIPv6) ?? ""
        lastTarget = try c.decodeIfPresent(String.self, forKey: .lastTarget) ?? ""
        lastRunAt = try DateValue.decodeIfPresent(from: c, forKey: .lastRunAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError) ?? ""
        createdAt = try DateValue.decodeIfPresent(from: c, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: c, forKey: .updatedAt)
        maxRetries = try c.decodeIfPresent(Int.self, forKey: .maxRetries) ?? 0
        commentMode = try c.decodeIfPresent(String.self, forKey: .commentMode) ?? ""
        recordComment = try c.decodeIfPresent(String.self, forKey: .recordComment) ?? ""
        cnameTarget = try c.decodeIfPresent(String.self, forKey: .cnameTarget) ?? ""
        webhookURL = try c.decodeIfPresent(String.self, forKey: .webhookURL) ?? ""
        webhookMethod = try c.decodeIfPresent(String.self, forKey: .webhookMethod) ?? ""
    }

    /// `lattice-server`'s `ddnsDefaultInterval`, for a profile that sets none.
    public static let defaultIntervalSeconds = 300
    /// A profile is overdue once this many intervals pass without a run.
    public static let staleFactor = 2.0

    /// Seconds between attempts, the server default filled in.
    public var effectiveIntervalSeconds: Int {
        intervalSeconds > 0 ? intervalSeconds : Self.defaultIntervalSeconds
    }

    public var isCNAME: Bool { recordType.trimmingCharacters(in: .whitespaces) == "cname" }

    /// Current, failing (the last run erred) or stale (overdue), the three
    /// words Inbox and the verdict use. Waiting and unchecked read current:
    /// neither is a problem yet.
    public func health(now: Date) -> DDNSHealth {
        health(now: now, node: nil)
    }

    /// `health(now:)` judged against the node's reported addresses, which is
    /// what tells a moved address apart from one that holds still.
    public func health(now: Date, node: DDNSNodeAddresses?) -> DDNSHealth {
        switch assess(node: node, now: now).state {
        case .failing: .failing
        case .stale: .stale
        case .waiting, .current, .unchecked: .current
        }
    }

    /// `assessDdns` from the console's `ddnsModel.ts`. The server sweeps every
    /// minute and writes only when the node's address moved or the last write
    /// failed, so an old `last_run_at` alone is not late. A profile is stale
    /// when the node reports an address it has not written and it has not run
    /// for twice its interval, or when it never wrote and twice its interval
    /// passed since it was created. Without node data an address profile is
    /// unchecked, except that a profile that never ran is still judged by its
    /// age, which needs no address.
    public func assess(node: DDNSNodeAddresses?, now: Date) -> DDNSAssessment {
        let interval = effectiveIntervalSeconds
        let lastRun = Self.plausible(lastRunAt)
        let since = lastRun ?? Self.plausible(createdAt)
        let overdue = since.map { now.timeIntervalSince($0) > Self.staleFactor * Double(interval) } ?? false
        let failing = !lastError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if isCNAME {
            let state: DDNSState = failing ? .failing : (cnameInSync ? .current : (overdue ? .stale : .waiting))
            return DDNSAssessment(state: state, intervalSeconds: interval, moved: [], noAddress: false, nodeDown: false, nodeUnknown: node == nil, lastRunAt: lastRun)
        }

        var moved: [DDNSMove] = []
        var noAddress = false
        if let node {
            let wanted: [(DDNSFamily, Bool, String, String)] = [
                (.v4, enableIPv4, node.publicIPv4.trimmed, lastIPv4.trimmed),
                (.v6, enableIPv6, node.publicIPv6.trimmed, lastIPv6.trimmed),
            ]
            let enabled = wanted.filter(\.1)
            for (family, _, current, published) in enabled where !current.isEmpty && current != published {
                moved.append(DDNSMove(family: family, published: published, current: current))
            }
            noAddress = !enabled.isEmpty && enabled.allSatisfy { $0.2.isEmpty }
        }

        let state: DDNSState
        if failing {
            state = .failing
        } else if node == nil {
            state = lastRun == nil && overdue ? .stale : .unchecked
        } else if !moved.isEmpty || lastRun == nil {
            state = overdue ? .stale : .waiting
        } else {
            state = .current
        }
        return DDNSAssessment(state: state, intervalSeconds: interval, moved: moved, noAddress: noAddress, nodeDown: node?.down ?? false, nodeUnknown: node == nil, lastRunAt: lastRun)
    }

    /// `ddnsCnameInSync`: the server confirmed the target the profile asks for.
    public var cnameInSync: Bool {
        let target = Self.normalizeHost(cnameTarget)
        return !target.isEmpty && Self.normalizeHost(lastTarget) == target
    }

    /// `ddnsNormalizeHost`: trimmed, lowercased, without the trailing dot.
    public static func normalizeHost(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix(".") { value.removeLast() }
        return value.lowercased()
    }

    /// `ddnsTime`: nil for absent or implausible (pre-2000, Go zero) times.
    private static func plausible(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSince1970 >= 946_684_800 else { return nil }
        return date
    }
}

/// What the node reports, for judging a DDNS profile (`DdnsNodeInput`).
public struct DDNSNodeAddresses: Sendable, Hashable {
    public var publicIPv4: String
    public var publicIPv6: String
    /// The agent is not in contact (offline, never reported, disabled).
    public var down: Bool

    public init(publicIPv4: String, publicIPv6: String, down: Bool) {
        self.publicIPv4 = publicIPv4
        self.publicIPv6 = publicIPv6
        self.down = down
    }
}

/// `DdnsState`: the console's five words for a profile.
public enum DDNSState: String, Sendable, Hashable, CaseIterable {
    case failing, stale, waiting, current, unchecked
}

public enum DDNSFamily: String, Sendable, Hashable {
    case v4, v6
}

/// A family whose record differs from the node's address.
public struct DDNSMove: Sendable, Hashable {
    public var family: DDNSFamily
    /// What the profile last wrote; empty when it never wrote this family.
    public var published: String
    /// What the node reports now.
    public var current: String
}

/// `DdnsAssessment`.
public struct DDNSAssessment: Sendable, Hashable {
    public var state: DDNSState
    public var intervalSeconds: Int
    public var moved: [DDNSMove]
    public var noAddress: Bool
    public var nodeDown: Bool
    public var nodeUnknown: Bool
    public var lastRunAt: Date?
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

public extension LatticeClient {
    func listDDNS() async throws -> [DDNSProfile] {
        try await perform([DDNSProfile].self, path: "/api/ddns")
    }
}
