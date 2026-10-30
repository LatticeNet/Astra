import SwiftUI

/// M6-04 Self-host DNS: deployments by standing, with drift, certificate
/// watch and publish errors in words. Gate dns:admin.
struct DNSScreen: View {
    static let queryKey = "networking.dns.query"

    @Environment(NetworkingStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @SceneStorage(Self.queryKey) private var query = ""
    @State private var stable = NetworkingStableList<NetworkingDNSDeployment>()

    var body: some View {
        NetworkingListState(state: store.deployments, noun: "DNS deployments", web: LatticeConsolePath(path: "/network/dns"),
                            retry: { Task { await store.refreshDNS() } }) { _ in
            list
        }
        .navigationTitle("Self-host DNS")
        .navigationSubtitle(query)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NetworkingMoreMenu(link: nil, web: LatticeConsolePath(path: "/network/dns")) {
                    Button("Add a deployment on web", systemImage: "plus") { router.openOnWeb(LatticeConsolePath(path: "/network/dns")) }
                }
            }
        }
        .onChange(of: store.deployments.loadedAt, initial: true) { offer(force: false) }
        .onChange(of: query) { offer(force: true) }
        .polling(.standard, version: changes.version([.dns, .nodes, .checks])) {
            await store.refreshDNS()
        }
    }

    private var filtered: (rows: [NetworkingDNSDeployment], error: String?) {
        let now = Date()
        let all = (store.deployments.value ?? []).sorted {
            ($0.health(now: now).rank, $0.displayName) < ($1.health(now: now).rank, $1.displayName)
        }
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return (all, nil) }
        switch NetworkingQuery.dns(text) {
        case .success(let compiled): return (LatticeQueryEngine.apply(compiled, to: all, now: now), nil)
        case .failure(let error): return (all, NetworkingQuery.message(error, noun: "Deployments"))
        }
    }

    private func offer(force: Bool) {
        stable.offer(filtered.rows, voiceOver: voiceOver, force: force)
    }

    private var list: some View {
        let now = Date()
        let shown = stable.shown
        let attention = shown.filter { $0.health(now: now).rank <= 1 }
        let rest = shown.filter { $0.health(now: now).rank > 1 }
        return List {
            NetworkingRefreshError(state: store.deployments, noun: "DNS deployments") { Task { await store.refreshDNS() } }
            NetworkingQueryError(message: filtered.error)
            if stable.held != nil, voiceOver {
                Section { PendingUpdatesRow(count: stable.pendingCount) { stable.showHeld() } }
            }
            if shown.isEmpty {
                Section {
                    if query.isEmpty {
                        ContentUnavailableView("No DNS deployments", systemImage: "globe",
                                               description: Text("Self-hosted resolvers are added on the web."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            section("Needs attention", attention, now: now)
            section("Deployments", rest, now: now)
            Section {} footer: {
                FreshnessFooter(state: store.deployments, interval: Polling.standard.interval(lowPower: false))
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "engine:external, is:drift, node:")
        .onScrollPhaseChange { _, phase in if phase != .idle { stable.noteActivity() } }
        .refreshable {
            await store.refreshDNS()
            offer(force: true)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [NetworkingDNSDeployment], now: Date) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { deployment in
                    NavigationLink(value: AppRoute.networking(.dnsDeployment(id: deployment.id))) {
                        NetworkingDNSRow(deployment: deployment, now: now)
                    }
                    .contextMenu {
                        Button("Open", systemImage: "arrow.right.circle") { router.push(.networking(.dnsDeployment(id: deployment.id))) }
                        Button("Copy link", systemImage: "link") { NetworkingCopy.copy(NetworkingCopy.link(.dnsDeployment(id: deployment.id), fallback: "lattice://dns/\(deployment.id)")) }
                        Button("Copy ID", systemImage: "number") { NetworkingCopy.copy(deployment.id) }
                        Button("Open on web", systemImage: "safari") { router.openOnWeb(.dnsDeployment(id: deployment.id)) }
                    }
                }
            } header: {
                Text("\(title) (\(rows.count))").accessibilityAddTraits(.isHeader)
            }
        }
    }
}

/// One deployment: its standing, node and listener, the reason when there
/// is a problem, and the certificate countdown when one is known.
struct NetworkingDNSRow: View {
    let deployment: NetworkingDNSDeployment
    let now: Date

    var body: some View {
        let health = deployment.health(now: now)
        let style = StatusStyle.networkingDNS(health)
        let detail = detailText
        StatusRow(style: style, title: deployment.displayName, detail: IdentifierText.breakable(detail), reason: health.reason,
                  accessibilityPhrase: "\(deployment.displayName), \(style.word), \(detail)")
    }

    private var detailText: String {
        let base = "\(deployment.nodeDisplayName), \(deployment.isExternal ? "observed" : deployment.listenSummary)"
        let cert = deployment.certState(now: now)
        if case .unknown = cert { return base }
        return "\(base), certificate \(cert.words)"
    }
}
