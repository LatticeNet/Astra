import SwiftUI

/// Maps each VPNRoute case to its screen.
struct VPNDestination: View {
    let route: VPNRoute

    var body: some View {
        switch route {
        case .users: VPNUsersScreen()
        case .user(let id): VPNUserDetailScreen(id: id)
        case .lines: VPNLinesScreen()
        case .line(let id): VPNLineDetailScreen(id: id)
        }
    }
}
