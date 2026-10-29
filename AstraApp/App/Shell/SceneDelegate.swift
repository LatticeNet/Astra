import SwiftUI
import UIKit

/// Attached through the app delegate's scene configuration, so no plist scene
/// manifest is needed (section 8.8). SwiftUI keeps its own window; this
/// delegate adds the scene-level windows above it: the OutcomeBanner and the
/// privacy cover with the app lock.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    private var bannerWindow: BannerWindow?
    private var shield: ShieldController?
    private weak var scene: UIWindowScene?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        self.scene = scene
        let services = AppServices.shared
        if services.launch.demo, services.launch.boldText {
            // `-AstraBoldText`: SwiftUI text ignores a legibility weight set only
            // in the environment, while a scene trait override reaches it, the
            // UIKit bars and the scene-level windows alike, as Bold Text does.
            scene.traitOverrides.legibilityWeight = .bold
        }
        bannerWindow = BannerWindow(scene: scene, center: services.banner, services: services)
        shield = ShieldController(scene: scene) { services.runner.authenticator }
        services.router.mainWindow = { [weak self] in self?.mainWindow }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        shield?.sceneWillResignActive()
        // A held step-up grant must not outlive leaving the app or the lock,
        // or a reveal could skip the code step after it.
        AppServices.shared.stepUp.invalidate()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        shield?.sceneDidBecomeActive()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        Task { await BackgroundRefresh.schedule() }
    }

    /// SwiftUI's window: the scene's normal-level window that is not one of ours.
    private var mainWindow: UIWindow? {
        scene?.windows.first { $0.windowLevel == .normal && !($0 is BannerWindow) }
    }
}

/// Supplies the scene configuration and registers the background task.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundRefresh.register()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}
