import Foundation

/// The terminal session list (M12-01), created by StoreRegistry. The
/// transcript screen owns its own model (`TerminalTranscriptModel`).
///
/// Listing sessions and reading transcripts need terminal:open, which only
/// the Operator plus root preset holds, so most tokens see the denied state.
/// The server lists only this operator's own sessions.
@MainActor @Observable
final class TerminalStore {
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog
    @ObservationIgnored private var generation = -1

    private(set) var sessions: ResourceState<[TerminalSession]> = .idle

    static let requirement = ScopeRequirement(TerminalLimits.scope)
    static let surface = "Terminal sessions"

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    /// "terminal:open" when the primary credential lacks it; nil when it
    /// holds it or its scopes are not known yet.
    var scopeMissing: String? {
        session.missing(Self.requirement)?.first
    }

    /// The id of the token this phone uses, to tell its own sessions apart.
    var currentTokenID: String? {
        session.primaryIdentity?.tokenID
    }

    func session(id: String) -> TerminalSession? {
        sessions.value?.first { $0.id == id }
    }

    @discardableResult
    func refresh() async -> Bool {
        if session.generation != generation {
            generation = session.generation
            sessions = .idle
        }
        if let missing = scopeMissing {
            sessions = .denied(scope: missing)
            return true
        }
        guard let client = session.client else { return false }
        let before = sessions
        sessions = before.reloading
        do {
            sessions = .loaded(try await client.terminalListSessions(), at: Date())
            return true
        } catch {
            if TerminalStore.isCancellation(error) {
                sessions = before
                return true
            }
            let apiError = LatticeAPIError(error)
            if case .invalidResponse = apiError { session.markCompanionBehind(Self.surface) }
            if case .forbidden = apiError { session.noteForbidden() }
            sessions = sessions.failing(apiError, surface: Self.surface, missingScope: TerminalLimits.scope)
            return false
        }
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        if case .transport(.cancelled) = LatticeAPIError(error) { return true }
        return false
    }
}
