import SwiftUI

/// M6-10 Tunnels: cloudflared tunnel profiles with their node and ingress.
/// Gate tunnel:admin.
struct TunnelsScreen: View {
    static let queryKey = "networking.tunnels.query"

    @Environment(NetworkingStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @SceneStorage(Self.queryKey) private var query = ""
    @State private var stable = NetworkingStableList<TunnelProfile>()

    var body: some View {
        NetworkingListState(state: store.tunnels, noun: "tunnels", web: LatticeConsolePath(path: "/network/tunnels"),
                            retry: { Task { await store.refreshTunnels() } }) { _ in
            list
        }
        .navigationTitle("Tunnels")
        .navigationSubtitle(query)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NetworkingMoreMenu(link: nil, web: LatticeConsolePath(path: "/network/tunnels")) {
                    Button("Create a tunnel on web", systemImage: "plus") { router.openOnWeb(LatticeConsolePath(path: "/network/tunnels")) }
                }
            }
        }
        .onChange(of: store.tunnels.loadedAt, initial: true) { offer(force: false) }
        .onChange(of: nodes.loadedAt) { offer(force: false) }
        .onChange(of: query) { offer(force: true) }
        .polling(.standard, version: changes.version([.tunnels, .nodes])) {
            await nodes.refreshIfOlder(than: 60)
            return await store.refreshTunnels()
        }
    }

    private var filtered: (rows: [TunnelProfile], error: String?) {
        let all = (store.tunnels.value ?? []).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return (all, nil) }
        switch NetworkingQuery.tunnels(text) {
        case .success(let compiled):
            let rows = all.map { NetworkingQuery.TunnelRow(tunnel: $0, nodeName: nodes.name(for: $0.nodeID)) }
            return (LatticeQueryEngine.apply(compiled, to: rows, now: Date()).map(\.tunnel), nil)
        case .failure(let error):
            return (all, NetworkingQuery.message(error, noun: "Tunnels"))
        }
    }

    private func offer(force: Bool) {
        stable.offer(filtered.rows, voiceOver: voiceOver, force: force)
    }

    private var list: some View {
        let shown = stable.shown
        return List {
            NetworkingRefreshError(state: store.tunnels, noun: "tunnels") { Task { await store.refreshTunnels() } }
            NetworkingQueryError(message: filtered.error)
            if stable.held != nil, voiceOver {
                Section { PendingUpdatesRow(count: stable.pendingCount) { stable.showHeld() } }
            }
            if shown.isEmpty {
                Section {
                    if query.isEmpty {
                        ContentUnavailableView("No tunnels", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                               description: Text("cloudflared tunnel profiles are created on the web."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            } else {
                Section {
                    ForEach(shown) { tunnel in
                        NavigationLink(value: AppRoute.networking(.tunnel(id: tunnel.id))) {
                            NetworkingTunnelRow(tunnel: tunnel)
                        }
                        .contextMenu {
                            Button("Open", systemImage: "arrow.right.circle") { router.push(.networking(.tunnel(id: tunnel.id))) }
                            Button("Copy link", systemImage: "link") { NetworkingCopy.copy(NetworkingCopy.link(.tunnel(id: tunnel.id), fallback: "lattice://tunnels/\(tunnel.id)")) }
                            Button("Copy ID", systemImage: "number") { NetworkingCopy.copy(tunnel.id) }
                            Button("Open on web", systemImage: "safari") { router.openOnWeb(.tunnel(id: tunnel.id)) }
                        }
                    }
                } header: {
                    Text("Tunnels (\(shown.count))").accessibilityAddTraits(.isHeader)
                }
            }
            Section {} footer: {
                FreshnessFooter(state: store.tunnels, interval: Polling.standard.interval(lowPower: false))
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Search, host:, node:")
        .onScrollPhaseChange { _, phase in if phase != .idle { stable.noteActivity() } }
        .refreshable {
            await store.refreshTunnels()
            offer(force: true)
        }
    }
}

/// One tunnel: its node's honesty carries the state, since the profile has none of its own.
struct NetworkingTunnelRow: View {
    let tunnel: TunnelProfile
    @Environment(NodeDirectory.self) private var nodes

    var body: some View {
        let node = nodes.nodes[tunnel.nodeID]
        let style: StatusStyle = node.map {
            var style = StatusStyle.node($0.honesty)
            style.word = "node \(style.word)"
            return style
        } ?? StatusStyle(word: "node unknown", symbol: "questionmark.circle", tone: .quiet)
        let hosts = tunnel.ingress.map(\.hostname).filter { !$0.isEmpty }
        let detail = "\(nodes.name(for: tunnel.nodeID)), \(hosts.first.map { hosts.count > 1 ? "\($0) +\(hosts.count - 1)" : $0 } ?? "no hostname")"
        StatusRow(style: style, title: tunnel.displayName, detail: detail, trailing: NetworkingText.plural(tunnel.ingress.count, "rule"),
                  accessibilityPhrase: "\(tunnel.displayName), \(style.word), \(detail), \(NetworkingText.plural(tunnel.ingress.count, "ingress rule"))")
    }
}
