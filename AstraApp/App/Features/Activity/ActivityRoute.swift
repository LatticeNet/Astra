import SwiftUI

/// M4 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M4 may add cases but must not rename or remove these.
enum ActivityRoute: Hashable, Codable, Sendable {
    case task(id: String)
    case taskNode(taskID: String, nodeID: String)
    case auditEvent(id: String)
    case trace(correlationID: String)
}

/// M4 registers its demo intents and sheets for `-AstraPresent` here.
extension ActivityRoute: DemoHooks {}
