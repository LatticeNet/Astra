import SwiftUI

/// M6-08 Geo-Routing: each routing with its hostname, strategy and the DNS
/// nodes that answer it. Gate geo:read.
struct GeoRoutingScreen: View {
    static let queryKey = "networking.geo.query"

    @Environment(NetworkingStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @SceneStorage(Self.queryKey) private var query = ""
    @State private var stable = NetworkingStableList<NetworkingGeoRouting>()

    var body: some View {
        NetworkingListState(state: store.geo, noun: "geo routings", web: LatticeConsolePath(path: "/network/geo-routing"),
                            retry: { Task { await store.refreshGeo() } }) { _ in
            list
        }
        .navigationTitle("Geo-Routing")
        .navigationSubtitle(query)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NetworkingMoreMenu(link: nil, web: LatticeConsolePath(path: "/network/geo-routing")) {
                    Button("Add a routing on web", systemImage: "plus") { router.openOnWeb(LatticeConsolePath(path: "/network/geo-routing")) }
                }
            }
        }
        .onChange(of: store.geo.loadedAt, initial: true) { offer(force: false) }
        .onChange(of: query) { offer(force: true) }
        .polling(.standard, version: changes.version([.geo, .nodes])) {
            await nodes.refreshIfOlder(than: 60)
            return await store.refreshGeo()
        }
    }

    private var filtered: (rows: [NetworkingGeoRouting], error: String?) {
        let all = (store.geo.value ?? []).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return (all, nil) }
        switch NetworkingQuery.geo(text) {
        case .success(let compiled): return (LatticeQueryEngine.apply(compiled, to: all, now: Date()), nil)
        case .failure(let error): return (all, NetworkingQuery.message(error, noun: "Routings"))
        }
    }

    private func offer(force: Bool) {
        stable.offer(filtered.rows, voiceOver: voiceOver, force: force)
    }

    private var list: some View {
        let shown = stable.shown
        return List {
            NetworkingRefreshError(state: store.geo, noun: "geo routings") { Task { await store.refreshGeo() } }
            NetworkingQueryError(message: filtered.error)
            if stable.held != nil, voiceOver {
                Section { PendingUpdatesRow(count: stable.pendingCount) { stable.showHeld() } }
            }
            if shown.isEmpty {
                Section {
                    if query.isEmpty {
                        ContentUnavailableView("No geo routings", systemImage: "globe.asia.australia",
                                               description: Text("A geo routing answers one hostname with the nearest healthy node. Routings are added on the web."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            } else {
                Section {
                    ForEach(shown) { routing in
                        NavigationLink(value: AppRoute.networking(.geoRoute(id: routing.id))) {
                            NetworkingGeoRow(routing: routing)
                        }
                        .contextMenu {
                            Button("Open", systemImage: "arrow.right.circle") { router.push(.networking(.geoRoute(id: routing.id))) }
                            Button("Copy link", systemImage: "link") { NetworkingCopy.copy(NetworkingCopy.link(.geoRoute(id: routing.id), fallback: "lattice://geo-routes/\(routing.id)")) }
                            Button("Copy ID", systemImage: "number") { NetworkingCopy.copy(routing.id) }
                            Button("Open on web", systemImage: "safari") { router.openOnWeb(.geoRoute(id: routing.id)) }
                        }
                    }
                } header: {
                    Text("Routings (\(shown.count))").accessibilityAddTraits(.isHeader)
                }
            }
            Section {} footer: {
                FreshnessFooter(state: store.geo, interval: Polling.standard.interval(lowPower: false))
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "host:, strategy:geoip, is:applied")
        .onScrollPhaseChange { _, phase in if phase != .idle { stable.noteActivity() } }
        .refreshable {
            await store.refreshGeo()
            offer(force: true)
        }
    }
}

struct NetworkingGeoRow: View {
    let routing: NetworkingGeoRouting

    var body: some View {
        let style = StatusStyle.networkingGeo(routing)
        let detail = "\(routing.hostname), \(routing.strategyWords)"
        StatusRow(style: style, title: routing.displayName, detail: detail,
                  reason: routing.lastError.isEmpty ? nil : routing.lastError,
                  trailing: NetworkingText.plural(routing.nodeIDs.count, "target"),
                  accessibilityPhrase: "\(routing.displayName), \(style.word), \(detail)")
    }
}
