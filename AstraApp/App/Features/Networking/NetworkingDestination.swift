import SwiftUI

/// Maps each NetworkingRoute case to its screen.
struct NetworkingDestination: View {
    let route: NetworkingRoute

    var body: some View {
        switch route {
        case .outboundPolicy: OutboundPolicyScreen()
        case .policy(let id): PolicyDetailScreen(id: id)
        case .nodePolicy(let nodeID): NodePolicyScreen(nodeID: nodeID)
        case .dns: DNSScreen()
        case .dnsDeployment(let id): DNSDeploymentScreen(id: id)
        case .ddns: DDNSScreen()
        case .ddnsProfile(let id): DDNSProfileScreen(id: id)
        case .geoRouting: GeoRoutingScreen()
        case .geoRoute(let id): GeoRouteScreen(id: id)
        case .tunnels: TunnelsScreen()
        case .tunnel(let id): TunnelScreen(id: id)
        case .inboundFirewall(let nodeID): InboundFirewallScreen(nodeID: nodeID)
        case .securityGroup(let id): SecurityGroupScreen(id: id)
        }
    }
}
