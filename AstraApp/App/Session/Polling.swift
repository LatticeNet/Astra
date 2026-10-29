import SwiftUI

/// Low Power Mode, observed so polling cadences follow it (section 6.8).
@MainActor @Observable
final class PowerMonitor {
    private(set) var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }
}

/// The polling cadences of section 6.8.
enum Polling: Sendable {
    /// Inbox, NodeDetail overview.
    case inbox
    /// A running task or an open terminal transcript.
    case live
    /// Paths, matrix, path detail.
    case paths
    /// Incidents, checks, monitoring overview.
    case monitoring
    /// Every other list and detail.
    case standard

    func interval(lowPower: Bool) -> TimeInterval {
        switch self {
        case .inbox: lowPower ? 60 : 15
        case .live: lowPower ? 10 : 3
        case .paths: lowPower ? 120 : 60
        case .monitoring: lowPower ? 60 : 30
        case .standard: lowPower ? 120 : 60
        }
    }

    /// A failed poll doubles the interval, up to five minutes.
    static func backoff(_ interval: TimeInterval, failures: Int) -> TimeInterval {
        min(interval * pow(2, Double(failures)), 300)
    }
}

/// The identity of a polling loop: a ChangeLog version and the cadence. A
/// bump of either restarts the loop with an immediate refresh.
struct PollKey: Hashable {
    var version: Int
    var cadence: Polling
}

extension View {
    /// The fixed polling idiom: refreshes at once, then every interval while
    /// the view is visible, the scene is active and the network is up.
    /// `refresh` returns false when it failed, which backs the interval off.
    func polling(_ cadence: Polling, version: Int, refresh: @escaping @MainActor () async -> Bool) -> some View {
        modifier(PollingModifier(cadence: cadence, version: version, refresh: refresh))
    }
}

private struct PollingModifier: ViewModifier {
    let cadence: Polling
    let version: Int
    let refresh: @MainActor () async -> Bool

    @Environment(\.scenePhase) private var scenePhase
    @Environment(PowerMonitor.self) private var power
    @Environment(NetworkMonitor.self) private var network

    func body(content: Content) -> some View {
        content.task(id: LoopKey(key: PollKey(version: version, cadence: cadence), active: scenePhase == .active && network.isSatisfied, lowPower: power.isLowPower)) {
            guard scenePhase == .active, network.isSatisfied else { return }
            var failures = 0
            while !Task.isCancelled {
                failures = await refresh() ? 0 : failures + 1
                let wait = Polling.backoff(cadence.interval(lowPower: power.isLowPower), failures: failures)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private struct LoopKey: Hashable {
        var key: PollKey
        var active: Bool
        var lowPower: Bool
    }
}
