import SwiftUI

/// A run of states over a window (path 24-cell strip, node status history).
/// State is encoded by shape as well as color (section 4.6): down is a full
/// cell, degraded half height, up a thin tick at the baseline, unknown a
/// hollow outline, paused a gap.
struct StateStrip: View {
    enum Cell: Sendable, Hashable {
        case up, degraded, down, unknown, paused
    }

    let cells: [Cell]
    var height: CGFloat = 16

    @Environment(\.astraDifferentiateWithoutColor) private var differentiate

    var body: some View {
        Canvas { context, size in
            guard !cells.isEmpty else { return }
            let gap: CGFloat = 2
            let width = (size.width - gap * CGFloat(cells.count - 1)) / CGFloat(cells.count)
            for (index, cell) in cells.enumerated() {
                let x = CGFloat(index) * (width + gap)
                let full = CGRect(x: x, y: 0, width: width, height: size.height)
                switch cell {
                case .down:
                    fill(&context, full, .statusFailFill)
                case .degraded:
                    fill(&context, CGRect(x: x, y: size.height / 2, width: width, height: size.height / 2), .statusWarnFill)
                case .up:
                    fill(&context, CGRect(x: x, y: size.height - 2, width: width, height: 2), .statusOKFill)
                case .unknown:
                    context.stroke(Path(roundedRect: full.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1.5), with: .color(.statusQuiet), lineWidth: 1)
                case .paused:
                    break
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func fill(_ context: inout GraphicsContext, _ rect: CGRect, _ color: Color) {
        let path = Path(roundedRect: rect, cornerRadius: 1.5)
        context.fill(path, with: .color(color))
        if differentiate {
            context.stroke(path, with: .color(.primary.opacity(0.6)), lineWidth: 1)
        }
    }
}

/// The strip's legend, shown when Differentiate Without Color is on.
struct StateStripLegend: View {
    var body: some View {
        HStack(spacing: Spacing.m) {
            item("up", .up)
            item("degraded", .degraded)
            item("down", .down)
            item("unknown", .unknown)
        }
        .textRole(.chartAxis)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func item(_ word: String, _ cell: StateStrip.Cell) -> some View {
        HStack(spacing: Spacing.xs) {
            StateStrip(cells: [cell], height: 10).frame(width: 8)
            Text(word)
        }
    }
}
