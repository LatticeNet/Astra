import SwiftUI

/// M3 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M3 may add cases but must not rename or remove these.
enum MonitoringRoute: Hashable, Codable, Sendable {
    case path(key: String)
    case matrix
    case chain(id: String)
    case check(id: String)
    case checkResults(id: String)
    case definition(id: String)
    case incident(id: String)
    case maintenanceWindow(id: String)
}

/// M3 registers its demo intents and sheets for `-AstraPresent` here.
extension MonitoringRoute: DemoHooks {}
