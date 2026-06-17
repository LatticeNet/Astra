import SwiftUI
import Charts

// MARK: - Theme

/// Central color and gradient language for the Lattice client. Defined in code
/// (not just the asset catalog) so gradients and semantic status colors stay
/// consistent across every screen and adapt to light/dark automatically.
enum Theme {
    static let accent = Color(red: 0.0, green: 0.80, blue: 0.74)        // Lattice teal
    static let accentDeep = Color(red: 0.0, green: 0.62, blue: 0.66)
    static let secondary = Color(red: 0.40, green: 0.40, blue: 0.96)    // indigo
    static let violet = Color(red: 0.58, green: 0.36, blue: 0.96)

    static let online = Color(red: 0.20, green: 0.82, blue: 0.55)
    static let offline = Color(red: 0.95, green: 0.30, blue: 0.36)
    static let warning = Color(red: 1.0, green: 0.62, blue: 0.18)
    static let critical = Color(red: 0.96, green: 0.26, blue: 0.30)
    static let disabled = Color.secondary

    static let brandGradient = LinearGradient(
        colors: [accent, secondary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let healthGradient = LinearGradient(
        colors: [online, accent],
        startPoint: .leading,
        endPoint: .trailing
    )

    static func gradient(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color, color.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Color for a metric fraction (0...1) against a critical threshold (also 0...1).
    static func usageColor(fraction: Double, critical: Double = 0.9) -> Color {
        switch fraction {
        case ..<(critical * 0.7): return online
        case ..<critical: return warning
        default: return critical <= fraction ? Theme.critical : warning
        }
    }
}

// MARK: - Card container

/// The signature surface: a rounded material panel with a hairline border. Used
/// for nearly every grouped block so the app reads as one cohesive system.
struct LatticeCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

extension View {
    func latticeCard(padding: CGFloat = 16) -> some View {
        LatticeCard(padding: padding) { self }
    }
}

// MARK: - Section header

struct SectionHeaderView: View {
    var title: String
    var systemImage: String?
    var accessory: String?

    init(_ title: String, systemImage: String? = nil, accessory: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.accent)
            }
            Text(title)
                .font(.headline)
            Spacer()
            if let accessory {
                Text(accessory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Status pill

struct StatusPill: View {
    var text: String
    var systemImage: String
    var color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
    }
}

// MARK: - Stat tile

struct StatTile: View {
    var title: String
    var value: String
    var systemImage: String
    var tint: Color
    var caption: String?

    init(title: String, value: String, systemImage: String, tint: Color, caption: String? = nil) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.tint = tint
        self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Spacer()
            }
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeCard()
    }
}

// MARK: - Health ring gauge

/// A circular gauge for an overall fraction (0...1). Used for fleet health and
/// per-metric utilisation.
struct RingGauge: View {
    var fraction: Double
    var lineWidth: CGFloat = 12
    var gradient: LinearGradient = Theme.healthGradient
    var label: String?
    var caption: String?

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(fraction, 1)))
                .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: fraction)
            VStack(spacing: 2) {
                if let label {
                    Text(label)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }
}

// MARK: - Metric bar (compact labeled progress)

struct MetricBar: View {
    var title: String
    var value: Double          // 0...1
    var text: String
    var color: Color

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
            GridRow {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.14))
                        Capsule()
                            .fill(color.gradient)
                            .frame(width: proxy.size.width * min(max(value, 0), 1))
                    }
                }
                .frame(height: 7)
                Text(text)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }
}

// MARK: - Sparkline

/// A small filled line chart over recent metric samples (0...1 values).
struct Sparkline: View {
    var samples: [MetricSample]
    var keyPath: KeyPath<MetricSample, Double>
    var color: Color
    var height: CGFloat = 44

    var body: some View {
        if samples.count < 2 {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
                .frame(height: height)
                .overlay(
                    Text("Collecting…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                )
        } else {
            Chart(samples) { sample in
                AreaMark(
                    x: .value("Time", sample.date),
                    y: .value("Value", sample[keyPath: keyPath])
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom)
                )
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("Value", sample[keyPath: keyPath])
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...1)
            .frame(height: height)
        }
    }
}

// MARK: - Empty state

struct AstraEmptyStateView: View {
    var title: String
    var systemImage: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(Theme.accent.opacity(0.8))
            Text(title)
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

// MARK: - Inline async status row

struct InlineStatusView: View {
    var isLoading: Bool
    var error: String?

    var body: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let error, !error.isEmpty {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.warning)
        }
    }
}

// MARK: - Key/value detail row

struct DetailRow: View {
    var label: String
    var value: String
    var monospaced: Bool = false
    var copyable: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .subheadline.monospaced() : .subheadline)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .contextMenu {
            if copyable {
                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = value
                    #endif
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
    }
}
