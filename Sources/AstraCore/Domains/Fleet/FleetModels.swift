import Foundation

public struct NodeCapabilityEffective: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var capability: String
    public var enforced: Bool
    public var mutates: Bool
    public var allowed: Bool
    public var source: String
    public var reason: String
    public var state: String
    /// The operator's own words on the explicit record, when there is one.
    public var recordReason: String = ""
    public var actorID: String = ""
    public var updatedAt: Date?

    public var id: String { capability }

    enum CodingKeys: String, CodingKey {
        case capability, enforced, mutates, allowed, source, reason, state
        case recordReason = "record_reason"
        case actorID = "actor_id"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capability = try c.decodeIfPresent(String.self, forKey: .capability) ?? ""
        enforced = try c.decodeIfPresent(Bool.self, forKey: .enforced) ?? false
        mutates = try c.decodeIfPresent(Bool.self, forKey: .mutates) ?? false
        allowed = try c.decodeIfPresent(Bool.self, forKey: .allowed) ?? false
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        recordReason = try c.decodeIfPresent(String.self, forKey: .recordReason) ?? ""
        actorID = try c.decodeIfPresent(String.self, forKey: .actorID) ?? ""
        updatedAt = fleetDate(try DateValue.decodeIfPresent(from: c, forKey: .updatedAt))
    }
}

public struct NodeCapabilitiesResponse: Decodable, Sendable {
    public var nodeID: String
    public var effective: [NodeCapabilityEffective]

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case effective
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        effective = try c.decodeIfPresent([NodeCapabilityEffective].self, forKey: .effective) ?? []
    }
}

public struct NodeGeoResolveResult: Identifiable, Decodable, Equatable, Hashable, Sendable {
    public var nodeID: String
    public var ip: String
    public var status: String
    public var message: String
    public var geo: NodeGeoInfo?

    public var id: String { nodeID }

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case ip, status, message, geo
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        ip = try container.decodeIfPresent(String.self, forKey: .ip) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        geo = try container.decodeIfPresent(NodeGeoInfo.self, forKey: .geo)
    }
}

/// One-time credential responses (`token` is shown once and never again).
public struct NodeTokenResponse: Decodable, Sendable, Identifiable {
    public var nodeID: String
    public var token: String
    public var serverURL: String?
    public var command: String?

    public var id: String { token }

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case token
        case serverURL = "server_url"
        case command
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        serverURL = try container.decodeIfPresent(String.self, forKey: .serverURL)
        command = try container.decodeIfPresent(String.self, forKey: .command)
    }
}

/// One point of a node's recent metric history captured during a refresh.
public struct MetricSample: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var date: Date
    public var cpu: Double          // percent, 0...100
    public var memory: Double       // fraction, 0...1
    public var disk: Double         // fraction, 0...1
    public var netRxBytes: UInt64
    public var netTxBytes: UInt64

    public init(date: Date, cpu: Double, memory: Double, disk: Double, netRxBytes: UInt64 = 0, netTxBytes: UInt64 = 0) {
        self.date = date
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.netRxBytes = netRxBytes
        self.netTxBytes = netTxBytes
    }

    public var id: Date { date }
}

/// A bounded, per-node ring buffer of metric samples. The app records one sample
/// per node on every successful refresh so detail screens can draw live trends
/// without any server-side history API.
public struct MetricsHistory: Equatable, Sendable {
    public private(set) var samplesByNode: [String: [MetricSample]]
    public var capacity: Int

    public init(capacity: Int = 90, samplesByNode: [String: [MetricSample]] = [:]) {
        self.capacity = max(1, capacity)
        self.samplesByNode = samplesByNode
    }

    /// Record a sample for each node from a refresh snapshot.
    public mutating func record(nodes: [LatticeNode], at date: Date = Date()) {
        for node in nodes {
            let sample = MetricSample(
                date: date,
                cpu: node.metrics.cpuPercent,
                memory: node.memoryUsedFraction ?? 0,
                disk: node.diskUsedFraction ?? 0,
                netRxBytes: node.metrics.netRxBytes,
                netTxBytes: node.metrics.netTxBytes
            )
            var existing = samplesByNode[node.id] ?? []
            existing.append(sample)
            if existing.count > capacity {
                existing.removeFirst(existing.count - capacity)
            }
            samplesByNode[node.id] = existing
        }
        pruneMissing(nodeIDs: Set(nodes.map(\.id)))
    }

    public func samples(for nodeID: String) -> [MetricSample] {
        samplesByNode[nodeID] ?? []
    }

    /// Drop history for nodes that no longer exist so memory stays bounded.
    public mutating func pruneMissing(nodeIDs: Set<String>) {
        for key in samplesByNode.keys where !nodeIDs.contains(key) {
            samplesByNode.removeValue(forKey: key)
        }
    }
}

/// The thresholds `FleetSummary` counts a node as critical against. They were
/// part of the retired on-device monitor configuration.
public struct FleetThresholds: Codable, Equatable, Hashable, Sendable {
    public var offlineTimeout: TimeInterval
    public var cpuCritical: Double
    public var memoryCritical: Double
    public var diskCritical: Double

    public init(offlineTimeout: TimeInterval = 180, cpuCritical: Double = 90, memoryCritical: Double = 90, diskCritical: Double = 90) {
        self.offlineTimeout = offlineTimeout
        self.cpuCritical = cpuCritical
        self.memoryCritical = memoryCritical
        self.diskCritical = diskCritical
    }
}

/// Aggregate health across the whole fleet, computed from a node snapshot and the
/// operator's alert thresholds.
public struct FleetSummary: Equatable, Sendable {
    public var total: Int
    public var online: Int
    public var offline: Int
    public var disabled: Int
    public var critical: Int
    public var averageCPU: Double
    public var averageMemory: Double
    public var totalNetRxBytes: UInt64
    public var totalNetTxBytes: UInt64

    public init(nodes: [LatticeNode], thresholds configuration: FleetThresholds, now: Date = Date()) {
        total = nodes.count
        var online = 0, offline = 0, disabled = 0, critical = 0
        var cpuSum = 0.0, memSum = 0.0, onlineForAvg = 0
        var rx: UInt64 = 0, tx: UInt64 = 0

        for node in nodes {
            let isOffline = node.isOffline(referenceDate: now, timeout: configuration.offlineTimeout)
            if node.disabled { disabled += 1 }
            if isOffline {
                offline += 1
                critical += 1
                continue
            }
            online += 1
            onlineForAvg += 1
            cpuSum += node.metrics.cpuPercent
            memSum += (node.memoryUsedFraction ?? 0) * 100
            rx += node.metrics.netRxBytes
            tx += node.metrics.netTxBytes

            var isCritical = false
            if node.metrics.cpuPercent >= configuration.cpuCritical { isCritical = true }
            if let memory = node.memoryUsedFraction, memory * 100 >= configuration.memoryCritical { isCritical = true }
            if let disk = node.diskUsedFraction, disk * 100 >= configuration.diskCritical { isCritical = true }
            if isCritical { critical += 1 }
        }

        self.online = online
        self.offline = offline
        self.disabled = disabled
        self.critical = critical
        self.averageCPU = onlineForAvg > 0 ? cpuSum / Double(onlineForAvg) : 0
        self.averageMemory = onlineForAvg > 0 ? memSum / Double(onlineForAvg) : 0
        self.totalNetRxBytes = rx
        self.totalNetTxBytes = tx
    }

    /// Fraction of the fleet that is healthy (online and not critical), 0...1.
    public var healthFraction: Double {
        guard total > 0 else { return 1 }
        let healthy = max(0, online - critical)
        return Double(healthy) / Double(total)
    }
}

// MARK: - Shared decoding helpers for the Fleet domain

/// Go writes a zero `time.Time` as year 1 for fields without `omitzero`; it
/// means "never", so it decodes to nil.
func fleetDate(_ date: Date?) -> Date? {
    guard let date, date.timeIntervalSince1970 > 0 else { return nil }
    return date
}

// MARK: - Node facts the Shared node model does not carry yet

/// `agent_debug` on a node view: verbose agent diagnostics and whether the
/// server collects them.
public struct FleetAgentDebug: Decodable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var collect: Bool
    public var updatedAt: Date?

    public init(enabled: Bool = false, collect: Bool = false, updatedAt: Date? = nil) {
        self.enabled = enabled
        self.collect = collect
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case enabled, collect, updatedAt = "updated_at" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        collect = try c.decodeIfPresent(Bool.self, forKey: .collect) ?? false
        updatedAt = fleetDate(try DateValue.decodeIfPresent(from: c, forKey: .updatedAt))
    }
}

/// `agent_runtime`: what the agent reports it actually runs with.
public struct FleetAgentRuntime: Decodable, Equatable, Hashable, Sendable {
    public var allowExec: Bool
    public var allowRootExec: Bool
    public var noExec: Bool
    public var allowTerminal: Bool
    public var terminalTransport: String
    public var singBoxDiscover: Bool?
    public var taskSandbox: String

    public init(allowExec: Bool = false, allowRootExec: Bool = false, noExec: Bool = false, allowTerminal: Bool = false,
                terminalTransport: String = "", singBoxDiscover: Bool? = nil, taskSandbox: String = "") {
        self.allowExec = allowExec
        self.allowRootExec = allowRootExec
        self.noExec = noExec
        self.allowTerminal = allowTerminal
        self.terminalTransport = terminalTransport
        self.singBoxDiscover = singBoxDiscover
        self.taskSandbox = taskSandbox
    }

    enum CodingKeys: String, CodingKey {
        case allowExec = "allow_exec", allowRootExec = "allow_root_exec", noExec = "no_exec"
        case allowTerminal = "allow_terminal", terminalTransport = "terminal_transport"
        case singBoxDiscover = "singbox_discover", taskSandbox = "task_sandbox"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowExec = try c.decodeIfPresent(Bool.self, forKey: .allowExec) ?? false
        allowRootExec = try c.decodeIfPresent(Bool.self, forKey: .allowRootExec) ?? false
        noExec = try c.decodeIfPresent(Bool.self, forKey: .noExec) ?? false
        allowTerminal = try c.decodeIfPresent(Bool.self, forKey: .allowTerminal) ?? false
        terminalTransport = try c.decodeIfPresent(String.self, forKey: .terminalTransport) ?? ""
        singBoxDiscover = try c.decodeIfPresent(Bool.self, forKey: .singBoxDiscover)
        taskSandbox = try c.decodeIfPresent(String.self, forKey: .taskSandbox) ?? ""
    }
}

/// `ip_config`: how the agent discovers its public address. The script itself
/// is never part of a node view; only its digest is.
public struct FleetIPConfig: Decodable, Equatable, Hashable, Sendable {
    public var mode: String
    public var staticIPv4: String
    public var staticIPv6: String
    public var resolvers: [String]
    public var scriptSHA256: String

    public init(mode: String = "", staticIPv4: String = "", staticIPv6: String = "", resolvers: [String] = [], scriptSHA256: String = "") {
        self.mode = mode
        self.staticIPv4 = staticIPv4
        self.staticIPv6 = staticIPv6
        self.resolvers = resolvers
        self.scriptSHA256 = scriptSHA256
    }

    enum CodingKeys: String, CodingKey {
        case mode, resolvers
        case staticIPv4 = "static_ipv4", staticIPv6 = "static_ipv6", scriptSHA256 = "script_sha256"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
        staticIPv4 = try c.decodeIfPresent(String.self, forKey: .staticIPv4) ?? ""
        staticIPv6 = try c.decodeIfPresent(String.self, forKey: .staticIPv6) ?? ""
        resolvers = try c.decodeIfPresent([String].self, forKey: .resolvers) ?? []
        scriptSHA256 = try c.decodeIfPresent(String.self, forKey: .scriptSHA256) ?? ""
    }
}

/// The parts of a `nodeView` (server.go) that `LatticeNode` does not decode:
/// agent debug, runtime, launch profile, source allowlist, address discovery
/// and the provider half of the geo record. Decoded from the same `/api/nodes`
/// body as the node itself.
public struct FleetNodeFacts: Decodable, Equatable, Hashable, Sendable {
    public var id: String
    public var agentDebug: FleetAgentDebug
    public var agentRuntime: FleetAgentRuntime?
    /// The launch profile's sing-box flag, for drift against the runtime.
    public var launchSingBoxDiscover: Bool?
    public var agentSourceAllowlist: [String]
    public var ipConfig: FleetIPConfig?
    public var provider: String
    public var asOrg: String
    public var asn: Int

    public init(id: String, agentDebug: FleetAgentDebug = FleetAgentDebug(), agentRuntime: FleetAgentRuntime? = nil,
                launchSingBoxDiscover: Bool? = nil, agentSourceAllowlist: [String] = [], ipConfig: FleetIPConfig? = nil,
                provider: String = "", asOrg: String = "", asn: Int = 0) {
        self.id = id
        self.agentDebug = agentDebug
        self.agentRuntime = agentRuntime
        self.launchSingBoxDiscover = launchSingBoxDiscover
        self.agentSourceAllowlist = agentSourceAllowlist
        self.ipConfig = ipConfig
        self.provider = provider
        self.asOrg = asOrg
        self.asn = asn
    }

    enum CodingKeys: String, CodingKey {
        case id, geo
        case agentDebug = "agent_debug", agentRuntime = "agent_runtime", agentLaunch = "agent_launch"
        case agentSourceAllowlist = "agent_source_allowlist", ipConfig = "ip_config"
    }

    private struct Launch: Decodable {
        var singboxDiscover: Bool?
        enum CodingKeys: String, CodingKey { case singboxDiscover = "singbox_discover" }
    }

    private struct GeoProvider: Decodable {
        var provider: String?
        var asOrg: String?
        var asn: Int?
        enum CodingKeys: String, CodingKey { case provider, asn, asOrg = "as_org" }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agentDebug = try c.decodeIfPresent(FleetAgentDebug.self, forKey: .agentDebug) ?? FleetAgentDebug()
        agentRuntime = try c.decodeIfPresent(FleetAgentRuntime.self, forKey: .agentRuntime)
        launchSingBoxDiscover = try c.decodeIfPresent(Launch.self, forKey: .agentLaunch)?.singboxDiscover
        agentSourceAllowlist = try c.decodeIfPresent([String].self, forKey: .agentSourceAllowlist) ?? []
        ipConfig = try c.decodeIfPresent(FleetIPConfig.self, forKey: .ipConfig)
        let geo = try c.decodeIfPresent(GeoProvider.self, forKey: .geo)
        provider = geo?.provider ?? ""
        asOrg = geo?.asOrg ?? ""
        asn = geo?.asn ?? 0
    }
}

/// One node with its Fleet-only facts: the row every Fleet list shows.
public struct FleetNodeRecord: Identifiable, Equatable, Hashable, Sendable {
    public var node: LatticeNode
    public var facts: FleetNodeFacts

    public init(node: LatticeNode, facts: FleetNodeFacts? = nil) {
        self.node = node
        self.facts = facts ?? FleetNodeFacts(id: node.id)
    }

    public var id: String { node.id }
}

// MARK: - Status history (`GET /api/nodes/status-history`)

/// One transition in a node's online record. `to` is `online`, `offline` or
/// `unknown` (the control plane itself was down).
public struct FleetStatusEvent: Decodable, Equatable, Hashable, Sendable {
    public var at: Date?
    public var to: String
    public var cause: String

    public init(at: Date?, to: String, cause: String = "") {
        self.at = at
        self.to = to
        self.cause = cause
    }

    enum CodingKeys: String, CodingKey { case at, to, cause }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = fleetDate(try DateValue.decodeIfPresent(from: c, forKey: .at))
        to = try c.decodeIfPresent(String.self, forKey: .to) ?? ""
        cause = try c.decodeIfPresent(String.self, forKey: .cause) ?? ""
    }
}

public struct FleetNodeStatusHistory: Decodable, Equatable, Hashable, Sendable {
    public var initial: String
    public var events: [FleetStatusEvent]
    public var onlineSeconds: Int
    public var offlineSeconds: Int
    public var unknownSeconds: Int
    public var episodes: Int
    public var longestOfflineSeconds: Int

    public init(initial: String, events: [FleetStatusEvent], onlineSeconds: Int = 0, offlineSeconds: Int = 0,
                unknownSeconds: Int = 0, episodes: Int = 0, longestOfflineSeconds: Int = 0) {
        self.initial = initial
        self.events = events
        self.onlineSeconds = onlineSeconds
        self.offlineSeconds = offlineSeconds
        self.unknownSeconds = unknownSeconds
        self.episodes = episodes
        self.longestOfflineSeconds = longestOfflineSeconds
    }

    enum CodingKeys: String, CodingKey {
        case initial, events, episodes
        case onlineSeconds = "online_seconds", offlineSeconds = "offline_seconds", unknownSeconds = "unknown_seconds"
        case longestOfflineSeconds = "longest_offline_seconds"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        initial = try c.decodeIfPresent(String.self, forKey: .initial) ?? "unknown"
        events = try c.decodeIfPresent([FleetStatusEvent].self, forKey: .events) ?? []
        onlineSeconds = try c.decodeIfPresent(Int.self, forKey: .onlineSeconds) ?? 0
        offlineSeconds = try c.decodeIfPresent(Int.self, forKey: .offlineSeconds) ?? 0
        unknownSeconds = try c.decodeIfPresent(Int.self, forKey: .unknownSeconds) ?? 0
        episodes = try c.decodeIfPresent(Int.self, forKey: .episodes) ?? 0
        longestOfflineSeconds = try c.decodeIfPresent(Int.self, forKey: .longestOfflineSeconds) ?? 0
    }

    /// The share of observed time the node was online, nil when nothing was observed.
    public var onlineShare: Double? {
        let observed = onlineSeconds + offlineSeconds
        return observed > 0 ? Double(onlineSeconds) / Double(observed) : nil
    }
}

public struct FleetStatusHistoryResponse: Decodable, Equatable, Sendable {
    public var since: Date?
    public var until: Date?
    public var nodes: [String: FleetNodeStatusHistory]

    enum CodingKeys: String, CodingKey { case since, until, nodes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        since = fleetDate(try DateValue.decodeIfPresent(from: c, forKey: .since))
        until = fleetDate(try DateValue.decodeIfPresent(from: c, forKey: .until))
        nodes = try c.decodeIfPresent([String: FleetNodeStatusHistory].self, forKey: .nodes) ?? [:]
    }
}

// MARK: - Metric history (`GET /api/nodes/history`)

/// The ranges the phone offers; the server takes these names verbatim.
public enum FleetMetricsRange: String, Sendable, Hashable, CaseIterable, Codable {
    case oneHour = "1h"
    case oneDay = "24h"
    case sevenDays = "7d"
    case thirtyDays = "30d"

    /// Days of status history that cover the range (the server takes whole days, 1 to 30).
    public var statusDays: Int {
        switch self {
        case .oneHour, .oneDay: 1
        case .sevenDays: 7
        case .thirtyDays: 30
        }
    }

    public var seconds: TimeInterval {
        switch self {
        case .oneHour: 3_600
        case .oneDay: 86_400
        case .sevenDays: 7 * 86_400
        case .thirtyDays: 30 * 86_400
        }
    }
}

/// One series of `MetricsQuery`. A bucket nothing was recorded in is absent,
/// so timestamps further apart than the step are a gap; a null average is a
/// bucket whose value could not be computed.
public struct FleetMetricSeries: Decodable, Equatable, Hashable, Sendable {
    public var name: String
    public var kind: String
    public var unit: String
    public var t: [Int64]
    public var avg: [Double?]
    public var min: [Double?]
    public var max: [Double?]

    public init(name: String, kind: String = "gauge", unit: String = "", t: [Int64], avg: [Double?], min: [Double?] = [], max: [Double?] = []) {
        self.name = name
        self.kind = kind
        self.unit = unit
        self.t = t
        self.avg = avg
        self.min = min
        self.max = max
    }

    enum CodingKeys: String, CodingKey { case name, kind, unit, t, avg, min, max }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        t = try c.decodeIfPresent([Int64].self, forKey: .t) ?? []
        avg = try c.decodeIfPresent([Double?].self, forKey: .avg) ?? []
        min = try c.decodeIfPresent([Double?].self, forKey: .min) ?? []
        max = try c.decodeIfPresent([Double?].self, forKey: .max) ?? []
    }

    /// The samples with a value, in time order.
    public var points: [FleetMetricPoint] {
        zip(t, avg).compactMap { time, value in
            guard let value, value.isFinite else { return nil }
            return FleetMetricPoint(date: Date(timeIntervalSince1970: TimeInterval(time)), value: value)
        }
    }
}

public struct FleetMetricPoint: Equatable, Hashable, Sendable, Identifiable {
    public var date: Date
    public var value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }

    public var id: Date { date }
}

public struct FleetMetricsQuery: Decodable, Equatable, Sendable {
    public var owner: String
    public var tier: String
    public var resolutionSeconds: Int
    public var stepSeconds: Int
    public var from: Date?
    public var to: Date?
    public var series: [FleetMetricSeries]

    enum CodingKeys: String, CodingKey {
        case owner, tier, from, to, series
        case resolutionSeconds = "resolution_seconds", stepSeconds = "step_seconds"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
        tier = try c.decodeIfPresent(String.self, forKey: .tier) ?? ""
        resolutionSeconds = try c.decodeIfPresent(Int.self, forKey: .resolutionSeconds) ?? 0
        stepSeconds = try c.decodeIfPresent(Int.self, forKey: .stepSeconds) ?? 0
        from = fleetDate(try DateValue.decodeIfPresent(from: c, forKey: .from))
        to = fleetDate(try DateValue.decodeIfPresent(from: c, forKey: .to))
        series = try c.decodeIfPresent([FleetMetricSeries].self, forKey: .series) ?? []
    }

    public func series(named name: String) -> FleetMetricSeries? {
        series.first { $0.name == name }
    }
}

/// The node series the server records (selfmon.go), in the order the phone shows them.
public enum FleetMetric: String, Sendable, Hashable, CaseIterable {
    case cpu
    case memory = "mem"
    case disk
    case rx = "net_rx"
    case tx = "net_tx"

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .rx: "Received"
        case .tx: "Sent"
        }
    }

    public var isRate: Bool { self == .rx || self == .tx }
}

// MARK: - Duplicates (`GET /api/nodes/duplicates`)

public struct FleetDuplicateGroup: Decodable, Equatable, Hashable, Sendable, Identifiable {
    /// `wireguard_key`, `public_internal_ip` or `host_fingerprint`.
    public var reason: String
    /// `high` or `medium`.
    public var confidence: String
    /// The shared value, shortened by the server when it is sensitive.
    public var signal: String
    public var nodeIDs: [String]

    public init(reason: String, confidence: String, signal: String, nodeIDs: [String]) {
        self.reason = reason
        self.confidence = confidence
        self.signal = signal
        self.nodeIDs = nodeIDs
    }

    public var id: String { "\(reason):\(nodeIDs.joined(separator: ","))" }

    enum CodingKeys: String, CodingKey { case reason, confidence, signal, nodeIDs = "node_ids" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        confidence = try c.decodeIfPresent(String.self, forKey: .confidence) ?? ""
        signal = try c.decodeIfPresent(String.self, forKey: .signal) ?? ""
        nodeIDs = try c.decodeIfPresent([String].self, forKey: .nodeIDs) ?? []
    }

    /// "Same WireGuard key", in the words a row shows.
    public var reasonSentence: String {
        switch reason {
        case "wireguard_key": "Same WireGuard key"
        case "public_internal_ip": "Same public and internal address"
        case "host_fingerprint": "Same host fingerprint"
        default: reason.replacingOccurrences(of: "_", with: " ")
        }
    }
}

public struct FleetDuplicatesResponse: Decodable, Equatable, Sendable {
    public var groups: [FleetDuplicateGroup]

    enum CodingKeys: String, CodingKey { case groups }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([FleetDuplicateGroup].self, forKey: .groups) ?? []
    }

    /// How many nodes appear in any set, each counted once.
    public var nodeCount: Int { Set(groups.flatMap(\.nodeIDs)).count }
}

// MARK: - Writes: identity, debug, capabilities

/// `POST /api/nodes/update`. The server replaces name, role, comment and tags
/// whole, so every one is sent; the allowlist and inventory are left out,
/// which the server reads as "keep".
public struct FleetNodeUpdateRequest: Encodable, Equatable, Sendable {
    public var nodeID: String
    public var name: String
    public var role: String
    public var comment: String
    public var tags: [String]

    public init(nodeID: String, name: String, role: String, comment: String, tags: [String]) {
        self.nodeID = nodeID
        self.name = name
        self.role = role
        self.comment = comment
        self.tags = tags
    }

    enum CodingKeys: String, CodingKey { case name, role, comment, tags, nodeID = "node_id" }
}

public struct FleetNodeUpdateResponse: Decodable, Equatable, Sendable {
    public var ok: Bool
    public var name: String
    public var role: String
    public var comment: String
    public var tags: [String]

    enum CodingKeys: String, CodingKey { case ok, name, role, comment, tags }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

struct FleetDebugRequest: Encodable {
    var nodeID: String
    var enabled: Bool
    var collect: Bool
    enum CodingKeys: String, CodingKey { case enabled, collect, nodeID = "node_id" }
}

struct FleetGeoClearRequest: Encodable {
    var nodeID: String
    var clear = true
    enum CodingKeys: String, CodingKey { case clear, nodeID = "node_id" }
}

/// `POST /api/nodes/capabilities`: `enrolled`, `excluded` (a reason is
/// required) or empty to clear the record.
public struct FleetCapabilityDecisionRequest: Encodable, Equatable, Sendable {
    public var nodeID: String
    public var capability: String
    public var state: String
    public var reason: String

    public init(nodeID: String, capability: String, state: String, reason: String = "") {
        self.nodeID = nodeID
        self.capability = capability
        self.state = state
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey { case capability, state, reason, nodeID = "node_id" }
}

/// `nodeCapabilityView`, the answer to a capability decision.
public struct FleetNodeCapabilityRecord: Decodable, Equatable, Sendable {
    public var nodeID: String
    public var capability: String
    public var state: String
    public var reason: String
    public var enforced: Bool

    enum CodingKeys: String, CodingKey { case capability, state, reason, enforced, nodeID = "node_id" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        capability = try c.decodeIfPresent(String.self, forKey: .capability) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        enforced = try c.decodeIfPresent(Bool.self, forKey: .enforced) ?? false
    }
}

// MARK: - Capability gates (`GET /api/capabilities`)

public struct FleetRefusedNode: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var nodeID: String
    public var name: String
    public var reason: String

    public init(nodeID: String, name: String = "", reason: String = "") {
        self.nodeID = nodeID
        self.name = name
        self.reason = reason
    }

    public var id: String { nodeID }
    public var displayName: String { name.isEmpty ? nodeID : name }

    enum CodingKeys: String, CodingKey { case name, reason, nodeID = "node_id" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

/// `capabilityImpactView`: one gate and what enforcing it would refuse, as
/// if it were enforced now. `refused` names at most ten nodes.
public struct FleetCapabilityImpact: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var capability: String
    public var enforced: Bool
    public var mutates: Bool
    public var derived: Bool
    public var allowCount: Int
    public var refuseCount: Int
    public var refused: [FleetRefusedNode]

    public init(capability: String, enforced: Bool, mutates: Bool, derived: Bool, allowCount: Int, refuseCount: Int, refused: [FleetRefusedNode] = []) {
        self.capability = capability
        self.enforced = enforced
        self.mutates = mutates
        self.derived = derived
        self.allowCount = allowCount
        self.refuseCount = refuseCount
        self.refused = refused
    }

    public var id: String { capability }

    enum CodingKeys: String, CodingKey {
        case capability, enforced, mutates, derived, refused
        case allowCount = "allow_count", refuseCount = "refuse_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capability = try c.decodeIfPresent(String.self, forKey: .capability) ?? ""
        enforced = try c.decodeIfPresent(Bool.self, forKey: .enforced) ?? false
        mutates = try c.decodeIfPresent(Bool.self, forKey: .mutates) ?? false
        derived = try c.decodeIfPresent(Bool.self, forKey: .derived) ?? false
        allowCount = try c.decodeIfPresent(Int.self, forKey: .allowCount) ?? 0
        refuseCount = try c.decodeIfPresent(Int.self, forKey: .refuseCount) ?? 0
        refused = try c.decodeIfPresent([FleetRefusedNode].self, forKey: .refused) ?? []
    }

    /// The console's description of the gate kind (settings.capabilities).
    public var kindSentence: String {
        mutates ? "Changes nodes, so it is opt-in" : "Reads nodes"
    }

    /// What turning the gate on would do, in the console's words.
    public var impactSentence: String {
        "\(allowCount) in scope, \(refuseCount) would be refused"
    }
}

struct FleetCapabilityImpactList: Decodable {
    var capabilities: [FleetCapabilityImpact]
    enum CodingKeys: String, CodingKey { case capabilities }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capabilities = try c.decodeIfPresent([FleetCapabilityImpact].self, forKey: .capabilities) ?? []
    }
}

struct FleetGateRequest: Encodable {
    var capability: String
    var enforced: Bool
}

// MARK: - Node delete (`POST /api/nodes/delete/plan` and `/delete`)

/// `nodeDeleteSummary`: what deleting a node removes or strips. The plan and
/// the delete answer the same shape; `mutated` tells them apart.
public struct FleetNodeDeleteSummary: Decodable, Equatable, Hashable, Sendable {
    public var nodeID: String
    public var nodeName: String
    public var found: Bool
    public var mutated: Bool
    /// Every counter by its JSON key, so a new server counter is never dropped.
    public var counters: [String: Int]

    public init(nodeID: String, nodeName: String, found: Bool = true, mutated: Bool = false, counters: [String: Int]) {
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.found = found
        self.mutated = mutated
        self.counters = counters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        nodeID = try c.decodeIfPresent(String.self, forKey: LatticeCodingKey("node_id")) ?? ""
        nodeName = try c.decodeIfPresent(String.self, forKey: LatticeCodingKey("node_name")) ?? ""
        found = try c.decodeIfPresent(Bool.self, forKey: LatticeCodingKey("found")) ?? false
        mutated = try c.decodeIfPresent(Bool.self, forKey: LatticeCodingKey("mutated")) ?? false
        var counters: [String: Int] = [:]
        for key in c.allKeys where !["node_id", "node_name", "found", "mutated"].contains(key.stringValue) {
            if let value = try? c.decode(Int.self, forKey: key) { counters[key.stringValue] = value }
        }
        self.counters = counters
    }

    public subscript(_ key: String) -> Int { counters[key] ?? 0 }

    public var logStorePurgeErrors: Int { self["log_store_purge_errs"] }
}
