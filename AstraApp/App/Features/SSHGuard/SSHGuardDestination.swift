import SwiftUI

/// Maps each SSHGuardRoute case to its screen.
struct SSHGuardDestination: View {
    let route: SSHGuardRoute

    var body: some View {
        switch route {
        case .board(let posture, let coverage): SSHGuardBoardScreen(posture: posture, coverage: coverage)
        case .node(let id): SSHGuardNodeScreen(nodeID: id)
        case .agentUpdates(let view, let nodeID): AgentUpdatesScreen(view: view, nodeID: nodeID)
        case .agentRelease(let id): AgentReleaseScreen(id: id)
        }
    }
}
