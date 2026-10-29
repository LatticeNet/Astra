import Foundation

/// The audit list (section 8.4): pages of the question on screen with what
/// the server says about its scan, the last chain verification made on this
/// iPhone, and the export in progress. Created by StoreRegistry; the event
/// and trace screens own their own models.
@MainActor @Observable
final class AuditStore {
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog
    @ObservationIgnored private var generation = -1

    private(set) var page: ResourceState<AuditPage> = .idle
    private(set) var isLoadingMore = false
    private(set) var loadMoreError: LatticeAPIError?
    /// The question the rows answer.
    private(set) var query: AuditQuery?
    /// The last verification on this iPhone, held in memory only.
    private(set) var lastVerify: (status: AuditChainStatus, at: Date)?
    private(set) var verify: ResourceState<AuditChainStatus> = .idle
    private(set) var export: ActivityAuditExportState = .idle

    static let readRequirement = ScopeRequirement("audit:read")

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    // MARK: Refresh

    /// Page one of `query`, or every page already shown when the question is unchanged.
    @discardableResult
    func refresh(_ query: AuditQuery) async -> Bool {
        resetIfCredentialChanged()
        if let missing = session.missing(Self.readRequirement), !missing.isEmpty {
            page = .denied(scope: missing.joined(separator: " and "))
            return true
        }
        guard let client = session.client else { return false }
        var asked = query
        if query != self.query {
            if page.value != nil { page = .loading(previous: nil, previousAt: nil) }
            self.query = query
        } else if let shown = page.value?.events.count, shown > query.limit {
            // A poll keeps the pages already scrolled through, up to the server's largest page.
            asked.limit = min(shown, AuditModel.maxPageSize)
        }
        let before = page
        page = before.reloading
        do {
            page = .loaded(try await client.auditPage(asked), at: Date())
            loadMoreError = nil
            return true
        } catch {
            if TasksStore.isCancellation(error) { page = before; return true }
            let apiError = LatticeAPIError(error)
            if case .invalidResponse = apiError { session.markCompanionBehind("Audit") }
            if case .forbidden = apiError { session.noteForbidden() }
            page = page.failing(apiError, surface: "Audit", missingScope: "audit:read")
            return false
        }
    }

    func loadMore() async {
        guard !isLoadingMore, let current = page.value, var next = query, current.events.count < current.total, let client = session.client else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        next.offset = current.events.count
        do {
            let more = try await client.auditPage(next)
            var merged = current
            let known = Set(current.events.map(\.id))
            merged.events += more.events.filter { !known.contains($0.id) }
            merged.total = more.total
            merged.scanned = more.scanned ?? merged.scanned
            merged.complete = more.complete ?? merged.complete
            page = .loaded(merged, at: page.loadedAt ?? Date())
            loadMoreError = nil
        } catch {
            if TasksStore.isCancellation(error) { return }
            loadMoreError = LatticeAPIError(error)
        }
    }

    var hasMore: Bool {
        guard let current = page.value else { return false }
        return current.events.count < current.total
    }

    func event(id: String) -> AuditEvent? {
        page.value?.events.first { $0.id == id }
    }

    // MARK: Verify

    /// `GET /api/audit/verify`. Non-mutating, so no confirmation.
    @discardableResult
    func runVerify() async -> Bool {
        // Claim the credential first, so the next list refresh keeps this result.
        resetIfCredentialChanged()
        if let missing = session.missing(Self.readRequirement), !missing.isEmpty {
            verify = .denied(scope: missing.joined(separator: " and "))
            return true
        }
        guard let client = session.client else { return false }
        let before = verify
        verify = before.reloading
        do {
            let status = try await client.verifyAuditChain()
            verify = .loaded(status, at: Date())
            lastVerify = (status, Date())
            return true
        } catch {
            if TasksStore.isCancellation(error) { verify = before; return true }
            verify = verify.failing(LatticeAPIError(error), surface: "Audit verification", missingScope: "audit:read")
            return false
        }
    }

    // MARK: Export

    /// Builds a file of every event the question matches, paging to the end
    /// of the range, or the audit head record. Nothing is written to disk.
    func startExport(_ format: AuditExportFormat, query: AuditQuery) async {
        resetIfCredentialChanged()
        guard !export.isRunning, let client = session.client else { return }
        if format == .head {
            if lastVerify == nil { await runVerify() }
            guard let last = lastVerify, let record = AuditExport.headRecord(last.status, verifiedAt: last.at) else {
                export = .failed("No anchored, verified head to export. Verify the chain first; a server without an anchor has no head to take off the box.")
                return
            }
            export = .ready(ActivityExportFile(name: AuditExport.fileName(.head, partial: false), format: .head, data: Data(record.utf8)),
                            title: AuditExport.shareTitle(.head, count: 0, partial: nil), summary: "Audit head of \(last.status.count) events")
            return
        }
        export = .running(count: 0)
        do {
            let result = try await AuditExport.collect(query, client: client) { [weak self] count in
                await MainActor.run { self?.export = .running(count: count) }
            }
            let text = format == .csv ? AuditExport.csv(result.events, partial: result.partial) : AuditExport.ndjson(result.events, partial: result.partial)
            let file = ActivityExportFile(name: AuditExport.fileName(format, partial: result.partial != nil), format: format, data: Data(text.utf8))
            let count = result.events.count == 1 ? "1 event" : "\(result.events.count) events"
            export = .ready(file, title: AuditExport.shareTitle(format, count: result.events.count, partial: result.partial),
                            summary: result.partial.map { "\($0.label). \(count) in the file." } ?? "\(count) in the file.")
        } catch {
            export = .failed("Could not export: \(LatticeAPIError(error).localizedDescription)")
        }
    }

    func clearExport() {
        export = .idle
    }

    private func resetIfCredentialChanged() {
        guard generation != session.generation else { return }
        generation = session.generation
        page = .idle
        query = nil
        lastVerify = nil
        verify = .idle
        export = .idle
    }
}

/// Where an export is: reading pages, ready to share, or failed.
enum ActivityAuditExportState {
    case idle
    case running(count: Int)
    case ready(ActivityExportFile, title: String, summary: String)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
