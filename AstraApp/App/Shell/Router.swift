import SwiftUI
import UIKit

/// The only way modules navigate across their boundaries (section 2.4).
@MainActor @Observable
final class Router {
    private let appState: AppState
    private let runner: ActionRunner
    private let session: SessionStore
    private let banner: BannerCenter
    @ObservationIgnored var mainWindow: () -> UIWindow? = { nil }

    init(appState: AppState, runner: ActionRunner, session: SessionStore, banner: BannerCenter) {
        self.appState = appState
        self.runner = runner
        self.session = session
        self.banner = banner
    }

    /// Pushes onto the selected tab's stack.
    func push(_ route: AppRoute) {
        appState.paths[appState.selectedTab, default: []].append(route)
    }

    /// Selects a tab and, for a scoped tab, its segment. A query is handed to
    /// the scope root's search field once.
    func select(tab: AppTab, scope: String? = nil, query: String? = nil) {
        appState.selectedTab = tab
        switch tab {
        case .fleet:
            if let scope = scope.flatMap(FleetScope.init(rawValue:)) { appState.fleetScope = scope }
        case .monitor:
            if let segment = scope.flatMap(MonitorSegment.init(rawValue:)) { appState.monitorSegment = segment }
        case .activity:
            if let scope = scope.flatMap(ActivityScope.init(rawValue:)) { appState.activityScope = scope }
        case .inbox, .browse:
            break
        }
        if let query {
            appState.pendingQuery[scope ?? tab.rawValue] = query
        }
    }

    /// Presents a global sheet after dismissing whatever is up. While a write
    /// or decision is in flight the request waits for it.
    func present(_ sheet: GlobalSheet) {
        if runner.isBusy {
            banner.show(BannerMessage(text: "Opens after the current action finishes"))
        }
        runner.whenIdle { [weak self] in
            self?.dismissPresented { self?.appState.globalSheet = sheet }
        }
    }

    /// Presents the Settings sheet with its stack set to `path`.
    func openSettings(_ path: [SettingsRoute] = []) {
        if appState.settingsPresented {
            appState.settingsPath = path
            return
        }
        runner.whenIdle { [weak self] in
            self?.dismissPresented {
                self?.appState.settingsPath = path
                self?.appState.settingsPresented = true
            }
        }
    }

    /// Opens the exact console route in the default browser, so the console
    /// session there is reused (section 6.15).
    func openOnWeb(_ path: LatticeConsolePath) {
        guard let console = session.consoleURL, !session.isDemo else {
            banner.show(BannerMessage(text: session.isDemo ? "Demo data has no console to open." : "No console URL is set.", tone: .warn))
            return
        }
        UIApplication.shared.open(path.url(console: console))
    }

    /// Dismisses any presented sheet, then runs `next` once it is gone.
    func dismissPresented(then next: @escaping @MainActor () -> Void) {
        appState.globalSheet = nil
        appState.settingsPresented = false
        // The welcome cover is never dismissed from here.
        guard session.isConnected, let root = mainWindow()?.rootViewController, let presented = root.presentedViewController,
              !presented.isBeingDismissed else {
            next()
            return
        }
        root.dismiss(animated: true) { MainActor.assumeIsolated { next() } }
    }
}
