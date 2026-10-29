import SwiftUI

/// M7 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M7 may add cases but must not rename or remove these.
enum SSHGuardRoute: Hashable, Codable, Sendable {
    case board(posture: String?, coverage: String?)
    case node(id: String)
    case agentUpdates(view: String?, nodeID: String?)
    case agentRelease(id: String)
}

/// M7 registers its demo intents and sheets for `-AstraPresent` here.
extension SSHGuardRoute: DemoHooks {}
