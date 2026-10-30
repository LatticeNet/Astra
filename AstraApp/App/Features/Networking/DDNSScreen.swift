import SwiftUI

/// M6-06 DDNS: profiles in Failing, Stale and Current, judged against the
/// node's reported address. Swipe Run now (T3). Gate ddns:admin.
struct DDNSScreen: View {
    static let queryKey = "networking.ddns.query"

    @Environment(NetworkingStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @SceneStorage(Self.queryKey) private var query = ""
    @State private var stable = NetworkingStableList<NetworkingDDNSRow>()

    var body: some View {
        NetworkingListState(state: store.ddns, noun: "DDNS profiles", web: LatticeConsolePath(path: "/network/ddns"),
                            retry: { Task { await store.refreshDDNS() } }) { _ in
            list
        }
        .navigationTitle("DDNS")
        .navigationSubtitle(query)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NetworkingMoreMenu(link: nil, web: LatticeConsolePath(path: "/network/ddns")) {
                    Button("Add a profile on web", systemImage: "plus") { router.openOnWeb(LatticeConsolePath(path: "/network/ddns")) }
                }
            }
        }
        .onChange(of: store.ddns.loadedAt, initial: true) { offer(force: false) }
        .onChange(of: nodes.loadedAt) { offer(force: false) }
        .onChange(of: query) { offer(force: true) }
        .polling(.standard, version: changes.version([.ddns, .nodes])) {
            await nodes.refreshIfOlder(than: 60)
            return await store.refreshDDNS()
        }
    }

    private var allRows: [NetworkingDDNSRow] {
        let now = Date()
        return (store.ddns.value ?? []).map { NetworkingDDNSRow(profile: $0, node: nodes.nodes[$0.nodeID], now: now) }
            .sorted { ($0.rank, $0.name) < ($1.rank, $1.name) }
    }

    private var filtered: (rows: [NetworkingDDNSRow], error: String?) {
        let rows = allRows
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return (rows, nil) }
        switch NetworkingQuery.ddns(text) {
        case .success(let compiled):
            let kept = Set(LatticeQueryEngine.apply(compiled, to: rows.map(\.queryRow), now: Date()).map(\.profile.id))
            return (rows.filter { kept.contains($0.id) }, nil)
        case .failure(let error):
            return (rows, NetworkingQuery.message(error, noun: "Profiles"))
        }
    }

    private func offer(force: Bool) {
        stable.offer(filtered.rows, voiceOver: voiceOver, force: force)
    }

    private var list: some View {
        let shown = stable.shown
        return List {
            NetworkingRefreshError(state: store.ddns, noun: "DDNS profiles") { Task { await store.refreshDDNS() } }
            NetworkingQueryError(message: filtered.error)
            if stable.held != nil, voiceOver {
                Section { PendingUpdatesRow(count: stable.pendingCount) { stable.showHeld() } }
            }
            if shown.isEmpty {
                Section {
                    if query.isEmpty {
                        ContentUnavailableView("No DDNS profiles", systemImage: "arrow.triangle.2.circlepath.circle",
                                               description: Text("Profiles that keep a record pointed at a node are added on the web."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            ForEach(DDNSHealth.allCases.sorted { NetworkingDDNSRow.rank($0) < NetworkingDDNSRow.rank($1) }, id: \.self) { health in
                let rows = shown.filter { $0.health == health }
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { row in rowView(row) }
                    } header: {
                        Text("\(health.rawValue.sentenceCased) (\(rows.count))").accessibilityAddTraits(.isHeader)
                    } footer: {
                        if health == .stale {
                            Text("The node reports an address the profile has not written, and it has not run for twice its interval.")
                        }
                    }
                }
            }
            Section {} footer: {
                FreshnessFooter(state: store.ddns, interval: Polling.standard.interval(lowPower: false))
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Search, state:, domain:")
        .onScrollPhaseChange { _, phase in if phase != .idle { stable.noteActivity() } }
        .refreshable {
            await nodes.refreshIfOlder(than: 0)
            await store.refreshDDNS()
            offer(force: true)
        }
    }

    private func rowView(_ row: NetworkingDDNSRow) -> some View {
        let blocked = store.blocked(NetworkingIntents.ddnsRunScopes)
        return NavigationLink(value: AppRoute.networking(.ddnsProfile(id: row.id))) {
            NetworkingDDNSRowView(row: row)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if blocked == nil {
                Button("Run now", systemImage: "play.circle") { run(row) }
                    .tint(Color.accentFill)
            }
        }
        .contextMenu {
            Button("Open", systemImage: "arrow.right.circle") { router.push(.networking(.ddnsProfile(id: row.id))) }
            Button("Copy link", systemImage: "link") { NetworkingCopy.copy(NetworkingCopy.link(.ddnsProfile(id: row.id), fallback: "lattice://ddns/\(row.id)")) }
            Button("Copy ID", systemImage: "number") { NetworkingCopy.copy(row.id) }
            Button("Open on web", systemImage: "safari") { router.openOnWeb(.ddnsProfile(id: row.id)) }
            Divider()
            NetworkingGatedButton(title: "Run now", systemImage: "play.circle", blocked: blocked) { run(row) }
        }
    }

    private func run(_ row: NetworkingDDNSRow) {
        stable.setBusy(true)
        Task {
            await runner.run(NetworkingIntents.runDDNS(row.profile))
            stable.setBusy(false)
        }
    }
}

/// A DDNS profile with the health the list groups it by.
struct NetworkingDDNSRow: Identifiable, Sendable {
    let profile: DDNSProfile
    let nodeName: String
    let health: DDNSHealth
    let assessment: DDNSAssessment

    init(profile: DDNSProfile, node: LatticeNode?, now: Date) {
        self.profile = profile
        nodeName = node?.displayName ?? profile.nodeID
        let addresses = node.map {
            DDNSNodeAddresses(publicIPv4: $0.publicIP ?? "", publicIPv6: $0.publicIPv6 ?? "", down: !["online", "degraded"].contains($0.status))
        }
        assessment = profile.assess(node: addresses, now: now)
        health = profile.health(now: now, node: addresses)
    }

    var id: String { profile.id }
    var name: String { profile.name.isEmpty ? profile.id : profile.name }
    var rank: Int { Self.rank(health) }

    static func rank(_ health: DDNSHealth) -> Int {
        switch health {
        case .failing: 0
        case .stale: 1
        case .current: 2
        }
    }

    var queryRow: NetworkingQuery.DDNSRow { NetworkingQuery.DDNSRow(profile: profile, nodeName: nodeName, health: health) }

    /// "home.example.net +1".
    var recordText: String {
        guard let first = profile.domains.first else { return "no record" }
        return profile.domains.count > 1 ? "\(first) +\(profile.domains.count - 1)" : first
    }

    /// The reason line: the provider's words when failing, the move when stale.
    var reason: String? {
        switch health {
        case .failing: return NetworkingDDNSPreview.errorText(profile.lastError)
        case .stale:
            if let move = assessment.moved.first {
                return move.published.isEmpty ? "Node reports \(move.current); never written" : "Node reports \(move.current); record has \(move.published)"
            }
            return "No run for twice its interval"
        case .current: return nil
        }
    }
}

struct NetworkingDDNSRowView: View {
    let row: NetworkingDDNSRow
    @Environment(\.locale) private var locale

    var body: some View {
        let style = StatusStyle.networkingDDNS(row.health)
        let lastRun = row.profile.lastRunAt.map { "ran \(TimeDisplay.relative($0, now: .now, locale: locale))" } ?? "never ran"
        let detail = "\(row.recordText), \(row.nodeName), \(lastRun)"
        // Host names and node ids break at their separators, never at an inserted hyphen.
        let shown = "\(IdentifierText.breakable(row.recordText)), \(IdentifierText.breakable(row.nodeName)), \(lastRun)"
        StatusRow(style: style, title: row.name, detail: shown, reason: row.reason,
                  accessibilityPhrase: "\(row.name), \(style.word), \(detail)")
    }
}
