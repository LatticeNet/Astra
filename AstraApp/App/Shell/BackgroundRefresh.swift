import BackgroundTasks
import Foundation
import UserNotifications

/// Background badge refresh (section 6.9). It updates only the badge; the
/// server's notify channels are the alerter, and the app never posts a
/// notification. The handler reads only the PAT, never a session.
enum BackgroundRefresh {
    static let identifier = "org.roobli.astra.refresh"
    static let interval: TimeInterval = 15 * 60

    private enum Key {
        static let enabled = "badge.refreshEnabled"
        static let lastRunAt = "badge.lastRunAt"
        static let lastOutcome = "badge.lastOutcome"
        static let sourceAt = "badge.sourceAt"
        static let serverURL = "session.serverURL"
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.enabled) }
        set { UserDefaults.standard.set(newValue, forKey: Key.enabled) }
    }

    static var lastRunAt: Date? { UserDefaults.standard.object(forKey: Key.lastRunAt) as? Date }
    static var lastOutcome: String? { UserDefaults.standard.string(forKey: Key.lastOutcome) }
    /// When the badge's data came from, shown in Inbox so a stale badge is not trusted.
    static var badgeSourceAt: Date? { UserDefaults.standard.object(forKey: Key.sourceAt) as? Date }

    /// Registers the launch handler. Must run before launch finishes. The
    /// handler runs on a background queue, so it is not main-actor isolated.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { @Sendable task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task)
        }
    }

    /// Schedules the next run, only while Badge refresh is on and badge
    /// authorization is granted.
    static func schedule() async {
        guard isEnabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.badgeSetting == .enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        let box = TaskBox(task: task)
        let work = Task {
            let success = await refreshBadge()
            await schedule()
            box.task.setTaskCompleted(success: success)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// `BGTask` is not Sendable; the system allows completing it from any thread.
    private struct TaskBox: @unchecked Sendable {
        let task: BGAppRefreshTask
    }

    /// Fetches human-pending approvals and open or acknowledged incidents with
    /// the PAT, computes the badge with the same `BadgeCount` Inbox uses, and
    /// sets it. Without `monitor:read` the badge counts approvals only.
    static func refreshBadge() async -> Bool {
        guard let raw = UserDefaults.standard.string(forKey: Key.serverURL), let url = URL(string: raw),
              let token = KeychainStore.loadPAT() else {
            record("No API token on this iPhone")
            return false
        }
        let client = LatticeClient(baseURL: url, credential: LatticeCredential(bearerToken: token))
        do {
            let approvals = try await client.listHumanPendingApprovals()
            try Task.checkCancellation()
            var incidents: [Incident] = []
            var note = "Updated"
            do {
                incidents = try await client.listIncidents(states: [.open, .acknowledged]).incidents
            } catch LatticeAPIError.forbidden {
                note = "Updated, approvals only (no monitor:read)"
            }
            try Task.checkCancellation()
            let count = BadgeCount.compute(approvals: approvals, incidents: incidents)
            try await UNUserNotificationCenter.current().setBadgeCount(count)
            UserDefaults.standard.set(Date(), forKey: Key.sourceAt)
            record(note)
            return true
        } catch is CancellationError {
            record("Stopped by iOS before it finished")
            return false
        } catch {
            record(LatticeAPIError(error).localizedDescription)
            return false
        }
    }

    /// Foreground Inbox refreshes stamp the badge source too.
    static func noteForegroundBadge() {
        UserDefaults.standard.set(Date(), forKey: Key.sourceAt)
    }

    private static func record(_ outcome: String) {
        UserDefaults.standard.set(Date(), forKey: Key.lastRunAt)
        UserDefaults.standard.set(outcome, forKey: Key.lastOutcome)
    }
}
