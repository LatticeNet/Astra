import SwiftUI

/// M1 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M1 may add cases but must not rename or remove these.
enum InboxRoute: Hashable, Codable, Sendable {
    case allAttention
    case trust
}

/// M1 registers its demo intents and sheets for `-AstraPresent` here.
extension InboxRoute: DemoHooks {}
