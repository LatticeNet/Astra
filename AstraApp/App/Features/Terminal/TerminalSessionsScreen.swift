import SwiftUI

/// M12-01 Terminal. This operator's sessions, live first, with who opened
/// each, its transport and when it was last active. Close (T2) by swipe or
/// menu; opening a session and typing stay on the web.
/// Gate terminal:open, which also guards the list.
struct TerminalSessionsScreen: View {
    var nodeID: String?

    static let queryKey = "terminal.sessions.query"

    @Environment(TerminalStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @SceneStorage(Self.queryKey) private var query = ""
    @State private var showAllNodes = false
    @State private var stable = TerminalStableList<TerminalSession> { $0.isLive == $1.isLive }

    private var nodeFilter: String? { showAllNodes ? nil : nodeID }

    var body: some View {
        content
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.large)
            .navigationSubtitle(nodeFilter.map { "On \(nodes.name(for: $0))" } ?? "")
            .searchable(text: $query, prompt: "Search sessions")
            .toolbar { toolbar }
            .onChange(of: store.sessions.loadedAt, initial: true) { offer(force: false) }
            .onChange(of: nodes.loadedAt) { offer(force: false) }
            .onChange(of: query) { offer(force: true) }
            .onChange(of: showAllNodes) { offer(force: true) }
            .polling(.standard, version: changes.version([.terminal, .nodes])) {
                await nodes.refreshIfOlder(than: 60)
                return await store.refresh()
            }
    }

    @ViewBuilder
    private var content: some View {
        if !network.isSatisfied, store.sessions.value == nil, !store.sessions.isLoading, store.scopeMissing == nil {
            TerminalOfflineView(noun: "Terminal sessions", retry: refresh)
        } else {
            ResourceView(state: store.sessions, noun: "terminal sessions", retry: refresh) { _ in
                list
            }
        }
    }

    private var filtered: [TerminalSession] {
        let all = store.sessions.value ?? []
        let now = Date()
        let onNode = all.filter { nodeFilter == nil || $0.nodeID == nodeFilter }
        let matching = onNode.filter {
            TerminalSessionList.matches($0, nodeName: nodes.name(for: $0.nodeID), transport: TerminalTransport.of($0, runtime: nil, now: now), query: query)
        }
        return TerminalSessionList.live(matching) + TerminalSessionList.ended(matching)
    }

    private func offer(force: Bool) {
        stable.offer(filtered, voiceOver: voiceOver, force: force)
    }

    private var list: some View {
        let shown = stable.shown
        let live = shown.filter(\.isLive)
        let ended = shown.filter { !$0.isLive }
        let all = store.sessions.value ?? []
        return List {
            if case .failed(let error, let last, _) = store.sessions, last != nil {
                ErrorRow(message: "Could not refresh terminal sessions: \(error.localizedDescription)", retry: refresh)
            }
            if stable.held != nil, voiceOver {
                Section { PendingUpdatesRow(count: stable.pendingCount) { stable.showHeld() } }
            }
            if let nodeFilter {
                Section {
                    FilterStateRow(text: "Showing sessions on \(nodes.name(for: nodeFilter)) only.") { showAllNodes = true }
                }
            }
            if shown.isEmpty {
                Section { emptyState(all: all) }
            }
            if !live.isEmpty {
                Section {
                    ForEach(live) { row($0) }
                } header: {
                    Text(live.count == 1 ? "1 live" : "\(live.count) live").accessibilityAddTraits(.isHeader)
                } footer: {
                    Text("A live session is a root shell on its node. Close one you no longer need.")
                }
            }
            if !ended.isEmpty {
                Section {
                    ForEach(ended) { row($0) }
                } header: {
                    Text("Ended").accessibilityAddTraits(.isHeader)
                } footer: {
                    Text("The server keeps an ended session for \(TerminalLimits.closedRetentionMinutes) minutes, then forgets it. The audit log keeps the record.")
                }
            }
            Section {
                TerminalOpensInRow(title: "Terminal audit trail", symbol: "list.bullet.rectangle", tab: .activity,
                                   hint: "Shows terminal actions in the audit log") {
                    router.select(tab: .activity, scope: "audit", query: "action:terminal.*", auditLayer: .all)
                }
                WebLinkRow(title: "New session on web", path: .terminalNewSession(nodeID: nodeFilter))
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Opening a shell and typing stay on the web. \(TerminalLimits.sentence)")
                    FreshnessFooter(state: store.sessions, interval: Polling.standard.interval(lowPower: false))
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await store.refresh()
            offer(force: true)
        }
        .onScrollPhaseChange { _, phase in if phase != .idle { stable.noteActivity() } }
    }

    @ViewBuilder
    private func emptyState(all: [TerminalSession]) -> some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: query)
        } else if let nodeFilter, !all.isEmpty {
            ContentUnavailableView {
                Label("No sessions on \(nodes.name(for: nodeFilter))", systemImage: "apple.terminal")
            } description: {
                Text("You have sessions on other nodes.")
            } actions: {
                Button("Show all sessions") { showAllNodes = true }
            }
        } else {
            ContentUnavailableView {
                Label("No terminal sessions", systemImage: "apple.terminal")
            } description: {
                Text("Your live sessions, and those that ended in the last \(TerminalLimits.closedRetentionMinutes) minutes, appear here. Shells are opened on the web.")
            } actions: {
                Button("New session on web") { router.openOnWeb(.terminalNewSession(nodeID: nodeFilter)) }
            }
        }
    }

    private func row(_ session: TerminalSession) -> some View {
        let name = nodes.name(for: session.nodeID)
        return NavigationLink(value: AppRoute.terminal(.transcript(sessionID: session.id))) {
            TerminalSessionRow(session: session, nodeName: name, currentTokenID: store.currentTokenID)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if session.isLive, network.isSatisfied {
                Button("Close", systemImage: "xmark.square") { close(session, name: name) }
                    .tint(Color.destructiveFill)
            }
        }
        .contextMenu {
            Button("Open transcript", systemImage: "text.alignleft") { router.push(.terminal(.transcript(sessionID: session.id))) }
            Button("Copy link", systemImage: "link") { TerminalCopy.copy(TerminalCopy.link(sessionID: session.id)) }
            Button("Copy ID", systemImage: "number") { TerminalCopy.copy(session.id) }
            Button("Open on web", systemImage: "safari") { router.openOnWeb(.terminalSession(id: session.id)) }
            if session.isLive {
                Divider()
                TerminalGatedButton(title: "Close session", systemImage: "xmark.square",
                                    unavailable: network.isSatisfied ? nil : "No connection", role: .destructive) { close(session, name: name) }
            }
        }
        .accessibilityActions {
            Button("Copy link") { TerminalCopy.copy(TerminalCopy.link(sessionID: session.id)) }
            Button("Copy ID") { TerminalCopy.copy(session.id) }
            Button("Open on web") { router.openOnWeb(.terminalSession(id: session.id)) }
        }
    }

    private func close(_ session: TerminalSession, name: String) {
        Task { await runner.run(TerminalIntents.close(session, nodeName: name)) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                // A plus would promise creation here; this leaves the app.
                Button("New session on web", systemImage: "safari") { router.openOnWeb(.terminalNewSession(nodeID: nodeFilter)) }
                    .accessibilityHint("Opens the console's Terminal page in your browser")
                Button("Terminal audit trail", systemImage: "list.bullet.rectangle") {
                    router.select(tab: .activity, scope: "audit", query: "action:terminal.*", auditLayer: .all)
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    private func refresh() {
        Task { await store.refresh() }
    }
}
