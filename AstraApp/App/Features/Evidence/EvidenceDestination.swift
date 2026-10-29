import SwiftUI

/// Maps each EvidenceRoute case to its screen.
struct EvidenceDestination: View {
    let route: EvidenceRoute

    var body: some View {
        switch route {
        case .overview: EvidenceScreen()
        case .connections(let filter): ConnectionsScreen(filter: filter)
        case .connection(let id): ConnectionDetailScreen(id: id)
        case .logs(let nodeID): LogExplorerScreen(nodeID: nodeID)
        }
    }
}
