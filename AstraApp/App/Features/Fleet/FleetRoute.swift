import SwiftUI

/// M2 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M2 may add cases but must not rename or remove these.
enum FleetRoute: Hashable, Codable, Sendable {
    case node(id: String, tab: NodeDetailTab = .overview)
    case nodeHistory(id: String)
    case nodeNetwork(id: String)
    case nodeCapabilities(id: String)
    case nodeBeacon(id: String)
    case duplicates
    case group(id: String)
    case unlocated
    case capabilityGates
    case gate(id: String)
}

/// M2 registers its demo intents and sheets for `-AstraPresent` here.
extension FleetRoute: DemoHooks {}
