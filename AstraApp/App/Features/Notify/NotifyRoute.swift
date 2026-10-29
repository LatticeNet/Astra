import SwiftUI

/// M9 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M9 may add cases but must not rename or remove these.
enum NotifyRoute: Hashable, Codable, Sendable {
    case notifications(view: String?)
    case delivery(id: String)
    case channel(id: String)
    case rule(id: String)
    case webhooks
    case webhook(id: String)
}

/// M9 registers its demo intents and sheets for `-AstraPresent` here.
extension NotifyRoute: DemoHooks {}
