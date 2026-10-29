import Foundation

/// A M1 list store, created by StoreRegistry and read from the environment.
@MainActor @Observable
final class ApprovalsStore {
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    // M1: implement
}
