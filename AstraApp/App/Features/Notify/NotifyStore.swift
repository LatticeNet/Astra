import Foundation

/// The notify lists (section 8.4): channels, rules, the witness, the event
/// catalogue, inbound webhooks and the Sent log. Created by StoreRegistry;
/// the detail screens own their own models.
///
/// Every `/api/notify` read requires notify:admin, and the server refuses
/// the whole surface to a token with a node allowlist, because a channel, a
/// rule and a delivery have no node to confine them to. A confined token
/// therefore reads nothing here and the screens say why.
@MainActor @Observable
final class NotifyStore {
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog
    @ObservationIgnored private var generation = -1

    private(set) var channels: ResourceState<[NotifyChannel]> = .idle
    private(set) var rules: ResourceState<[NotifyRule]> = .idle
    private(set) var witness: ResourceState<NotifyWitnessStatus> = .idle
    private(set) var catalogue: ResourceState<NotifyCatalogue> = .idle
    private(set) var webhooks: ResourceState<[NotifyWebhook]> = .idle
    private(set) var sent: ResourceState<NotifyDeliveriesResponse> = .idle
    /// The question the Sent rows answer.
    private(set) var sentFilters = NotifySentFilters()

    static let requirement = ScopeRequirement(NotifyIntents.adminScope)

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    // MARK: Access

    /// The token is confined to some nodes, so the server refuses every notify read.
    var isConfined: Bool { session.tokenScopes?.isConfined ?? false }

    var confinedCount: Int { session.tokenScopes?.serverAllowlist.count ?? 0 }

    /// "notify:admin" when the primary credential lacks it; nil when it holds
    /// it or its scopes are not known yet.
    var adminMissing: String? {
        session.missing(Self.requirement)?.first
    }

    /// Filing a witness plan also needs node:admin and network:plan.
    var witnessMissing: String? {
        guard let missing = session.missing(ScopeRequirement(groups: NotifyIntents.witnessScopes.map { [$0] })), !missing.isEmpty else { return nil }
        return missing.joined(separator: " and ")
    }

    // MARK: Refresh

    /// Routing: channels, rules, the witness and the catalogue.
    @discardableResult
    func refreshRouting() async -> Bool {
        resetIfCredentialChanged()
        // Unstructured tasks inherit the main actor, where the key paths live.
        let c = Task { await self.load(\.channels, surface: "Notification channels") { try await $0.listNotifyChannels() } }
        let r = Task { await self.load(\.rules, surface: "Notification rules") { try await $0.listNotifyRules() } }
        let w = Task { await self.load(\.witness, surface: "The control-plane witness") { try await $0.notifyFetchWitness() } }
        let k = Task { await self.loadCatalogueIfNeeded() }
        let results = [await c.value, await r.value, await w.value, await k.value]
        return !results.contains(false)
    }

    /// Channels and rules for a detail screen opened by link, read once.
    func refreshRoutingIfNeeded() async {
        if channels.value == nil || rules.value == nil { await refreshRouting() }
    }

    /// The Sent log for `filters`, with the channels and catalogue the filter menu names.
    @discardableResult
    func refreshSent(filters: NotifySentFilters) async -> Bool {
        resetIfCredentialChanged()
        if filters != sentFilters {
            // Another question's rows must not stay on screen under the new one.
            if sent.value != nil { sent = .loading(previous: nil, previousAt: nil) }
            sentFilters = filters
        }
        let s = Task { await self.load(\.sent, surface: "The Sent log") { try await $0.fetchDeliveries(query: filters.query()) } }
        let c = Task { await self.load(\.channels, surface: "Notification channels") { try await $0.listNotifyChannels() } }
        let k = Task { await self.loadCatalogueIfNeeded() }
        let results = [await s.value, await c.value, await k.value]
        // Only the log itself decides the backoff; the menu's names are extras.
        return results[0]
    }

    /// Webhooks, with the channels and rules that decide whether each reaches anyone.
    @discardableResult
    func refreshWebhooks() async -> Bool {
        resetIfCredentialChanged()
        let h = Task { await self.load(\.webhooks, surface: "Inbound webhooks") { try await $0.notifyListWebhooks() } }
        let c = Task { await self.load(\.channels, surface: "Notification channels") { try await $0.listNotifyChannels() } }
        let r = Task { await self.load(\.rules, surface: "Notification rules") { try await $0.listNotifyRules() } }
        let results = [await h.value, await c.value, await r.value]
        return results[0]
    }

    func channel(id: String) -> NotifyChannel? { channels.value?.first { $0.id == id } }
    func rule(id: String) -> NotifyRule? { rules.value?.first { $0.id == id } }
    func webhook(id: String) -> NotifyWebhook? { webhooks.value?.first { $0.id == id } }

    /// The label of an event type, from the catalogue when it has loaded.
    func eventLabel(_ eventType: String) -> String {
        if eventType.isEmpty { return "Notification" }
        return catalogue.value?.label(for: eventType) ?? eventType
    }

    // MARK: Loading

    private func loadCatalogueIfNeeded() async -> Bool {
        // The table changes only with the server build; one read per session is enough.
        if catalogue.value != nil, case .loaded = catalogue { return true }
        return await load(\.catalogue, surface: "The event catalogue") { try await $0.notifyFetchCatalogue() }
    }

    private func load<Value: Sendable>(
        _ keyPath: ReferenceWritableKeyPath<NotifyStore, ResourceState<Value>>,
        surface: String,
        fetch: @Sendable (LatticeClient) async throws -> Value
    ) async -> Bool {
        if isConfined { return true }
        if let missing = adminMissing {
            self[keyPath: keyPath] = .denied(scope: missing)
            return true
        }
        guard let client = session.client else { return false }
        let before = self[keyPath: keyPath]
        self[keyPath: keyPath] = before.reloading
        do {
            let value = try await fetch(client)
            self[keyPath: keyPath] = .loaded(value, at: Date())
            return true
        } catch {
            if Self.isCancellation(error) {
                self[keyPath: keyPath] = before
                return true
            }
            let apiError = LatticeAPIError(error)
            if case .invalidResponse = apiError { session.markCompanionBehind(surface) }
            if case .forbidden = apiError { session.noteForbidden() }
            self[keyPath: keyPath] = self[keyPath: keyPath].failing(apiError, surface: surface, missingScope: NotifyIntents.adminScope)
            return false
        }
    }

    private func resetIfCredentialChanged() {
        guard session.generation != generation else { return }
        generation = session.generation
        channels = .idle
        rules = .idle
        witness = .idle
        catalogue = .idle
        webhooks = .idle
        sent = .idle
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        if case .transport(.cancelled) = LatticeAPIError(error) { return true }
        return false
    }
}
