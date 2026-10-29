import SwiftUI

/// M3-02 Paths. A scope root, frozen as `init()`.
struct PathsScreen: View {
    var body: some View {
        MonitoringPathsList(isRoot: true)
    }
}

/// The Paths list views (section 5.4, M3-02).
enum MonitoringPathsView: String, CaseIterable, Hashable {
    case problems, all, chains

    var title: String {
        switch self {
        case .problems: "Problems"
        case .all: "All"
        case .chains: "Chains"
        }
    }
}

/// The Paths list, as the Monitor segment and as the filtered screen the
/// matrix headers push (`MonitoringRoute.paths(query:)`).
struct MonitoringPathsList: View {
    var isRoot = false
    var initialQuery: String?

    static let queryKey = "monitor.paths.query"
    static let viewKey = "monitor.paths.view"
    static let unmeasuredKey = "monitor.paths.unmeasured"

    @Environment(MonitoringStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(ChangeLog.self) private var changes
    @Environment(NodeDirectory.self) private var nodes
    @Environment(Router.self) private var router

    @SceneStorage(MonitoringPathsList.queryKey) private var rootQuery = ""
    @SceneStorage(MonitoringPathsList.viewKey) private var viewRaw = MonitoringPathsView.problems.rawValue
    @SceneStorage(MonitoringPathsList.unmeasuredKey) private var showUnmeasured = false
    @State private var pushedQuery = ""
    @State private var showUp = false

    private var view: MonitoringPathsView { isRoot ? (MonitoringPathsView(rawValue: viewRaw) ?? .problems) : .all }

    private var query: Binding<String> {
        isRoot ? $rootQuery : $pushedQuery
    }

    var body: some View {
        content
            .searchable(text: query, prompt: "source:, target:, state:, method:")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: isRoot ? .topBarLeading : .topBarTrailing) { viewMenu }
            }
            .onAppear(perform: consumeLinks)
            .onChange(of: appState.pendingQuery) { consumeLinks() }
            .onChange(of: appState.monitorView) { consumeLinks() }
            .polling(.paths, version: pollVersion) {
                await nodes.refreshIfOlder(than: 60)
                if view == .chains { await store.refreshChains() }
                return await store.refreshPaths(window: appState.monitorWindow)
            }
    }

    @ViewBuilder
    private var content: some View {
        if view == .chains {
            MonitoringChainsList()
        } else {
            MonitoringResource(state: store.paths, noun: "paths", retry: refresh) { _ in
                list
            }
        }
    }

    private var pollVersion: Int {
        changes.version([.paths, .vpn]) &* 32 &+ (MonitorWindow.allCases.firstIndex(of: appState.monitorWindow) ?? 0) &* 4 &+ (view == .chains ? 1 : 0)
    }

    private var subtitle: String {
        var parts: [String] = []
        if isRoot { parts.append(view.title) }
        if showUnmeasured { parts.append("with unmeasured") }
        let text = query.wrappedValue.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { parts.append(text) }
        return parts.joined(separator: ", ")
    }

    private var list: some View {
        let all = MonitoringPaths.visible(store.pathItems { nodes.nodes[$0]?.displayName }, showUnmeasured: showUnmeasured)
        let filtered = MonitoringQuery.filter(all, query: query.wrappedValue, provider: MonitoringPathQueryFields.self, now: Date())
        let groups = MonitoringPaths.groups(filtered.rows)
        return List {
            MonitoringRefreshError(state: store.paths, noun: "paths", retry: refresh)
            if let error = filtered.error {
                Section { MonitoringQueryErrorRow(message: error) }
            }
            if all.isEmpty {
                emptyState
            } else if groups.isEmpty {
                ContentUnavailableView.search(text: query.wrappedValue)
            }
            ForEach(groups, id: \.group) { entry in
                let collapsed = entry.group == .up && view == .problems && !showUp && query.wrappedValue.isEmpty
                Section {
                    if collapsed {
                        Button {
                            showUp = true
                        } label: {
                            HStack {
                                StatusRow(style: .path(.up), title: entry.items.count == 1 ? "1 path up" : "\(entry.items.count) paths up",
                                          accessibilityPhrase: "\(entry.items.count) paths up")
                                Text("Show").foregroundStyle(Color.accentText)
                            }
                        }
                        .tint(.primary)
                        .accessibilityHint("Lists the paths that are up")
                    } else {
                        ForEach(entry.items) { item in
                            NavigationLink(value: AppRoute.monitoring(.path(key: item.key))) {
                                MonitoringPathListRow(item: item)
                            }
                            .contextMenu {
                                MonitoringObjectMenu(route: .monitoring(.path(key: item.key)), link: .path(key: item.key), web: .path(key: item.key), objectID: item.key)
                                if !item.path.source.isEmpty {
                                    Button("Open source node", systemImage: "server.rack") { router.push(.fleet(.node(id: item.path.source))) }
                                }
                            } preview: {
                                MonitoringPathGlance(item: item)
                            }
                        }
                    }
                } header: {
                    Text("\(entry.group.title) (\(entry.items.count))").accessibilityAddTraits(.isHeader)
                } footer: {
                    if entry.group == groups.last?.group {
                        MonitoringFreshness(state: store.paths, cadence: .paths)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refreshPaths(window: appState.monitorWindow) }
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No paths measured", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
        } description: {
            Text("The latency plan has no pairs yet.")
        } actions: {
            Button("Latency plan on web") { router.openOnWeb(.monitoring(view: "topology")) }
        }
        Section {} footer: {
            MonitoringFreshness(state: store.paths, cadence: .paths)
        }
    }

    private var viewMenu: some View {
        Menu {
            if isRoot {
                Picker("View", selection: $viewRaw) {
                    ForEach(MonitoringPathsView.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            }
            Button("Matrix", systemImage: "square.grid.3x3") { router.push(.monitoring(.matrix)) }
            Button("Graph on web", systemImage: "safari") { router.openOnWeb(.monitoring(view: "topology")) }
            Divider()
            Toggle("Show unmeasured", systemImage: "eye", isOn: $showUnmeasured)
        } label: {
            Label("View", systemImage: showUnmeasured || view != .problems ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityValue(isRoot ? view.title : "All")
    }

    private func consumeLinks() {
        if !isRoot {
            if pushedQuery.isEmpty, let initialQuery { pushedQuery = initialQuery }
            return
        }
        if let linked = appState.monitorView, let wanted = MonitoringPathsView(rawValue: linked) {
            viewRaw = wanted.rawValue
            appState.monitorView = nil
        } else if appState.monitorView == "matrix" {
            // `lattice://monitor?segment=paths&view=matrix` opens the matrix over Paths.
            appState.monitorView = nil
            router.push(.monitoring(.matrix))
        }
        if let pending = appState.consumeQuery(MonitorSegment.paths.rawValue) {
            rootQuery = pending
        }
    }

    private func refresh() {
        Task { await store.refreshPaths(window: appState.monitorWindow) }
    }
}

/// The compact preview a path row's context menu shows.
struct MonitoringPathGlance: View {
    let item: MonitoringPathItem

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            MonitoringPathListRow(item: item)
            if let figures = MonitoringPaths.figures(item) { Text(figures).textRole(.metric) }
            Text("Window samples \(item.path.samples) of \(item.path.expected)").textRole(.rowDetail)
            Text(item.path.target).textRole(.identifierInRow).foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 320, alignment: .leading)
    }
}

/// The Chains view: each line chain as a vertical hop list (entry, relay,
/// exit) with the path state between hops.
struct MonitoringChainsList: View {
    @Environment(MonitoringStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes

    var body: some View {
        switch store.chains {
        case .denied(let scope):
            List {
                Section {
                    ScopeDeniedRow(scope: scope)
                } footer: {
                    Text("Line chains come from the vpn-core relay lines.")
                }
            }
            .listStyle(.insetGrouped)
        default:
            MonitoringResource(state: store.chains, noun: "line chains", retry: { Task { await store.refreshChains() } }) { rows in
                let chains = MonitoringChain.compose(rows)
                let items = store.pathItems { nodes.nodes[$0]?.displayName }
                List {
                    MonitoringRefreshError(state: store.chains, noun: "line chains") { Task { await store.refreshChains() } }
                    if chains.isEmpty {
                        ContentUnavailableView("No line chains", systemImage: "link", description: Text("No relay line forwards to another here."))
                    }
                    ForEach(chains) { chain in
                        Section {
                            NavigationLink(value: AppRoute.monitoring(.chain(id: chain.id))) {
                                StatusRow(style: MonitoringStyle.chain(chain.state), title: chainTitle(chain),
                                          detail: "\(chain.hops.count) hops", accessibilityPhrase: "Chain \(chainTitle(chain)), \(MonitoringStyle.chain(chain.state).word)")
                            }
                            ForEach(Array(chain.hops.enumerated()), id: \.element.id) { index, hop in
                                MonitoringHopRow(hop: hop, name: name(hop.nodeID), next: index + 1 < chain.hops.count ? chain.hops[index + 1] : nil,
                                                 nextName: index + 1 < chain.hops.count ? name(chain.hops[index + 1].nodeID) : nil, items: items)
                            }
                        }
                    }
                    Section {} footer: { MonitoringFreshness(state: store.chains, cadence: .paths) }
                }
                .listStyle(.insetGrouped)
                .refreshable { await store.refreshChains() }
            }
        }
    }

    private func name(_ id: String) -> String { nodes.name(for: id) }

    private func chainTitle(_ chain: MonitoringChain) -> String {
        guard let first = chain.hops.first, let last = chain.hops.last, chain.hops.count > 1 else { return chain.hops.first.map { name($0.nodeID) } ?? "Chain" }
        return "\(name(first.nodeID)) to \(name(last.nodeID))"
    }
}

/// One hop of a chain: its role and node, and the path to the next hop.
struct MonitoringHopRow: View {
    let hop: MonitoringChainHop
    let name: String
    let next: MonitoringChainHop?
    let nextName: String?
    let items: [MonitoringPathItem]

    var body: some View {
        let path = next.flatMap { next in items.first { $0.key == MonitoringChain.pathKey(from: hop, to: next) } }
        let role = hop.role.rawValue
        if let path {
            NavigationLink(value: AppRoute.monitoring(.path(key: path.key))) { row(path: path, role: role) }
        } else {
            row(path: nil, role: role)
        }
    }

    private func row(path: MonitoringPathItem?, role: String) -> some View {
        let style = path.map { StatusStyle.path($0.display) }
            ?? (next == nil ? StatusStyle(word: "", symbol: "flag.checkered", tone: .quiet) : StatusStyle(word: "not measured", symbol: "questionmark.circle", tone: .quiet))
        let detail = next.map { _ in path.flatMap { MonitoringStyle.figures($0) }.map { "to \(nextName ?? "") · \($0)" } ?? "to \(nextName ?? "")" }
        return StatusRow(
            style: style,
            title: "\(role.capitalized): \(name)",
            detail: detail,
            accessibilityPhrase: "\(role) \(name)" + (nextName.map { ", path to \($0) \(style.word)" } ?? "")
        )
    }
}
