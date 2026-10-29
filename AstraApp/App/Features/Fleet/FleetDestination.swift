import SwiftUI

/// Maps each FleetRoute case to its screen.
struct FleetDestination: View {
    let route: FleetRoute

    var body: some View {
        switch route {
        case .node(let id, let tab): NodeDetailScreen(id: id, tab: tab)
        case .nodeHistory(let id): NodeHistoryScreen(nodeID: id)
        case .nodeNetwork(let id): NodeNetworkScreen(nodeID: id)
        case .nodeCapabilities(let id): NodeCapabilitiesScreen(nodeID: id)
        case .nodeBeacon(let id): NodeBeaconScreen(nodeID: id)
        case .duplicates: DuplicatesScreen()
        case .group(let id): GroupDetailScreen(id: id)
        case .unlocated: UnlocatedNodesScreen()
        case .capabilityGates: CapabilityGatesScreen()
        case .gate(let id): GateDetailScreen(id: id)
        }
    }
}
