import SwiftUI

/// Maps each InventoryRoute case to its screen.
struct InventoryDestination: View {
    let route: InventoryRoute

    var body: some View {
        switch route {
        case .machine(let id): MachineDetailScreen(id: id)
        case .upcoming: UpcomingScreen()
        }
    }
}
