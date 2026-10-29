import SwiftUI

/// M4-01 Tasks. A scope root, frozen as `init()`. Running and waiting runs
/// first, then the rest newest first; each row says who queued it and how
/// far it got, never with a spinner.
struct TasksScreen: View {
    static let queryKey = "activity.tasks.query"
    static let rangeKey = "activity.tasks.range"

    @Environment(TasksStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(ChangeLog.self) private var changes
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @SceneStorage(TasksScreen.queryKey) private var query = ""
    @SceneStorage(TasksScreen.rangeKey) private var rangeTitle = TimeRangeSelection.all.title
    @State private var customRange: TimeRangeSelection?
    @State private var stable = ActivityStableList<LatticeTask>()

    var body: some View {
        ActivityResource(state: store.runs, noun: "runs", retry: refresh) { _ in
            list
        }
        .searchable(text: $query, prompt: "status:, node:, origin:, approval:")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("New task on web", systemImage: "safari") { router.openOnWeb(.tasks) }
                    .accessibilityHint("Opens the console in the browser")
            }
            ToolbarItem(placement: .topBarTrailing) {
                RangeMenu(selection: rangeBinding)
            }
        }
        .onAppear(perform: consumeQuery)
        .onChange(of: appState.pendingQuery) { consumeQuery() }
        .onChange(of: store.runs.loadedAt) { offer(force: false) }
        .onChange(of: filter) { offer(force: true) }
        .polling(.standard, version: changes.version([.tasks]) &* 31 &+ filter.hashValue % 31) {
            await nodes.refreshIfOlder(than: 60)
            return await store.refresh(filter: filter)
        }
    }

    // MARK: Question

    private var range: TimeRangeSelection {
        customRange ?? TimeRangeSelection.presets.first { $0.title == rangeTitle } ?? .all
    }

    private var rangeBinding: Binding<TimeRangeSelection> {
        Binding(get: { range }, set: { value in
            windowAnchor = Date()
            if case .custom = value { customRange = value } else { customRange = nil; rangeTitle = value.title }
        })
    }

    private var tokens: TasksParsedTokens {
        let directory = nodes.nodes
        let byName = Dictionary(directory.values.map { ($0.displayName.lowercased(), $0.id) }, uniquingKeysWith: { a, _ in a })
        let resolve: @Sendable (String) -> String? = { value in
            directory[value] != nil ? value : byName[value.lowercased()]
        }
        // An empty directory cannot tell a typo from a name: send what was typed.
        let resolvers: [String: @Sendable (String) -> String?] = directory.isEmpty ? [:] : ["node": resolve]
        return TasksTokens.parse(TasksModel.normalizedQuery(query), grammar: TasksModel.grammar, resolvers: resolvers)
    }

    private var filter: TasksListFilter {
        // The window is measured when it is chosen; a poll does not slide it.
        TasksModel.filter(tokens, since: range.since(now: windowAnchor), until: range.until)
    }

    @State private var windowAnchor = Date()

    private var subtitle: String {
        var parts: [String] = []
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(query) }
        if range != .all { parts.append(range.title) }
        return parts.joined(separator: ", ")
    }

    private func offer(force: Bool) {
        stable.offer(TasksModel.sorted(store.runs.value ?? []), voiceOver: voiceOver, force: force)
    }

    // MARK: List

    private var list: some View {
        let shown = stable.shown
        let live = shown.filter { TasksModel.isLive($0.status) }
        let settled = shown.filter { !TasksModel.isLive($0.status) }
        return List {
            ActivityRefreshError(state: store.runs, noun: "runs", retry: refresh)
            if !subtitle.isEmpty {
                FilterStateRow(text: "Showing runs matching \(subtitle)") {
                    query = ""
                    customRange = nil
                    rangeTitle = TimeRangeSelection.all.title
                }
            }
            if let notice = ActivityQueryNotice.message(tokens, textAllowed: false, keys: "status:, node:, origin: or approval:") {
                Section { ActivityQueryNotice(message: notice) }
            }
            countsSection
            if stable.held != nil, voiceOver {
                Section { PendingUpdatesRow(count: stable.pendingCount) { stable.showHeld() } }
            }
            if shown.isEmpty {
                if subtitle.isEmpty {
                    ContentUnavailableView {
                        Label("No runs", systemImage: "terminal")
                    } description: {
                        Text("No task has run on a node this token can see.")
                    } actions: {
                        Button("New task on web") { router.openOnWeb(.tasks) }
                    }
                } else {
                    ContentUnavailableView {
                        Label("No runs match", systemImage: "magnifyingglass")
                    } description: {
                        Text("Nothing matched \(subtitle). Widen the range, or drop a token.")
                    }
                }
            }
            if !live.isEmpty {
                Section {
                    ForEach(live) { row($0) }
                } header: {
                    Text("Running and waiting (\(live.count))").accessibilityAddTraits(.isHeader)
                }
            }
            if !settled.isEmpty {
                Section {
                    ForEach(settled) { row($0) }
                    if store.hasMore { loadMore }
                } header: {
                    Text(live.isEmpty ? "Runs (\(settled.count))" : "Finished and stopped (\(settled.count))").accessibilityAddTraits(.isHeader)
                }
            }
            Section {} footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    if !shown.isEmpty, store.total > shown.count, !store.hasMore {
                        Text("Showing \(shown.count) of \(store.total).").textRole(.footnote)
                    }
                    ActivityFreshness(state: store.runs)
                }
            }
        }
        .listStyle(.insetGrouped)
        .onScrollPhaseChange { _, phase in
            if phase != .idle { stable.noteActivity() }
        }
        .refreshable {
            windowAnchor = Date()
            await store.refresh(filter: filter)
            offer(force: true)
        }
    }

    /// The day so far, as the console's head says it: what failed and
    /// finished in 24 h, and what is live now. Omitted when unread.
    @ViewBuilder
    private var countsSection: some View {
        if let counts = store.counts.value, subtitle.isEmpty {
            let live = [(counts.running, "running"), (counts.stalled, "stalled"), (counts.queued, "queued"), (counts.pending, "pending")]
                .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
            Section {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(counts.failed24h == 0 ? "No failed runs in 24 hours" : (counts.failed24h == 1 ? "1 failed run in 24 hours" : "\(counts.failed24h) failed runs in 24 hours"))
                        .foregroundStyle(counts.failed24h > 0 ? Color.statusFailText : .primary)
                    Text(([counts.finished24h == 1 ? "1 finished" : "\(counts.finished24h) finished"] + live).joined(separator: ", "))
                        .textRole(.rowDetail)
                }
                .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                .accessibilityElement(children: .combine)
                if counts.failed24h > 0 {
                    Button("Show failed runs") { query = "status:failed" }
                }
            }
        }
    }

    private var loadMore: some View {
        Group {
            if let error = store.loadMoreError {
                ErrorRow(message: "Could not load more runs: \(error.localizedDescription)") { Task { await store.loadMore() } }
            } else {
                Button(store.isLoadingMore ? "Loading more runs" : "Load more runs") { Task { await store.loadMore() } }
                    .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget)
                    .disabled(store.isLoadingMore)
                    .task { await store.loadMore() }
            }
        }
    }

    private func row(_ task: LatticeTask) -> some View {
        NavigationLink(value: AppRoute.activity(.task(id: task.id))) {
            ActivityTaskRow(task: task, summary: store.summary(of: task), resultsComplete: !store.resultsTruncated,
                            approval: store.approval(id: task.approvalID), nodeName: nodes.name(for:))
        }
        .contextMenu {
            ActivityObjectMenu(route: .activity(.task(id: task.id)), link: .task(id: task.id), web: .task(id: task.id), objectID: task.id)
            Divider()
            if TasksModel.isCancellable(task.status) {
                ActivityMenuButton(title: "Cancel task", symbol: "stop.circle", needs: store.canRun ? nil : "Needs task:run") {
                    Task { await runner.run(TasksIntents.cancel(task)) }
                }
            }
            ActivityMenuButton(title: "Rerun", symbol: "arrow.clockwise", needs: store.canRun ? nil : "Needs task:run") {
                Task { await runner.run(TasksIntents.rerun(task, nodeNames: nodeNames(task))) }
            }
        } preview: {
            ActivityTaskRow(task: task, summary: store.summary(of: task), resultsComplete: !store.resultsTruncated,
                            approval: store.approval(id: task.approvalID), nodeName: nodes.name(for:))
                .padding()
                .frame(width: 340)
        }
    }

    private func nodeNames(_ task: LatticeTask) -> [String: String] {
        Dictionary(task.targets.map { ($0, nodes.name(for: $0)) }, uniquingKeysWith: { a, _ in a })
    }

    private func consumeQuery() {
        if let pending = appState.consumeQuery(ActivityScope.tasks.rawValue) { query = pending }
    }

    private func refresh() {
        Task { await store.refresh(filter: filter) }
    }
}

/// A run: the shared TaskRow (state word, targets, count, age), then who
/// queued it, with the plan seal when an approval did, and why it failed.
struct ActivityTaskRow: View {
    let task: LatticeTask
    let summary: TasksRunSummary?
    var resultsComplete = true
    var approval: Approval?
    let nodeName: (String) -> String

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var glyphWidth: CGFloat = 28

    var body: some View {
        let progress = summary.flatMap { TasksModel.listProgress($0, complete: resultsComplete || $0.reported == $0.total) }
        let detail = [targets?.activityUnbroken, progress].compactMap { $0 }.joined(separator: ", ")
        // The age keeps moving between polls.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                TaskRow(task: task, progress: detail)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        Text(originText.activityUnbroken).textRole(.rowDetail).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        if let seal = approval?.planSHA256, !seal.isEmpty {
                            SealLabel(sha256: seal, state: .unverified)
                        }
                    }
                    if let reason {
                        Text(reason)
                            .textRole(.rowReason(Color.statusFailText))
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    }
                }
                .padding(.leading, typeSize.isAccessibilitySize ? 0 : glyphWidth + Spacing.m)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label(detail: detail))
        }
        .modifier(ActivitySealContent(sha256: approval?.planSHA256 ?? ""))
    }

    private var targets: String? {
        guard let first = task.targets.first else { return nil }
        let name = nodeName(first)
        return task.targets.count == 1 ? name : "\(name) and \(task.targets.count - 1) more"
    }

    private var originText: String {
        switch TasksModel.origin(of: task) {
        case .approval(let id):
            if let approval { return "Approval: \(ApprovalEvents.title(for: approval))" }
            return id.isEmpty ? "Filed by an approval" : "Approval \(id)"
        case .rerun(let source, let node):
            let what = source.isEmpty ? "Rerun" : "Rerun of \(source)"
            return node.isEmpty ? what : "\(what) on \(nodeName(node))"
        case .direct(let actor):
            return actor.isEmpty ? "Direct" : "Direct, by \(actor)"
        }
    }

    private var reason: String? {
        guard let failure = summary?.firstFailure else { return nil }
        let reason = TasksModel.failureReason(failure)
        return task.targets.count == 1 ? reason : "\(nodeName(failure.result.nodeID)): \(reason)"
    }

    private func label(detail: String) -> String {
        let state = task.runState(now: Date())
        let age = task.createdAt.map { RelativeDateFormatter.string(from: $0) }
        return ["Task \(task.id)", state.tasksWord, detail, age, originText, reason].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// The seal phrase on request, only when the row carries a seal.
struct ActivitySealContent: ViewModifier {
    let sha256: String

    func body(content: Content) -> some View {
        if sha256.isEmpty { content } else { content.sealCustomContent(sha256) }
    }
}
