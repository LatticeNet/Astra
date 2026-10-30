import SwiftUI

/// The app root (F-01): five tabs, the welcome cover, the Settings sheet and
/// the global sheets, scene storage for state restoration, and scene-phase
/// handling. The banner, privacy cover and lock live in scene-level windows.
struct RootTabs: View {
    @Environment(AppState.self) private var appState
    @Environment(SessionStore.self) private var session
    @Environment(DeepLinkRouter.self) private var deepLinks
    @Environment(ChangeLog.self) private var changes
    @Environment(InboxStore.self) private var inbox
    @Environment(BannerCenter.self) private var banner
    @Environment(\.scenePhase) private var scenePhase

    // State restoration (section 2.6). Keys are `<module>.<screen>.<field>`.
    @SceneStorage("shell.root.tab") private var storedTab: AppTab = .inbox
    @SceneStorage("shell.path.inbox") private var storedInbox = Data()
    @SceneStorage("shell.path.fleet") private var storedFleet = Data()
    @SceneStorage("shell.path.monitor") private var storedMonitor = Data()
    @SceneStorage("shell.path.activity") private var storedActivity = Data()
    @SceneStorage("shell.path.browse") private var storedBrowse = Data()
    @SceneStorage("fleet.root.scope") private var storedFleetScope: FleetScope = .nodes
    @SceneStorage("monitor.root.segment") private var storedMonitorSegment: MonitorSegment = .overview
    @SceneStorage("monitor.root.window") private var storedMonitorWindow: MonitorWindow = .oneDay
    @SceneStorage("activity.root.scope") private var storedActivityScope: ActivityScope = .tasks
    @SceneStorage("inbox.review.target") private var storedReviewTarget = ""
    @State private var restored = false
    @AppStorage(DisplaySettings.utcKey) private var showUTC = false

    var body: some View {
        @Bindable var appState = appState
        TabView(selection: tabSelection) {
            Tab(AppTab.inbox.title, systemImage: AppTab.inbox.symbol, value: AppTab.inbox) {
                TabStack(tab: .inbox) { InboxScreen() }
            }
            .badge(appState.badgeCount ?? 0)
            Tab(AppTab.fleet.title, systemImage: AppTab.fleet.symbol, value: AppTab.fleet) {
                TabStack(tab: .fleet) { FleetRoot() }
            }
            Tab(AppTab.monitor.title, systemImage: AppTab.monitor.symbol, value: AppTab.monitor) {
                TabStack(tab: .monitor) { MonitorRoot() }
            }
            Tab(AppTab.activity.title, systemImage: AppTab.activity.symbol, value: AppTab.activity) {
                TabStack(tab: .activity) { ActivityRoot() }
            }
            Tab(AppTab.browse.title, systemImage: AppTab.browse.symbol, value: AppTab.browse) {
                TabStack(tab: .browse) { BrowseRoot() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .actionHost()
        .sheet(isPresented: $appState.settingsPresented) {
            SettingsScreen()
        }
        .sheet(item: $appState.globalSheet) { sheet in
            GlobalSheetView(sheet: sheet)
        }
        .fullScreenCover(isPresented: $appState.welcomePresented) {
            WelcomeFlow()
        }
        .onOpenURL { deepLinks.handle($0) }
        .onAppear(perform: restore)
        .onChange(of: session.isConnected) { _, connected in
            if !connected {
                resetNavigation()
                appState.welcomePresented = true
            }
        }
        .onChange(of: appState.welcomePresented) { _, presented in
            if !presented { deepLinks.releaseHeld() }
        }
        .environment(\.timeZoneMode, showUTC ? .utc : .local)
        .onChange(of: session.generation) {
            changes.recordAll()
            // A banner (and its Undo) speaks for the session that wrote it.
            banner.dismiss()
        }
        // The badge lives here, not in InboxScreen: TabView builds tab content
        // lazily, so a launch restored to another tab never builds Inbox.
        .onChange(of: inbox.badge) { syncBadge() }
        .task(id: session.generation) {
            guard session.isConnected else { return }
            // InboxScreen polls while it is on screen; any other tab still
            // needs the count of approvals and incidents waiting.
            if appState.selectedTab != .inbox { await inbox.refresh() }
            syncBadge()
        }
        // Scene storage is written on every change and saved by the system
        // when the scene goes to the background.
        .onChange(of: appState.paths) { if restored { persist() } }
        .onChange(of: appState.selectedTab) { if restored { persist() } }
        .onChange(of: appState.fleetScope) { if restored { persist() } }
        .onChange(of: appState.monitorSegment) { if restored { persist() } }
        .onChange(of: appState.monitorWindow) { if restored { persist() } }
        .onChange(of: appState.activityScope) { if restored { persist() } }
        .onChange(of: appState.globalSheet) { if restored { persist() } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, restored { persist() }
        }
        .task { await LaunchActions.apply(AppServices.shared.launch, services: AppServices.shared) }
    }

    /// Tapping the selected tab again pops to its root and scrolls to the top.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { appState.selectedTab },
            set: { tab in
                if tab == appState.selectedTab { appState.reselect(tab) } else { appState.selectedTab = tab }
            }
        )
    }

    private func syncBadge() {
        appState.badgeCount = inbox.badge
        appState.badgeSourceAt = inbox.badgeSourceAt
    }

    // MARK: Restoration

    private func restore() {
        guard !restored else { return }
        restored = true
        appState.welcomePresented = !session.isConnected
        appState.selectedTab = storedTab
        appState.fleetScope = storedFleetScope
        appState.monitorSegment = storedMonitorSegment
        appState.monitorWindow = storedMonitorWindow
        appState.activityScope = storedActivityScope
        for (tab, data) in [(AppTab.inbox, storedInbox), (.fleet, storedFleet), (.monitor, storedMonitor), (.activity, storedActivity), (.browse, storedBrowse)] {
            // A route enum change makes old data undecodable: that tab starts at its root.
            if !data.isEmpty, let path = try? JSONDecoder().decode([AppRoute].self, from: data) {
                appState.paths[tab] = path
            }
        }
        // Review reopens by id and re-hashes; a decision is never restored.
        if !storedReviewTarget.isEmpty, session.isConnected {
            appState.globalSheet = .review(.single(storedReviewTarget))
        }
        appState.shellRestored = true
        deepLinks.releaseHeld()
    }

    private func persist() {
        storedTab = appState.selectedTab
        storedFleetScope = appState.fleetScope
        storedMonitorSegment = appState.monitorSegment
        storedMonitorWindow = appState.monitorWindow
        storedActivityScope = appState.activityScope
        let encoder = JSONEncoder()
        storedInbox = (try? encoder.encode(appState.path(.inbox))) ?? Data()
        storedFleet = (try? encoder.encode(appState.path(.fleet))) ?? Data()
        storedMonitor = (try? encoder.encode(appState.path(.monitor))) ?? Data()
        storedActivity = (try? encoder.encode(appState.path(.activity))) ?? Data()
        storedBrowse = (try? encoder.encode(appState.path(.browse))) ?? Data()
        if case .review(.single(let id)) = appState.globalSheet {
            storedReviewTarget = id
        } else {
            storedReviewTarget = ""
        }
    }

    private func resetNavigation() {
        appState.paths = [:]
        appState.globalSheet = nil
        appState.settingsPresented = false
        appState.selectedTab = .inbox
        appState.badgeCount = nil
    }
}

/// One tab's stack, bound to its path in AppState.
private struct TabStack<Root: View>: View {
    let tab: AppTab
    @ViewBuilder let root: () -> Root
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack(path: pathBinding) {
            root()
                .appRouteDestinations()
                .environment(\.scrollToTopSignal, appState.scrollToTop[tab, default: 0])
        }
    }

    private var pathBinding: Binding<[AppRoute]> {
        Binding(
            get: { appState.paths[tab, default: []] },
            set: { appState.paths[tab] = $0 }
        )
    }
}
