import SwiftUI

/// Chart conventions of section 4.6, shared so every module's charts read the
/// same way. Swift Charts only; no area fill under lines, no gradients.
enum ChartStyle {
    static let lineWidth: CGFloat = 2
    /// The p50 to p95 band opacity over `accent.text`.
    static let bandOpacity: Double = 0.15

    static let baselineDash: [CGFloat] = [1, 3]
    static let triggerDash: [CGFloat] = [4, 2]
    static let compareDash: [CGFloat] = [6, 3]

    /// Map arcs: solid up, dashed degraded, dotted down.
    static let arcDegradedDash: [CGFloat] = [6, 4]
    static let arcDownDash: [CGFloat] = [1, 4]

    /// Consecutive samples further apart than this many intervals start a new segment.
    static let gapFactor: Double = 2.5

    /// Use as `@ScaledMetric(relativeTo: .body) var chartHeight = ChartStyle.height`.
    static let height: CGFloat = 180
    static let minimumHeight: CGFloat = 160

    /// Series with more marks than this hide them from accessibility.
    static let accessibleMarkLimit = 60

    /// Splits samples into segments at gaps, so a chart never interpolates
    /// across missing data.
    static func segments<Sample>(_ samples: [Sample], interval: TimeInterval, date: (Sample) -> Date) -> [[Sample]] {
        var result: [[Sample]] = []
        var current: [Sample] = []
        for sample in samples {
            if let last = current.last, date(sample).timeIntervalSince(date(last)) > interval * gapFactor {
                result.append(current)
                current = []
            }
            current.append(sample)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
