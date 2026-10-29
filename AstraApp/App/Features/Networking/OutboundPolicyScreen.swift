import SwiftUI

/// The three views of the outbound policy page (console `?view=`).
enum NetworkingOutboundView: String, CaseIterable, Hashable {
    case policies, nodes, matrix

    var title: String {
        switch self {
        case .policies: "Policies"
        case .nodes: "Nodes"
        case .matrix: "Matrix"
        }
    }
}

/// M6-01 Outbound policy: the outbound policies, what each node's document
/// holds, and the group-pair matrix as a list. Gate netpolicy:read.
struct OutboundPolicyScreen: View {
    /// A link may open one view; it is applied once and then the picker rules.
    var initialView: String?

    static let viewKey = "networking.outbound.view"
    static let queryKey = "networking.outbound.query"
    static let directionKey = "networking.outbound.direction"

    @Environment(NetworkingStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @SceneStorage(Self.viewKey) private var viewRaw = NetworkingOutboundView.policies.rawValue
    @SceneStorage(Self.queryKey) private var query = ""
    @SceneStorage(Self.directionKey) private var direction = "egress"
    @State private var width: CGFloat?
    @State private var stablePolicies = NetworkingStableList<NetworkingGroupPolicy>()
    @State private var stableNodes = NetworkingStableList<NetworkingNodePolicyRow>()
    @State private var appliedInitialView = false

    private var selected: NetworkingOutboundView { NetworkingOutboundView(rawValue: viewRaw) ?? .policies }

    var body: some View {
        decorated
            .toolbar { toolbar }
            .onChange(of: store.netPolicies.loadedAt) { offer(force: false) }
            .onChange(of: store.groupPolicies.loadedAt, initial: true) { offer(force: false) }
            .onChange(of: nodes.loadedAt) { offer(force: false) }
            .onChange(of: query) { offer(force: true) }
            .onChange(of: viewRaw) { offer(force: true) }
            .onAppear(perform: applyInitialView)
            .polling(.standard, version: pollVersion) { await refresh() }
    }

    private var decorated: some View {
        content
            .navigationTitle("Outbound policy")
            // Inline: a large title would sit under the picker bar's scroll edge effect.
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(subtitle)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .safeAreaBar(edge: .top) {
                if verticalSizeClass != .compact, !isDenied {
                    picker(width: width).padding(.horizontal, Spacing.l).padding(.bottom, Spacing.s)
                }
            }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if verticalSizeClass == .compact, !isDenied {
            ToolbarItem(placement: .topBarTrailing) { picker(width: typeSize.isAccessibilitySize ? 0 : width).frame(maxWidth: 320) }
        }
        ToolbarItem(placement: .topBarTrailing) {
            NetworkingMoreMenu(link: nil, web: webPath) {
                NetworkingGatedButton(title: "Plan all outbound policies", systemImage: "doc.badge.gearshape", blocked: planAllBlocked) { planAll() }
            }
        }
    }

    private var subtitle: String {
        guard selected == .matrix else { return query }
        return direction == "ingress" ? "Ingress" : "Egress"
    }

    private var webPath: LatticeConsolePath {
        selected == .policies ? LatticeConsolePath(path: "/network/outbound")
            : LatticeConsolePath(path: "/network/outbound", query: [URLQueryItem(name: "view", value: selected.rawValue)])
    }

    private func applyInitialView() {
        guard !appliedInitialView, let initialView else { return }
        appliedInitialView = true
        if initialView == "matrix-ingress" {
            viewRaw = NetworkingOutboundView.matrix.rawValue
            direction = "ingress"
        } else if let view = NetworkingOutboundView(rawValue: initialView) {
            viewRaw = view.rawValue
            if view == .matrix { direction = "egress" }
        }
    }

    private func refresh() async -> Bool {
        await nodes.refreshIfOlder(than: 60)
        if selected == .matrix {
            return await store.refreshMatrix(direction)
        }
        return await store.refreshPolicies()
    }

    /// The data version, with the matrix direction folded in so switching
    /// views or directions restarts the loop with an immediate read.
    private var pollVersion: Int {
        let mode = selected == .matrix ? (direction == "ingress" ? 2 : 1) : 0
        return changes.version([.policies, .nodes, .groups]) * 4 + mode
    }

    private var isDenied: Bool {
        if case .denied = store.netPolicies { return true }
        return false
    }

    private func picker(width: CGFloat?) -> some View {
        AdaptiveSegmentedPicker(
            title: "Outbound policy view",
            options: NetworkingOutboundView.allCases.map { ($0, $0.title) },
            selection: Binding(get: { selected }, set: { viewRaw = $0.rawValue }),
            containerWidth: width
        )
    }

    @ViewBuilder
    private var content: some View {
        switch selected {
        case .policies, .nodes:
            NetworkingListState(state: store.groupPolicies, noun: "outbound policies", web: LatticeConsolePath(path: "/network/outbound"),
                                retry: { Task { await store.refreshPolicies() } }) { _ in
                if selected == .policies { policiesList } else { nodesList }
            }
        case .matrix:
            NetworkingListState(state: store.matrix(direction), noun: "the policy matrix", web: LatticeConsolePath(path: "/network/outbound", query: [URLQueryItem(name: "view", value: "matrix")]),
                                retry: { Task { await store.refreshMatrix(direction) } }) { matrix in
                matrixList(matrix)
            }
        }
    }

    // MARK: Data

    private var docsByNode: [String: NetPolicy] {
        Dictionary((store.netPolicies.value ?? []).map { ($0.targetNodeID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func name(_ id: String) -> String {
        if let node = nodes.nodes[id] { return node.displayName }
        if let group = store.groupNames[id] { return group }
        return docsByNode[id]?.displayName ?? id
    }

    private var filteredPolicies: (rows: [NetworkingGroupPolicy], error: String?) {
        let all = (store.groupPolicies.value ?? []).sorted { ($0.enabled ? 0 : 1, $0.priority, $0.displayName) < ($1.enabled ? 0 : 1, $1.priority, $1.displayName) }
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return (all, nil) }
        switch NetworkingQuery.policies(text) {
        case .success(let compiled): return (LatticeQueryEngine.apply(compiled, to: all, now: Date()), nil)
        case .failure(let error): return (all, NetworkingQuery.message(error, noun: "Policies"))
        }
    }

    private var allNodeRows: [NetworkingNodePolicyRow] {
        NetworkingNodePolicyRow.rows(policies: store.netPolicies.value ?? [], nodes: nodes.nodes.values.map { ($0.id, $0.displayName) })
    }

    private var filteredNodes: (rows: [NetworkingNodePolicyRow], error: String?) {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return (allNodeRows, nil) }
        switch NetworkingQuery.nodes(text) {
        case .success(let compiled): return (LatticeQueryEngine.apply(compiled, to: allNodeRows, now: Date()), nil)
        case .failure(let error): return (allNodeRows, NetworkingQuery.message(error, noun: "Nodes"))
        }
    }

    private func offer(force: Bool) {
        stablePolicies.offer(filteredPolicies.rows, voiceOver: voiceOver, force: force)
        stableNodes.offer(filteredNodes.rows, voiceOver: voiceOver, force: force)
    }

    /// Failed and not-yet-applied documents among a policy's target nodes.
    private func counts(_ policy: NetworkingGroupPolicy) -> (failed: Int, pending: Int) {
        let docs = docsByNode
        var failed = 0, pending = 0
        for id in policy.targetNodeIDs {
            switch docs[id].map(NetworkingPolicyState.of) {
            case .failed: failed += 1
            case .planned, .notPlanned: pending += 1
            default: break
            }
        }
        return (failed, pending)
    }

    // MARK: Policies

    private var policiesList: some View {
        let shown = stablePolicies.shown
        let enabled = shown.filter(\.enabled)
        let disabled = shown.filter { !$0.enabled }
        return List {
            NetworkingRefreshError(state: store.groupPolicies, noun: "outbound policies") { Task { await store.refreshPolicies() } }
            NetworkingQueryError(message: filteredPolicies.error)
            if stablePolicies.held != nil, voiceOver {
                Section { PendingUpdatesRow(count: stablePolicies.pendingCount) { stablePolicies.showHeld() } }
            }
            if shown.isEmpty {
                Section {
                    if query.isEmpty {
                        ContentUnavailableView("No outbound policies", systemImage: "arrow.up.forward.circle",
                                               description: Text("Outbound policies are written on the web. Until one exists, each node keeps whatever document it has."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            policySection("Enabled", enabled)
            policySection("Disabled", disabled)
            if !enabled.isEmpty {
                Section {
                    NetworkingActionRow(title: "Plan all outbound policies", systemImage: "doc.badge.gearshape",
                                        detail: "Files one plan per covered node for approval", blocked: planAllBlocked) { planAll() }
                } footer: {
                    Text("Planning always covers every node any enabled policy reaches, not only one policy.")
                }
            }
            Section {} footer: {
                FreshnessFooter(state: store.groupPolicies, interval: Polling.standard.interval(lowPower: false))
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "name:, is:enabled, nodes>3")
        .onScrollPhaseChange { _, phase in if phase != .idle { stablePolicies.noteActivity() } }
        .refreshable {
            await store.refreshPolicies()
            offer(force: true)
        }
    }

    @ViewBuilder
    private func policySection(_ title: String, _ rows: [NetworkingGroupPolicy]) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { policy in
                    NavigationLink(value: AppRoute.networking(.policy(id: policy.id))) {
                        policyRow(policy)
                    }
                    .contextMenu {
                        Button("Open", systemImage: "arrow.right.circle") { router.push(.networking(.policy(id: policy.id))) }
                        Button("Copy link", systemImage: "link") { NetworkingCopy.copy(NetworkingCopy.link(.policy(id: policy.id), fallback: "lattice://policies/\(policy.id)")) }
                        Button("Copy ID", systemImage: "number") { NetworkingCopy.copy(policy.id) }
                        Button("Open on web", systemImage: "safari") { router.openOnWeb(.policy(id: policy.id)) }
                    }
                }
            } header: {
                Text("\(title) (\(rows.count))").accessibilityAddTraits(.isHeader)
            }
        }
    }

    private func policyRow(_ policy: NetworkingGroupPolicy) -> some View {
        let counts = counts(policy)
        let style = StatusStyle.networkingGroupPolicy(policy, failed: counts.failed, pending: counts.pending)
        let target = NetworkingText.target(policy.target, groupNames: store.groupNames, nodeName: name)
        let detail = "\(target), priority \(policy.priority)"
        let nodesText = NetworkingText.plural(policy.targetNodeIDs.count, "node")
        return StatusRow(style: style, title: policy.displayName, detail: detail, trailing: nodesText,
                         accessibilityPhrase: "\(policy.displayName), \(style.word), \(detail), \(nodesText)")
    }

    // MARK: Nodes

    private var nodesList: some View {
        let shown = stableNodes.shown
        let groups = Dictionary(grouping: shown) { row -> Int in
            switch row.state {
            case .failed: 0
            case .planned: 1
            case .notPlanned: 2
            case .applied: 3
            case .off: 4
            case nil: 5
            }
        }
        let titles = ["Apply failed", "Planned, not applied", "Not planned yet", "Applied", "Disabled", "No policy"]
        return List {
            NetworkingRefreshError(state: store.netPolicies, noun: "node policies") { Task { await store.refreshPolicies() } }
            NetworkingQueryError(message: filteredNodes.error)
            if stableNodes.held != nil, voiceOver {
                Section { PendingUpdatesRow(count: stableNodes.pendingCount) { stableNodes.showHeld() } }
            }
            if shown.isEmpty {
                Section {
                    if query.isEmpty {
                        ContentUnavailableView("No nodes", systemImage: "server.rack", description: Text("This token sees no node."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            ForEach(0..<titles.count, id: \.self) { index in
                if let rows = groups[index], !rows.isEmpty {
                    Section {
                        ForEach(rows) { row in
                            NavigationLink(value: AppRoute.networking(.nodePolicy(nodeID: row.nodeID))) {
                                StatusRow(style: .networkingNodePolicy(row), title: row.nodeName,
                                          detail: row.policy == nil ? "egress not filtered" : "\(row.kind.word), \(NetworkingText.plural(row.policy?.rules.count ?? 0, "rule"))",
                                          reason: row.policy.flatMap { $0.lastError.isEmpty ? nil : $0.lastError })
                            }
                        }
                    } header: {
                        Text("\(titles[index]) (\(rows.count))").accessibilityAddTraits(.isHeader)
                    } footer: {
                        if index == 5 { Text("No outbound policy reaches these nodes and none has its own, so nothing filters their egress.") }
                    }
                }
            }
            Section {} footer: {
                FreshnessFooter(state: store.netPolicies, interval: Polling.standard.interval(lowPower: false))
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "state:failed, kind:manual")
        .onScrollPhaseChange { _, phase in if phase != .idle { stableNodes.noteActivity() } }
        .refreshable {
            await nodes.refreshIfOlder(than: 0)
            await store.refreshPolicies()
            offer(force: true)
        }
    }

    // MARK: Matrix

    private func matrixList(_ matrix: NetworkingMatrix) -> some View {
        let rows = matrix.rows
        let ingress = direction == "ingress"
        return List {
            Section {
                AdaptiveSegmentedPicker(title: "Direction", options: [("egress", "Egress"), ("ingress", "Ingress")], selection: $direction, containerWidth: width)
                    .frame(minHeight: Spacing.minimumTarget)
            } footer: {
                Text(ingress ? "Who each targeted group admits, from the enabled policies' ingress rules." : "Where each targeted group may connect, from the enabled policies' egress rules. A policy that targets only nodes has no row.")
            }
            NetworkingRefreshError(state: store.matrix(direction), noun: "the matrix") { Task { await store.refreshMatrix(direction) } }
            if rows.isEmpty {
                Section {
                    ContentUnavailableView(ingress ? "No ingress rules" : "No group targets",
                                           systemImage: "square.grid.3x3",
                                           description: Text(ingress ? "No enabled policy that targets a node group has an ingress rule." : "No enabled policy targets a node group or the whole fleet."))
                }
            }
            ForEach(rows) { row in
                Section {
                    sourceRow(row, ingress: ingress)
                    ForEach(row.destinations, id: \.groupID) { destination in
                        destinationRow(destination, ingress: ingress)
                    }
                    if row.externalRules > 0 {
                        DetailRow(label: ingress ? "From outside the fleet" : "Outside the fleet", value: NetworkingText.plural(row.externalRules, "rule"), copyable: false)
                    }
                } footer: {
                    if !row.exclusions.isEmpty {
                        Text(row.exclusions.map { exclusion in
                            let names = exclusion.nodes.map(\.displayName)
                            let hidden = exclusion.hidden > 0 ? " and \(NetworkingText.plural(exclusion.hidden, "node")) this token cannot see" : ""
                            return "\(exclusion.label) leaves out \(ListFormatter.localizedString(byJoining: names))\(hidden)."
                        }.joined(separator: " "))
                    }
                }
            }
            Section {} footer: {
                FreshnessFooter(state: store.matrix(direction), interval: Polling.standard.interval(lowPower: false))
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refreshMatrix(direction) }
    }

    @ViewBuilder
    private func sourceRow(_ row: NetworkingMatrixRow, ingress: Bool) -> some View {
        let sentence = row.reachSentence(direction: direction)
        let style = StatusStyle(word: sentence, symbol: row.sourceID == nil ? "globe" : "square.stack.3d.up", tone: .quiet)
        let label = StatusRow(style: style, title: row.sourceName,
                              detail: row.excludedCount > 0 ? "\(NetworkingText.plural(row.excludedCount, "node")) left out" : nil,
                              accessibilityPhrase: "\(row.sourceName) \(sentence)")
            .accessibilityAddTraits(.isHeader)
        if let groupID = row.sourceID {
            NavigationLink(value: AppRoute.fleet(.group(id: groupID))) { label }
        } else {
            label
        }
    }

    private func destinationRow(_ destination: NetworkingMatrixRow.Destination, ingress: Bool) -> some View {
        let cell = destination.cell
        let style: StatusStyle = cell.mixed
            ? StatusStyle(word: "allow and deny", symbol: "circle.lefthalf.filled", tone: .quiet)
            : (cell.allows ? StatusStyle(word: "allow", symbol: "checkmark.circle", tone: .quiet) : StatusStyle(word: "deny", symbol: "nosign", tone: .quiet))
        let title = "\(ingress ? "From" : "To") \(destination.name)"
        return StatusRow(style: style, title: title, detail: cell.trafficText, trailing: NetworkingText.plural(cell.ruleCount, "rule"),
                         accessibilityPhrase: "\(title), \(style.word), \(cell.trafficText)")
    }

    // MARK: Plan all

    private var coveredNodes: [ObjectRef] {
        let ids = Set((store.groupPolicies.value ?? []).filter(\.enabled).flatMap(\.targetNodeIDs))
        return ids.map { ObjectRef(kind: "node", id: $0, name: name($0)) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var planAllBlocked: String? {
        if let blocked = store.blocked([NetworkingIntents.policyAdmin]) { return blocked }
        if store.groupPolicies.value == nil { return "Loading outbound policies" }
        return coveredNodes.isEmpty ? "No enabled policy covers a node" : nil
    }

    private func planAll() {
        Task { await runner.run(NetworkingIntents.planAllGroupPolicies(covered: coveredNodes)) }
    }
}
