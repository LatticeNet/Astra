import Charts
import SwiftUI

/// M8-11 System: the control plane's own health from `/api/system/health`
/// and `/api/system/series`: host, process, data files, store writes, HTTP
/// routes with latency, plugin performance, the metrics store and the
/// probe. Read only. Gate `*` held by name on a token with no node
/// allowlist (`requireFullAdmin`).
struct SystemScreen: View {
    static let rangeKey = "platform.system.range"

    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @Environment(NetworkMonitor.self) private var network

    @SceneStorage(SystemScreen.rangeKey) private var range = "24h"
    @State private var model = PlatformSystemModel()

    private var missing: String? {
        guard let scopes = session.tokenScopes else { return nil }
        if !scopes.allows("*") { return "* (a full administrator)" }
        return scopes.isConfined ? "* on a token with no node allowlist" : nil
    }

    var body: some View {
        content
            .navigationTitle("System")
            .navigationSubtitle(missing == nil ? "Last \(range)" : "")
            .refreshable { await reload() }
            // The range is part of the key, so choosing one reloads at once.
            .polling(.standard, version: changes.version(.plugins) * 16 + (PlatformSystem.ranges.firstIndex(of: range) ?? 0)) { await reload() }
            .toolbar {
                if missing == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Range", selection: $range) {
                            ForEach(PlatformSystem.ranges, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Range: \(range)", systemImage: "calendar.badge.clock")
                    }
                    .accessibilityValue(range)
                }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Open on web", systemImage: "safari") { router.openOnWeb(.platformSystem) }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
    }

    @discardableResult
    private func reload() async -> Bool {
        if let missing {
            model.deny(missing)
            return true
        }
        guard let client = session.client else { return false }
        return await model.load(client: client, range: range)
    }

    @ViewBuilder
    private var content: some View {
        PlatformListState(state: model.health, noun: "system health", retry: { Task { await reload() } }) { health in
            list(health)
        }
    }

    @ViewBuilder
    private func list(_ health: PlatformSystemHealth) -> some View {
        List {
            PlatformRefreshError(state: model.health, noun: "system health") { Task { await reload() } }
            overviewSection(health)
            hostSection(health.host)
            chartsSection
            processSection(health.process)
            filesSection(health.files)
            eventSection("HTTP routes", rows: health.http, footer: "Route groups by calls over the range, with latency at the 95th percentile.")
            eventSection("Store writes", rows: health.store, footer: "Writes to the state store by caller.")
            pluginSection(health)
            metricsSection(health.metricsStore)
            Section {
            } footer: {
                FreshnessFooter(state: model.health, interval: 60)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Sections

    @ViewBuilder
    private func overviewSection(_ health: PlatformSystemHealth) -> some View {
        // Stale, failed or offline data must not keep claiming the plane is up.
        let doubt = PlatformConfidence.doubt(model.health, offline: !network.isSatisfied, now: Date(), mode: mode, locale: locale)
        Section {
            if let process = health.process {
                let uptime = UptimeFormatter.string(seconds: UInt64(max(process.uptimeSeconds, 0)))
                let style = doubt == nil ? StatusStyle(word: "up \(uptime)", symbol: "checkmark.circle.fill", tone: .ok) : PlatformConfidence.style
                StatusRow(style: style,
                          title: "Control plane \(process.version)", detail: process.commit.isEmpty ? nil : "commit \(process.commit)",
                          reason: PlatformConfidence.reason(doubt),
                          accessibilityPhrase: "Control plane \(process.version), \(style.word)")
            }
            if let probe = health.probe {
                if probe.available {
                    StatusRow(style: doubt == nil ? StatusStyle(word: "available", symbol: "dot.radiowaves.left.and.right", tone: .ok) : PlatformConfidence.style,
                              title: "Probe \(probe.probeVersion)",
                              detail: "\(probe.engine) \(probe.coreVersion) · \(probe.targets) targets · \(probe.inflight) of \(probe.maxInflight) in flight")
                } else {
                    StatusRow(style: StatusStyle(word: "unavailable", symbol: "exclamationmark.triangle.fill", tone: .warn),
                              title: "Probe", reason: probe.reason.isEmpty ? "The probe did not answer." : probe.reason)
                }
            }
            if let store = health.metricsStore, !store.lastWriteError.isEmpty {
                StatusRow(style: StatusStyle(word: "write failing", symbol: "xmark.octagon.fill", tone: .fail),
                          title: "Metrics store", reason: store.lastWriteError)
            }
        } header: {
            Text("Overview")
        }
    }

    @ViewBuilder
    private func hostSection(_ host: PlatformSystemHost?) -> some View {
        if let host {
            Section("Host") {
                if let load1 = host.load1 {
                    DetailRow(label: "Load", value: [load1, host.load5, host.load15].compactMap { $0 }.map { String(format: "%.2f", $0) }.joined(separator: " · "),
                              secondary: "1, 5 and 15 minutes", copyable: false)
                }
                if let total = host.memTotalBytes, let available = host.memAvailableBytes {
                    ValueBarRow(label: "Memory", value: "\(ByteFormatter.bytes(total - min(available, total))) of \(ByteFormatter.bytes(total))", fraction: host.memoryFraction)
                }
                if let total = host.diskTotalBytes, let used = host.diskUsedBytes {
                    ValueBarRow(label: "Disk", value: "\(ByteFormatter.bytes(used)) of \(ByteFormatter.bytes(total))", fraction: host.diskFraction)
                }
                if !host.dataDir.isEmpty {
                    DetailRow(label: "Data directory", value: host.dataDir, monospaced: true)
                }
            }
        }
    }

    @ViewBuilder
    private var chartsSection: some View {
        Section {
            switch model.series {
            case .loaded(let query, _), .loading(let query?, _), .failed(_, let query?, _):
                PlatformSystemChart(clockAxis: ["1h", "6h", "24h"].contains(range), title: "Memory used", unit: "bytes", segments: PlatformSystem.segments(query.series(named: "host.mem_used"), stepSeconds: query.stepSeconds))
                PlatformSystemChart(clockAxis: ["1h", "6h", "24h"].contains(range), title: "Process memory", unit: "bytes", segments: PlatformSystem.segments(query.series(named: "proc.rss"), stepSeconds: query.stepSeconds))
                PlatformSystemChart(clockAxis: ["1h", "6h", "24h"].contains(range), title: "Process CPU", unit: "percent", segments: PlatformSystem.segments(query.series(named: "proc.cpu"), stepSeconds: query.stepSeconds))
                PlatformSystemChart(clockAxis: ["1h", "6h", "24h"].contains(range), title: "Load", unit: "load", segments: PlatformSystem.segments(query.series(named: "host.load1"), stepSeconds: query.stepSeconds))
            default:
                PlatformSectionState(state: model.series, noun: "charts") { Task { await reload() } }
            }
        } header: {
            Text("Over the last \(range)")
        } footer: {
            Text("Gaps are times nothing was recorded, such as a restart; lines never bridge them.")
        }
    }

    @ViewBuilder
    private func processSection(_ process: PlatformSystemProcess?) -> some View {
        if let process {
            Section("Process") {
                DetailRow(label: "Version", value: process.version, secondary: process.commit.isEmpty ? nil : "commit \(process.commit)")
                DetailRow(label: "Go", value: process.goVersion, copyable: false)
                DetailRow(label: "CPU", value: process.cpuPercent.map { String(format: "%.1f%% of %d cores", $0, process.cpus) } ?? "Not reported", copyable: false)
                DetailRow(label: "Resident memory", value: PlatformFormat.bytes(process.rssBytes), copyable: false)
                DetailRow(label: "Heap", value: ByteFormatter.bytes(process.heapBytes), secondary: "\(ByteFormatter.bytes(process.goTotalBytes)) held by Go", copyable: false)
                DetailRow(label: "Goroutines", value: process.goroutines.formatted(), copyable: false)
                DetailRow(label: "Open files", value: process.openFDs.map { $0.formatted() } ?? "Not reported", copyable: false)
                DetailRow(label: "Longest GC pause", value: PlatformFormat.latency(process.gcPauseMaxSeconds), copyable: false)
                if let started = process.startedAt {
                    TimeRow(label: "Started", date: started)
                }
            }
        }
    }

    @ViewBuilder
    private func filesSection(_ files: [PlatformSystemFile]) -> some View {
        if !files.isEmpty {
            Section("Data files") {
                ForEach(files) { file in
                    DetailRow(label: file.label.sentenceCased, value: PlatformFormat.bytes(file.sizeBytes), secondary: file.path, copyable: false)
                }
            }
        }
    }

    @ViewBuilder
    private func eventSection(_ title: String, rows: [PlatformSystemEventRow], footer: String) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    PlatformEventRowView(row: row, title: row.name)
                }
            } header: {
                Text(title)
            } footer: {
                Text(footer)
            }
        }
    }

    @ViewBuilder
    private func pluginSection(_ health: PlatformSystemHealth) -> some View {
        if !health.plugins.isEmpty || !health.pluginProcesses.isEmpty {
            Section {
                ForEach(health.plugins) { row in
                    PlatformEventRowView(row: row, title: "\(row.plugin) \(row.name)")
                }
                ForEach(health.pluginProcesses) { process in
                    DetailRow(label: "\(process.plugin) processes",
                              value: "\(process.processes.formatted()) runs, \(String(format: "%.0f", process.cpuSeconds)) s CPU",
                              secondary: "Peak memory \(ByteFormatter.bytes(UInt64(max(process.peakRSSBytes, 0))))", copyable: false)
                }
            } header: {
                Text("Plugin performance")
            } footer: {
                Text("Plugin methods by calls; process use is counted as each process exits.")
            }
        }
    }

    @ViewBuilder
    private func metricsSection(_ store: PlatformMetricsStore?) -> some View {
        if let store {
            Section("Metrics store") {
                ValueBarRow(label: "Series", value: "\(store.series.formatted()) of \(store.maxSeries.formatted())",
                            fraction: store.maxSeries > 0 ? Double(store.series) / Double(store.maxSeries) : nil)
                DetailRow(label: "Size", value: PlatformFormat.bytes(store.sizeBytes), secondary: store.path, copyable: false)
                DetailRow(label: "Sample every", value: "\(store.sampleSeconds) s", copyable: false)
                if let last = store.lastWriteAt {
                    TimeRow(label: "Last write", date: last)
                }
                if store.refusedSamples > 0 || store.lateSamples > 0 {
                    DetailRow(label: "Samples refused", value: "\(store.refusedSamples) refused, \(store.lateSamples) late", copyable: false)
                }
            }
        }
    }
}

/// One route group, store caller or plugin method: calls, failures and latency.
struct PlatformEventRowView: View {
    let row: PlatformSystemEventRow
    let title: String

    var body: some View {
        let rate = PlatformSystem.errorRate(row)
        let failing = rate >= 0.01
        let style = failing
            ? StatusStyle(word: "\(PlatformFormat.percent(rate)) failed", symbol: "exclamationmark.triangle.fill", tone: rate >= 0.25 ? .fail : .warn)
            : StatusStyle(word: row.errors == 0 ? "no failures" : "\(row.errors) failed", symbol: "checkmark.circle.fill", tone: .ok)
        let detail = "\(PlatformFormat.count(row.calls)) calls · p50 \(PlatformFormat.latency(row.p50Seconds)) · p95 \(PlatformFormat.latency(row.p95Seconds))"
        StatusRow(style: style, title: title, detail: detail, titleIsIdentifier: true,
                  accessibilityPhrase: "\(title), \(style.word), \(row.calls) calls, 95th percentile \(PlatformFormat.latency(row.p95Seconds))")
    }
}

/// One control-plane series as a line that breaks at gaps, with a text
/// summary above it and an Audio Graph descriptor (section 4.6).
struct PlatformSystemChart: View {
    /// Short ranges label the time axis with clock times, longer ones with dates.
    let clockAxis: Bool
    let title: String
    let unit: String
    let segments: [[PlatformSystem.Point]]

    @ScaledMetric(relativeTo: .body) private var chartHeight = ChartStyle.height
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @State private var selected: PlatformSystem.Point?
    @State private var pulse: HapticPulse?

    var body: some View {
        let points = segments.flatMap { $0 }
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(summary(points))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if points.isEmpty {
                Text("No data in this range.")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: Spacing.minimumTarget)
            } else {
                Chart {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        ForEach(segment, id: \.date) { point in
                            LineMark(x: .value("Time", point.date), y: .value(title, point.value), series: .value("Segment", index))
                                .foregroundStyle(Color.accentText)
                                .lineStyle(StrokeStyle(lineWidth: ChartStyle.lineWidth))
                                .accessibilityHidden(points.count > ChartStyle.accessibleMarkLimit)
                        }
                    }
                    if let selected {
                        RuleMark(x: .value("Selected", selected.date))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .annotation(position: .top, alignment: .center, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                VStack(spacing: Spacing.xxs) {
                                    Text(format(selected.value)).font(.footnote.monospacedDigit().weight(.semibold))
                                    Text(calloutTime(selected.date)).textRole(.chartAxis).foregroundStyle(.secondary)
                                }
                                .padding(Spacing.xs)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
                            }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: typeSize.isAccessibilitySize ? 2 : 3)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) { Text(format(number)).font(TextRole.chartAxis.font) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: typeSize.isAccessibilitySize ? 2 : 3)) { value in
                        AxisGridLine()
                        AxisValueLabel(collisionResolution: .greedy) {
                            if let date = value.as(Date.self) {
                                Text(clockAxis ? TimeDisplay.clock(date, mode: mode, locale: locale) : date.formatted(.dateTime.month(.abbreviated).day()))
                                    .font(TextRole.chartAxis.font)
                            }
                        }
                    }
                }
                // The same long press then drag as node history and path charts (section 4.6).
                .chartGesture { proxy in
                    LongPressGesture(minimumDuration: 0.3)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { value in
                            guard case .second(true, let drag?) = value, let date: Date = proxy.value(atX: drag.location.x) else { return }
                            let nearest = points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                            if nearest != selected {
                                selected = nearest
                                pulse = HapticPulse(event: .selection)
                            }
                        }
                        .onEnded { _ in selected = nil }
                }
                .haptics(pulse)
                .environment(\.timeZone, mode.timeZone)
                .frame(height: max(chartHeight, ChartStyle.minimumHeight))
                .accessibilityChartDescriptor(PlatformChartDescriptor(title: title, unit: unit, points: points))
            }
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .contain)
    }

    private func summary(_ points: [PlatformSystem.Point]) -> String {
        guard let last = points.last else { return title }
        let peak = points.map(\.value).max() ?? last.value
        return "\(title): \(format(last.value)) now, peak \(format(peak))"
    }

    private func format(_ value: Double) -> String {
        Self.format(value, unit: unit)
    }

    /// Long ranges span days, so the callout names the day as well as the clock.
    private func calloutTime(_ date: Date) -> String {
        let clock = TimeDisplay.clock(date, mode: mode, locale: locale)
        guard !clockAxis else { return clock }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = mode.timeZone
        return "\(date.formatted(style)) \(clock)"
    }

    nonisolated static func format(_ value: Double, unit: String) -> String {
        switch unit {
        case "bytes": ByteFormatter.bytes(UInt64(max(value, 0)))
        case "percent": String(format: "%.1f%%", value)
        default: String(format: "%.2f", value)
        }
    }
}

struct PlatformChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let unit: String
    let points: [PlatformSystem.Point]

    func makeChartDescriptor() -> AXChartDescriptor {
        let first = points.first?.date ?? Date()
        let last = points.last?.date ?? Date()
        let values = points.map(\.value)
        let low = values.min() ?? 0
        let high = max(values.max() ?? 1, low + 1)
        let x = AXNumericDataAxisDescriptor(title: "Time", range: 0...max(1, last.timeIntervalSince(first)), gridlinePositions: []) { seconds in
            first.addingTimeInterval(seconds).formatted(date: .abbreviated, time: .shortened)
        }
        let y = AXNumericDataAxisDescriptor(title: title, range: low...high, gridlinePositions: []) { [unit] in PlatformSystemChart.format($0, unit: unit) }
        let series = AXDataSeriesDescriptor(name: title, isContinuous: true, dataPoints: points.map {
            AXDataPoint(x: $0.date.timeIntervalSince(first), y: $0.value)
        })
        return AXChartDescriptor(title: title, summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}

/// System health and series, held by the screen only.
@MainActor @Observable
final class PlatformSystemModel {
    private(set) var health: ResourceState<PlatformSystemHealth> = .idle
    private(set) var series: ResourceState<PlatformMetricsQuery> = .idle

    func deny(_ scope: String) {
        health = .denied(scope: scope)
        series = .denied(scope: scope)
    }

    func load(client: LatticeClient, range: String) async -> Bool {
        health = health.reloading
        series = series.reloading
        async let healthRead = client.platformSystemHealth(range: range)
        async let seriesRead = client.platformSystemSeries(series: PlatformSystem.chartSeries, range: range)
        var ok = true
        do {
            health = .loaded(try await healthRead, at: Date())
        } catch {
            health = health.failing(LatticeAPIError(error), surface: "System health", missingScope: "*")
            ok = false
        }
        do {
            series = .loaded(try await seriesRead, at: Date())
        } catch {
            series = series.failing(LatticeAPIError(error), surface: "System charts", missingScope: "*")
        }
        return ok
    }
}
