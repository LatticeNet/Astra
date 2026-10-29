import Foundation
import Network

/// Where network path updates come from, so demo mode can substitute one.
protocol NetworkPathSource: Sendable {
    func start(_ update: @escaping @Sendable (Bool) -> Void)
    func stop()
}

/// The system path monitor.
final class SystemPathSource: NetworkPathSource {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "org.roobli.astra.network-path")

    func start(_ update: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in update(path.status == .satisfied) }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}

/// A fixed path for demo mode: unsatisfied in the Offline scenario.
struct DemoPathSource: NetworkPathSource {
    let satisfied: Bool

    func start(_ update: @escaping @Sendable (Bool) -> Void) {
        update(satisfied)
    }

    func stop() {}
}

/// Network reachability for the app (section 6.11). Unsatisfied stops
/// polling, turns freshness footers to "Offline", and disables writes.
@MainActor @Observable
final class NetworkMonitor {
    private(set) var isSatisfied = true
    private(set) var offlineSince: Date?
    private var source: (any NetworkPathSource)?

    func use(_ source: any NetworkPathSource) {
        self.source?.stop()
        self.source = source
        source.start { [weak self] satisfied in
            Task { @MainActor in self?.apply(satisfied) }
        }
    }

    private func apply(_ satisfied: Bool) {
        guard satisfied != isSatisfied || (offlineSince == nil && !satisfied) else { return }
        isSatisfied = satisfied
        offlineSince = satisfied ? nil : Date()
    }
}
