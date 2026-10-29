import Foundation

/// A M4 list store, created by StoreRegistry and read from the environment.
@MainActor @Observable
final class AuditStore {
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    // M4: implement
}
