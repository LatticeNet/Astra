import Charts
import SwiftUI

/// One node metric over a range, drawn by the chart conventions of 4.6: a
/// 2 pt line in `accent.text`, gaps where buckets are missing, a long press
/// then drag to scrub, an Audio Graph descriptor and a text summary above.
struct FleetMetricChart: View {
    let metric: FleetMetric
    let series: FleetMetricSeries?
    let step: TimeInterval
    let range: FleetMetricsRange

    @ScaledMetric(relativeTo: .body) private var chartHeight = ChartStyle.height
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @State private var selected: FleetMetricPoint?
    @State private var pulse: HapticPulse?

    private var points: [FleetMetricPoint] { series?.points ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if points.isEmpty {
                Text("No samples in this range")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
            } else {
                chart
                    .frame(height: max(ChartStyle.minimumHeight, chartHeight))
                    .accessibilityChartDescriptor(FleetChartDescriptor(metric: metric, points: points, unit: unit))
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private var unit: String { metric.isRate ? "bytes per second" : "percent" }

    private func format(_ value: Double) -> String {
        metric.isRate ? ByteFormatter.speed(value) : String(format: "%.0f%%", value)
    }

    private var summary: String {
        guard let last = points.last else { return "\(metric.title): no samples, \(rangeWords)" }
        let average = points.map(\.value).reduce(0, +) / Double(points.count)
        let peak = points.map(\.value).max() ?? last.value
        return "\(metric.title) \(format(last.value)) now, average \(format(average)), peak \(format(peak)), \(rangeWords)"
    }

    private var rangeWords: String {
        switch range {
        case .oneHour: "last hour"
        case .oneDay: "last 24 hours"
        case .sevenDays: "last 7 days"
        case .thirtyDays: "last 30 days"
        }
    }

    private var chart: some View {
        let segments = ChartStyle.segments(points, interval: step) { $0.date }
        return Chart {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                ForEach(segment) { point in
                    LineMark(x: .value("Time", point.date), y: .value(metric.title, point.value), series: .value("Segment", index))
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
                            Text(TimeDisplay.clock(selected.date, mode: mode, locale: locale)).textRole(.chartAxis).foregroundStyle(.secondary)
                        }
                        .padding(Spacing.xs)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
                    }
            }
        }
        .chartYScale(domain: metric.isRate ? .automatic(includesZero: true) : .automatic(includesZero: true))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: typeSize.isAccessibilitySize ? 2 : 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(range == .oneHour || range == .oneDay ? TimeDisplay.clock(date, mode: mode, locale: locale) : date.formatted(.dateTime.month(.abbreviated).day()))
                            .font(TextRole.chartAxis.font)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: typeSize.isAccessibilitySize ? 2 : 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(metric.isRate ? ByteFormatter.speed(number) : "\(Int(number))%").font(TextRole.chartAxis.font)
                    }
                }
            }
        }
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
    }
}

/// The Audio Graph for a node metric.
struct FleetChartDescriptor: AXChartDescriptorRepresentable {
    let metric: FleetMetric
    let points: [FleetMetricPoint]
    let unit: String

    func makeChartDescriptor() -> AXChartDescriptor {
        let first = points.first?.date ?? Date()
        let last = points.last?.date ?? Date()
        let values = points.map(\.value)
        let x = AXNumericDataAxisDescriptor(
            title: "Time",
            range: 0...max(1, last.timeIntervalSince(first)),
            gridlinePositions: []
        ) { seconds in
            first.addingTimeInterval(seconds).formatted(date: .omitted, time: .shortened)
        }
        let y = AXNumericDataAxisDescriptor(
            title: metric.title,
            range: (values.min() ?? 0)...max((values.max() ?? 1), (values.min() ?? 0) + 1),
            gridlinePositions: []
        ) { value in "\(Int(value)) \(unit)" }
        let series = AXDataSeriesDescriptor(name: metric.title, isContinuous: true, dataPoints: points.map {
            AXDataPoint(x: $0.date.timeIntervalSince(first), y: $0.value)
        })
        return AXChartDescriptor(title: "\(metric.title) history", summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}

/// M2-04 Node history: the status strip, then one full-width chart per
/// metric, over 1 h, 24 h, 7 d or 30 d.
struct NodeHistoryScreen: View {
    let nodeID: String

    static let rangeKey = "fleet.history.range"

    @Environment(SessionStore.self) private var session
    @Environment(FleetStore.self) private var store
    @Environment(\.astraDifferentiateWithoutColor) private var differentiate
    @SceneStorage(NodeHistoryScreen.rangeKey) private var rangeRaw = FleetMetricsRange.oneDay.rawValue
    @State private var metrics: ResourceState<FleetMetricsQuery> = .idle
    @State private var status: ResourceState<FleetStatusHistoryResponse> = .idle

    private var range: FleetMetricsRange { FleetMetricsRange(rawValue: rangeRaw) ?? .oneDay }

    var body: some View {
        FleetListState(state: metrics, noun: "history", retry: { Task { await load() } }) { query in
            List {
                Section {
                    statusStrip
                } header: {
                    Text("Status")
                }
                FleetRefreshError(state: metrics, noun: "history") { Task { await load() } }
                ForEach(FleetMetric.allCases, id: \.self) { metric in
                    Section(metric.title) {
                        FleetMetricChart(metric: metric, series: query.series(named: metric.rawValue),
                                         step: TimeInterval(max(query.stepSeconds, 1)), range: range)
                    }
                }
                Section {
                } footer: {
                    FleetFooter(state: metrics)
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle(store.record(id: nodeID)?.node.displayName ?? "History")
        .navigationSubtitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaBar(edge: .top) {
            Picker("Range", selection: $rangeRaw) {
                ForEach(FleetMetricsRange.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.s)
        }
        .refreshable { await load() }
        .task(id: rangeRaw) { await load() }
    }

    @ViewBuilder
    private var statusStrip: some View {
        switch status {
        case .loaded(let response, _), .loading(let response?, _), .failed(_, let response?, _):
            if let history = response.nodes[nodeID], let since = response.since, let until = response.until {
                let cells = FleetStatusStrip.cells(history, since: since, until: until, count: 24).map { cell -> StateStrip.Cell in
                    switch cell {
                    case .online: .up
                    case .offline: .down
                    case .unknown: .unknown
                    }
                }
                VStack(alignment: .leading, spacing: Spacing.s) {
                    StateStrip(cells: cells)
                    if differentiate { StateStripLegend() }
                    Text(statusSummary(history))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, Spacing.xs)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(statusSummary(history))
            }
        case .denied(let scope):
            ScopeDeniedRow(scope: scope)
        default:
            LoadingRows(label: "Loading status history", count: 1)
        }
    }

    private func statusSummary(_ history: FleetNodeStatusHistory) -> String {
        let share = history.onlineShare.map { String(format: "%.1f%% online", $0 * 100) } ?? "Not observed"
        let episodes = history.episodes == 1 ? "1 outage" : "\(history.episodes) outages"
        let longest = history.longestOfflineSeconds > 0 ? ", longest \(RelativeDateFormatter.shortDuration(TimeInterval(history.longestOfflineSeconds)))" : ""
        return "\(share), \(episodes)\(longest)"
    }

    private func load() async {
        guard let client = session.client else { return }
        let id = nodeID
        let range = range
        metrics = metrics.reloading
        status = status.reloading
        do {
            metrics = .loaded(try await client.fleetNodeHistory(nodeID: id, range: range), at: Date())
        } catch {
            metrics = metrics.failing(LatticeAPIError(error), surface: "History", missingScope: "node:read")
        }
        do {
            status = .loaded(try await client.fleetStatusHistory(nodeID: id, days: range.statusDays), at: Date())
        } catch {
            status = status.failing(LatticeAPIError(error), surface: "Status history", missingScope: "node:read")
        }
    }
}
