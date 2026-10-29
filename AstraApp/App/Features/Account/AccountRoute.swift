import SwiftUI

/// M11 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M11 may add cases but must not rename or remove these.
enum AccountRoute: Hashable, Codable, Sendable {
    case security
    case passkey(id: String)
    case access(view: String?)
    case user(id: String)
    case token(id: String)
    case ssoProvider(id: String)
}

/// M11 registers its demo intents and sheets for `-AstraPresent` here.
extension AccountRoute: DemoHooks {}
