import SwiftUI
import UIKit

/// M4-02 Task run. The run's state and how far it got (a count, never a
/// spinner), who queued it, and every target worst first. Polls every 3 s
/// while the run is live and on screen.
struct TaskRunScreen: View {
    let id: String

    @Environment(TasksStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    @State private var model = ActivityTaskRunModel()

    var body: some View {
        content
            .navigationTitle(id)
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(model.task.value.map { $0.runState(now: Date()).tasksWord } ?? "")
            .toolbar { toolbar }
            .polling(model.isLive ? .live : .standard, version: changes.version([.tasks])) {
                await nodes.refreshIfOlder(than: 60)
                return await model.load(id: id, hint: store.task(id: id), session: session)
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.notFound {
            WholeScreenState {
                ContentUnavailableView {
                    Label("Task not found in the last \(TasksModel.lookupLimit)", systemImage: "terminal")
                } description: {
                    Text("It was deleted, it is older than the newest \(TasksModel.lookupLimit) runs, or this token cannot see its nodes.")
                } actions: {
                    Button("Open on web") { router.openOnWeb(.task(id: id)) }
                }
            }
        } else {
            ActivityResource(state: model.task, noun: "the run", retry: reload, web: .task(id: id)) { task in
                detail(task)
            }
        }
    }

    private func reload() {
        Task { await model.load(id: id, hint: store.task(id: id), session: session) }
    }

    // MARK: Detail

    private func detail(_ task: LatticeTask) -> some View {
        let now = Date()
        let state = task.runState(now: now)
        let rows = TasksModel.nodeRows(for: task, results: model.results.value ?? [], now: now)
        let summary = TasksModel.summary(of: task, results: model.results.value ?? [])
        return List {
            ActivityRefreshError(state: model.task, noun: "the run", retry: reload)
            Section {
                ActivityStateHeader(style: StatusStyle.task(state), reason: headerReason(task, state: state, summary: summary))
                originLine(task)
            }
            nodesSection(task, rows: rows)
            Section {
                originRows(task)
                if !task.actorID.isEmpty { DetailRow(label: "Creator", value: task.actorID, copyable: false) }
                if !task.tokenID.isEmpty { DetailRow(label: "Token", value: task.tokenID, monospaced: true) }
                if let created = task.createdAt {
                    DetailRow(label: "Created", value: TimeDisplay.dateTime(created, mode: mode, locale: locale),
                              secondary: TimeDisplay.otherZone(created, mode: mode, locale: locale), copyable: false)
                }
                if let duration = duration(task, now: now) {
                    DetailRow(label: TasksModel.isLive(task.status) ? "Running for" : "Duration", value: duration, copyable: false)
                }
                let facts = TasksModel.scriptFacts(task)
                if !facts.isEmpty { DetailRow(label: "Script", value: facts, copyable: false) }
                if !task.scriptSHA256.isEmpty { DetailRow(label: "Script digest", value: task.scriptSHA256, monospaced: true) }
                DetailRow(label: "Nodes", value: task.targets.count == 1 ? "1 node" : "\(task.targets.count) nodes", copyable: false)
            } header: {
                Text("Run").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Scripts can hold credentials, so the run leaves the script out. Reveal it from More with your authenticator code.")
            }
            Section {
                WebLinkRow(path: .task(id: task.id))
            } footer: {
                ActivityFreshness(state: model.task, cadence: model.isLive ? .live : .standard)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.load(id: id, hint: model.task.value, session: session) }
    }

    /// The one line under the state: how far a live run got (a count, never
    /// a spinner), how a settled one ended, or why it stopped.
    private func headerReason(_ task: LatticeTask, state: TaskRunState, summary: TasksRunSummary) -> String? {
        if state == .leased || state == .queued { return TasksModel.liveProgress(summary) }
        if state == .finished || state == .failed, summary.reported > 0 {
            return summary.failed > 0 ? "\(summary.passed) of \(summary.total) passed, \(summary.failed) failed" : "\(summary.passed) of \(summary.total) passed"
        }
        return switch state {
        case .stalled: TasksModel.stalledText(task.leaseProgress())
        case .expired: "No node picked it up before its queue deadline"
        case .pending: "Not yet sent to nodes"
        case .cancelled: "Cancelled before it finished"
        default: nil
        }
    }

    private func duration(_ task: LatticeTask, now: Date) -> String? {
        guard let start = task.startedAt else { return nil }
        let end = task.finishedAt ?? (TasksModel.isLive(task.status) ? now : nil)
        guard let end, end >= start else { return nil }
        let seconds = end.timeIntervalSince(start)
        // The node rows say "<1 s" for the same span; "0 s" would read as no run at all.
        return seconds < 1 ? "<1 s" : TaskLeaseProgress.formatLeaseAge(seconds)
    }

    /// What filed the run, in the header, so a twelve-node run answers it
    /// before its node list; the full rows stay in the Run section.
    private func originLine(_ task: LatticeTask) -> some View {
        let text: String = switch TasksModel.origin(of: task) {
        case .approval(let approvalID):
            model.approval.map { "Filed by approval: \(ApprovalEvents.title(for: $0))" } ?? (approvalID.isEmpty ? "Filed by an approval" : "Filed by approval \(approvalID)")
        case .rerun(let source, _):
            source.isEmpty ? "Rerun" : "Rerun of \(source)"
        case .direct(let actor):
            actor.isEmpty ? "Direct" : "Direct, by \(actor)"
        }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(text.activityUnbroken).textRole(.rowDetail)
                if let seal = model.approval?.planSHA256, !seal.isEmpty { SealLabel(sha256: seal, state: .unverified) }
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(text.activityUnbroken).textRole(.rowDetail)
                if let seal = model.approval?.planSHA256, !seal.isEmpty { SealLabel(sha256: seal, state: .unverified) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func originRows(_ task: LatticeTask) -> some View {
        switch TasksModel.origin(of: task) {
        case .approval(let approvalID):
            if approvalID.isEmpty {
                DetailRow(label: "Origin", value: "An approval this token cannot read", copyable: false)
            } else {
                Button {
                    router.present(.review(.single(approvalID)))
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("Filed by approval").textRole(.rowDetail)
                        Text(model.approval.map { ApprovalEvents.title(for: $0) } ?? approvalID)
                            .foregroundStyle(Color.accentText)
                    }
                    .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
                }
                .accessibilityHint("Opens the approval with its plan")
                if let seal = model.approval?.planSHA256, !seal.isEmpty {
                    SealLabel(sha256: seal, state: .unverified, placement: .standalone)
                }
            }
        case .rerun(let source, let node):
            if source.isEmpty {
                DetailRow(label: "Origin", value: "Rerun", copyable: false)
            } else {
                ActivityLinkRow(label: node.isEmpty ? "Rerun of" : "Rerun on \(nodes.name(for: node)) of", value: source, monospaced: true, route: .activity(.task(id: source)))
            }
        case .direct:
            DetailRow(label: "Origin", value: "Direct", copyable: false)
        }
    }

    @ViewBuilder
    private func nodesSection(_ task: LatticeTask, rows: [TasksNodeRow]) -> some View {
        Section {
            if case .failed(let error, _, _) = model.results {
                ErrorRow(message: "Could not read the results: \(error.localizedDescription)", retry: reload)
            }
            if model.results.value == nil, model.results.isLoading {
                LoadingRows(label: "Loading node results", count: min(3, max(1, task.targets.count)))
            } else {
                ForEach(rows) { row in nodeRow(task, row) }
            }
        } header: {
            Text("Nodes (\(rows.count))").accessibilityAddTraits(.isHeader)
        } footer: {
            if model.truncated {
                Text("Not every result was read, so a node may show no result yet.")
            } else if store.canRun, !rows.isEmpty {
                Text("Swipe a node to run the script again there. Each rerun is a separate task run.")
            }
        }
    }

    private func nodeRow(_ task: LatticeTask, _ row: TasksNodeRow) -> some View {
        let name = nodes.name(for: row.nodeID)
        var style = StatusStyle.task(row.state)
        if row.oldLease { style.tone = .warn }
        var details: [String] = []
        if let result = row.result {
            // A failure reason already starts with the exit code.
            if row.reason?.hasPrefix("exit ") != true { details.append("exit \(result.result.exitCode)") }
            if result.stdoutBytes + result.stderrBytes > 0 {
                details.append(ByteCountFormatter.string(fromByteCount: Int64(result.stdoutBytes + result.stderrBytes), countStyle: .file) + " of output")
            }
        }
        if let attempts = row.attemptsText, row.reason?.contains(attempts) != true { details.append(attempts) }
        let trailing = row.duration.map { $0 < 1 ? "<1 s" : TaskLeaseProgress.formatLeaseAge($0) }
        return NavigationLink(value: AppRoute.activity(.taskNode(taskID: task.id, nodeID: row.nodeID))) {
            StatusRow(style: style, title: name, detail: details.joined(separator: ", "), reason: row.reason, trailing: trailing,
                      accessibilityPhrase: "\(name), \(style.word)" + (row.result.map { ", exit code \($0.result.exitCode)" } ?? ""))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if store.canRun {
                Button("Rerun on this node", systemImage: "arrow.clockwise") {
                    Task { await runner.run(TasksIntents.rerunNode(task, nodeID: row.nodeID, nodeName: name)) }
                }
                .tint(Color.accentFill)
            }
        }
        .contextMenu {
            Button("Open output", systemImage: "doc.plaintext") { router.push(.activity(.taskNode(taskID: task.id, nodeID: row.nodeID))) }
            Button("Open node", systemImage: "server.rack") { router.push(.fleet(.node(id: row.nodeID))) }
            Button("Copy node ID", systemImage: "number") { UIPasteboard.general.string = row.nodeID }
            Divider()
            ActivityMenuButton(title: "Rerun on this node", symbol: "arrow.clockwise", needs: store.canRun ? nil : "Needs task:run") {
                Task { await runner.run(TasksIntents.rerunNode(task, nodeID: row.nodeID, nodeName: name)) }
            }
        } preview: {
            StatusRow(style: style, title: name, detail: details.joined(separator: ", "), reason: row.reason, trailing: trailing)
                .padding()
                .frame(width: 320)
        }
    }

    // MARK: Toolbar

    /// Copy link and Open on web stay in every state, since the id comes
    /// from the route; the writes join once the run has loaded.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let task = model.task.value, TasksModel.isCancellable(task.status), store.canRun {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel task", systemImage: "stop.circle") {
                    Task { await runner.run(TasksIntents.cancel(task)) }
                }
                .accessibilityHint("Asks before it stops pending work")
            }
        }
        ToolbarItem(placement: .topBarTrailing) { menu(model.task.value) }
    }

    private func menu(_ task: LatticeTask?) -> some View {
        Menu {
            if let task { writes(task) }
            ActivityObjectMenu(link: .task(id: id), web: .task(id: id), objectID: id)
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    @ViewBuilder
    private func writes(_ task: LatticeTask) -> some View {
        let needs = store.canRun ? nil : "Needs task:run"
        let failed = TasksModel.failedNodes(TasksModel.nodeRows(for: task, results: model.results.value ?? [], now: Date()))
        // A token without task:run sees why Cancel is off here, not a grey glyph in the bar.
        if TasksModel.isCancellable(task.status), !store.canRun {
            ActivityMenuButton(title: "Cancel task", symbol: "stop.circle", needs: needs) {}
        }
        ActivityMenuButton(title: "Rerun", symbol: "arrow.clockwise", needs: needs) {
            Task { await runner.run(TasksIntents.rerun(task, nodeNames: names(task.targets))) }
        }
        if !failed.isEmpty {
            ActivityMenuButton(title: failed.count == 1 ? "Rerun the failed node" : "Rerun \(failed.count) failed nodes", symbol: "arrow.clockwise.circle", needs: needs) {
                let refs = failed.map { ObjectRef(kind: "node", id: $0, name: nodes.name(for: $0)) }
                Task { await runner.run(TasksIntents.rerunFailed(task, nodes: refs)) }
            }
        }
        ActivityMenuButton(title: "Reveal script", symbol: "eye", needs: revealNeeds) {
            Task { await runner.reveal(TasksIntents.revealScript(task)) }
        }
        Divider()
        ActivityMenuButton(title: "Delete task", symbol: "trash", role: .destructive, needs: needs) {
            Task {
                if case .done = await runner.run(TasksIntents.delete(task)) { dismiss() }
            }
        }
        Divider()
    }

    /// The reveal runs on the session: it needs task:read there, and without
    /// a session the flow signs in first.
    private var revealNeeds: String? {
        guard session.revealClient != nil else { return nil }
        if let missing = session.missing(ScopeRequirement(TasksIntents.readScope), on: .session), !missing.isEmpty {
            return "Needs task:read on the session"
        }
        return nil
    }

    private func names(_ ids: [String]) -> [String: String] {
        Dictionary(ids.map { ($0, nodes.name(for: $0)) }, uniquingKeysWith: { a, _ in a })
    }
}

/// The run screen's own data (section 8.1: view-owned): the run, its results
/// with bodies left out, and the approval behind it.
@MainActor @Observable
final class ActivityTaskRunModel {
    private(set) var task: ResourceState<LatticeTask> = .idle
    private(set) var results: ResourceState<[TasksResultRow]> = .idle
    private(set) var truncated = false
    private(set) var approval: Approval?
    private(set) var notFound = false
    @ObservationIgnored private var approvalRead = false

    var isLive: Bool { task.value.map { TasksModel.isLive($0.status) } ?? false }

    @discardableResult
    func load(id: String, hint: LatticeTask?, session: SessionStore) async -> Bool {
        if let missing = session.missing(TasksStore.readRequirement), !missing.isEmpty {
            task = .denied(scope: missing.joined(separator: " and "))
            return true
        }
        guard let client = session.client else { return false }
        if task.value == nil, let hint { task = .loaded(hint, at: Date()) }
        let before = task
        task = before.reloading
        do {
            guard let found = try await client.tasksFind(id: id, hint: task.value ?? hint) else {
                notFound = true
                task = before.value.map { .loaded($0, at: before.loadedAt ?? Date()) } ?? .idle
                return true
            }
            notFound = false
            task = .loaded(found, at: Date())
            async let resultsOK = loadResults(found, client: client)
            await loadApproval(found, client: client)
            return await resultsOK
        } catch {
            if TasksStore.isCancellation(error) { task = before; return true }
            let apiError = LatticeAPIError(error)
            if case .invalidResponse = apiError { session.markCompanionBehind("Task run") }
            task = task.failing(apiError, surface: "Task run", missingScope: TasksIntents.readScope)
            return false
        }
    }

    private func loadResults(_ task: LatticeTask, client: LatticeClient) async -> Bool {
        let before = results
        results = before.reloading
        do {
            let answer = try await client.tasksAllResults(taskIDs: [task.id])
            truncated = answer.truncated
            results = .loaded(answer.rows, at: Date())
            return true
        } catch {
            if TasksStore.isCancellation(error) { results = before; return true }
            results = results.failing(LatticeAPIError(error), surface: "Task results", missingScope: TasksIntents.readScope)
            return false
        }
    }

    private func loadApproval(_ task: LatticeTask, client: LatticeClient) async {
        guard !approvalRead, !task.approvalID.isEmpty else { return }
        approvalRead = true
        approval = try? await client.fetchApproval(id: task.approvalID)
    }
}
