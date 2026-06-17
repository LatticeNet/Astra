import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        TabView {
            OverviewView()
                .tabItem { Label("Overview", systemImage: "square.grid.2x2") }

            NodesView()
                .tabItem { Label("Nodes", systemImage: "server.rack") }

            MonitorsView()
                .tabItem { Label("Monitors", systemImage: "waveform.path.ecg") }

            InventoryView()
                .tabItem { Label("Inventory", systemImage: "shippingbox") }

            MoreHubView()
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
        }
        .tint(Theme.accent)
    }
}
