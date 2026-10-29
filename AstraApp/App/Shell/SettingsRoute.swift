import Foundation

/// The foundation pages of the Settings sheet (F-04 to F-12).
enum SettingsPage: String, Hashable, Codable, Sendable, CaseIterable {
    case connection, scopes, session, deviceSecurity, badge, display, diagnostics, demo, about
    /// Debug builds only: every status state, for the color check of section 4.1.
    case statusSampler
}

/// The Settings sheet's own stack (section 2.4). Frozen after M0.
enum SettingsRoute: Hashable, Codable, Sendable {
    case page(SettingsPage)
    /// Hosted only in the Settings sheet's stack (M11).
    case account(AccountRoute)
}
