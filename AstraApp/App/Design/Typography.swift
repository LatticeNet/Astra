import SwiftUI

/// The typography roles of section 4.3. System text styles only, so every
/// role scales through the accessibility sizes.
enum TextRole {
    case verdict
    case detailHeader
    case rowTitle
    case rowDetail
    case rowReason(Color)
    case metric
    case count
    case code
    case identifierInRow
    case identifierInDetail
    case stamp
    case sealInRow
    case sealInStrip
    case chartAxis
    case footnote

    var font: Font {
        switch self {
        case .verdict: .headline
        case .detailHeader: .title3.weight(.semibold)
        case .rowTitle: .body
        case .rowDetail, .rowReason: .subheadline
        case .metric: .body.monospacedDigit()
        case .count: .subheadline.monospacedDigit()
        case .code: .callout.monospaced()
        case .identifierInRow, .sealInRow: .footnote.monospaced()
        case .identifierInDetail, .sealInStrip: .body.monospaced()
        case .stamp: .footnote.monospacedDigit()
        case .chartAxis: .caption2
        case .footnote: .footnote
        }
    }

    var color: Color? {
        switch self {
        case .rowDetail, .stamp, .footnote, .sealInRow: .secondary
        case .rowReason(let color): color
        default: nil
        }
    }
}

extension View {
    /// Applies a typography role: its font and, where the role fixes one, its color.
    func textRole(_ role: TextRole) -> some View {
        modifier(TextRoleModifier(role: role))
    }
}

private struct TextRoleModifier: ViewModifier {
    let role: TextRole

    func body(content: Content) -> some View {
        if let color = role.color {
            content.font(role.font).foregroundStyle(color)
        } else {
            content.font(role.font)
        }
    }
}
