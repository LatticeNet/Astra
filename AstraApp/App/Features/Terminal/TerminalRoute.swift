import SwiftUI

/// M12 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M12 may add cases but must not rename or remove these.
enum TerminalRoute: Hashable, Codable, Sendable {
    case sessions(nodeID: String?)
    case transcript(sessionID: String)
}

/// M12 registers its demo intents and sheets for `-AstraPresent` here.
extension TerminalRoute: DemoHooks {}
