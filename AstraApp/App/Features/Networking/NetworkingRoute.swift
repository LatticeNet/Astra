import SwiftUI

/// M6 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M6 may add cases but must not rename or remove these.
enum NetworkingRoute: Hashable, Codable, Sendable {
    case outboundPolicy
    case policy(id: String)
    case nodePolicy(nodeID: String)
    case dns
    case dnsDeployment(id: String)
    case ddns
    case ddnsProfile(id: String)
    case geoRouting
    case geoRoute(id: String)
    case tunnels
    case tunnel(id: String)
    case inboundFirewall(nodeID: String?)
    case securityGroup(id: String)
}

/// M6 registers its demo intents and sheets for `-AstraPresent` here.
extension NetworkingRoute: DemoHooks {}
