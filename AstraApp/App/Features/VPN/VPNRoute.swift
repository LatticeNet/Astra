import SwiftUI

/// M13 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M13 may add cases but must not rename or remove these.
enum VPNRoute: Hashable, Codable, Sendable {
    case users
    case user(id: String)
    case lines
    case line(id: String)
}

/// M13 registers its demo intents and sheets for `-AstraPresent` here.
extension VPNRoute: DemoHooks {}
