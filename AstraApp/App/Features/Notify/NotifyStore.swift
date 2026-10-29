import Foundation

/// A M9 list store, created by StoreRegistry and read from the environment.
@MainActor @Observable
final class NotifyStore {
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    // M9: implement
}
