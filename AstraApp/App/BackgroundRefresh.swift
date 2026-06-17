import Foundation

#if os(iOS)
import BackgroundTasks
import UIKit
#endif

enum AstraBackgroundRefresh {
    static let identifier = "org.roobli.astra.refresh"
    static let minimumInterval: TimeInterval = 15 * 60
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

            let nodes = try await LatticeClient(baseURL: latticeURL, credential: credential).fetchNodes()
            try Task.checkCancellation()
            NodeStore.save(nodes)
            var engine = MonitorEngine(configuration: settings.monitorConfiguration, state: MonitorEngineStateStore.load())
            let events = engine.evaluate(nodes: nodes)

            if !events.isEmpty {
                var storedEvents = EventStore.load()
                storedEvents.insert(contentsOf: events.reversed(), at: 0)
                EventStore.save(storedEvents)
            }

            if settings.notificationsEnabled, !events.isEmpty {
                do {
                    try await sendBark(events: events, settings: settings)
                } catch let failure as BarkDeliveryFailure {
                    engine.markDeliveryFailed(events: failure.undeliveredEvents)
                    MonitorEngineStateStore.save(engine.state)
                    throw failure
                } catch {
                    engine.markDeliveryFailed(events: events)
                    MonitorEngineStateStore.save(engine.state)
                    throw error
                }
            } else if !settings.notificationsEnabled {
                engine.markDeliveryFailed(events: events)
            }
            try Task.checkCancellation()
            MonitorEngineStateStore.save(engine.state)
            BackgroundRefreshStatusStore.recordCompleted(success: true)
            return true
        } catch is CancellationError {
            return false
        } catch {
            BackgroundRefreshStatusStore.recordCompleted(success: false, error: error.localizedDescription)
            return false
        }
    }

    private static func sendBark(events: [MonitorEvent], settings: AppSettings) async throws {
        guard let barkURL = normalizedBarkURL(settings.barkServerURL) else {
            throw BarkError.invalidURL
        }
        let deviceKey = BarkDeviceKeyNormalizer.deviceKey(from: SecretStore.load(AppSecretAccount.barkDeviceKey))
        guard !deviceKey.isEmpty else {
            throw BarkError.missingDeviceKey
        }
        let configuration = BarkConfiguration(
            serverURL: barkURL,
            deviceKey: deviceKey,
            defaultGroup: settings.barkGroup,
            sound: settings.barkSound.isEmpty ? nil : settings.barkSound,
            icon: URL(string: "https://day.app/assets/images/avatar.jpg"),
            url: normalizedLatticeDashboardURL(settings.latticeBaseURL),
            level: settings.barkLevel
        )
        try await BarkClient().sendAll(configuration: configuration, events: events)
    }

    private static func normalizedLatticeURL(_ rawValue: String) -> URL? {
        AstraURLNormalizer.serviceURL(from: rawValue)
    }

    private static func normalizedBarkURL(_ rawValue: String) -> URL? {
        AstraURLNormalizer.serviceURL(from: rawValue, defaultScheme: "http")
    }

    private static func normalizedLatticeDashboardURL(_ rawValue: String) -> URL? {
        AstraURLNormalizer.latticeDashboardURL(from: rawValue)
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
        AstraBackgroundRefreshCoordinator.shared.registerLaunchHandler()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        AstraBackgroundRefreshCoordinator.shared.schedule(settings: SettingsStore.load())
    }
}
#endif
