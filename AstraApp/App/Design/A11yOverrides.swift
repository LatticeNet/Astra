import SwiftUI

extension EnvironmentValues {
    /// The system's Differentiate Without Color, or the demo override
    /// (`-AstraDifferentiateWithoutColor YES`). Every module reads this
    /// instead of the system key, so screenshots can exercise the shape
    /// encoding without a person toggling the setting.
    @Entry var astraDifferentiateWithoutColor: Bool = false
}

/// Applied once at the root: folds the system setting and the demo overrides
/// (bold text, differentiate without color, color filter) into the environment.
struct A11yOverrides: ViewModifier {
    let overrides: LaunchOverrides
    @Environment(\.accessibilityDifferentiateWithoutColor) private var systemDifferentiate

    func body(content: Content) -> some View {
        content
            .environment(\.astraDifferentiateWithoutColor, systemDifferentiate || overrides.differentiateWithoutColor)
            .modifier(BoldTextOverride(enabled: overrides.boldText))
            .colorFilter(overrides.colorFilter)
    }
}

extension View {
    /// Grayscale for the color check of section 4.1, over any hierarchy.
    /// Deuteranopia needs a color matrix SwiftUI does not offer, so
    /// `StatusSampler` renders it from a snapshot instead; elsewhere it is a no-op.
    @ViewBuilder
    func colorFilter(_ filter: LaunchOverrides.ColorFilter?) -> some View {
        switch filter {
        case .grayscale: grayscale(1)
        case .deuteranopia, nil: self
        }
    }
}

private struct BoldTextOverride: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.environment(\.legibilityWeight, .bold)
        } else {
            content
        }
    }
}
