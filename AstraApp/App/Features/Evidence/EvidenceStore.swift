import Foundation

/// The question the Connections list asks: the filters and the time range.
struct EvidenceConnectionsQuestion: Hashable, Sendable {
    var query: EvidenceConnectionQuery
    var range: TimeRangeSelection
}

/// What the Connections list holds for one question: every page read so far.
struct EvidenceConnectionsList: Sendable {
    var records: [EvidenceConnRecord]
    var nextCursor: String?
    var collectedTotal: Int64
    var collectedNewestAt: Date?
    /// The window start the pages were read with, so "Load more" asks the same.
    var since: Date?
}

/// The Evidence lists (section 8.4): capture sessions, trace policies with
/// collector readiness, raw log sources and their stats, the budgets, the
/// store's stats, and the Connections pages. Created by StoreRegistry; the
/// connection detail and the log explorer own their own models.
///
/// Every read needs log:read; the server narrows each to the nodes this
/// caller may see, so a confined token reads a smaller fleet, not nothing.
@MainActor @Observable
final class EvidenceStore {
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog
    @ObservationIgnored private var generation = -1

    private(set) var sessions: ResourceState<[EvidenceTraceSession]> = .idle
    private(set) var policies: ResourceState<[EvidenceTracePolicy]> = .idle
    private(set) var sources: ResourceState<[LogSource]> = .idle
    private(set) var sourceStats: ResourceState<[LogSourceStats]> = .idle
    private(set) var settings: ResourceState<EvidenceSettingsView> = .idle
    private(set) var traceStats: ResourceState<EvidenceTraceStats> = .idle
    private(set) var connections: ResourceState<EvidenceConnectionsList> = .idle
    private(set) var connectionsQuestion: EvidenceConnectionsQuestion?
    private(set) var isLoadingMore = false
    private(set) var loadMoreError: LatticeAPIError?

    static let requirement = ScopeRequirement(EvidenceCapture.readScope)

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    // MARK: Access

    /// "log:read" when the primary credential lacks it; nil when it holds it or is not known yet.
    var readMissing: String? { session.missing(Self.requirement)?.first }

    /// Whether this token may start or stop a capture on the node (log:admin there).
    func canAdmin(nodeID: String?) -> Bool {
        session.tokenScopes?.allows(EvidenceCapture.adminScope, nodeID: nodeID) ?? false
    }

    var adminMissing: String? { canAdmin(nodeID: nil) ? nil : EvidenceCapture.adminScope }

    /// The server runs without its trace store (503): no record can be kept and no capture start.
    var traceStoreOff: Bool {
        [sessions.evidenceError, policies.evidenceError].contains { Self.isUnavailable($0) }
    }

    /// The raw log store is off (503 on the source list).
    var logStoreOff: Bool {
        Self.isUnavailable(sources.evidenceError)
    }

    // MARK: Refresh

    /// The Overview: captures, policies, sources and stats, budgets and the store.
    @discardableResult
    func refreshOverview() async -> Bool {
        resetIfCredentialChanged()
        let s = Task { await self.load(\.sessions, surface: "Capture sessions") { try await $0.evidenceListSessions() } }
        let p = Task { await self.load(\.policies, surface: "Trace policies") { try await $0.evidencePolicies() } }
        let l = Task { await self.load(\.sources, surface: "Raw log sources") { try await $0.listLogSources() } }
        let t = Task { await self.load(\.sourceStats, surface: "Raw log stats") { try await $0.logStats() } }
        let b = Task { await self.load(\.settings, surface: "Evidence budgets") { try await $0.evidenceSettings() } }
        let k = Task { await self.load(\.traceStats, surface: "The trace store") { try await $0.evidenceTraceStats() } }
        let results = [await s.value, await p.value, await l.value, await t.value, await b.value, await k.value]
        // The captures and the policies decide the backoff; the rest are extras.
        return results[0] && results[1]
    }

    /// Sources and their stats, for the log explorer.
    @discardableResult
    func refreshSources() async -> Bool {
        resetIfCredentialChanged()
        let l = Task { await self.load(\.sources, surface: "Raw log sources") { try await $0.listLogSources() } }
        let t = Task { await self.load(\.sourceStats, surface: "Raw log stats") { try await $0.logStats() } }
        let results = [await l.value, await t.value]
        return results[0]
    }

    /// Captures only, for menus that name them.
    func refreshSessionsIfNeeded() async {
        if sessions.value == nil { await load(\.sessions, surface: "Capture sessions") { try await $0.evidenceListSessions() } }
    }

    /// The newest page for `question`. A different question drops the rows of the last one.
    @discardableResult
    func refreshConnections(_ question: EvidenceConnectionsQuestion) async -> Bool {
        resetIfCredentialChanged()
        if question != connectionsQuestion {
            if connections.value != nil { connections = .loading(previous: nil, previousAt: nil) }
            connectionsQuestion = question
            loadMoreError = nil
        }
        let since = question.range.since(now: Date())
        let until = question.range.until
        let asked = question
        let limit = max(EvidenceConnectionQuery.pageSize, connections.value?.records.count ?? 0)
        return await load(\.connections, surface: "Connection records", accept: { self.connectionsQuestion == asked }) { client in
            let page = try await client.evidenceConnections(asked.query, since: since, until: until, limit: min(limit, 1000))
            return EvidenceConnectionsList(records: page.records, nextCursor: page.nextCursor, collectedTotal: page.collectedTotal,
                                           collectedNewestAt: page.collectedNewestAt, since: since)
        }
    }

    /// The next keyset page, appended once each.
    func loadMoreConnections() async {
        guard let question = connectionsQuestion, let list = connections.value, let cursor = list.nextCursor,
              !isLoadingMore, let client = session.client else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await client.evidenceConnections(question.query, since: list.since, until: question.range.until, cursor: cursor)
            guard connectionsQuestion == question, var current = connections.value else { return }
            let have = Set(current.records.map(\.id))
            current.records += page.records.filter { !have.contains($0.id) }
            current.nextCursor = page.nextCursor
            connections = .loaded(current, at: connections.loadedAt ?? Date())
            loadMoreError = nil
        } catch {
            if !Self.isCancellation(error) { loadMoreError = LatticeAPIError(error) }
        }
    }

    // MARK: Derived

    /// One row per node this caller may read, in the console's order.
    func coverage(nodes: NodeDirectory, now: Date) -> [EvidenceCoverageRow]? {
        guard let policies = policies.value ?? (traceStoreOff ? [] : nil) else { return nil }
        let names = nodes.nodes.values.map { (id: $0.id, name: $0.name) }
        return EvidenceCoverage.rows(
            nodes: names, policies: traceStoreOff ? nil : policies, sessions: sessions.value ?? [],
            sources: sources.value ?? [], sourcesKnown: sources.value != nil, traceUnavailable: traceStoreOff,
            stats: sourceStats.value ?? [], now: now
        )
    }

    func session(id: String) -> EvidenceTraceSession? { sessions.value?.first { $0.id == id } }

    // MARK: Loading

    @discardableResult
    private func load<Value: Sendable>(
        _ keyPath: ReferenceWritableKeyPath<EvidenceStore, ResourceState<Value>>,
        surface: String,
        accept: () -> Bool = { true },
        fetch: @Sendable (LatticeClient) async throws -> Value
    ) async -> Bool {
        if let missing = readMissing {
            self[keyPath: keyPath] = .denied(scope: missing)
            return true
        }
        guard let client = session.client else { return false }
        let before = self[keyPath: keyPath]
        self[keyPath: keyPath] = before.reloading
        do {
            let value = try await fetch(client)
            guard accept() else { return true }
            self[keyPath: keyPath] = .loaded(value, at: Date())
            return true
        } catch {
            guard accept() else { return true }
            if Self.isCancellation(error) {
                self[keyPath: keyPath] = before
                return true
            }
            let apiError = LatticeAPIError(error)
            if case .invalidResponse = apiError { session.markCompanionBehind(surface) }
            if case .forbidden = apiError { session.noteForbidden() }
            self[keyPath: keyPath] = self[keyPath: keyPath].failing(apiError, surface: surface, missingScope: EvidenceCapture.readScope)
            return false
        }
    }

    private func resetIfCredentialChanged() {
        guard session.generation != generation else { return }
        generation = session.generation
        sessions = .idle
        policies = .idle
        sources = .idle
        sourceStats = .idle
        settings = .idle
        traceStats = .idle
        connections = .idle
        connectionsQuestion = nil
    }

    nonisolated static func isUnavailable(_ error: LatticeAPIError?) -> Bool {
        if case .server(let status, _, _)? = error { return status == 503 }
        return false
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        if case .transport(.cancelled) = LatticeAPIError(error) { return true }
        return false
    }
}

extension ResourceState {
    /// The error of a failed state, for the store-off checks.
    var evidenceError: LatticeAPIError? {
        if case .failed(let error, _, _) = self { return error }
        return nil
    }
}
