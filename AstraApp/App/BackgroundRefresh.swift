import Foundation

#if os(iOS)
import BackgroundTasks
import UIKit
import UserNotifications
#endif

enum AstraBackgroundRefresh {
    static let identifier = "org.roobli.astra.refresh"
    static let minimumInterval: TimeInterval = 15 * 60
}

enum InboxBadge {
    static func apply(count: Int) {
        #if os(iOS)
        UIApplication.shared.applicationIconBadgeNumber = count
        #endif
    }

    static func requestAuthorization() {
        #if os(iOS)
        UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { _, _ in }
        #endif
    }
}

enum BackgroundRefreshRunner {
    static func perform() async -> Bool {
        BackgroundRefreshStatusStore.recordStarted()
        do {
            try Task.checkCancellation()
            let settings = SettingsStore.load()
            guard settings.backgroundRefreshEnabled else {
                BackgroundRefreshStatusStore.recordCompleted(success: true)
                return true
            }
            guard let latticeURL = normalizedLatticeURL(settings.latticeBaseURL) else {
                BackgroundRefreshStatusStore.recordCompleted(success: false, error: "Lattice URL is invalid.")
                return false
            }

            let credential = LatticeCredential(
                bearerToken: SecretStore.load(AppSecretAccount.latticeToken),
                sessionCookie: SecretStore.load(AppSecretAccount.latticeSessionCookie),
                csrfToken: SecretStore.load(AppSecretAccount.latticeCSRFToken)
            )
            guard credential.hasAuthentication else {
                BackgroundRefreshStatusStore.recordCompleted(success: false, error: "Lattice credentials are missing.")
                return false
            }

            let pending = try await LatticeClient(baseURL: latticeURL, credential: credential).listHumanPendingApprovals()
            try Task.checkCancellation()
            InboxQuietStore.recordPendingCount(pending.count)
            await MainActor.run {
                InboxBadge.apply(count: pending.count)
            }
            BackgroundRefreshStatusStore.recordCompleted(success: true)
            return true
        } catch is CancellationError {
            return false
        } catch {
            BackgroundRefreshStatusStore.recordCompleted(success: false, error: error.localizedDescription)
            return false
        }
    }

    private static func normalizedLatticeURL(_ rawValue: String) -> URL? {
        AstraURLNormalizer.serviceURL(from: rawValue)
    }
}

@MainActor
final class AstraBackgroundRefreshCoordinator {
    static let shared = AstraBackgroundRefreshCoordinator()

    private var registered = false

    private init() {}

    func registerLaunchHandler() {
        #if os(iOS)
        guard !registered else {
            return
        }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: AstraBackgroundRefresh.identifier, using: nil) { task in
            Task { @MainActor in
                self.handle(task: task)
            }
        }
        if !registered {
            NSLog("Astra background refresh registration failed for \(AstraBackgroundRefresh.identifier)")
        }
        #endif
    }

    func schedule(settings: AppSettings = SettingsStore.load()) {
        #if os(iOS)
        guard settings.backgroundRefreshEnabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AstraBackgroundRefresh.identifier)
            return
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AstraBackgroundRefresh.identifier)
        let request = BGAppRefreshTaskRequest(identifier: AstraBackgroundRefresh.identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: max(AstraBackgroundRefresh.minimumInterval, settings.pollInterval))
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("Astra background refresh schedule failed: \(error)")
        }
        #endif
    }

    #if os(iOS)
    private func handle(task: BGTask) {
        schedule(settings: SettingsStore.load())

        let completion = BackgroundTaskCompletionBox()
        let worker = Task {
            let success = await BackgroundRefreshRunner.perform()
            await MainActor.run {
                completion.complete(task: task, success: success)
            }
        }
        task.expirationHandler = {
            worker.cancel()
            Task { @MainActor in
                BackgroundRefreshStatusStore.recordCompleted(success: false, error: "Background refresh expired.")
                completion.complete(task: task, success: false)
            }
        }
    }
    #endif
}

#if os(iOS)
@MainActor
private final class BackgroundTaskCompletionBox {
    private var completed = false

    func complete(task: BGTask, success: Bool) {
        guard !completed else {
            return
        }
        completed = true
        task.setTaskCompleted(success: success)
    }
}

@MainActor
final class AstraAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        InboxBadge.requestAuthorization()
        AstraBackgroundRefreshCoordinator.shared.registerLaunchHandler()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        AstraBackgroundRefreshCoordinator.shared.schedule(settings: SettingsStore.load())
    }
}
#endif
