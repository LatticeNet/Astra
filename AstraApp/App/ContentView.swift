import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            InboxView()
                .tabItem { Label("Inbox", systemImage: "tray.full") }
                .badge(model.humanPendingCount)
                .tag(AppTab.inbox)

            NodesView()
                .tabItem { Label("Fleet", systemImage: "server.rack") }
                .tag(AppTab.fleet)

            MoreHubView()
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
                .tag(AppTab.more)
        }
        .tint(Theme.accent)
    }
}
