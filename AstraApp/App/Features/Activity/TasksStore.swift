import Foundation

/// The Runs list (section 8.4): one server page of what the field asks for,
/// the 24 h counts, the results of the rows on screen (bodies left out), and
/// the plan seal of each approval that queued a run. Created by
/// StoreRegistry; the run screens own their own models.
@MainActor @Observable
final class TasksStore {
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog
    @ObservationIgnored private var generation = -1

    private(set) var runs: ResourceState<[LatticeTask]> = .idle
    /// What the server said it holds for the question; the list shows a page of it.
    private(set) var total = 0
    private(set) var isLoadingMore = false
    private(set) var loadMoreError: LatticeAPIError?
    /// Bumped when Load more appends a page. The appended rows keep the
    /// list's stamp, so the screen watches this to show them.
    private(set) var appendedPages = 0
    private(set) var counts: ResourceState<TaskCounts> = .idle
    /// Results per task id for the rows on screen.
    private(set) var results: [String: [TasksResultRow]] = [:]
    /// The results read stopped before the end: a run whose targets have not
    /// all reported may hide an unread failure, so it claims no count.
    private(set) var resultsTruncated = false
    /// The approvals behind approval-origin runs, by id; nil when unreadable.
    private(set) var approvals: [String: Approval?] = [:]
    /// The question the rows answer.
    private(set) var filter = TasksListFilter()

    static let readRequirement = ScopeRequirement(TasksIntents.readScope)

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    // MARK: Refresh

    /// Reads the first page for `filter`, the counts, and the rows' results.
    @discardableResult
    func refresh(filter: TasksListFilter) async -> Bool {
        resetIfCredentialChanged()
        if filter != self.filter {
            // Another question's rows must not stay on screen under the new one.
            if runs.value != nil { runs = .loading(previous: nil, previousAt: nil) }
            self.filter = filter
            results = [:]
        }
        let countsTask = Task { await self.loadCounts() }
        let ok = await loadRuns(limit: min(500, max(TasksModel.pageSize, runs.value?.count ?? 0)))
        let countsOK = await countsTask.value
        await loadResults()
        await loadApprovals()
        return ok && countsOK
    }

    /// The next server page, appended.
    func loadMore() async {
        guard !isLoadingMore, let rows = runs.value, rows.count < total, let client = session.client else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await client.listTasks(query: filter.query(limit: TasksModel.pageSize, offset: serverOffset))
            serverOffset += page.tasks.count
            let known = Set(rows.map(\.id))
            let added = page.tasks.filter { filter.matches($0) && !known.contains($0.id) }
            runs = .loaded(rows + added, at: runs.loadedAt ?? Date())
            total = page.total
            loadMoreError = nil
            appendedPages += 1
            await loadResults()
            await loadApprovals()
        } catch {
            if TasksStore.isCancellation(error) { return }
            loadMoreError = LatticeAPIError(error)
        }
    }

    @ObservationIgnored private var serverOffset = 0

    private func loadRuns(limit: Int) async -> Bool {
        if let missing = session.missing(Self.readRequirement), !missing.isEmpty {
            runs = .denied(scope: missing.joined(separator: " and "))
            return true
        }
        guard let client = session.client else { return false }
        let before = runs
        runs = before.reloading
        let filter = self.filter
        do {
            let page = try await client.listTasks(query: filter.query(limit: limit, offset: 0))
            serverOffset = page.tasks.count
            total = page.total
            runs = .loaded(page.tasks.filter(filter.matches), at: Date())
            return true
        } catch {
            if Self.isCancellation(error) {
                runs = before
                return true
            }
            let apiError = LatticeAPIError(error)
            if case .invalidResponse = apiError { session.markCompanionBehind("Tasks") }
            if case .forbidden = apiError { session.noteForbidden() }
            runs = runs.failing(apiError, surface: "Tasks", missingScope: TasksIntents.readScope)
            return false
        }
    }

    private func loadCounts() async -> Bool {
        if let missing = session.missing(Self.readRequirement), !missing.isEmpty {
            counts = .denied(scope: missing.joined(separator: " and "))
            return true
        }
        guard let client = session.client else { return false }
        let before = counts
        counts = before.reloading
        do {
            counts = .loaded(try await client.fetchTaskCounts(), at: Date())
            return true
        } catch {
            if Self.isCancellation(error) { counts = before; return true }
            counts = counts.failing(LatticeAPIError(error), surface: "Task counts", missingScope: TasksIntents.readScope)
            return false
        }
    }

    /// Results for the rows on screen, by id, bodies left out (`resultsRequest`).
    private func loadResults() async {
        guard let client = session.client, let rows = runs.value, !rows.isEmpty else { return }
        let ids = rows.prefix(TasksResultsQuery.maxTaskIDs).map(\.id)
        guard let answer = try? await client.tasksAllResults(taskIDs: ids) else { return }
        var grouped: [String: [TasksResultRow]] = [:]
        for row in answer.rows { grouped[row.result.taskID, default: []].append(row) }
        for id in ids where grouped[id] == nil { grouped[id] = [] }
        results.merge(grouped) { _, new in new }
        resultsTruncated = answer.truncated
    }

    /// The approvals behind approval-origin rows, read once each by id.
    private func loadApprovals() async {
        guard let client = session.client, let rows = runs.value else { return }
        let wanted = Set(rows.map(\.approvalID).filter { !$0.isEmpty && approvals[$0] == nil })
        await withTaskGroup(of: (String, Approval?).self) { group in
            for id in wanted.prefix(12) {
                group.addTask { (id, try? await client.fetchApproval(id: id)) }
            }
            for await (id, approval) in group { approvals[id] = .some(approval) }
        }
    }

    // MARK: Lookups

    func task(id: String) -> LatticeTask? {
        runs.value?.first { $0.id == id }
    }

    func summary(of task: LatticeTask) -> TasksRunSummary? {
        guard let rows = results[task.id] else { return nil }
        return TasksModel.summary(of: task, results: rows)
    }

    func approval(id: String) -> Approval? {
        approvals[id] ?? nil
    }

    /// True when the token may run, rerun, cancel and delete tasks.
    var canRun: Bool {
        session.missing(ScopeRequirement(TasksIntents.runScope))?.isEmpty ?? true
    }

    var hasMore: Bool {
        (runs.value?.count ?? 0) < total && serverOffset < total
    }

    // MARK: Loading

    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        if case .transport(.cancelled) = LatticeAPIError(error) { return true }
        return Task.isCancelled
    }

    private func resetIfCredentialChanged() {
        guard generation != session.generation else { return }
        generation = session.generation
        runs = .idle
        counts = .idle
        results = [:]
        approvals = [:]
        total = 0
        serverOffset = 0
    }
}
