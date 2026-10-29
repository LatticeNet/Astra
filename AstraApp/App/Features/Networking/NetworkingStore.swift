import Foundation

/// A M6 list store, created by StoreRegistry and read from the environment.
@MainActor @Observable
final class NetworkingStore {
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    // M6: implement
}
