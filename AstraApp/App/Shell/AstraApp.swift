import SwiftUI

@main
struct AstraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let services = AppServices.shared

    var body: some Scene {
        WindowGroup {
            RootTabs()
                .environment(services.appState)
                .environment(services.router)
                .environment(services.deepLinks)
                .environment(services.session)
                .environment(services.runner)
                .environment(services.changes)
                .environment(services.banner)
                .environment(services.network)
                .environment(services.power)
                .environment(services.nodes)
                .environment(services.stepUp)
                .injectStores(services.stores)
                .modifier(A11yOverrides(overrides: services.launch))
                .tint(Color.accentText)
        }
    }
}

/// The app's long-lived objects. The scene delegate is created by UIKit, so
/// it reaches them through `shared`; views read them from the environment.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let launch: LaunchOverrides
    let network = NetworkMonitor()
    let power = PowerMonitor()
    let changes = ChangeLog()
    let banner = BannerCenter()
    let appState = AppState()
    let session: SessionStore
    let runner: ActionRunner
    let router: Router
    let deepLinks: DeepLinkRouter
    let nodes: NodeDirectory
    let stepUp: StepUpCoordinator
    let stores: StoreRegistry

    private init() {
        launch = LaunchOverrides.current
        session = SessionStore(network: network)
        runner = ActionRunner(session: session, changes: changes, banner: banner, network: network)
        router = Router(appState: appState, runner: runner, session: session, banner: banner)
        deepLinks = DeepLinkRouter(appState: appState, router: router, runner: runner, session: session)
        nodes = NodeDirectory(session: session)
        stepUp = StepUpCoordinator(session: session)
        stores = StoreRegistry(session: session, changes: changes)

        if launch.demo, let auth = launch.auth {
            runner.demoAuthenticator = IntentAuth(mode: .stub(auth))
        }
        runner.openFiled = { [router] ids, refused in
            if ids.count == 1, refused.isEmpty {
                router.present(.review(.single(ids[0])))
            } else {
                router.present(.review(.batch(groupKey: "filed", ids: ids, refused: refused)))
            }
        }
        session.restore(launch: launch)
        if launch.demo, let intent = launch.intent {
            Task { await LaunchActions.runIntent(intent) }
        }
    }
}
