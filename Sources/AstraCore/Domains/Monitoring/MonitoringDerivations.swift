import Foundation

// Pure derivations for M3, ported from the console where it has them
// (monitorHealthModel.ts, pathsModel.ts, pathSeriesModel.ts, topologyModel.ts)
// and covered by MonitoringChecks.

// MARK: Check health (monitorHealthModel.ts)

/// What a check is doing now, read from each node's newest result.
public enum MonitoringHealth: Sendable, Hashable {
    case disabled
    /// Results not read yet.
    case unread
    case none
    case failing(failing: Int, total: Int, lastAt: Date)
    case stale(lastAt: Date)
    /// Every newest result measured nothing; `reason` is empty when they differ.
    case unmeasured(total: Int, reason: String, lastAt: Date)
    /// The newest runs pass but the control plane judges some of its paths degraded.
    case degraded(degraded: Int, total: Int, lastAt: Date)
    case up(total: Int, latencyMs: Double?, lastAt: Date)

    /// Failing first, then the warnings, then what is fine.
    public var rank: Int {
        switch self {
        case .failing: 0
        case .degraded: 1
        case .stale: 2
        case .unmeasured: 3
        case .none: 4
        case .unread: 5
        case .up: 6
        case .disabled: 7
        }
    }

    public var isFailing: Bool {
        if case .failing = self { return true }
        return false
    }

    public var lastAt: Date? {
        switch self {
        case .failing(_, _, let at), .stale(let at), .unmeasured(_, _, let at), .degraded(_, _, let at), .up(_, _, let at): at
        case .disabled, .unread, .none: nil
        }
    }

    /// How old the newest result may be before it stops counting as a reading.
    public static func staleAfter(intervalSec: Int) -> TimeInterval {
        let interval = intervalSec > 0 ? intervalSec : 60
        return TimeInterval(max(3 * interval, 180))
    }

    /// `monitorHealth`. `results` nil means not read yet.
    public static func of(_ monitor: Monitor, results: [MonitoringLatest]?, now: Date) -> MonitoringHealth {
        guard monitor.enabled else { return .disabled }
        guard let results else { return .unread }
        var newest: [String: MonitoringLatest] = [:]
        for result in results {
            let held = newest[result.nodeID]
            if held == nil || (result.at ?? .distantPast) >= (held?.at ?? .distantPast) { newest[result.nodeID] = result }
        }
        let latest = Array(newest.values)
        guard !latest.isEmpty else { return .none }
        let lastAt = latest.compactMap(\.at).max() ?? .distantPast
        let measured = latest.filter { $0.reason.isEmpty }
        let failing = measured.filter { !$0.success }.count
        if failing > 0 { return .failing(failing: failing, total: latest.count, lastAt: lastAt) }
        if now.timeIntervalSince(lastAt) > staleAfter(intervalSec: monitor.intervalSec) { return .stale(lastAt: lastAt) }
        if measured.isEmpty {
            let reasons = Set(latest.map(\.reason))
            return .unmeasured(total: latest.count, reason: reasons.count == 1 ? (reasons.first ?? "") : "", lastAt: lastAt)
        }
        let latencies = measured.compactMap(\.latencyMs).filter(\.isFinite)
        let mean = latencies.isEmpty ? nil : latencies.reduce(0, +) / Double(latencies.count)
        return .up(total: latest.count, latencyMs: mean, lastAt: lastAt)
    }

    /// `checksModel.withPathVerdict`: a passing check some of whose paths the
    /// control plane judges degraded reads degraded, never up.
    public func withPathVerdict(_ paths: [PathView], monitorID: String, judgesDegraded: Bool) -> MonitoringHealth {
        guard case .up(_, _, let lastAt) = self, judgesDegraded else { return self }
        let own = paths.filter { $0.monitorID == monitorID }
        let degraded = own.filter { $0.state == "degraded" }.count
        return degraded > 0 ? .degraded(degraded: degraded, total: own.count, lastAt: lastAt) : self
    }
}

// MARK: Chart segments (section 4.6: missing data is a gap)

/// One plotted value at one time.
public struct MonitoringChartPoint: Sendable, Hashable {
    public var t: Date
    public var value: Double

    public init(t: Date, value: Double) {
        self.t = t
        self.value = value
    }
}

public enum MonitoringSeriesSegments {
    /// Consecutive samples further apart than this many steps start a new segment.
    public static let gapFactor = 2.5

    /// Splits values into runs that may be joined by a line: a missing value
    /// ends a run, and so does a step further than 2.5 intervals from the last
    /// value. Never interpolates across either.
    public static func segments(_ values: [(t: Date, value: Double?)], stepSeconds: Int) -> [[MonitoringChartPoint]] {
        let limit = Double(max(stepSeconds, 1)) * gapFactor
        var result: [[MonitoringChartPoint]] = []
        var current: [MonitoringChartPoint] = []
        for entry in values.sorted(by: { $0.t < $1.t }) {
            guard let value = entry.value, value.isFinite else {
                if !current.isEmpty { result.append(current); current = [] }
                continue
            }
            if let last = current.last, entry.t.timeIntervalSince(last.t) > limit {
                result.append(current)
                current = []
            }
            current.append(MonitoringChartPoint(t: entry.t, value: value))
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// p50 runs. A step with no runs (`n` 0) has no p50 and is a gap.
    public static func p50(_ series: MonitoringPathSeries) -> [[MonitoringChartPoint]] {
        segments(series.buckets.map { ($0.t, $0.n > 0 ? $0.p50Ms : nil) }, stepSeconds: series.stepSeconds)
    }

    /// p95 runs, for the band between p50 and p95.
    public static func p95(_ series: MonitoringPathSeries) -> [[MonitoringChartPoint]] {
        segments(series.buckets.map { ($0.t, $0.n > 0 ? $0.p95Ms : nil) }, stepSeconds: series.stepSeconds)
    }

    /// Loss as a share 0 to 1, nil where nothing ran.
    public static func loss(_ series: MonitoringPathSeries) -> [MonitoringChartPoint] {
        series.buckets.compactMap { bucket in
            guard bucket.n > 0, let loss = bucket.loss else { return nil }
            return MonitoringChartPoint(t: bucket.t, value: loss)
        }
    }

    /// The previous window's p50 laid over this window's steps.
    public static func previous(_ series: MonitoringPathSeries) -> [[MonitoringChartPoint]] {
        guard let previous = series.previous else { return [] }
        let values = series.buckets.enumerated().map { index, bucket in
            (bucket.t, index < previous.p50Ms.count ? previous.p50Ms[index] : nil)
        }
        return segments(values, stepSeconds: series.stepSeconds)
    }

    /// True when the series has no step with data: the chart is replaced by a sentence.
    public static func isEmpty(_ series: MonitoringPathSeries) -> Bool {
        !series.buckets.contains { $0.n > 0 }
    }

    /// The newest step that heard anything.
    public static func lastData(_ series: MonitoringPathSeries) -> Date? {
        series.buckets.last { $0.n > 0 }?.t
    }
}

// MARK: State strip (section 4.6)

/// One cell of a state strip, encoded by shape as well as color.
public enum MonitoringStripCell: String, Sendable, Hashable, CaseIterable {
    case up, degraded, down, unknown, paused
}

public enum MonitoringStrip {
    public static let defaultLossTrigger = 0.02

    /// The window in `count` cells (fewer when the series has fewer steps).
    /// A cell that expected no runs is paused (a gap); one that heard none is
    /// unknown; one whose every run failed is down; one over the loss or
    /// latency trigger is degraded.
    public static func cells(_ series: MonitoringPathSeries, count: Int = 24) -> [MonitoringStripCell] {
        let buckets = series.buckets
        guard !buckets.isEmpty, count > 0 else { return [] }
        let cellCount = min(count, buckets.count)
        let lossTrigger = series.baseline?.triggerLoss ?? defaultLossTrigger
        let latencyTrigger = series.baseline?.triggerP50Ms
        return (0..<cellCount).map { index in
            let start = index * buckets.count / cellCount
            let end = (index + 1) * buckets.count / cellCount
            let chunk = buckets[start..<end]
            let runs = chunk.reduce(0) { $0 + $1.n }
            let expected = chunk.reduce(0) { $0 + $1.expected }
            if runs == 0 { return expected == 0 ? .paused : .unknown }
            let failed = chunk.reduce(0) { $0 + $1.fail }
            if failed >= runs { return .down }
            let sent = chunk.reduce(0) { $0 + $1.sent }
            let lost = chunk.reduce(0) { $0 + $1.lost }
            let loss = sent > 0 ? Double(lost) / Double(sent) : Double(failed) / Double(runs)
            let worstP50 = chunk.compactMap(\.p50Ms).max()
            if loss > lossTrigger { return .degraded }
            if let latencyTrigger, let worstP50, worstP50 > latencyTrigger { return .degraded }
            return .up
        }
    }

    /// The strip in words, for the row's accessibility label:
    /// "Last 24 intervals: 20 up, 2 degraded, 2 no data".
    public static func summary(_ cells: [MonitoringStripCell]) -> String {
        guard !cells.isEmpty else { return "No history in this window" }
        let order: [(MonitoringStripCell, String)] = [(.down, "down"), (.degraded, "degraded"), (.unknown, "no data"), (.paused, "paused"), (.up, "up")]
        let parts = order.compactMap { cell, word -> String? in
            let n = cells.filter { $0 == cell }.count
            return n > 0 ? "\(n) \(word)" : nil
        }
        return "Last \(cells.count) intervals: " + parts.joined(separator: ", ")
    }
}

// MARK: Paths (pathsModel.ts)

/// A path as the lists show it: the cell plus the names of its ends.
public struct MonitoringPathItem: Sendable, Hashable, Identifiable {
    public var path: PathView
    public var sourceName: String
    /// The target node's name, or the address a check dials.
    public var targetName: String
    public var region: String
    public var country: String
    public var display: PathDisplayState

    public var id: String { path.id }
    public var key: String { path.key }

    /// "skipped" for a pair its check skips, else the display word (console `displayState`).
    public var stateWord: String {
        if display.measure == .skipped { return "skipped" }
        switch display {
        case .up: return "up"
        case .degraded: return "degraded"
        case .down: return "down"
        case .paused: return "paused"
        case .unknown: return "unknown"
        }
    }

    public var reason: PathReason? {
        switch display {
        case .degraded(let reason), .unknown(let reason): reason
        case .paused(let reason): reason
        case .up, .down: nil
        }
    }

    /// Whether the figures describe the path now (`measuresNow`).
    public var measuresNow: Bool {
        switch display {
        case .up, .degraded, .down: true
        case .unknown, .paused: false
        }
    }

    /// "edge-tyo-1 to relay-fra-1", the spoken and title form.
    public var spokenTitle: String { "\(sourceName) to \(targetName)" }
}

/// The groups of the Paths list, in `topologyModel` order.
public enum MonitoringPathGroup: String, Sendable, Hashable, CaseIterable {
    case down, degraded, unknown, paused, up

    public var title: String {
        switch self {
        case .down: "Down"
        case .degraded: "Degraded"
        case .unknown: "Unknown"
        case .paused: "Paused"
        case .up: "Up"
        }
    }

    public init(_ state: PathDisplayState) {
        switch state {
        case .down: self = .down
        case .degraded: self = .degraded
        case .unknown: self = .unknown
        case .paused: self = .paused
        case .up: self = .up
        }
    }
}

/// `countPaths`: measured paths only in `paths`.
public struct MonitoringPathCounts: Sendable, Hashable {
    public var paths = 0
    public var up = 0
    public var degraded = 0
    public var down = 0
    public var unknown = 0
    public var paused = 0
    public var skipped = 0

    public init() {}

    public var problems: Int { down + degraded }
}

public enum MonitoringPaths {
    public static let controlPlaneName = "control plane"

    /// Every path of the response with names resolved: the response's own
    /// sources and targets first, then `nodeName`, then the id.
    public static func items(_ response: PathsResponse, nodeName: (String) -> String? = { _ in nil }) -> [MonitoringPathItem] {
        var sourceNames: [String: (String, String)] = [:]
        for source in response.sources { sourceNames[source.nodeID] = (source.name, source.region ?? "") }
        var targetNames: [String: (name: String, region: String, country: String)] = [:]
        for target in response.targets { targetNames[target.nodeID] = (target.name, target.region ?? "", target.country ?? "") }
        return response.paths.map { path in
            let source: String
            if path.source.isEmpty {
                source = controlPlaneName
            } else {
                source = nonEmpty(sourceNames[path.source]?.0) ?? nonEmpty(targetNames[path.source]?.name) ?? nodeName(path.source) ?? path.source
            }
            let target: String
            var region = ""
            var country = ""
            if path.targetNode.isEmpty {
                target = displayAddress(path.target)
            } else {
                let named = targetNames[path.targetNode]
                target = nonEmpty(named?.name) ?? nodeName(path.targetNode) ?? path.targetNode
                region = named?.region ?? ""
                country = named?.country ?? ""
            }
            return MonitoringPathItem(
                path: path, sourceName: source, targetName: target, region: region, country: country,
                display: path.displayState(judgesDegraded: response.judgesDegraded)
            )
        }
    }

    /// An address without its scheme and path, so a check to a URL reads as its host.
    public static func displayAddress(_ target: String) -> String {
        guard let url = URL(string: target), let host = url.host(), url.scheme != nil else { return target }
        return host
    }

    /// The default views leave out pairs their check skips (design 32 R2);
    /// "Show unmeasured" brings them back.
    public static func visible(_ items: [MonitoringPathItem], showUnmeasured: Bool) -> [MonitoringPathItem] {
        showUnmeasured ? items : items.filter { $0.display.measure != .skipped }
    }

    /// Groups in order down, degraded, unknown, paused, up; empty groups are left out.
    public static func groups(_ items: [MonitoringPathItem]) -> [(group: MonitoringPathGroup, items: [MonitoringPathItem])] {
        let sorted = items.sorted { a, b in
            if a.sourceName != b.sourceName { return a.sourceName.localizedStandardCompare(b.sourceName) == .orderedAscending }
            if a.targetName != b.targetName { return a.targetName.localizedStandardCompare(b.targetName) == .orderedAscending }
            return a.id < b.id
        }
        return MonitoringPathGroup.allCases.compactMap { group in
            let members = sorted.filter { MonitoringPathGroup($0.display) == group }
            return members.isEmpty ? nil : (group, members)
        }
    }

    /// `countPaths`.
    public static func counts(_ items: [MonitoringPathItem]) -> MonitoringPathCounts {
        var counts = MonitoringPathCounts()
        for item in items {
            switch item.display.measure {
            case .skipped: counts.skipped += 1; continue
            case .paused: counts.paused += 1; continue
            case .measured: break
            }
            counts.paths += 1
            switch item.display {
            case .up: counts.up += 1
            case .degraded: counts.degraded += 1
            case .down: counts.down += 1
            case .unknown: counts.unknown += 1
            case .paused: counts.paused += 1
            }
        }
        return counts
    }

    /// The reverse direction of a node pair, when the matrix measures it.
    public static func reverse(of item: MonitoringPathItem, in items: [MonitoringPathItem]) -> MonitoringPathItem? {
        guard !item.path.targetNode.isEmpty, !item.path.source.isEmpty else { return nil }
        return pairOrder(items.filter { $0.path.source == item.path.targetNode && $0.path.targetNode == item.path.source }).first
    }

    /// `topologyModel.pairOrder`: the cells of one pair in the order they
    /// speak, the live ones (up, degraded, down) first and the worst first
    /// within each, so a check that cannot run never greys a measured pair.
    public static func pairOrder(_ items: [MonitoringPathItem]) -> [MonitoringPathItem] {
        func live(_ item: MonitoringPathItem) -> Int {
            switch item.display {
            case .up, .degraded, .down: 0
            case .unknown, .paused: 1
            }
        }
        return items.sorted { a, b in
            if live(a) != live(b) { return live(a) < live(b) }
            if a.display.severityRank != b.display.severityRank { return a.display.severityRank < b.display.severityRank }
            return a.id < b.id
        }
    }

    /// The cell a path screen shows: the named check's cell on the pair, or
    /// the pair's first cell in `pairOrder` when none is named or it is gone.
    public static func cell(key: String, monitorID: String?, in items: [MonitoringPathItem]) -> MonitoringPathItem? {
        let pair = items.filter { $0.key == key }
        if let monitorID, !monitorID.isEmpty, let named = pair.first(where: { $0.path.monitorID == monitorID }) { return named }
        return pairOrder(pair).first
    }

    /// Every cell of a pair, in `pairOrder`.
    public static func checks(onPair key: String, in items: [MonitoringPathItem]) -> [MonitoringPathItem] {
        pairOrder(items.filter { $0.key == key })
    }

    /// Down and degraded paths, the most recent problem first, for Overview.
    public static func recentlyDegraded(_ items: [MonitoringPathItem], limit: Int = 5) -> [MonitoringPathItem] {
        let problems = items.filter {
            switch $0.display {
            case .down, .degraded: true
            default: false
            }
        }
        return Array(problems.sorted { a, b in
            let ta = a.path.degraded?.since ?? a.path.lastAt ?? .distantPast
            let tb = b.path.degraded?.since ?? b.path.lastAt ?? .distantPast
            if ta != tb { return ta > tb }
            return a.display.severityRank < b.display.severityRank
        }.prefix(limit))
    }

    /// The figures in words: "p50 41 ms, loss 0.2%" or nil when nothing is measured now.
    public static func figures(_ item: MonitoringPathItem) -> String? {
        guard item.measuresNow else { return nil }
        let parts = [item.path.p50Ms.map { "p50 \(milliseconds($0))" }, item.path.loss.map { "loss \(percent($0))" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// Number formats the monitoring screens share. Locale-independent on
/// purpose: these are measurements, written as the console writes them.
public enum MonitoringFormat {
    public static func milliseconds(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f ms", value) : String(format: "%.1f ms", value).replacingOccurrences(of: ".0 ms", with: " ms")
    }

    /// A share 0 to 1 as a percentage with one decimal.
    public static func percent(_ share: Double) -> String {
        String(format: "%.1f%%", share * 100)
    }
}

private func milliseconds(_ value: Double) -> String { MonitoringFormat.milliseconds(value) }
private func percent(_ share: Double) -> String { MonitoringFormat.percent(share) }

// MARK: Path evidence (PathDetail header)

public enum MonitoringPathEvidence {
    /// "Loss 6.2% against a baseline of 0.4%, trigger 2.0%, since 14:02".
    /// `since` is the formatted time; nil without degradation evidence.
    public static func sentence(_ degradation: PathDegradation?, since: String?) -> String? {
        guard let degradation else { return nil }
        var parts: [String] = []
        if let loss = degradation.loss {
            parts.append("Loss \(percent(loss.value)) against a baseline of \(percent(loss.baseline)), trigger \(percent(loss.trigger))")
        }
        if let latency = degradation.latency {
            parts.append("p50 \(milliseconds(latency.p50Ms)) against a baseline of \(milliseconds(latency.baselineMs)), trigger \(milliseconds(latency.triggerMs))")
        }
        guard !parts.isEmpty else { return nil }
        var text = parts.joined(separator: "; ")
        if let since { text += ", since \(since)" }
        return text
    }
}

// MARK: Matrix (PathMatrix)

public struct MonitoringMatrixColumn: Sendable, Hashable, Identifiable {
    /// The target node id, or `@<monitorID>` for a check to an address.
    public var id: String
    public var name: String
    public var targetNode: String

    public init(id: String, name: String, targetNode: String) {
        self.id = id
        self.name = name
        self.targetNode = targetNode
    }
}

public struct MonitoringMatrixRow: Sendable, Hashable, Identifiable {
    /// The source node id; empty for the control plane.
    public var id: String
    public var name: String
    /// One per column; nil where the source does not probe that target.
    public var cells: [MonitoringStripCell?]
    public var down: Int
    public var degraded: Int
    public var unknown: Int
    public var paused: Int
    public var up: Int

    public var hasProblems: Bool { down + degraded > 0 }

    /// "edge-tyo-1: 1 down, 1 degraded, 1 up".
    public var summary: String {
        let parts = [(down, "down"), (degraded, "degraded"), (unknown, "unknown"), (paused, "paused"), (up, "up")]
            .compactMap { count, word in count > 0 ? "\(count) \(word)" : nil }
        return "\(name): " + (parts.isEmpty ? "no paths" : parts.joined(separator: ", "))
    }
}

public struct MonitoringMatrix: Sendable, Hashable {
    public var columns: [MonitoringMatrixColumn]
    public var rows: [MonitoringMatrixRow]

    /// Sources as rows and targets as columns. A source with several checks to
    /// one target shows the worst of them.
    public init(items: [MonitoringPathItem]) {
        var columnNames: [String: (name: String, targetNode: String)] = [:]
        var rowNames: [String: String] = [:]
        var worst: [String: [String: MonitoringPathItem]] = [:]
        for item in items {
            let column = item.path.targetNode.isEmpty ? "@\(item.path.monitorID)" : item.path.targetNode
            columnNames[column] = (item.targetName, item.path.targetNode)
            rowNames[item.path.source] = item.sourceName
            if let held = worst[item.path.source]?[column], held.display.severityRank <= item.display.severityRank { continue }
            worst[item.path.source, default: [:]][column] = item
        }
        func order(_ a: (key: String, value: String), _ b: (key: String, value: String)) -> Bool {
            a.value.localizedStandardCompare(b.value) == .orderedAscending
        }
        columns = columnNames.map { (key: $0.key, value: $0.value.name) }.sorted(by: order).map { entry in
            MonitoringMatrixColumn(id: entry.key, name: entry.value, targetNode: columnNames[entry.key]?.targetNode ?? "")
        }
        let columnIDs = columns.map(\.id)
        rows = rowNames.sorted(by: order).map { source, name in
            let cells = columnIDs.map { worst[source]?[$0].map { MonitoringMatrix.cell($0.display) } }
            func count(_ cell: MonitoringStripCell) -> Int { cells.filter { $0 == cell }.count }
            return MonitoringMatrixRow(id: source, name: name, cells: cells, down: count(.down), degraded: count(.degraded),
                                       unknown: count(.unknown), paused: count(.paused), up: count(.up))
        }
    }

    public static func cell(_ state: PathDisplayState) -> MonitoringStripCell {
        switch state {
        case .up: .up
        case .degraded: .degraded
        case .down: .down
        case .unknown: .unknown
        case .paused: .paused
        }
    }

    /// The query that lists one source's paths: `source:<name>`.
    public static func sourceQuery(_ row: MonitoringMatrixRow) -> String {
        "source:\(MonitoringQueryText.quote(row.name))"
    }

    /// The query that lists one target's paths: `target:<name>`.
    public static func targetQuery(_ column: MonitoringMatrixColumn) -> String {
        "target:\(MonitoringQueryText.quote(column.name))"
    }
}

/// Quoting for values written into a query (`quoteQueryValue`).
public enum MonitoringQueryText {
    public static func quote(_ value: String) -> String {
        let plain = value.allSatisfy { $0.isLetter || $0.isNumber || "-_.@/".contains($0) }
        if plain && !value.isEmpty { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: Incidents to paths

public enum MonitoringIncidentLink {
    /// The path an incident is about, when the matrix has it: the source and
    /// check the server keyed it on, then the path key a derived pending id
    /// carries, then the "source to target" names of its subject or title.
    public static func pathKey(for incident: Incident, in items: [MonitoringPathItem]) -> String? {
        item(for: incident, in: items)?.key
    }

    /// The cell an incident is about: the exact check when the server keyed
    /// the incident on its source and monitor, else the pair's first cell in
    /// `pairOrder`.
    public static func item(for incident: Incident, in items: [MonitoringPathItem]) -> MonitoringPathItem? {
        guard incident.kind.hasPrefix("path.") else { return nil }
        if !incident.nodeID.isEmpty, !incident.monitorID.isEmpty,
           let match = items.first(where: { $0.path.source == incident.nodeID && $0.path.monitorID == incident.monitorID }) {
            return match
        }
        let prefix = "path.degraded/"
        let keyed = incident.key.hasPrefix(prefix) ? String(incident.key.dropFirst(prefix.count)) : ""
        if !keyed.isEmpty, decodePathKey(keyed) != nil, let match = MonitoringPaths.cell(key: keyed, monitorID: nil, in: items) {
            return match
        }
        for text in [incident.subject, incident.title] {
            guard let (source, target) = names(in: text) else { continue }
            let named = items.filter { $0.sourceName == source && $0.targetName == target }
            if let match = MonitoringPaths.pairOrder(named).first {
                return match
            }
        }
        return nil
    }

    /// "a → b", "a to b" or "Path a to b degraded" split into its two names.
    public static func names(in text: String) -> (String, String)? {
        var body = text
        if body.hasPrefix("Path ") { body = String(body.dropFirst(5)) }
        for suffix in [" degraded", " recovered", " down"] where body.hasSuffix(suffix) {
            body = String(body.dropLast(suffix.count))
        }
        for separator in [" → ", " to "] {
            let parts = body.components(separatedBy: separator)
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                return (parts[0].trimmingCharacters(in: .whitespaces), parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}

// MARK: Line chains (topologyModel.ts chainState)

public enum MonitoringChainState: String, Sendable, Hashable {
    case converged, pending, drifted, failed

    /// `chainState`.
    public init(_ row: MonitoringLineChain) {
        switch row.status {
        case "converged": self = .converged
        case "drifted": self = .drifted
        case "failed": self = .failed
        default: self = row.attempt?.status == "failed" ? .failed : .pending
        }
    }

    var rank: Int {
        switch self {
        case .failed: 0
        case .drifted: 1
        case .pending: 2
        case .converged: 3
        }
    }
}

public enum MonitoringHopRole: String, Sendable, Hashable {
    case entry, relay, exit
}

/// One node a chain passes, with the line on it and the route to the next hop.
public struct MonitoringChainHop: Sendable, Hashable, Identifiable {
    public var nodeID: String
    public var lineUUID: String
    public var role: MonitoringHopRole
    /// The route from this hop to the next; nil on the exit.
    public var route: MonitoringLineChain?

    public var id: String { "\(nodeID)/\(lineUUID)" }
}

/// Line routes joined end to end: entry, relays, exit.
public struct MonitoringChain: Sendable, Hashable, Identifiable {
    public var hops: [MonitoringChainHop]

    /// The entry line's uuid.
    public var id: String { hops.first?.lineUUID ?? "" }

    /// The worst route state along the chain.
    public var state: MonitoringChainState {
        hops.compactMap(\.route).map(MonitoringChainState.init).min { $0.rank < $1.rank } ?? .pending
    }

    /// Joins rows whose target line is another row's source line. Every row
    /// lands in exactly one chain, cycles included.
    public static func compose(_ rows: [MonitoringLineChain]) -> [MonitoringChain] {
        var bySource: [String: MonitoringLineChain] = [:]
        for row in rows { bySource[row.sourceLineUUID] = row }
        let targeted = Set(rows.compactMap { $0.current?.targetLineUUID }.filter { !$0.isEmpty })
        let entries = rows.filter { !targeted.contains($0.sourceLineUUID) }
            + rows.filter { targeted.contains($0.sourceLineUUID) }
        var visited: Set<String> = []
        var chains: [MonitoringChain] = []
        for entry in entries where !visited.contains(entry.sourceLineUUID) {
            var hops: [MonitoringChainHop] = []
            var row: MonitoringLineChain? = entry
            while let current = row, !visited.contains(current.sourceLineUUID) {
                visited.insert(current.sourceLineUUID)
                hops.append(MonitoringChainHop(nodeID: current.sourceNodeID, lineUUID: current.sourceLineUUID, role: .relay, route: current))
                guard let next = current.current, !next.targetLineUUID.isEmpty else { break }
                if let following = bySource[next.targetLineUUID], !visited.contains(following.sourceLineUUID) {
                    row = following
                } else {
                    hops.append(MonitoringChainHop(nodeID: next.targetNodeID, lineUUID: next.targetLineUUID, role: .exit, route: nil))
                    row = nil
                }
            }
            if !hops.isEmpty { hops[0].role = .entry }
            if hops.count > 1 { hops[hops.count - 1].role = .exit }
            chains.append(MonitoringChain(hops: hops))
        }
        return chains.sorted { $0.state.rank < $1.state.rank || ($0.state == $1.state && $0.id < $1.id) }
    }

    /// The path key between two consecutive hops.
    public static func pathKey(from hop: MonitoringChainHop, to next: MonitoringChainHop) -> String {
        encodePathKey(.pair(source: hop.nodeID, targetNode: next.nodeID))
    }
}

// MARK: Maintenance windows (server_incidents.go upsertMaintenanceWindow)

public enum MonitoringMaintenance {
    /// `maxMaintenanceNameLen`, in bytes as Go counts them.
    public static let nameLimit = 120
    /// `maxMaintenanceReasonLen`.
    public static let reasonLimit = 500
    /// `maxMaintenanceWindowSpan`.
    public static let maxSpan: TimeInterval = 30 * 86_400

    public enum Preset: String, Sendable, Hashable, CaseIterable {
        case thirtyMinutes, oneHour, fourHours, until

        public var title: String {
            switch self {
            case .thirtyMinutes: "30 min"
            case .oneHour: "1 h"
            case .fourHours: "4 h"
            case .until: "Until"
            }
        }

        /// The end for a preset that has a fixed length; nil for Until.
        public func end(from start: Date) -> Date? {
            switch self {
            case .thirtyMinutes: start.addingTimeInterval(30 * 60)
            case .oneHour: start.addingTimeInterval(3_600)
            case .fourHours: start.addingTimeInterval(4 * 3_600)
            case .until: nil
            }
        }
    }

    /// "Maintenance edge-tyo-3 14:05", clipped to the server's limit.
    public static func defaultName(subject: String, time: String) -> String {
        clip("Maintenance \(subject) \(time)".trimmingCharacters(in: .whitespaces), toBytes: nameLimit)
    }

    /// What the server would refuse, checked on device; nil when it may be sent.
    public static func problem(name: String, reason: String, hasSubject: Bool, startsAt: Date, endsAt: Date, now: Date) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Name the window." }
        if trimmed.utf8.count > nameLimit { return "The name is at most \(nameLimit) characters." }
        if reason.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > reasonLimit { return "The note is at most \(reasonLimit) characters." }
        if !hasSubject { return "Choose a node." }
        if endsAt <= now { return "The end must be in the future." }
        if endsAt <= startsAt { return "The end must be after the start." }
        if endsAt.timeIntervalSince(startsAt) > maxSpan { return "A window lasts at most 30 days." }
        return nil
    }

    /// The body of a new window starting now (`starts_at` explicit, so the
    /// confirmation and the stored window agree).
    public static func input(name: String, reason: String, nodeIDs: [String], groupIDs: [String] = [], startsAt: Date, endsAt: Date) -> MaintenanceWindowInput {
        let note = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return MaintenanceWindowInput(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            reason: note.isEmpty ? nil : note,
            nodeIDs: nodeIDs.isEmpty ? nil : nodeIDs,
            groupIDs: groupIDs.isEmpty ? nil : groupIDs,
            startsAt: startsAt,
            endsAt: endsAt
        )
    }

    /// Whether a window holds an incident: by id, else by name.
    public static func holds(_ window: MaintenanceWindow, _ incident: Incident) -> Bool {
        if !incident.maintenanceID.isEmpty { return incident.maintenanceID == window.id }
        return !incident.maintenance.isEmpty && incident.maintenance == window.name
    }

    private static func clip(_ text: String, toBytes limit: Int) -> String {
        var result = ""
        for character in text {
            if (result + String(character)).utf8.count > limit { break }
            result.append(character)
        }
        return result
    }
}
