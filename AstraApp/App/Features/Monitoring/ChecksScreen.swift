import SwiftUI

/// M3-06 Checks. A scope root, frozen as `init()`. Failing checks first, then
/// the operator's checks by type, the generated ones collapsed, and the
/// check definitions.
struct ChecksScreen: View {
    static let queryKey = "monitor.checks.query"

    @Environment(MonitoringStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(ChangeLog.self) private var changes
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @SceneStorage(ChecksScreen.queryKey) private var query = ""
    @State private var stable = MonitoringStableList<MonitoringCheckItem>()
    @State private var showGenerated = false

    var body: some View {
        MonitoringResource(state: store.monitors, noun: "checks", retry: refresh) { _ in
            list
        }
        .searchable(text: $query, prompt: "type:, node:, state:")
        .navigationSubtitle(query.isEmpty ? "" : query)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("New check on web", systemImage: "plus") { router.openOnWeb(.monitoring(view: "checks")) }
            }
        }
        .onAppear(perform: consumeQuery)
        .onChange(of: appState.pendingQuery) { consumeQuery() }
        .onChange(of: store.monitors.loadedAt) { offer(force: false) }
        .onChange(of: store.paths.loadedAt) { offer(force: false) }
        .onChange(of: query) { offer(force: true) }
        .onAppear { offer(force: true) }
        .polling(.monitoring, version: changes.version([.checks, .definitions, .paths]) &* 8 &+ (MonitorWindow.allCases.firstIndex(of: appState.monitorWindow) ?? 0)) {
            await nodes.refreshIfOlder(than: 60)
            // The paths read carries the verdict each check's health folds in.
            let paths = Task { await store.refreshPaths(window: appState.monitorWindow) }
            let checks = await store.refreshChecks()
            return await paths.value && checks
        }
    }

    private var items: [MonitoringCheckItem] {
        let now = Date()
        let all = (store.monitors.value ?? []).map { monitor in
            let health = store.health(of: monitor, now: now)
            let names = (monitor.nodeIDs + monitor.latest.map(\.nodeID)).filter { !$0.isEmpty }.map { nodes.name(for: $0) }
            return MonitoringCheckItem(monitor: monitor, health: health, nodeNames: Array(Set(names)).sorted())
        }
        let filtered = MonitoringQuery.filter(all, query: query, provider: MonitoringCheckQueryFields.self, now: now).rows
        return filtered.sorted { a, b in
            a.health.rank != b.health.rank ? a.health.rank < b.health.rank
                : a.monitor.displayName.localizedStandardCompare(b.monitor.displayName) == .orderedAscending
        }
    }

    private func offer(force: Bool) {
        stable.offer(items, voiceOver: voiceOver, force: force)
    }

    private var queryError: String? {
        MonitoringQuery.filter([MonitoringCheckItem](), query: query, provider: MonitoringCheckQueryFields.self, now: Date()).error
    }

    private var list: some View {
        let shown = stable.shown
        let failing = shown.filter(\.health.isFailing)
        let attention = shown.filter { !$0.health.isFailing && $0.health.rank <= 2 }
        let rest = shown.filter { $0.health.rank > 2 }
        let operatorChecks = rest.filter { !$0.monitor.isGenerated }
        let generated = rest.filter { $0.monitor.isGenerated }
        let byType = Dictionary(grouping: operatorChecks) { $0.monitor.typeWord }
        let types = MonitorType.allCases.map(\.rawValue).filter { byType[$0] != nil } + byType.keys.filter { MonitorType(rawValue: $0) == nil }.sorted()
        return List {
            MonitoringRefreshError(state: store.monitors, noun: "checks", retry: refresh)
            if let queryError { Section { MonitoringQueryErrorRow(message: queryError) } }
            if stable.held != nil {
                Section {
                    PendingUpdatesRow(count: stable.pendingCount) { stable.showHeld() }
                }
            }
            if shown.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView {
                        Label("No checks", systemImage: "checklist")
                    } description: {
                        Text("Nothing is checked yet.")
                    } actions: {
                        Button("New check on web") { router.openOnWeb(.monitoring(view: "checks")) }
                    }
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
            if !failing.isEmpty {
                Section {
                    ForEach(failing) { row($0) }
                } header: {
                    Text("Failing (\(failing.count))").accessibilityAddTraits(.isHeader)
                }
            }
            if !attention.isEmpty {
                Section {
                    ForEach(attention) { row($0) }
                } header: {
                    Text("Degraded or stale (\(attention.count))").accessibilityAddTraits(.isHeader)
                }
            }
            ForEach(types, id: \.self) { type in
                let members = byType[type] ?? []
                Section {
                    ForEach(members) { row($0) }
                } header: {
                    Text("\((MonitorType(rawValue: type)?.displayName ?? type)) (\(members.count))").accessibilityAddTraits(.isHeader)
                }
            }
            if !generated.isEmpty {
                Section {
                    if showGenerated || !query.isEmpty {
                        ForEach(generated) { row($0) }
                    } else {
                        Button {
                            showGenerated = true
                        } label: {
                            HStack {
                                Text(generated.count == 1 ? "1 check" : "\(generated.count) checks")
                                Spacer()
                                Text("Show").foregroundStyle(Color.accentText)
                            }
                            .frame(minHeight: Spacing.minimumTarget)
                        }
                        .tint(.primary)
                        .accessibilityLabel("\(generated.count) generated checks. Show")
                    }
                } header: {
                    Text("Generated by definitions and probes").accessibilityAddTraits(.isHeader)
                } footer: {
                    Text("Change these through the definition or probe configuration that made them.")
                }
            }
            definitionsSection
            Section {} footer: { MonitoringFreshness(state: store.monitors, cadence: .monitoring) }
        }
        .listStyle(.insetGrouped)
        .onScrollPhaseChange { _, phase in
            if phase != .idle { stable.noteActivity() }
        }
        .refreshable {
            async let paths = store.refreshPaths(window: appState.monitorWindow)
            await store.refreshChecks()
            _ = await paths
            offer(force: true)
        }
    }

    @ViewBuilder
    private var definitionsSection: some View {
        switch store.definitions {
        case .denied(let scope):
            Section { ScopeDeniedRow(scope: scope) } header: { Text("Definitions").accessibilityAddTraits(.isHeader) }
        case .companionBehind(let surface):
            Section { CompanionBehindRow(surface: surface) } header: { Text("Definitions").accessibilityAddTraits(.isHeader) }
        default:
            if let list = store.definitions.value, !list.definitions.isEmpty {
                Section {
                    ForEach(list.definitions) { definition in
                        NavigationLink(value: AppRoute.monitoring(.definition(id: definition.id))) {
                            StatusRow(
                                style: definition.enabled
                                    ? StatusStyle(word: "enabled", symbol: "square.stack.3d.up", tone: .quiet)
                                    : StatusStyle(word: "paused", symbol: "pause.circle", tone: .quiet),
                                title: definition.displayName,
                                detail: definitionDetail(definition),
                                accessibilityPhrase: "Definition \(definition.displayName)"
                            )
                        }
                        .contextMenu {
                            MonitoringObjectMenu(route: .monitoring(.definition(id: definition.id)), link: .definition(id: definition.id),
                                                 web: .definition(id: definition.id), objectID: definition.id)
                        }
                    }
                } header: {
                    Text("Definitions").accessibilityAddTraits(.isHeader)
                }
            } else if case .failed(let error, nil, _) = store.definitions {
                Section { ErrorRow(message: "Could not load definitions: \(error.localizedDescription)", retry: refresh) }
            }
        }
    }

    private func definitionDetail(_ definition: MonitoringCheckDefinition) -> String {
        var parts = [definition.type]
        if let summary = definition.summary {
            parts.append(summary.paths == 1 ? "1 path" : "\(summary.paths) paths")
            if summary.pausedTargets > 0 { parts.append("\(summary.pausedTargets) paused") }
        }
        return parts.joined(separator: ", ")
    }

    private func row(_ item: MonitoringCheckItem) -> some View {
        let monitor = item.monitor
        let editable = monitor.isEditable && store.serverEditsChecks
        return NavigationLink(value: AppRoute.monitoring(.check(id: monitor.id))) {
            MonitoringCheckRow(item: item)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if editable && store.canAdmin {
                Button(monitor.enabled ? "Pause" : "Resume", systemImage: monitor.enabled ? "pause.circle" : "play.circle") {
                    Task { await runner.run(MonitoringIntents.setEnabled(monitor, enabled: !monitor.enabled)) }
                }
                .tint(.statusQuiet)
            }
        }
        .contextMenu {
            MonitoringObjectMenu(route: .monitoring(.check(id: monitor.id)), link: .check(id: monitor.id), web: .check(id: monitor.id), objectID: monitor.id)
            Divider()
            if editable {
                Button(monitor.enabled ? "Pause" : "Resume", systemImage: monitor.enabled ? "pause.circle" : "play.circle") {
                    Task { await runner.run(MonitoringIntents.setEnabled(monitor, enabled: !monitor.enabled)) }
                }
                .disabled(!store.canAdmin)
                if !store.canAdmin { Text("Needs monitor:admin") }
            } else if monitor.isGenerated {
                Text(monitor.checkDefinitionID.isEmpty ? "Generated by the \(monitor.managedBy) probes" : "Generated by a definition: change it on web")
            }
        } preview: {
            MonitoringCheckRow(item: item).padding().frame(width: 320)
        }
    }

    private func consumeQuery() {
        if let pending = appState.consumeQuery(MonitorSegment.checks.rawValue) { query = pending }
    }

    private func refresh() {
        Task { await store.refreshChecks() }
    }
}
