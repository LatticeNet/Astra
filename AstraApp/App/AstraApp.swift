import SwiftUI

#if os(iOS)
import UIKit
#endif

@main
struct AstraApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AstraAppDelegate.self) private var appDelegate
    #endif

    @StateObject private var model = DashboardModel()

    var body: some Scene {
        WindowGroup {
            rootView
        }
    }

    @ViewBuilder
    private var rootView: some View {
        #if os(iOS)
        ContentView()
            .environmentObject(model)
            .task {
                model.configureBackgroundRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                model.saveSettings()
            }
        #else
        ContentView()
            .environmentObject(model)
            .task {
                model.configureBackgroundRefresh()
            }
        #endif
    }
}
