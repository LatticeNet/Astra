import Foundation

/// The plugin reads (M8-01, M8-02, M8-12, M8-03), created by StoreRegistry
/// and read from the environment. Three reads merge into one row per
/// plugin, as the console merges them: the registered list (audit:read),
/// the lifecycle list (plugin:admin, read only when held) and the
/// contributions (any signed-in caller).
@MainActor @Observable
final class PlatformStore {
    nonisolated static let readScope = "audit:read"
    nonisolated static let adminScope = "plugin:admin"

    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog

    private(set) var registered: ResourceState<[PlatformPlugin]> = .idle
    private(set) var contributions: ResourceState<[PlatformPlugin]> = .idle
    /// Denied without plugin:admin; then health reads "active", never "running".
    private(set) var lifecycle: ResourceState<[PlatformInstallation]> = .idle
    private(set) var trust: PluginTrust?

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    /// The scope an action lacks, or nil when held or not known yet.
    func missing(_ scope: String) -> String? {
        guard let missing = session.missing(ScopeRequirement(scope)), !missing.isEmpty else { return nil }
        return missing.joined(separator: ", ")
    }

    var readMissing: String? { missing(Self.readScope) }
    var adminMissing: String? { missing(Self.adminScope) }

    /// One row per plugin from whichever reads landed.
    var rows: [PlatformPluginRow] {
        PlatformPluginRows.merge(registered: registered.value, lifecycle: lifecycle.value, contributions: contributions.value)
    }

    func row(id: String) -> PlatformPluginRow? {
        rows.first { $0.id == id }
    }

    /// The manifest of an active plugin, from the contributions (filtered
    /// for this caller) or the registered list.
    func plugin(id: String) -> PlatformPlugin? {
        contributions.value?.first { $0.id == id } ?? registered.value?.first { $0.id == id }
    }

    /// The registered list's state, which gates Plugins and Plugin detail.
    var listState: ResourceState<[PlatformPluginRow]> {
        switch registered {
        case .idle: .idle
        case .loading(let previous, let at): .loading(previous: previous.map { _ in rows }, previousAt: at)
        case .loaded(_, let at): .loaded(rows, at: at)
        case .failed(let error, let last, let at): .failed(error, last: last.map { _ in rows }, lastAt: at)
        case .denied(let scope): .denied(scope: scope)
        case .companionBehind(let surface): .companionBehind(surface: surface)
        }
    }

    // MARK: Reads

    /// Every read Plugins needs. Returns false when the main read failed.
    @discardableResult
    func refresh() async -> Bool {
        guard let client = session.client else { return false }
        async let contributionsRead = refreshContributions()
        async let lifecycleRead: Void = refreshLifecycle(client)
        async let trustRead = try? client.fetchPluginTrust()
        var ok = true
        if let missing = readMissing {
            registered = .denied(scope: missing)
        } else {
            registered = registered.reloading
            do {
                registered = .loaded(try await client.platformPlugins(), at: Date())
            } catch {
                let apiError = LatticeAPIError(error)
                registered = registered.failing(apiError, surface: "Plugins", missingScope: Self.readScope)
                if case .forbidden = apiError { session.noteForbidden() }
                ok = false
            }
        }
        _ = await contributionsRead
        _ = await lifecycleRead
        if let fetched = await trustRead { trust = fetched }
        return ok
    }

    /// Contributions alone, for Extensions and extension pages, which any
    /// signed-in caller may read.
    @discardableResult
    func refreshContributions() async -> Bool {
        guard let client = session.client else { return false }
        contributions = contributions.reloading
        do {
            contributions = .loaded(try await client.platformContributions(), at: Date())
            return true
        } catch {
            contributions = contributions.failing(LatticeAPIError(error), surface: "Plugin pages")
            return false
        }
    }

    private func refreshLifecycle(_ client: LatticeClient) async {
        if let missing = adminMissing {
            lifecycle = .denied(scope: missing)
            return
        }
        lifecycle = lifecycle.reloading
        do {
            lifecycle = .loaded(try await client.platformLifecycle(), at: Date())
        } catch {
            lifecycle = lifecycle.failing(LatticeAPIError(error), surface: "Plugin lifecycle", missingScope: Self.adminScope)
        }
    }
}
