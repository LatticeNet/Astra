import Foundation

public struct NodeCapabilityEffective: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var capability: String
    public var enforced: Bool
    public var mutates: Bool
    public var allowed: Bool
    public var source: String
    public var reason: String
    public var state: String

    public var id: String { capability }

    enum CodingKeys: String, CodingKey {
        case capability, enforced, mutates, allowed, source, reason, state
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
