import Accessibility
import Charts
import SwiftUI

/// The latency and loss charts of PathDetail (M3-04) and CheckDetail, drawn
/// to section 4.6: a p50 line and p95 band that break at every gap, the
/// baseline, trigger and degraded rules each labelled at its end, method
/// changes, maintenance bands, the previous window, and loss bars beneath
/// on the same time axis. Scrubbing starts with a long press.
struct PathCharts: View {
    let series: MonitoringPathSeries
    /// Tints loss bars and the band only while the path reads degraded or down.
    var problem = false
    var degradedSince: Date?
    var maintenance: [MaintenanceWindow] = []
    var compare = false

    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 180
    @State private var selected: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(summary)
                .textRole(.rowDetail)
                .accessibilityLabel(summary)
            ZStack(alignment: .topLeading) {
                latencyChart
                if let selected, series.buckets.indices.contains(selected) {
                    callout(series.buckets[selected])
                }
            }
            Text("Loss").textRole(.chartAxis).foregroundStyle(.secondary).accessibilityHidden(true)
            lossChart
        }
        .environment(\.timeZone, mode.timeZone)
        .sensoryFeedback(.selection, trigger: selected)
    }

    private var accessible: Bool { typeSize.isAccessibilitySize }
    private var manyMarks: Bool { series.buckets.count > ChartStyle.accessibleMarkLimit }
    private var height: CGFloat { max(chartHeight, ChartStyle.minimumHeight) }

    /// "p50 41 ms, loss 0.2%, last 1h".
    private var summary: String {
        let measured = series.buckets.filter { $0.n > 0 }
        let p50s = measured.compactMap(\.p50Ms).sorted()
        let median = p50s.isEmpty ? nil : p50s[p50s.count / 2]
        let runs = measured.reduce(0) { $0 + $1.n }
        let failed = measured.reduce(0) { $0 + $1.fail }
        let sent = measured.reduce(0) { $0 + $1.sent }
        let lost = measured.reduce(0) { $0 + $1.lost }
        var parts: [String] = []
        if let median { parts.append("p50 \(MonitoringFormat.milliseconds(median))") }
        if sent > 0 {
            parts.append("loss \(MonitoringFormat.percent(Double(lost) / Double(sent)))")
        } else if runs > 0 {
            parts.append("loss \(MonitoringFormat.percent(Double(failed) / Double(runs)))")
        }
        parts.append("last \(series.window)")
        let gaps = series.buckets.filter { $0.n == 0 && $0.expected > 0 }.count
        if gaps > 0 { parts.append(gaps == 1 ? "1 step without data" : "\(gaps) steps without data") }
        return parts.joined(separator: ", ")
    }

    // MARK: Latency

    private var latencyChart: some View {
        let p50 = MonitoringSeriesSegments.p50(series)
        let band = bandSegments
        let previous = compare ? MonitoringSeriesSegments.previous(series) : []
        return Chart {
            ForEach(maintenanceSpans, id: \.start) { span in
                RectangleMark(xStart: .value("Start", span.start), xEnd: .value("End", span.end))
                    .foregroundStyle(Color.chartBand)
                    .annotation(position: .top, alignment: .leading) { label("maintenance") }
            }
            ForEach(Array(band.enumerated()), id: \.offset) { index, segment in
                ForEach(segment, id: \.t) { point in
                    AreaMark(x: .value("Time", point.t), yStart: .value("p50", point.low), yEnd: .value("p95", point.high), series: .value("Band", "band\(index)"))
                        .foregroundStyle(Color.accentText.opacity(ChartStyle.bandOpacity))
                        .interpolationMethod(.linear)
                        .accessibilityHidden(true)
                }
            }
            ForEach(Array(previous.enumerated()), id: \.offset) { index, segment in
                ForEach(segment, id: \.t) { point in
                    LineMark(x: .value("Time", point.t), y: .value("Previous p50", point.value), series: .value("Series", "previous\(index)"))
                        .foregroundStyle(Color.chartCompare)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: ChartStyle.compareDash))
                        .accessibilityHidden(true)
                }
            }
            if let first = previous.first?.first {
                PointMark(x: .value("Time", first.t), y: .value("Previous p50", first.value))
                    .symbolSize(0)
                    .annotation(position: .bottom, alignment: .leading) { label("previous") }
                    .accessibilityHidden(true)
            }
            ForEach(Array(p50.enumerated()), id: \.offset) { index, segment in
                ForEach(segment, id: \.t) { point in
                    LineMark(x: .value("Time", point.t), y: .value("p50", point.value), series: .value("Series", "p50-\(index)"))
                        .foregroundStyle(Color.accentText)
                        .lineStyle(StrokeStyle(lineWidth: ChartStyle.lineWidth))
                        .interpolationMethod(.linear)
                        .accessibilityHidden(manyMarks)
                    if segment.count == 1 {
                        // A lone sample between gaps still shows as a point.
                        PointMark(x: .value("Time", point.t), y: .value("p50", point.value))
                            .foregroundStyle(Color.accentText)
                            .symbolSize(16)
                            .accessibilityHidden(manyMarks)
                    }
                }
            }
            if let baseline = series.baseline?.p50Ms {
                RuleMark(y: .value("Baseline", baseline))
                    .foregroundStyle(Color.statusQuiet)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: ChartStyle.baselineDash))
                    .annotation(position: .top, alignment: .trailing) { label("baseline") }
                    .accessibilityHidden(true)
            }
            if let trigger = series.baseline?.triggerP50Ms {
                RuleMark(y: .value("Trigger", trigger))
                    .foregroundStyle(Color.statusWarnFill)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: ChartStyle.triggerDash))
                    .annotation(position: .top, alignment: .trailing) { label("trigger") }
                    .accessibilityHidden(true)
            }
            if let degradedSince, inRange(degradedSince) {
                RuleMark(x: .value("Degraded", degradedSince))
                    .foregroundStyle(Color.statusFailFill)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: nearEnd(degradedSince) ? .trailing : .leading) {
                        label("degraded \(TimeDisplay.clock(degradedSince, mode: mode, locale: locale))")
                    }
                    .accessibilityHidden(true)
            }
            ForEach(methodMarkers, id: \.t) { change in
                PointMark(x: .value("Method change", change.t), y: .value("p50", yTop))
                    .symbol(.diamond)
                    .symbolSize(30)
                    .foregroundStyle(Color.statusQuiet)
                    .annotation(position: .bottom, alignment: .leading) { label(change.method) }
                    .accessibilityHidden(true)
            }
            if let selected, series.buckets.indices.contains(selected) {
                RuleMark(x: .value("Selected", series.buckets[selected].t))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: domain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: accessible ? 2 : 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let ms = value.as(Double.self) { Text("\(Int(ms))ms").font(.caption2) }
                }
            }
        }
        .chartXAxis { xAxis }
        .frame(height: height)
        .chartOverlay { proxy in scrubber(proxy) }
        .accessibilityChartDescriptor(MonitoringChartDescriptor(series: series, title: "Latency, p50 in milliseconds"))
    }

    // MARK: Loss

    private var lossChart: some View {
        let points = MonitoringSeriesSegments.loss(series)
        let step = TimeInterval(max(series.stepSeconds, 60))
        return Chart {
            ForEach(points, id: \.t) { point in
                BarMark(xStart: .value("Start", point.t), xEnd: .value("End", point.t.addingTimeInterval(step * 0.8)), y: .value("Loss", point.value * 100))
                    .foregroundStyle(problem && point.value > 0 ? Color.statusWarnFill : Color.statusQuiet)
                    .accessibilityHidden(manyMarks)
            }
            if let trigger = series.baseline?.triggerLoss {
                RuleMark(y: .value("Trigger", trigger * 100))
                    .foregroundStyle(Color.statusWarnFill)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: ChartStyle.triggerDash))
                    .annotation(position: .top, alignment: .trailing) { label("trigger") }
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: domain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Double.self) { Text("\(Int(percent))%").font(.caption2) }
                }
            }
        }
        .chartXAxis { xAxis }
        .frame(height: max(height * 0.4, 72))
        .accessibilityChartDescriptor(MonitoringChartDescriptor(series: series, title: "Loss in percent", loss: true))
    }

    private var xAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: accessible ? 2 : 4)) { _ in
            AxisGridLine()
            AxisValueLabel(format: axisFormat)
        }
    }

    private var axisFormat: Date.FormatStyle {
        let span = (series.buckets.last?.t ?? Date()).timeIntervalSince(series.buckets.first?.t ?? Date())
        var style = span > 2 * 86_400 ? Date.FormatStyle().month(.abbreviated).day() : Date.FormatStyle().hour().minute()
        style.timeZone = mode.timeZone
        style.locale = locale
        return style
    }

    // MARK: Pieces

    private struct BandPoint {
        let t: Date
        let low: Double
        let high: Double
    }

    /// The p50 to p95 band, broken at the same gaps as the line.
    private var bandSegments: [[BandPoint]] {
        let p95ByTime = Dictionary(series.buckets.compactMap { b in b.p95Ms.map { (b.t, $0) } }, uniquingKeysWith: { a, _ in a })
        return MonitoringSeriesSegments.p50(series).map { segment in
            segment.compactMap { point in p95ByTime[point.t].map { BandPoint(t: point.t, low: point.value, high: max($0, point.value)) } }
        }.filter { !$0.isEmpty }
    }

    private var domain: ClosedRange<Date> {
        let start = series.from ?? series.buckets.first?.t ?? Date().addingTimeInterval(-3_600)
        let end = max(series.to ?? series.buckets.last?.t ?? Date(), start.addingTimeInterval(60))
        return start...end
    }

    private func inRange(_ date: Date) -> Bool { domain.contains(date) }

    /// In the last third of the chart, where a leading label would be clipped.
    private func nearEnd(_ date: Date) -> Bool {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        return date.timeIntervalSince(domain.lowerBound) > span * 2 / 3
    }

    /// Maintenance windows clipped to the chart's span.
    private var maintenanceSpans: [(start: Date, end: Date)] {
        maintenance.compactMap { window in
            guard let start = window.startsAt, let end = window.endsAt else { return nil }
            let lower = max(start, domain.lowerBound)
            let upper = min(end, domain.upperBound)
            return lower < upper ? (lower, upper) : nil
        }
    }

    /// Method changes inside the window, after the first (which only names the starting method).
    private var methodMarkers: [MonitoringMethodChange] {
        Array(series.methodChanges.dropFirst()).filter { inRange($0.t) }
    }

    private var yTop: Double {
        let values = series.buckets.compactMap(\.p95Ms) + [series.baseline?.triggerP50Ms].compactMap { $0 }
        return values.max() ?? 1
    }

    private func label(_ text: String) -> some View {
        Text(text).textRole(.chartAxis).foregroundStyle(.secondary)
    }

    private func callout(_ bucket: MonitoringPathBucket) -> some View {
        let time = TimeDisplay.clock(bucket.t, mode: mode, locale: locale)
        let text: String
        if bucket.n == 0 {
            text = "\(time): no data"
        } else {
            let parts = [bucket.p50Ms.map { "p50 \(MonitoringFormat.milliseconds($0))" }, bucket.loss.map { "loss \(MonitoringFormat.percent($0))" }].compactMap { $0 }
            text = "\(time): " + (parts.isEmpty ? "every run failed" : parts.joined(separator: ", "))
        }
        return Text(text)
            .textRole(.stamp)
            .foregroundStyle(.primary)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(uiColor: .separator)))
            .padding(.leading, 36)
            .accessibilityHidden(true)
    }

    /// Long press, then drag: vertical scrolling and the back swipe keep working.
    private func scrubber(_ proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(
                    LongPressGesture(minimumDuration: 0.3)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { value in
                            guard case .second(true, let drag) = value else { return }
                            let origin = proxy.plotFrame.map { geometry[$0].origin.x } ?? 0
                            let x = (drag?.location.x ?? 0) - origin
                            if let date: Date = proxy.value(atX: x) { selected = nearest(date) }
                        }
                        .onEnded { _ in selected = nil }
                )
        }
    }

    private func nearest(_ date: Date) -> Int? {
        guard !series.buckets.isEmpty else { return nil }
        return series.buckets.indices.min { abs(series.buckets[$0].t.timeIntervalSince(date)) < abs(series.buckets[$1].t.timeIntervalSince(date)) }
    }
}

/// Audio Graphs for a path chart: p50 (or loss) over time, gaps left out.
struct MonitoringChartDescriptor: AXChartDescriptorRepresentable {
    let series: MonitoringPathSeries
    let title: String
    var loss = false

    func makeChartDescriptor() -> AXChartDescriptor {
        let points: [(Date, Double)] = series.buckets.compactMap { bucket in
            guard bucket.n > 0 else { return nil }
            if loss { return bucket.loss.map { (bucket.t, $0 * 100) } }
            return bucket.p50Ms.map { (bucket.t, $0) }
        }
        let start = points.first?.0 ?? Date()
        let end = max(points.last?.0 ?? Date(), start.addingTimeInterval(1))
        let values = points.map(\.1)
        let xAxis = AXNumericDataAxisDescriptor(
            title: "Time",
            range: start.timeIntervalSince1970...end.timeIntervalSince1970,
            gridlinePositions: []
        ) { value in
            Date(timeIntervalSince1970: value).formatted(date: .omitted, time: .shortened)
        }
        let yAxis = AXNumericDataAxisDescriptor(
            title: loss ? "Loss" : "p50",
            range: 0...max(values.max() ?? 1, 1),
            gridlinePositions: []
        ) { value in
            loss ? String(format: "%.1f percent", value) : String(format: "%.0f milliseconds", value)
        }
        let data = AXDataSeriesDescriptor(
            name: title,
            isContinuous: false,
            dataPoints: points.map { AXDataPoint(x: $0.0.timeIntervalSince1970, y: $0.1) }
        )
        return AXChartDescriptor(title: title, summary: nil, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [data])
    }
}
