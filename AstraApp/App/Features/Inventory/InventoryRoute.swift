import SwiftUI

/// M5 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M5 may add cases but must not rename or remove these.
enum InventoryRoute: Hashable, Codable, Sendable {
    case machine(id: String)
    case upcoming
}

/// M5 registers its demo intents and sheets for `-AstraPresent` here.
extension InventoryRoute: DemoHooks {}
