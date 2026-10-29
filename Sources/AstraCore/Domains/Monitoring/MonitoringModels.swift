import Foundation

// Monitoring response and request shapes, from lattice-server
// (server_views.go monitorView, check_definitions_api.go, monitor_paths.go,
// latency_rollups.go, server_linechain.go) and lattice-sdk/model. Absent
// optional figures decode to nil so a gap never reads as a zero.

public enum MonitorType: String, Codable, CaseIterable, Sendable {
    case tcp
    case http
    case icmp
    case tls
    case beacon
    case dns

    public var displayName: String {
        switch self {
        case .tcp: "TCP"
        case .http: "HTTP"
        case .icmp: "ICMP"
        case .tls: "TLS"
        case .beacon: "Beacon"
        case .dns: "DNS"
        }
    }
}

/// One node's newest result for a monitor and the run it ends (`monitorLatestView`).
public struct MonitoringLatest: Codable, Equatable, Hashable, Sendable {
    /// Empty on a tls monitor: the control plane dials those itself.
    public var nodeID: String
    public var at: Date?
    public var success: Bool
    public var latencyMs: Double?
    public var error: String
    public var certNotAfter: Date?
    public var receivedAt: Date?
    /// Failures in a row ending with this result; 0 after a success.
    public var failStreak: Int
    /// When the current run of passes or failures began.
    public var since: Date?
    public var sent: Int
    public var lost: Int
    public var rttsMs: [Double]
    /// Set when the newest run measured nothing; the fields above are then its last real outcome.
    public var reason: String
    public var reasonAt: Date?

    public init(nodeID: String, at: Date?, success: Bool, latencyMs: Double? = nil, error: String = "", failStreak: Int = 0, since: Date? = nil, reason: String = "") {
        self.nodeID = nodeID
        self.at = at
        self.success = success
        self.latencyMs = latencyMs
        self.error = error
        self.failStreak = failStreak
        self.since = since
        self.sent = 0
        self.lost = 0
        self.rttsMs = []
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case at, success, error, since, sent, lost, reason
        case nodeID = "node_id"
        case latencyMs = "latency_ms"
        case certNotAfter = "cert_not_after"
        case receivedAt = "received_at"
        case failStreak = "fail_streak"
        case rttsMs = "rtts_ms"
        case reasonAt = "reason_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        at = try DateValue.decodeIfPresent(from: c, forKey: .at)
        success = try c.decodeIfPresent(Bool.self, forKey: .success) ?? false
        latencyMs = try c.decodeIfPresent(Double.self, forKey: .latencyMs)
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
        certNotAfter = try DateValue.decodeIfPresent(from: c, forKey: .certNotAfter)
        receivedAt = try DateValue.decodeIfPresent(from: c, forKey: .receivedAt)
        failStreak = try c.decodeIfPresent(Int.self, forKey: .failStreak) ?? 0
        since = try DateValue.decodeIfPresent(from: c, forKey: .since)
        sent = try c.decodeIfPresent(Int.self, forKey: .sent) ?? 0
        lost = try c.decodeIfPresent(Int.self, forKey: .lost) ?? 0
        rttsMs = try c.decodeIfPresent([Double].self, forKey: .rttsMs) ?? []
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        reasonAt = try DateValue.decodeIfPresent(from: c, forKey: .reasonAt)
    }
}

public struct Monitor: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var typeRaw: String
    public var target: String
    public var intervalSec: Int
    public var timeoutSec: Int
    public var assignAll: Bool
    public var nodeIDs: [String]
    public var enabled: Bool
    public var createdAt: Date?
    public var updatedAt: Date?
    /// tls: days before expiry the probe starts failing.
    public var thresholdDays: Int = 0
    /// The node the target is resolved from (icmp, tcp); `target` is then the resolution in force now.
    public var targetNode: String = ""
    public var packets: Int = 0
    public var expectStatus: String = ""
    public var dnsName: String = ""
    public var dnsType: String = ""
    /// Set on a monitor the control plane generates ("latency"); edits and deletes are refused.
    public var managedBy: String = ""
    /// The check definition the monitor was expanded from; edited and deleted through it.
    public var checkDefinitionID: String = ""
    /// What an edit names (`POST /api/monitors/update`); 0 from a server that predates editing.
    public var version: Int64 = 0
    /// Sources paused one by one; they keep their history.
    public var pausedNodeIDs: [String] = []
    /// `down`, `down_and_degraded` or `off`.
    public var alert: String = ""
    public var alertAfter: Int = 0
    /// Each assigned node's newest result this caller may see, sorted by node id.
    public var latest: [MonitoringLatest] = []

    public init(
        id: String,
        name: String = "",
        typeRaw: String = "http",
        target: String = "",
        intervalSec: Int = 60,
        timeoutSec: Int = 10,
        assignAll: Bool = false,
        nodeIDs: [String] = [],
        enabled: Bool = true,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.typeRaw = typeRaw
        self.target = target
        self.intervalSec = intervalSec
        self.timeoutSec = timeoutSec
        self.assignAll = assignAll
        self.nodeIDs = nodeIDs
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var type: MonitorType? { MonitorType(rawValue: typeRaw) }

    public var displayName: String { name.isEmpty ? id : name }

    /// Generated by a check definition or a probe configuration: the server
    /// refuses edits and deletes (`generatedMonitorRefusal`), so the phone
    /// offers neither.
    public var isGenerated: Bool { !managedBy.isEmpty || !checkDefinitionID.isEmpty }

    /// Whether the server supports editing this monitor (it sends `version`).
    public var isEditable: Bool { !isGenerated && version > 0 }

    /// The type word as the list shows it ("tls"), or the raw value.
    public var typeWord: String { typeRaw.isEmpty ? "check" : typeRaw.lowercased() }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case typeRaw = "type"
        case target
        case intervalSec = "interval_sec"
        case timeoutSec = "timeout_sec"
        case assignAll = "assign_all"
        case nodeIDs = "node_ids"
        case enabled
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case thresholdDays = "threshold_days"
        case targetNode = "target_node"
        case packets
        case expectStatus = "expect_status"
        case dnsName = "dns_name"
        case dnsType = "dns_type"
        case managedBy = "managed_by"
        case checkDefinitionID = "check_definition_id"
        case version
        case pausedNodeIDs = "paused_node_ids"
        case alert
        case alertAfter = "alert_after"
        case latest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        typeRaw = try container.decodeIfPresent(String.self, forKey: .typeRaw) ?? ""
        target = try container.decodeIfPresent(String.self, forKey: .target) ?? ""
        intervalSec = try container.decodeIfPresent(Int.self, forKey: .intervalSec) ?? 0
        timeoutSec = try container.decodeIfPresent(Int.self, forKey: .timeoutSec) ?? 0
        assignAll = try container.decodeIfPresent(Bool.self, forKey: .assignAll) ?? false
        nodeIDs = try container.decodeIfPresent([String].self, forKey: .nodeIDs) ?? []
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        createdAt = try DateValue.decodeIfPresent(from: container, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: container, forKey: .updatedAt)
        thresholdDays = try container.decodeIfPresent(Int.self, forKey: .thresholdDays) ?? 0
        targetNode = try container.decodeIfPresent(String.self, forKey: .targetNode) ?? ""
        packets = try container.decodeIfPresent(Int.self, forKey: .packets) ?? 0
        expectStatus = try container.decodeIfPresent(String.self, forKey: .expectStatus) ?? ""
        dnsName = try container.decodeIfPresent(String.self, forKey: .dnsName) ?? ""
        dnsType = try container.decodeIfPresent(String.self, forKey: .dnsType) ?? ""
        managedBy = try container.decodeIfPresent(String.self, forKey: .managedBy) ?? ""
        checkDefinitionID = try container.decodeIfPresent(String.self, forKey: .checkDefinitionID) ?? ""
        version = try container.decodeIfPresent(Int64.self, forKey: .version) ?? 0
        pausedNodeIDs = try container.decodeIfPresent([String].self, forKey: .pausedNodeIDs) ?? []
        alert = try container.decodeIfPresent(String.self, forKey: .alert) ?? ""
        alertAfter = try container.decodeIfPresent(Int.self, forKey: .alertAfter) ?? 0
        latest = try container.decodeIfPresent([MonitoringLatest].self, forKey: .latest) ?? []
    }
}

public struct MonitorResult: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var monitorID: String
    public var nodeID: String
    public var at: Date?
    public var success: Bool
    public var latencyMs: Double
    public var error: String?
    public var certNotAfter: Date? = nil
    /// When the server received it; well after `at`, the result waited in an agent's buffer.
    public var receivedAt: Date? = nil
    public var sent: Int = 0
    public var lost: Int = 0
    public var rttsMs: [Double] = []
    /// Set when the run measured nothing (icmp_not_permitted and the like): neither up nor down.
    public var reason: String = ""
    public var dnsRcode: String = ""
    public var dnsAnswers: [String] = []

    public init(monitorID: String, nodeID: String, at: Date? = nil, success: Bool = false, latencyMs: Double = 0, error: String? = nil) {
        self.monitorID = monitorID
        self.nodeID = nodeID
        self.at = at
        self.success = success
        self.latencyMs = latencyMs
        self.error = error
    }

    public var id: String {
        "\(monitorID).\(nodeID).\(at?.timeIntervalSince1970 ?? 0)"
    }

    enum CodingKeys: String, CodingKey {
        case monitorID = "monitor_id"
        case nodeID = "node_id"
        case at
        case success
        case latencyMs = "latency_ms"
        case error
        case certNotAfter = "cert_not_after"
        case receivedAt = "received_at"
        case sent, lost, reason
        case rttsMs = "rtts_ms"
        case dnsRcode = "dns_rcode"
        case dnsAnswers = "dns_answers"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        monitorID = try container.decodeIfPresent(String.self, forKey: .monitorID) ?? ""
        nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        at = try DateValue.decodeIfPresent(from: container, forKey: .at)
        success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? false
        latencyMs = try container.decodeIfPresent(Double.self, forKey: .latencyMs) ?? 0
        error = try container.decodeIfPresent(String.self, forKey: .error)
        certNotAfter = try DateValue.decodeIfPresent(from: container, forKey: .certNotAfter)
        receivedAt = try DateValue.decodeIfPresent(from: container, forKey: .receivedAt)
        sent = try container.decodeIfPresent(Int.self, forKey: .sent) ?? 0
        lost = try container.decodeIfPresent(Int.self, forKey: .lost) ?? 0
        rttsMs = try container.decodeIfPresent([Double].self, forKey: .rttsMs) ?? []
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        dnsRcode = try container.decodeIfPresent(String.self, forKey: .dnsRcode) ?? ""
        dnsAnswers = try container.decodeIfPresent([String].self, forKey: .dnsAnswers) ?? []
    }

    /// The outcome word for a result row: unmeasured runs are neither up nor down.
    public var outcome: MonitoringResultOutcome {
        if !reason.isEmpty { return .unmeasured }
        return success ? .passed : .failed
    }
}

/// A result's outcome, which the results screen filters by.
public enum MonitoringResultOutcome: String, Sendable, Hashable, CaseIterable {
    case passed, failed, unmeasured
}

public struct MonitorStats: Equatable, Sendable {
    public var sampleCount: Int
    public var successCount: Int
    public var averageLatencyMs: Double?
    public var lastResult: MonitorResult?

    public init(results: [MonitorResult]) {
        sampleCount = results.count
        successCount = results.filter(\.success).count

        let latencies = results.filter(\.success).map(\.latencyMs)
        averageLatencyMs = latencies.isEmpty ? nil : latencies.reduce(0, +) / Double(latencies.count)
        lastResult = results.max { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
    }

    public var uptimeFraction: Double? {
        guard sampleCount > 0 else { return nil }
        return Double(successCount) / Double(sampleCount)
    }
}

// MARK: Path series (GET /api/monitors/series)

/// One step of a path series. `n` 0 with `expected` above 0 is a step with
/// no data: a gap, never interpolated.
public struct MonitoringPathBucket: Decodable, Equatable, Hashable, Sendable {
    public var t: Date
    public var n: Int
    public var expected: Int
    public var fail: Int
    public var minMs: Double?
    public var p50Ms: Double?
    public var p95Ms: Double?
    public var maxMs: Double?
    public var jitterMs: Double?
    /// Fail over n (or lost over sent), 0 to 1; nil when n is zero.
    public var loss: Double?
    public var sent: Int
    public var lost: Int

    public init(t: Date, n: Int, expected: Int, fail: Int = 0, p50Ms: Double? = nil, p95Ms: Double? = nil, loss: Double? = nil) {
        self.t = t
        self.n = n
        self.expected = expected
        self.fail = fail
        self.p50Ms = p50Ms
        self.p95Ms = p95Ms
        self.loss = loss
        self.sent = 0
        self.lost = 0
    }

    enum CodingKeys: String, CodingKey {
        case t, n, expected, fail, loss, sent, lost
        case minMs = "min_ms"
        case p50Ms = "p50_ms"
        case p95Ms = "p95_ms"
        case maxMs = "max_ms"
        case jitterMs = "jitter_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try DateValue.decodeRequired(from: c, forKey: .t)
        n = try c.decodeIfPresent(Int.self, forKey: .n) ?? 0
        expected = try c.decodeIfPresent(Int.self, forKey: .expected) ?? 0
        fail = try c.decodeIfPresent(Int.self, forKey: .fail) ?? 0
        minMs = try c.decodeIfPresent(Double.self, forKey: .minMs)
        p50Ms = try c.decodeIfPresent(Double.self, forKey: .p50Ms)
        p95Ms = try c.decodeIfPresent(Double.self, forKey: .p95Ms)
        maxMs = try c.decodeIfPresent(Double.self, forKey: .maxMs)
        jitterMs = try c.decodeIfPresent(Double.self, forKey: .jitterMs)
        loss = try c.decodeIfPresent(Double.self, forKey: .loss)
        sent = try c.decodeIfPresent(Int.self, forKey: .sent) ?? 0
        lost = try c.decodeIfPresent(Int.self, forKey: .lost) ?? 0
    }
}

/// Where a path's method begins.
public struct MonitoringMethodChange: Decodable, Equatable, Hashable, Sendable {
    public var t: Date
    public var method: String

    enum CodingKeys: String, CodingKey { case t, method }

    public init(t: Date, method: String) {
        self.t = t
        self.method = method
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try DateValue.decodeRequired(from: c, forKey: .t)
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? ""
    }
}

/// The 7-day baseline a path's degraded state is judged on (`model.PathBaseline`).
public struct MonitoringPathBaseline: Decodable, Equatable, Hashable, Sendable {
    public var from: Date?
    public var to: Date?
    public var hours: Int
    /// At least 24 hours: the path is judged.
    public var ready: Bool
    public var p50Ms: Double?
    public var loss: Double?
    public var triggerP50Ms: Double?
    public var triggerLoss: Double?

    enum CodingKeys: String, CodingKey {
        case from, to, hours, ready, loss
        case p50Ms = "p50_ms"
        case triggerP50Ms = "trigger_p50_ms"
        case triggerLoss = "trigger_loss"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try DateValue.decodeIfPresent(from: c, forKey: .from)
        to = try DateValue.decodeIfPresent(from: c, forKey: .to)
        hours = try c.decodeIfPresent(Int.self, forKey: .hours) ?? 0
        ready = try c.decodeIfPresent(Bool.self, forKey: .ready) ?? false
        p50Ms = try c.decodeIfPresent(Double.self, forKey: .p50Ms)
        loss = try c.decodeIfPresent(Double.self, forKey: .loss)
        triggerP50Ms = try c.decodeIfPresent(Double.self, forKey: .triggerP50Ms)
        triggerLoss = try c.decodeIfPresent(Double.self, forKey: .triggerLoss)
    }
}

/// The previous period's p50, one per bucket of the series; nil where nothing succeeded.
public struct MonitoringPreviousSeries: Decodable, Equatable, Hashable, Sendable {
    public var from: Date?
    public var to: Date?
    public var offsetSeconds: Int
    public var stepSeconds: Int
    public var p50Ms: [Double?]

    enum CodingKeys: String, CodingKey {
        case from, to
        case offsetSeconds = "offset_seconds"
        case stepSeconds = "step_seconds"
        case p50Ms = "p50_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try DateValue.decodeIfPresent(from: c, forKey: .from)
        to = try DateValue.decodeIfPresent(from: c, forKey: .to)
        offsetSeconds = try c.decodeIfPresent(Int.self, forKey: .offsetSeconds) ?? 0
        stepSeconds = try c.decodeIfPresent(Int.self, forKey: .stepSeconds) ?? 0
        p50Ms = try c.decodeIfPresent([Double?].self, forKey: .p50Ms) ?? []
    }
}

/// `GET /api/monitors/series` (`model.PathSeries`). Every step is present.
public struct MonitoringPathSeries: Decodable, Equatable, Sendable {
    /// The check that answered on a node pair: a definition id or a monitor id.
    public var check: String
    public var window: String
    public var stepSeconds: Int
    public var from: Date?
    public var to: Date?
    public var methodChanges: [MonitoringMethodChange]
    public var buckets: [MonitoringPathBucket]
    public var baseline: MonitoringPathBaseline?
    public var previous: MonitoringPreviousSeries?

    public init(window: String, stepSeconds: Int, buckets: [MonitoringPathBucket], methodChanges: [MonitoringMethodChange] = []) {
        self.check = ""
        self.window = window
        self.stepSeconds = stepSeconds
        self.from = buckets.first?.t
        self.to = buckets.last?.t
        self.methodChanges = methodChanges
        self.buckets = buckets
    }

    enum CodingKeys: String, CodingKey {
        case check, window, from, to, buckets, baseline, previous
        case stepSeconds = "step_seconds"
        case methodChanges = "method_changes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        check = try c.decodeIfPresent(String.self, forKey: .check) ?? ""
        window = try c.decodeIfPresent(String.self, forKey: .window) ?? ""
        stepSeconds = try c.decodeIfPresent(Int.self, forKey: .stepSeconds) ?? 0
        from = try DateValue.decodeIfPresent(from: c, forKey: .from)
        to = try DateValue.decodeIfPresent(from: c, forKey: .to)
        methodChanges = try c.decodeIfPresent([MonitoringMethodChange].self, forKey: .methodChanges) ?? []
        buckets = try c.decodeIfPresent([MonitoringPathBucket].self, forKey: .buckets) ?? []
        baseline = try c.decodeIfPresent(MonitoringPathBaseline.self, forKey: .baseline)
        previous = try c.decodeIfPresent(MonitoringPreviousSeries.self, forKey: .previous)
    }
}

// MARK: Latency rollups and series (the latency probe plan's endpoints)

public struct MonitoringLatencyStats: Decodable, Equatable, Hashable, Sendable {
    public var samples: Int
    public var failures: Int
    public var expected: Int
    public var p50Ms: Double?
    public var p95Ms: Double?
    public var loss: Double?

    enum CodingKeys: String, CodingKey {
        case samples, failures, expected, loss
        case p50Ms = "p50_ms"
        case p95Ms = "p95_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        samples = try c.decodeIfPresent(Int.self, forKey: .samples) ?? 0
        failures = try c.decodeIfPresent(Int.self, forKey: .failures) ?? 0
        expected = try c.decodeIfPresent(Int.self, forKey: .expected) ?? 0
        p50Ms = try c.decodeIfPresent(Double.self, forKey: .p50Ms)
        p95Ms = try c.decodeIfPresent(Double.self, forKey: .p95Ms)
        loss = try c.decodeIfPresent(Double.self, forKey: .loss)
    }
}

/// One step of a pair's latency series; a bucket with no samples is a gap.
public struct MonitoringLatencyBucket: Decodable, Equatable, Hashable, Sendable {
    public var at: Date
    public var stats: MonitoringLatencyStats

    enum CodingKeys: String, CodingKey { case at }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try DateValue.decodeRequired(from: c, forKey: .at)
        stats = try MonitoringLatencyStats(from: decoder)
    }
}

/// `GET /api/monitors/latency/series?source&target&window`.
public struct MonitoringLatencySeries: Decodable, Equatable, Sendable {
    public var source: String
    public var target: String
    public var monitorID: String
    public var window: String
    public var bucketSec: Int
    public var from: Date?
    public var to: Date?
    public var buckets: [MonitoringLatencyBucket]

    enum CodingKeys: String, CodingKey {
        case source, target, window, from, to, buckets
        case monitorID = "monitor_id"
        case bucketSec = "bucket_sec"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        monitorID = try c.decodeIfPresent(String.self, forKey: .monitorID) ?? ""
        window = try c.decodeIfPresent(String.self, forKey: .window) ?? ""
        bucketSec = try c.decodeIfPresent(Int.self, forKey: .bucketSec) ?? 0
        from = try DateValue.decodeIfPresent(from: c, forKey: .from)
        to = try DateValue.decodeIfPresent(from: c, forKey: .to)
        buckets = try c.decodeIfPresent([MonitoringLatencyBucket].self, forKey: .buckets) ?? []
    }

    /// The same steps as a path series, so one chart draws both.
    public var asPathSeries: MonitoringPathSeries {
        MonitoringPathSeries(
            window: window,
            stepSeconds: bucketSec,
            buckets: buckets.map { bucket in
                let stats = bucket.stats
                return MonitoringPathBucket(t: bucket.at, n: stats.samples, expected: stats.expected, fail: stats.failures,
                                            p50Ms: stats.p50Ms, p95Ms: stats.p95Ms, loss: stats.samples > 0 ? stats.loss : nil)
            }
        )
    }
}

public struct MonitoringLatencyPairRollup: Decodable, Equatable, Sendable {
    public var source: String
    public var target: String
    public var monitorID: String
    public var windows: [String: MonitoringLatencyStats]
    public var latest: MonitorResult?

    enum CodingKeys: String, CodingKey {
        case source, target, windows, latest
        case monitorID = "monitor_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        monitorID = try c.decodeIfPresent(String.self, forKey: .monitorID) ?? ""
        windows = try c.decodeIfPresent([String: MonitoringLatencyStats].self, forKey: .windows) ?? [:]
        latest = try c.decodeIfPresent(MonitorResult.self, forKey: .latest)
    }
}

/// `GET /api/monitors/latency/rollups`.
public struct MonitoringLatencyRollups: Decodable, Equatable, Sendable {
    public var generatedAt: Date?
    public var intervalSec: Int
    public var pairs: [MonitoringLatencyPairRollup]

    enum CodingKeys: String, CodingKey {
        case pairs
        case generatedAt = "generated_at"
        case intervalSec = "interval_sec"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try DateValue.decodeIfPresent(from: c, forKey: .generatedAt)
        intervalSec = try c.decodeIfPresent(Int.self, forKey: .intervalSec) ?? 0
        pairs = try c.decodeIfPresent([MonitoringLatencyPairRollup].self, forKey: .pairs) ?? []
    }
}

// MARK: Check definitions (GET /api/monitors/definitions)

/// Which nodes a definition runs from or reaches (`TargetSelector`).
public struct MonitoringTargetSelector: Decodable, Equatable, Hashable, Sendable {
    public var nodes: [String]
    public var groups: [String]
    public var all: Bool
    public var exclude: [String]

    enum CodingKeys: String, CodingKey { case nodes, groups, all, exclude }

    public init(nodes: [String] = [], groups: [String] = [], all: Bool = false, exclude: [String] = []) {
        self.nodes = nodes
        self.groups = groups
        self.all = all
        self.exclude = exclude
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try c.decodeIfPresent([String].self, forKey: .nodes) ?? []
        groups = try c.decodeIfPresent([String].self, forKey: .groups) ?? []
        all = try c.decodeIfPresent(Bool.self, forKey: .all) ?? false
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
    }

    public var isEmpty: Bool { !all && nodes.isEmpty && groups.isEmpty }
}

public struct MonitoringDefinitionSummary: Decodable, Equatable, Hashable, Sendable {
    public var monitors: Int
    public var paths: Int
    public var pausedTargets: Int
    public var pausedRuns: Int

    enum CodingKeys: String, CodingKey {
        case monitors, paths
        case pausedTargets = "paused_targets"
        case pausedRuns = "paused_runs"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        monitors = try c.decodeIfPresent(Int.self, forKey: .monitors) ?? 0
        paths = try c.decodeIfPresent(Int.self, forKey: .paths) ?? 0
        pausedTargets = try c.decodeIfPresent(Int.self, forKey: .pausedTargets) ?? 0
        pausedRuns = try c.decodeIfPresent(Int.self, forKey: .pausedRuns) ?? 0
    }
}

/// One expanded monitor of a definition; `inSet` false marks a paused target.
public struct MonitoringDefinitionMonitor: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var monitorID: String
    public var method: String
    public var target: String
    public var targetNode: String
    public var inSet: Bool
    public var enabled: Bool
    public var sources: [String]
    public var runs: Int

    public var id: String { monitorID }

    enum CodingKeys: String, CodingKey {
        case method, target, enabled, sources, runs
        case monitorID = "monitor_id"
        case targetNode = "target_node"
        case inSet = "in_set"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        monitorID = try c.decodeIfPresent(String.self, forKey: .monitorID) ?? ""
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? ""
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        targetNode = try c.decodeIfPresent(String.self, forKey: .targetNode) ?? ""
        inSet = try c.decodeIfPresent(Bool.self, forKey: .inSet) ?? true
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
        runs = try c.decodeIfPresent(Int.self, forKey: .runs) ?? 0
    }
}

/// A source to target pair a definition never measures.
public struct MonitoringLatencyPair: Decodable, Equatable, Hashable, Sendable {
    public var source: String
    public var target: String
}

/// `CheckDefinitionView`: the definition, what it holds now, and on a read of
/// one, every monitor it expanded to.
public struct MonitoringCheckDefinition: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// A monitor kind, or `auto`.
    public var type: String
    public var sources: MonitoringTargetSelector
    public var targets: MonitoringTargetSelector
    public var addresses: [String]
    public var intervalSec: Int
    public var timeoutSec: Int
    public var packets: Int
    public var thresholdDays: Int
    public var expectStatus: String
    public var alert: String
    public var alertAfter: Int
    public var enabled: Bool
    public var excludedPairs: [MonitoringLatencyPair]
    public var version: Int64
    public var createdAt: Date?
    public var updatedAt: Date?
    public var updatedBy: String
    public var summary: MonitoringDefinitionSummary?
    /// Present on a read of one definition (`?id=`) and after a save.
    public var monitors: [MonitoringDefinitionMonitor]?

    enum CodingKeys: String, CodingKey {
        case id, name, type, sources, targets, addresses, packets, alert, enabled, version, summary, monitors
        case intervalSec = "interval_sec"
        case timeoutSec = "timeout_sec"
        case thresholdDays = "threshold_days"
        case expectStatus = "expect_status"
        case alertAfter = "alert_after"
        case excludedPairs = "excluded_pairs"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        sources = try c.decodeIfPresent(MonitoringTargetSelector.self, forKey: .sources) ?? MonitoringTargetSelector()
        targets = try c.decodeIfPresent(MonitoringTargetSelector.self, forKey: .targets) ?? MonitoringTargetSelector()
        addresses = try c.decodeIfPresent([String].self, forKey: .addresses) ?? []
        intervalSec = try c.decodeIfPresent(Int.self, forKey: .intervalSec) ?? 0
        timeoutSec = try c.decodeIfPresent(Int.self, forKey: .timeoutSec) ?? 0
        packets = try c.decodeIfPresent(Int.self, forKey: .packets) ?? 0
        thresholdDays = try c.decodeIfPresent(Int.self, forKey: .thresholdDays) ?? 0
        expectStatus = try c.decodeIfPresent(String.self, forKey: .expectStatus) ?? ""
        alert = try c.decodeIfPresent(String.self, forKey: .alert) ?? ""
        alertAfter = try c.decodeIfPresent(Int.self, forKey: .alertAfter) ?? 0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        excludedPairs = try c.decodeIfPresent([MonitoringLatencyPair].self, forKey: .excludedPairs) ?? []
        version = try c.decodeIfPresent(Int64.self, forKey: .version) ?? 0
        createdAt = try DateValue.decodeIfPresent(from: c, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: c, forKey: .updatedAt)
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy) ?? ""
        summary = try c.decodeIfPresent(MonitoringDefinitionSummary.self, forKey: .summary)
        monitors = try c.decodeIfPresent([MonitoringDefinitionMonitor].self, forKey: .monitors)
    }

    public var displayName: String { name.isEmpty ? id : name }
}

/// The deprecated path set, listed as the built-in check named Fleet mesh.
public struct MonitoringFleetMesh: Decodable, Equatable, Hashable, Sendable {
    public var name: String
    public var enabled: Bool
    public var stored: Bool
    public var version: Int64
    public var method: String
    public var sources: Int
    public var targets: Int
    public var paths: Int
    public var pausedTargets: Int
    public var migrated: Bool
    public var definitions: [String]

    enum CodingKeys: String, CodingKey {
        case name, enabled, stored, version, method, sources, targets, paths, migrated, definitions
        case pausedTargets = "paused_targets"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        stored = try c.decodeIfPresent(Bool.self, forKey: .stored) ?? false
        version = try c.decodeIfPresent(Int64.self, forKey: .version) ?? 0
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? ""
        sources = try c.decodeIfPresent(Int.self, forKey: .sources) ?? 0
        targets = try c.decodeIfPresent(Int.self, forKey: .targets) ?? 0
        paths = try c.decodeIfPresent(Int.self, forKey: .paths) ?? 0
        pausedTargets = try c.decodeIfPresent(Int.self, forKey: .pausedTargets) ?? 0
        migrated = try c.decodeIfPresent(Bool.self, forKey: .migrated) ?? false
        definitions = try c.decodeIfPresent([String].self, forKey: .definitions) ?? []
    }
}

/// `CheckDefinitionList`.
public struct MonitoringDefinitionList: Decodable, Equatable, Sendable {
    public var definitions: [MonitoringCheckDefinition]
    public var fleetMesh: MonitoringFleetMesh?

    enum CodingKeys: String, CodingKey {
        case definitions
        case fleetMesh = "fleet_mesh"
    }

    public init(definitions: [MonitoringCheckDefinition], fleetMesh: MonitoringFleetMesh? = nil) {
        self.definitions = definitions
        self.fleetMesh = fleetMesh
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        definitions = try c.decodeIfPresent([MonitoringCheckDefinition].self, forKey: .definitions) ?? []
        fleetMesh = try c.decodeIfPresent(MonitoringFleetMesh.self, forKey: .fleetMesh)
    }
}

/// The answer to `POST /api/monitors/definitions/delete`.
public struct MonitoringDefinitionDeleteResult: Decodable, Equatable, Sendable {
    public var ok: Bool
    public var deleted: [String]
    public var runs: Int

    enum CodingKeys: String, CodingKey { case ok, deleted, runs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        deleted = try c.decodeIfPresent([String].self, forKey: .deleted) ?? []
        runs = try c.decodeIfPresent(Int.self, forKey: .runs) ?? 0
    }
}

// MARK: Line chains (GET /api/network/lines/chains)

public struct MonitoringLineChainCurrent: Decodable, Equatable, Hashable, Sendable {
    public var targetLineUUID: String
    public var targetNodeID: String
    public var artifactDigest: String
    public var status: String

    enum CodingKeys: String, CodingKey {
        case status
        case targetLineUUID = "target_line_uuid"
        case targetNodeID = "target_node_id"
        case artifactDigest = "artifact_digest"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targetLineUUID = try c.decodeIfPresent(String.self, forKey: .targetLineUUID) ?? ""
        targetNodeID = try c.decodeIfPresent(String.self, forKey: .targetNodeID) ?? ""
        artifactDigest = try c.decodeIfPresent(String.self, forKey: .artifactDigest) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
    }
}

public struct MonitoringLineChainAttempt: Decodable, Equatable, Hashable, Sendable {
    public var operation: String
    public var candidateTargetLineUUID: String
    public var approvalID: String
    public var status: String
    public var errorCode: String
    public var error: String

    enum CodingKeys: String, CodingKey {
        case operation, status, error
        case candidateTargetLineUUID = "candidate_target_line_uuid"
        case approvalID = "approval_id"
        case errorCode = "error_code"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operation = try c.decodeIfPresent(String.self, forKey: .operation) ?? ""
        candidateTargetLineUUID = try c.decodeIfPresent(String.self, forKey: .candidateTargetLineUUID) ?? ""
        approvalID = try c.decodeIfPresent(String.self, forKey: .approvalID) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode) ?? ""
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
    }
}

/// One relay line's downstream route: the line on `sourceNodeID` forwards
/// to `current.targetLineUUID` on `current.targetNodeID`.
public struct MonitoringLineChain: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var sourceLineUUID: String
    public var sourceNodeID: String
    /// planned, applying, applied_unobserved, converged, drifted or failed.
    public var status: String
    public var current: MonitoringLineChainCurrent?
    public var attempt: MonitoringLineChainAttempt?
    public var lastError: String

    public var id: String { sourceLineUUID }

    enum CodingKeys: String, CodingKey {
        case status, current, attempt
        case sourceLineUUID = "source_line_uuid"
        case sourceNodeID = "source_node_id"
        case lastError = "last_error"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceLineUUID = try c.decodeIfPresent(String.self, forKey: .sourceLineUUID) ?? ""
        sourceNodeID = try c.decodeIfPresent(String.self, forKey: .sourceNodeID) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        current = try c.decodeIfPresent(MonitoringLineChainCurrent.self, forKey: .current)
        attempt = try c.decodeIfPresent(MonitoringLineChainAttempt.self, forKey: .attempt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError) ?? ""
    }
}

// MARK: Request bodies

/// `POST /api/monitors/update` for pause and resume: exactly `{id, version,
/// enabled}`, the version that was read, so a stale read is refused with 409.
public struct MonitoringUpdateRequest: Encodable, Equatable, Sendable {
    public var id: String
    public var version: Int64
    public var enabled: Bool

    public init(id: String, version: Int64, enabled: Bool) {
        self.id = id
        self.version = version
        self.enabled = enabled
    }
}

/// `POST /api/monitors/definitions/delete`: the definition's version and
/// exactly the monitors it holds now, each of which goes with its history.
public struct MonitoringDefinitionDeleteRequest: Encodable, Equatable, Sendable {
    public var id: String
    public var version: Int64
    public var monitorIDs: [String]

    enum CodingKeys: String, CodingKey {
        case id, version
        case monitorIDs = "monitor_ids"
    }

    public init(id: String, version: Int64, monitorIDs: [String]) {
        self.id = id
        self.version = version
        self.monitorIDs = monitorIDs
    }

    /// The request for a definition as read by id: every monitor it listed.
    public init?(definition: MonitoringCheckDefinition) {
        guard let monitors = definition.monitors else { return nil }
        self.init(id: definition.id, version: definition.version, monitorIDs: monitors.map(\.monitorID))
    }
}
