import SwiftUI

/// M6-12 Inbound firewall (`latticenet.netguard`): each node's binding and
/// whether its ruleset is enforced, the security groups, zones and the
/// node-group bindings. Opened with a node id it shows that node. Gate
/// netguard:read; groups, zones and node-group bindings are fleet-wide and
/// need a token without a node allowlist (node-group bindings also group:read).
/// Every write is on the web.
struct InboundFirewallScreen: View {
    let nodeID: String?

    static let queryKey = "networking.firewall.query"
    static let pluginPage = LatticeConsolePath(path: "/plugins/latticenet.netguard/firewall")

    @Environment(NetworkingStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    @SceneStorage(Self.queryKey) private var query = ""
    @State private var stable = NetworkingStableList<NetworkingNodeGuard>()

    var body: some View {
        NetworkingListState(state: store.guardNodes, noun: "the inbound firewall", web: Self.pluginPage,
                            retry: { Task { await store.refreshFirewall() } }) { guardNodes in
            if let nodeID {
                nodeView(nodeID, guardNodes.first { $0.nodeID == nodeID })
            } else {
                fleetView
            }
        }
        .navigationTitle(nodeID.map { nodes.name(for: $0) } ?? "Inbound firewall")
        .navigationBarTitleDisplayMode(nodeID == nil ? .automatic : .inline)
        .navigationSubtitle(nodeID == nil ? query : "Inbound firewall")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NetworkingMoreMenu(link: nil, web: Self.pluginPage) {
                    Button("Open plugin page on web", systemImage: "safari") { router.openOnWeb(Self.pluginPage) }
                    if let nodeID {
                        Button("Open node", systemImage: "server.rack") { router.push(.fleet(.node(id: nodeID))) }
                    }
                }
            }
        }
        .onChange(of: store.guardNodes.loadedAt, initial: true) { offer(force: false) }
        .onChange(of: query) { offer(force: true) }
        .polling(.standard, version: changes.version([.netguard, .nodes, .groups])) {
            await nodes.refreshIfOlder(than: 60)
            return await store.refreshFirewall()
        }
    }

    // MARK: Fleet

    private var filtered: (rows: [NetworkingNodeGuard], error: String?) {
        let rank: (NetworkingGuardState) -> Int = { NetworkingGuardState.allCases.firstIndex(of: $0) ?? 9 }
        let all = (store.guardNodes.value ?? []).sorted { (rank($0.state), $0.displayName) < (rank($1.state), $1.displayName) }
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return (all, nil) }
        switch NetworkingQuery.guardNodes(text) {
        case .success(let compiled): return (LatticeQueryEngine.apply(compiled, to: all, now: Date()), nil)
        case .failure(let error): return (all, NetworkingQuery.message(error, noun: "Nodes"))
        }
    }

    private func offer(force: Bool) {
        stable.offer(filtered.rows, voiceOver: voiceOver, force: force)
    }

    private var fleetView: some View {
        let shown = stable.shown
        return List {
            NetworkingRefreshError(state: store.guardNodes, noun: "firewall nodes") { Task { await store.refreshFirewall() } }
            NetworkingQueryError(message: filtered.error)
            if stable.held != nil, voiceOver {
                Section { PendingUpdatesRow(count: stable.pendingCount) { stable.showHeld() } }
            }
            Section {
                if shown.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("No node has a firewall binding", systemImage: "shield.lefthalf.filled",
                                               description: Text("NetGuard lists a node once it has a binding or a legacy ruleset."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
                ForEach(shown) { node in
                    NavigationLink(value: AppRoute.networking(.inboundFirewall(nodeID: node.nodeID))) {
                        NetworkingGuardNodeRow(node: node)
                    }
                    .contextMenu {
                        Button("Open", systemImage: "arrow.right.circle") { router.push(.networking(.inboundFirewall(nodeID: node.nodeID))) }
                        Button("Open node", systemImage: "server.rack") { router.push(.fleet(.node(id: node.nodeID))) }
                        Button("Copy ID", systemImage: "number") { NetworkingCopy.copy(node.nodeID) }
                    }
                }
            } header: {
                Text("Nodes (\(shown.count))").accessibilityAddTraits(.isHeader)
            } footer: {
                if store.isConfined { Text("Only the nodes this token is confined to are listed.") }
            }
            groupsSection(store.guardGroups.value ?? [])
            zonesSection
            bindingsSection
            Section {
                WebLinkRow(title: "Open plugin page on web", path: Self.pluginPage)
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Adopting a node, editing groups and zones, and filing firewall plans are done on the web.")
                    FreshnessFooter(state: store.guardNodes, interval: Polling.standard.interval(lowPower: false))
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Search, state:, group:")
        .onScrollPhaseChange { _, phase in if phase != .idle { stable.noteActivity() } }
        .refreshable {
            await store.refreshFirewall()
            offer(force: true)
        }
    }

    @ViewBuilder
    private func groupsSection(_ groups: [NetworkingSecurityGroup]) -> some View {
        Section {
            if store.isConfined {
                NetworkingConfinedRow(what: "security groups")
            } else {
                switch store.guardGroups {
                case .denied(let scope): ScopeDeniedRow(scope: scope)
                case .companionBehind(let surface): CompanionBehindRow(surface: surface)
                case .failed(let error, nil, _): ErrorRow(message: "Could not load security groups: \(error.localizedDescription)") { Task { await store.refreshFirewall() } }
                default:
                    NetworkingRefreshError(state: store.guardGroups, noun: "security groups") { Task { await store.refreshFirewall() } }
                    if store.guardGroups.value == nil {
                        LoadingRows(label: "Loading security groups", count: 2)
                    } else if groups.isEmpty {
                        Text("No security groups").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
                    }
                    ForEach(groups) { group in
                        NavigationLink(value: AppRoute.networking(.securityGroup(id: group.id))) {
                            NetworkingSecurityGroupRow(group: group, boundCount: snapshot.boundNodes(of: group.id).count)
                        }
                    }
                }
            }
        } header: {
            Text("Security groups").accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private var zonesSection: some View {
        Section {
            if store.isConfined {
                NetworkingConfinedRow(what: "zones")
            } else {
                switch store.guardZones {
                case .denied(let scope): ScopeDeniedRow(scope: scope)
                case .companionBehind(let surface): CompanionBehindRow(surface: surface)
                case .failed(let error, nil, _): ErrorRow(message: "Could not load zones: \(error.localizedDescription)") { Task { await store.refreshFirewall() } }
                default:
                    NetworkingRefreshError(state: store.guardZones, noun: "zones") { Task { await store.refreshFirewall() } }
                    if store.guardZones.value == nil {
                        LoadingRows(label: "Loading zones", count: 2)
                    } else if store.guardZones.value?.isEmpty ?? false {
                        Text("No zones").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
                    }
                    ForEach(store.guardZones.value ?? []) { zone in
                        NetworkingZoneRow(zone: zone)
                    }
                }
            }
        } header: {
            Text("Zones").accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private var bindingsSection: some View {
        Section {
            if store.isConfined {
                NetworkingConfinedRow(what: "node-group bindings")
            } else {
                switch store.nodeGroupBindings {
                case .denied(let scope): ScopeDeniedRow(scope: scope)
                case .companionBehind(let surface): CompanionBehindRow(surface: surface)
                case .failed(let error, nil, _): ErrorRow(message: "Could not load node-group bindings: \(error.localizedDescription)") { Task { await store.refreshFirewall() } }
                default:
                    if store.nodeGroupBindings.value == nil { LoadingRows(label: "Loading node-group bindings", count: 1) }
                    if store.nodeGroupBindings.value?.isEmpty == true {
                        Text("No security group is bound to a node group").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
                    }
                    ForEach(store.nodeGroupBindings.value ?? []) { binding in
                        NavigationLink(value: AppRoute.fleet(.group(id: binding.groupID))) {
                            StatusRow(style: StatusStyle(word: "\(binding.activeCount) of \(binding.members.count) members enforced", symbol: "square.stack.3d.up", tone: .quiet),
                                      title: binding.displayName,
                                      detail: ListFormatter.localizedString(byJoining: binding.securityGroupIDs.map { snapshot.group(id: $0)?.displayName ?? $0 }))
                        }
                    }
                }
            }
        } header: {
            Text("Node-group bindings").accessibilityAddTraits(.isHeader)
        } footer: {
            Text("A member NetGuard does not manage gets nothing from its node group's binding until it is adopted.")
        }
    }

    private var snapshot: NetworkingFirewallSnapshot {
        NetworkingFirewallSnapshot(groups: store.guardGroups.value ?? [], zones: store.guardZones.value ?? [],
                                   nodes: store.guardNodes.value ?? [], nodeGroupBindings: store.nodeGroupBindings.value ?? [])
    }

    // MARK: One node

    @ViewBuilder
    private func nodeView(_ id: String, _ node: NetworkingNodeGuard?) -> some View {
        List {
            NetworkingRefreshError(state: store.guardNodes, noun: "the firewall") { Task { await store.refreshFirewall() } }
            if let node {
                Section {
                    NetworkingGuardNodeRow(node: node)
                }
                Section("Binding") {
                    DetailRow(label: "NetGuard", value: node.binding.managed ? "Writes this node's ruleset" : (node.source == "legacy" ? "Not adopted: a legacy ruleset runs" : "Observes only"), copyable: false)
                    if let applied = node.binding.lastAppliedAt {
                        DetailRow(label: "Last applied", value: TimeDisplay.dateTime(applied, mode: mode, locale: locale),
                                  secondary: TimeDisplay.otherZone(applied, mode: mode, locale: locale), copyable: false)
                    }
                    if !node.binding.lastPlanSHA.isEmpty {
                        DetailRow(label: "Last plan", value: node.binding.lastPlanSHA, monospaced: true)
                    }
                    if !node.binding.lastError.isEmpty {
                        DetailRow(label: "Last error", value: node.binding.lastError)
                    }
                    if !node.binding.overrides.isEmpty {
                        DetailRow(label: "Node overrides", value: NetworkingText.plural(node.binding.overrides.count, "rule"), copyable: false)
                    }
                }
                Section {
                    if node.groups.isEmpty && node.derivedGroups.isEmpty {
                        Text("No security group applies to this node.").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
                    }
                    ForEach(node.groups) { group in
                        NavigationLink(value: AppRoute.networking(.securityGroup(id: group.id))) {
                            NetworkingSecurityGroupRow(group: group, boundCount: nil)
                        }
                    }
                    ForEach(node.derivedGroups) { group in
                        NavigationLink(value: AppRoute.networking(.securityGroup(id: group.id))) {
                            NetworkingSecurityGroupRow(group: group, boundCount: nil)
                        }
                    }
                } header: {
                    Text("Security groups")
                } footer: {
                    Text("Groups bound to the node first, then those its node groups bind, in compile order.")
                }
                if !node.zones.isEmpty {
                    Section("Zones") {
                        ForEach(node.zones) { NetworkingZoneRow(zone: $0) }
                    }
                }
            } else {
                Section {
                    Text("\(nodes.name(for: id)) has no NetGuard binding and no legacy ruleset, or this token cannot read it.")
                        .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                }
            }
            Section {
                NetworkingNodeLink(nodeID: id)
                WebLinkRow(title: "Open plugin page on web", path: Self.pluginPage)
            } footer: {
                FreshnessFooter(state: store.guardNodes, interval: Polling.standard.interval(lowPower: false))
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refreshFirewall() }
    }
}

struct NetworkingGuardNodeRow: View {
    let node: NetworkingNodeGuard

    var body: some View {
        let style = StatusStyle.networkingGuard(node.state)
        let groups = (node.groups + node.derivedGroups).map(\.displayName)
        let detail = groups.isEmpty ? "no security group" : ListFormatter.localizedString(byJoining: groups)
        StatusRow(style: style, title: node.displayName, detail: detail,
                  reason: node.binding.lastError.isEmpty ? nil : node.binding.lastError,
                  accessibilityPhrase: "\(node.displayName), \(style.word), \(detail)")
    }
}

struct NetworkingSecurityGroupRow: View {
    let group: NetworkingSecurityGroup
    /// Nodes it reaches, when the list knows.
    let boundCount: Int?

    var body: some View {
        var parts = [NetworkingText.plural(group.visibleRuleCount, "rule")]
        if group.isLegacy { parts.append("legacy baseline") }
        if !group.viaNodeGroupName.isEmpty { parts.append("via \(group.viaNodeGroupName)") }
        if group.inactive { parts.append("inactive here") }
        let style = StatusStyle(word: group.inactive ? "inactive" : "", symbol: group.isLegacy ? "shield.lefthalf.filled" : "shield", tone: .quiet)
        let trailing = boundCount.map { NetworkingText.plural($0, "node") }
        return StatusRow(style: style, title: group.displayName, detail: parts.joined(separator: ", "), trailing: trailing,
                         accessibilityPhrase: ([group.displayName] + parts + [trailing].compactMap { $0 }).joined(separator: ", "))
    }
}

struct NetworkingZoneRow: View {
    let zone: NetworkingGuardZone

    var body: some View {
        StatusRow(style: StatusStyle(word: zone.builtin ? "built in" : "", symbol: "circle.dashed.inset.filled", tone: .quiet),
                  title: zone.displayName, detail: zone.summary,
                  accessibilityPhrase: ([zone.displayName, zone.builtin ? "built in" : "", zone.summary].filter { !$0.isEmpty }).joined(separator: ", "))
    }
}
