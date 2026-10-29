import Foundation

/// The SSH Guard board's status rows (M7-01), created by StoreRegistry and
/// read from the environment. The server skips nodes the caller lacks
/// `sshguard:read` or `network:plan` on, with no hidden count.
@MainActor @Observable
final class SSHGuardStore {
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog
    @ObservationIgnored private var generation = -1

    private(set) var status: ResourceState<[SSHGuardNodeStatus]> = .idle

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    /// Both scopes, as the server's handler checks them per node
    /// (`sshguard:admin` satisfies the read through the alias table).
    static let readRequirement = ScopeRequirement("sshguard:read", "network:plan")
    static let planRequirement = ScopeRequirement("sshguard:admin", "network:plan")
    static let excludeRequirement = ScopeRequirement("node:admin")

    /// The scopes the board lacks, or nil when it may read (or the scopes are not known yet).
    var missingRead: [String]? {
        guard let missing = session.missing(Self.readRequirement), !missing.isEmpty else { return nil }
        return missing
    }

    var canPlan: Bool { session.missing(Self.planRequirement)?.isEmpty ?? true }
    var canExclude: Bool { session.missing(Self.excludeRequirement)?.isEmpty ?? true }
    var confined: Bool { session.tokenScopes?.isConfined ?? false }

    /// "Needs sshguard:admin" for a disabled control, or nil when it may run.
    func planBlockReason() -> String? {
        guard let missing = session.missing(Self.planRequirement), !missing.isEmpty else { return nil }
        return "Needs \(missing.joined(separator: " and "))"
    }

    func status(for nodeID: String) -> SSHGuardNodeStatus? {
        status.value?.first { $0.nodeID == nodeID }
    }

    @discardableResult
    func refresh() async -> Bool {
        if generation != session.generation {
            generation = session.generation
            status = .idle
        }
        if let missing = missingRead {
            status = .denied(scope: missing.joined(separator: " and "))
            return true
        }
        guard let client = session.client else { return false }
        status = status.reloading
        do {
            status = .loaded(try await client.fetchSSHGuardStatus(), at: Date())
            return true
        } catch {
            let apiError = LatticeAPIError(error)
            if case .forbidden = apiError { session.noteForbidden() }
            if apiError == .invalidResponse { session.markCompanionBehind("SSH Guard") }
            status = status.failing(apiError, surface: "SSH Guard", missingScope: Self.readRequirement.summary)
            return false
        }
    }
}
