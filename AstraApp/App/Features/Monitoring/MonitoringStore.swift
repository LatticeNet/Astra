import Foundation

/// A M3 list store, created by StoreRegistry and read from the environment.
@MainActor @Observable
final class MonitoringStore {
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    // M3: implement
}
