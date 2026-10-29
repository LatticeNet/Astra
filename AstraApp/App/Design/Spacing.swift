import CoreGraphics

/// The spacing scale (section 4.4). List margins and row insets come from the
/// system inset-grouped list; these values are for the inside of rows and
/// headers, wrapped in `@ScaledMetric` where they separate text.
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32

    /// Minimum hit target on every axis.
    static let minimumTarget: CGFloat = 44
}
