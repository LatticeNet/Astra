import SwiftUI

/// M10 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M10 may add cases but must not rename or remove these.
enum EvidenceRoute: Hashable, Codable, Sendable {
    case overview
    case connections(filter: String?)
    case connection(id: String)
    case logs(nodeID: String?)
}

/// M10 registers its demo intents and sheets for `-AstraPresent` here.
extension EvidenceRoute: DemoHooks {}
