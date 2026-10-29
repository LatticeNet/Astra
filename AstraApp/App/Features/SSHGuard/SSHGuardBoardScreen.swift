import SwiftUI

/// M7-01 SSH Guard: posture and coverage of every node this token may see.
/// Filters always start at All and are not restored (section 2.6).
struct SSHGuardBoardScreen: View {
    var posture: String?
    var coverage: String?

    @Environment(SSHGuardStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(ActionRunner.self) private var runner
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    @State private var postureFilter = SSHGuardPostureFilter.all.title
    @State private var coverageFilter = SSHGuardCoverageFilter.all.title
    @State private var query = ""
    @State private var armTarget: SSHGuardArmTarget?
    @State private var stable = SSHGuardStableList<SSHGuardBoardRow>()
    @State private var appliedLink = false

    var body: some View {
        content
            .navigationTitle("SSH Guard")
            .navigationSubtitle(subtitle)
            .searchable(text: $query, tokens: tokensBinding, prompt: "posture:, state:, knock:, tag:") { token in
                Text(token.title)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    FilterMenu(sections: [
                        FilterMenuSection(title: "Posture", options: SSHGuardPostureFilter.allCases.map(\.title),
                                          defaultOption: SSHGuardPostureFilter.all.title, selection: $postureFilter),
                        FilterMenuSection(title: "Coverage", options: SSHGuardCoverageFilter.allCases.map(\.title),
                                          defaultOption: SSHGuardCoverageFilter.all.title, selection: $coverageFilter),
                    ])
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Open on web", systemImage: "safari") { router.openOnWeb(LatticeConsolePath(path: "/network/ssh-guard")) }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
            .sheet(item: $armTarget) { target in
                SSHGuardArmSheet(nodeID: target.nodeID, rotate: target.rotate)
            }
            .onAppear(perform: applyLinkFilters)
            .onChange(of: store.status.loadedAt) { offer(force: false) }
            .onChange(of: nodes.loadedAt) { offer(force: false) }
            .onChange(of: postureFilter) { offer(force: true) }
            .onChange(of: coverageFilter) { offer(force: true) }
            .onChange(of: query) { offer(force: true) }
            .onChange(of: armTarget == nil) { _, closed in stable.setBusy(!closed) }
            .polling(.standard, version: changes.version([.sshguard, .approvals, .nodes])) {
                await nodes.refreshIfOlder(than: 60)
                return await store.refresh()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store.status {
        case .denied(let scope):
            SSHGuardNeedsScopesView(missing: scope.isEmpty ? "sshguard:read and network:plan" : scope)
        case .companionBehind(let surface):
            WholeScreenState {
                ContentUnavailableView {
                    Label("This app is behind the server", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("\(surface) could not be read.")
                } actions: {
                    Button("Reload") { Task { await store.refresh() } }
                }
            }
        case .failed(let error, nil, _):
            WholeScreenState {
                ContentUnavailableView {
                    Label("Could not load SSH Guard", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    Button("Retry") { Task { await store.refresh() } }.buttonStyle(.bordered)
                }
            }
        default:
            if store.status.value == nil, !network.isSatisfied {
                SSHGuardOfflineState(noun: "SSH Guard")
            } else if store.status.value == nil {
                List { LoadingRows(label: "Loading SSH Guard", count: 6) }
            } else {
                list
            }
        }
    }

    // MARK: Rows

    private var allRows: [SSHGuardBoardRow] {
        let now = Date()
        return (store.status.value ?? []).map { SSHGuardBoardRow(status: $0, node: nodes.nodes[$0.nodeID], now: now) }
    }

    private var filtered: (rows: [SSHGuardBoardRow], error: String?) {
        let posture = SSHGuardPostureFilter(title: postureFilter)
        let coverage = SSHGuardCoverageFilter(title: coverageFilter)
        let rows = allRows.filter { posture.matches($0) && coverage.matches($0) }
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return (rows, nil) }
        switch LatticeQueryEngine.compile(text, provider: SSHGuardBoardQueryFields.self) {
        case .success(let compiled): return (LatticeQueryEngine.apply(compiled, to: rows, now: Date()), nil)
        case .failure(let error): return (rows, error.localizedDescription)
        }
    }

    private func offer(force: Bool) {
        stable.offer(filtered.rows, voiceOver: voiceOver, force: force)
    }

    private var list: some View {
        let shown = stable.shown
        let sections = SSHGuardBoardLayout.sections(shown)
        let queryError = filtered.error
        return List {
            if case .failed(let error, _, _) = store.status {
                ErrorRow(message: "Could not refresh SSH Guard: \(error.localizedDescription)") { Task { await store.refresh() } }
            }
            if store.confined {
                Section {
                    Label("Visible nodes only", systemImage: "eye.slash")
                        .foregroundStyle(.secondary)
                        .frame(minHeight: Spacing.minimumTarget)
                } footer: {
                    Text("This token is confined to some nodes. The server leaves out every node it cannot plan on and does not count them.")
                }
            }
            if isFiltered {
                FilterStateRow(text: "Showing \(filterSentence)") { clearFilters() }
            }
            if let queryError {
                Label(queryError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.statusWarnText)
                    .frame(minHeight: Spacing.minimumTarget)
            }
            if stable.held != nil, voiceOver {
                Section { PendingUpdatesRow(count: stable.pendingCount) { stable.showHeld() } }
            }
            if shown.isEmpty {
                Section { emptyState }
            }
            ForEach(sections, id: \.section) { group in
                Section {
                    ForEach(group.rows) { row in
                        rowView(row)
                    }
                } header: {
                    Text("\(group.section.title) (\(group.rows.count))").accessibilityAddTraits(.isHeader)
                } footer: {
                    if group.section == .confirmNeeded {
                        Text("Each node undoes its hardening at the time shown unless a confirm plan is approved and applied first.")
                    }
                }
            }
            Section {} footer: {
                FreshnessFooter(state: store.status, interval: Polling.standard.interval(lowPower: false))
            }
        }
        .listStyle(.insetGrouped)
        .onScrollPhaseChange { _, phase in
            if phase != .idle { stable.noteActivity() }
        }
        .refreshable {
            await nodes.refreshIfOlder(than: 0)
            await store.refresh()
            offer(force: true)
        }
    }

    @ViewBuilder
    private func rowView(_ row: SSHGuardBoardRow) -> some View {
        let action = SSHGuardBoardAction.primary(for: row)
        NavigationLink(value: AppRoute.sshGuard(.node(id: row.id))) {
            SSHGuardBoardRowView(row: row)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if store.canPlan {
                switch action {
                case .confirm:
                    Button("Confirm", systemImage: "checkmark.shield") { confirm(row) }
                        .tint(Color.accentFill)
                case .arm:
                    Button("Arm", systemImage: "lock.shield") { armTarget = SSHGuardArmTarget(nodeID: row.id, rotate: false) }
                        .tint(Color.accentFill)
                case .none:
                    EmptyView()
                }
            }
        }
        .contextMenu {
            menu(for: row, action: action)
        } preview: {
            SSHGuardGlance(row: row)
        }
    }

    @ViewBuilder
    private func menu(for row: SSHGuardBoardRow, action: SSHGuardBoardAction) -> some View {
        Button("Open", systemImage: "arrow.right.circle") { router.push(.sshGuard(.node(id: row.id))) }
        Button("Copy link", systemImage: "link") { SSHGuardCopy.copy(SSHGuardCopy.nodeLink(row.id)) }
        Button("Copy ID", systemImage: "number") { SSHGuardCopy.copy(row.id) }
        Button("Open on web", systemImage: "safari") { router.openOnWeb(.sshGuardNode(nodeID: row.id)) }
        Divider()
        switch action {
        case .confirm(let target):
            Button(target == .file ? "Confirm" : "Open confirm approval", systemImage: "checkmark.shield") { confirm(row) }
                .disabled(!store.canPlan)
        case .arm:
            Button("Arm", systemImage: "lock.shield") { armTarget = SSHGuardArmTarget(nodeID: row.id, rotate: false) }
                .disabled(!store.canPlan)
        case .none:
            if !row.status.actionableApprovalID.isEmpty {
                Button("Open approval", systemImage: "hand.raised") { router.present(.review(.single(row.status.actionableApprovalID))) }
            } else if row.scope == .excluded {
                Button("Not enrolled for SSH Guard", systemImage: "minus.circle") {}
                    .disabled(true)
            }
        }
        if !store.canPlan, action != .none {
            Text(store.planBlockReason() ?? "")
        }
    }

    private func confirm(_ row: SSHGuardBoardRow) {
        switch SSHGuardConfirmTarget.of(row.status) {
        case .review(let approvalID):
            router.present(.review(.single(approvalID)))
        case .file:
            let node = ObjectRef(kind: "node", id: row.id, name: row.name)
            let clock = row.deadline.map { TimeDisplay.clock($0, mode: mode, locale: locale) }
            Task { await runner.run(SSHGuardIntents.confirm(node, deadlineText: clock)) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if isFiltered {
            ContentUnavailableView("No nodes match \(filterSentence)", systemImage: "line.3.horizontal.decrease.circle")
        } else {
            ContentUnavailableView("No nodes to guard", systemImage: "lock.shield",
                                   description: Text("The server lists every node this token may plan on. None are visible."))
        }
    }

    // MARK: Filters

    private var isFiltered: Bool {
        postureFilter != SSHGuardPostureFilter.all.title || coverageFilter != SSHGuardCoverageFilter.all.title
    }

    private var filterSentence: String {
        [postureFilter, coverageFilter].filter { $0 != "All" }.joined(separator: ", ").lowercased()
    }

    private var subtitle: String {
        var parts = [postureFilter, coverageFilter].filter { $0 != "All" }
        if !query.isEmpty { parts.append(query) }
        return parts.joined(separator: ", ")
    }

    private func clearFilters() {
        postureFilter = SSHGuardPostureFilter.all.title
        coverageFilter = SSHGuardCoverageFilter.all.title
    }

    /// A link may open the board filtered (Inbox attention); the filter is not restored.
    private func applyLinkFilters() {
        guard !appliedLink else { return }
        appliedLink = true
        if let posture, let filter = SSHGuardPostureFilter(rawValue: posture) { postureFilter = filter.title }
        if let coverage, let filter = SSHGuardCoverageFilter(rawValue: coverage) { coverageFilter = filter.title }
        offer(force: true)
    }

    private var tokensBinding: Binding<[SSHGuardFilterToken]> {
        Binding(
            get: {
                var tokens: [SSHGuardFilterToken] = []
                if postureFilter != "All" { tokens.append(SSHGuardFilterToken(kind: .posture, title: postureFilter)) }
                if coverageFilter != "All" { tokens.append(SSHGuardFilterToken(kind: .coverage, title: coverageFilter)) }
                return tokens
            },
            set: { tokens in
                if !tokens.contains(where: { $0.kind == .posture }) { postureFilter = "All" }
                if !tokens.contains(where: { $0.kind == .coverage }) { coverageFilter = "All" }
            }
        )
    }
}

/// An active filter shown as a search token; removing it clears the filter.
struct SSHGuardFilterToken: Identifiable, Hashable {
    enum Kind: Hashable { case posture, coverage }
    let kind: Kind
    let title: String
    var id: String { "\(kind):\(title)" }
}

/// The context-menu preview: the row and a few facts.
struct SSHGuardGlance: View {
    let row: SSHGuardBoardRow
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SSHGuardBoardRowView(row: row)
            Divider()
            if let sshd = row.status.sshd {
                fact("Password login", sshd.passwordAuthentication ? "on" : "off")
                fact("sshd ports", sshd.ports.map(String.init).joined(separator: ", "))
            }
            fact("Knock gate", row.status.knockGate ? "present" : "absent")
            if let observed = row.status.realityCollectedAt {
                fact("Observed", TimeDisplay.relative(observed, now: .now, locale: locale))
            }
        }
        .padding(Spacing.l)
        .frame(width: 320)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }
}
