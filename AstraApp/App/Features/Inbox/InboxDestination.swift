import SwiftUI

/// Maps each InboxRoute case to its screen.
struct InboxDestination: View {
    let route: InboxRoute

    var body: some View {
        switch route {
        case .allAttention: InboxAllAttentionScreen()
        case .trust: TrustDetailScreen()
        }
    }
}
