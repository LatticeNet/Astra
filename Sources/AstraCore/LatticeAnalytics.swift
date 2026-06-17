import Foundation

// MARK: - Metric history (drives sparklines while polling)

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

// MARK: - Fleet summary

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

    public init(nodes: [LatticeNode], configuration: MonitorConfiguration, now: Date = Date()) {
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

// MARK: - Inventory summary (cost & renewals)

public struct InventorySummary: Equatable, Sendable {
    public var machineCount: Int
    public var monthlyCostByCurrency: [String: Double]
    public var dueSoon: [MachineProfile]
    public var overdue: [MachineProfile]

    public init(machines: [MachineProfile], window: Int = 14, now: Date = Date()) {
        machineCount = machines.count

        var costs: [String: Double] = [:]
        for machine in machines {
            guard let monthly = machine.monthlyCost else { continue }
            let currency = machine.currency.isEmpty ? "USD" : machine.currency.uppercased()
            costs[currency, default: 0] += monthly
        }
        monthlyCostByCurrency = costs

        var due: [MachineProfile] = []
        var over: [MachineProfile] = []
        for machine in machines {
            guard let days = machine.daysUntilRenewal(now: now) else { continue }
            if days < 0 {
                over.append(machine)
            } else if days <= window {
                due.append(machine)
            }
        }
        dueSoon = due.sorted { ($0.nextRenewal ?? .distantFuture) < ($1.nextRenewal ?? .distantFuture) }
        overdue = over.sorted { ($0.nextRenewal ?? .distantPast) < ($1.nextRenewal ?? .distantPast) }
    }

    public var primaryMonthlyCost: (currency: String, amount: Double)? {
        guard let entry = monthlyCostByCurrency.max(by: { $0.value < $1.value }) else { return nil }
        return (entry.key, entry.value)
    }
}

// MARK: - Monitor statistics

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

// MARK: - Formatters

public enum CurrencyFormatter {
    public static func string(amountMajorUnits amount: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !code.isEmpty {
            formatter.currencyCode = code
        }
        if let formatted = formatter.string(from: NSNumber(value: amount)) {
            return formatted
        }
        return String(format: "%.2f %@", amount, code)
    }
}

public enum RelativeDateFormatter {
    public static func string(from date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 0 {
            return shortDuration(-interval) + " from now"
        }
        if interval < 5 {
            return "just now"
        }
        return shortDuration(interval) + " ago"
    }

    /// Compact human duration: "45s", "12m", "3h", "2d".
    public static func shortDuration(_ seconds: TimeInterval) -> String {
        let value = Int(seconds.rounded())
        if value < 60 { return "\(value)s" }
        let minutes = value / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        return "\(days)d"
    }
}

public enum UptimeFormatter {
    /// Render an uptime in seconds as "12d 4h" / "4h 12m" / "12m".
    public static func string(seconds: UInt64) -> String {
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }
}
