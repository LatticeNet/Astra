import SwiftUI

/// Maps each TerminalRoute case to its screen.
struct TerminalDestination: View {
    let route: TerminalRoute

    var body: some View {
        switch route {
        case .sessions(let nodeID): TerminalSessionsScreen(nodeID: nodeID)
        case .transcript(let id): TerminalTranscriptScreen(sessionID: id)
        }
    }
}
