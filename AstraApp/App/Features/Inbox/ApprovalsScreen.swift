import SwiftUI

/// The search tokens Approvals understands: `status:`, `plugin:`, `node:`
/// and `id:`, plus free words matched against title, node, plugin and id.
struct InboxApprovalFilter: Equatable {
    var statuses: [String] = []
    var plugins: [String] = []
    var nodes: [String] = []
    var ids: [String] = []
    var words: [String] = []
    var unknown: [String] = []

    init(_ text: String) {
        for raw in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            let lower = raw.lowercased()
            guard let colon = lower.firstIndex(of: ":"), colon != lower.startIndex else {
                words.append(lower)
                continue
            }
            let field = String(lower[..<colon])
            let value = String(lower[lower.index(after: colon)...])
            guard !value.isEmpty else { continue }
            switch field {
            case "status": statuses.append(value)
            case "plugin": plugins.append(value)
            case "node": nodes.append(value)
            case "id": ids.append(value)
            default: unknown.append(field)
            }
        }
    }

    var isEmpty: Bool { statuses.isEmpty && plugins.isEmpty && nodes.isEmpty && ids.isEmpty && words.isEmpty }

    func matches(_ approval: Approval, nodeName: String) -> Bool {
        // A stale retirement is stale, not failed: nobody approved it.
        let state = ApprovalsTransition.isStaleRetirement(approval) ? .stale : approval.displayState
        let word = StatusStyle.approval(state).word.lowercased()
        if !statuses.isEmpty, !statuses.contains(where: { $0 == approval.status.lowercased() || $0 == word || ($0 == "needs" && approval.displayState == .needsYou) }) { return false }
        let pluginName = ApprovalVisibility.displayName(plugin: approval.plugin).lowercased()
        if !plugins.isEmpty, !plugins.contains(where: { approval.plugin.lowercased().contains($0) || pluginName.contains($0) }) { return false }
        let node = nodeName.lowercased()
        if !nodes.isEmpty, !nodes.contains(where: { node.contains($0) || approval.nodeID.lowercased().contains($0) }) { return false }
        if !ids.isEmpty, !ids.contains(approval.id.lowercased()) { return false }
        let haystack = [ApprovalEvents.title(for: approval), node, approval.nodeID, approval.plugin, pluginName, approval.id, approval.actorID].joined(separator: " ").lowercased()
        return words.allSatisfy(haystack.contains)
    }
}

/// M1-04 Approvals, an Activity scope: Needs you, History and Stuck (the
/// console's `view=needs|history|stuck`). Frozen as `init()`.
struct ApprovalsScreen: View {
    static let queryKey = "activity.approvals.query"

    @Environment(ApprovalsStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(Router.self) private var router
    @Environment(ChangeLog.self) private var changes
    @Environment(PowerMonitor.self) private var power
    @Environment(NodeDirectory.self) private var nodeDirectory
    @SceneStorage(ApprovalsScreen.queryKey) private var query = ""
    @State private var scope: ApprovalsScope = .needs

    private var filter: InboxApprovalFilter { InboxApprovalFilter(query) }
    private var interval: TimeInterval { Polling.standard.interval(lowPower: power.isLowPower) }

    var body: some View {
        @Bindable var store = store
        Group {
            if store.denied {
                ScopeDeniedScreen(scope: "network:plan")
            } else {
                list
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search approvals")
        .searchScopes($scope, activation: .automatic) {
            Text("Needs you").tag(ApprovalsScope.needs)
            Text("History").tag(ApprovalsScope.history)
            Text("Stuck").tag(ApprovalsScope.stuck)
        }
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("View", selection: $scope) {
                        Text("Needs you").tag(ApprovalsScope.needs)
                        Text("History").tag(ApprovalsScope.history)
                        Text("Stuck").tag(ApprovalsScope.stuck)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("View", systemImage: "line.3.horizontal.decrease.circle")
                }
                .accessibilityValue(scopeTitle)
            }
            if scope == .history {
                ToolbarItem(placement: .topBarLeading) {
                    RangeMenu(selection: $store.range)
                }
            }
        }
        .polling(.standard, version: changes.version([.approvals]) &* 4 &+ scopeOrdinal) {
            await store.refresh(scope)
        }
        .refreshable { _ = await store.refresh(scope, force: true) }
        .onChange(of: store.range) { Task { await store.refreshHistory(force: true) } }
        .onChange(of: InboxHistoryRequest(filter, resolveNode: resolveNode), initial: true) { _, request in
            guard store.historyRequest != request else { return }
            store.historyRequest = request
            if scope == .history { Task { await store.refreshHistory() } }
        }
        .onAppear(perform: consumeLink)
        .onChange(of: appState.approvalsView) { consumeLink() }
        .task { await nodeDirectory.refreshIfOlder(than: 60) }
    }

    private func consumeLink() {
        if let view = appState.approvalsView {
            scope = view
            appState.approvalsView = nil
        }
        if let pending = appState.consumeQuery(ActivityScope.approvals.rawValue) {
            query = pending
            if pending.hasPrefix("id:") { scope = .needs }
        }
    }

    private var scopeOrdinal: Int {
        switch scope {
        case .needs: 0
        case .history: 1
        case .stuck: 2
        }
    }

    private var scopeTitle: String {
        switch scope {
        case .needs: "Needs you"
        case .history: "History"
        case .stuck: "Stuck"
        }
    }

    private var subtitle: String {
        var parts = [scopeTitle]
        if scope == .history { parts.append(store.range.title) }
        if !filter.isEmpty { parts.append("filtered") }
        return parts.joined(separator: ", ")
    }

    // MARK: Lists

    /// One list for every scope and state, so the navigation bar always
    /// tracks the same scroll view.
    private var list: some View {
        List {
            switch scope {
            case .needs: needsSections
            case .history: historySections
            case .stuck: stuckSections
            }
        }
        .listStyle(.insetGrouped)
    }

    /// A `node:` value as a node id, when it is an id or names exactly one node.
    private func resolveNode(_ token: String) -> String? {
        if nodeDirectory.nodes[token] != nil { return token }
        let matches = nodeDirectory.nodes.values.filter { $0.displayName.lowercased() == token }
        return matches.count == 1 ? matches.first?.id : nil
    }

    private func name(_ approval: Approval) -> String {
        if approval.plugin == "agentupdate", let name = ApprovalEvents.parseAgentUpdatePlan(approval.plan).nodeName { return name }
        return approval.nodeID.isEmpty ? "" : nodeDirectory.name(for: approval.nodeID)
    }

    /// Placeholders, companion behind, or an error without earlier data.
    @ViewBuilder
    private func stateRows<Value>(_ state: ResourceState<Value>, noun: String, retry: @escaping () -> Void) -> some View {
        switch state {
        case .idle, .loading(nil, _):
            LoadingRows(label: "Loading \(noun)")
        case .companionBehind(let surface):
            CompanionBehindRow(surface: surface)
        case .failed(let error, nil, _):
            ErrorRow(message: "Could not load \(noun): \(error.localizedDescription)", retry: retry)
        case .failed(let error, .some, _):
            ErrorRow(message: "Could not refresh \(noun): \(error.localizedDescription)", retry: retry)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var needsSections: some View {
        Section {
            stateRows(store.needs, noun: "approvals") { Task { await store.refreshNeeds() } }
        }
        if let page = store.needs.value {
            let events = ApprovalEvents.group(page.approvals.filter { filter.matches($0, nodeName: name($0)) })
            Section {
                if events.isEmpty {
                    ContentUnavailableView(filter.isEmpty ? "Nothing needs you" : "No approvals match", systemImage: filter.isEmpty ? "checkmark.circle" : "magnifyingglass")
                }
                ForEach(events) { event in
                    InboxEventRow(event: event, nodeName: { nodeDirectory.name(for: $0) })
                }
            } footer: {
                footer(loadedAt: store.needs.loadedAt, failed: isFailed(store.needs), total: page.total, shown: page.approvals.count, limit: page.limit)
            }
        }
    }

    @ViewBuilder
    private var stuckSections: some View {
        Section {
            stateRows(store.stuck, noun: "stuck approvals") { Task { await store.refreshStuck() } }
        }
        if let approvals = store.stuck.value {
            let rows = approvals.filter { filter.matches($0, nodeName: name($0)) }
            Section {
                if rows.isEmpty {
                    ContentUnavailableView(filter.isEmpty ? "Nothing is stuck" : "No approvals match", systemImage: filter.isEmpty ? "checkmark.circle" : "magnifyingglass")
                }
                ForEach(rows) { approval in
                    row(approval)
                }
            } header: {
                Text("Approved, blocked").accessibilityAddTraits(.isHeader)
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("These plans will not apply by themselves. Open one to see why, and dismiss it inside Review where the server allows.")
                    footer(loadedAt: store.stuck.loadedAt, failed: isFailed(store.stuck))
                }
            }
        }
    }

    @ViewBuilder
    private var historySections: some View {
        let loader = store.history
        let rows = loader.items.filter { store.inRange($0) && filter.matches($0, nodeName: name($0)) }
        if loader.items.isEmpty, loader.isLoading || store.historyLoadedAt == nil, loader.error == nil {
            Section { LoadingRows(label: "Loading approval history") }
        } else if loader.items.isEmpty, let error = loader.error {
            Section {
                ErrorRow(message: "Could not load approval history: \(error.localizedDescription)") { Task { await store.refreshHistory(force: true) } }
            }
        } else {
            Section {
                if rows.isEmpty, loader.reachedEnd {
                    ContentUnavailableView(filter.isEmpty ? "No decided approvals in \(store.range.title)" : "No approvals match", systemImage: filter.isEmpty ? "clock" : "magnifyingglass")
                } else if rows.isEmpty {
                    // Later pages may still hold a match; the row below loads them.
                    Text(loader.items.count == 1 ? "No match in the 1 approval loaded so far" : "No match in the \(loader.items.count) approvals loaded so far")
                        .foregroundStyle(.secondary)
                        .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                }
                ForEach(rows) { approval in
                    row(approval)
                }
                LoadMoreRow(loader: loader)
            } footer: {
                footer(loadedAt: store.historyLoadedAt, failed: loader.error != nil)
            }
        }
    }

    private func row(_ approval: Approval) -> some View {
        Button { router.present(.review(.single(approval.id))) } label: {
            ApprovalRow(approval: approval, nodeName: name(approval).inboxNonEmpty)
        }
        .tint(.primary)
        .accessibilityHint("Opens the review")
        .contextMenu { InboxApprovalMenu(approval: approval) }
    }

    private func footer(loadedAt: Date?, failed: Bool, total: Int? = nil, shown: Int? = nil, limit: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if !store.hiddenPlugins.isEmpty {
                Label(AccessState.partial(plugins: store.hiddenPlugins.joined(separator: ", ")).text, systemImage: "eye.slash")
            }
            if let total, let shown, let limit, shown >= limit, total > shown {
                Text("Showing \(shown) of \(total)")
            }
            if !filter.unknown.isEmpty {
                Text("Ignored: \(filter.unknown.joined(separator: ", ")) is not a field here").foregroundStyle(Color.statusWarnText)
            }
            FreshnessFooter(loadedAt: loadedAt, lastAttemptFailed: failed, interval: interval)
        }
        .textRole(.footnote)
    }

    private func isFailed<Value>(_ state: ResourceState<Value>) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
