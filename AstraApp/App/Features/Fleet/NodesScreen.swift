import SwiftUI

/// M2-01 Nodes. A scope root, frozen as `init()`. Sections by status worst
/// first (or the toolbar grouping), the console query grammar in search,
/// the duplicate report as a banner, and Select for bulk disable and enable.
struct NodesScreen: View {
    static let queryKey = "fleet.nodes.query"
    static let groupKey = "fleet.nodes.groupBy"

    @Environment(FleetStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @SceneStorage(NodesScreen.queryKey) private var query = ""
    @SceneStorage(NodesScreen.groupKey) private var groupByRaw = FleetNodeGroupBy.status.rawValue
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()

    private var groupBy: FleetNodeGroupBy { FleetNodeGroupBy(rawValue: groupByRaw) ?? .status }

    /// The row names the provider unless the sections already do.
    private func rowProvider(_ record: FleetNodeRecord) -> String? {
        groupBy == .provider ? nil : record.facts.provider
    }

    var body: some View {
        FleetListState(state: store.nodes, noun: "nodes", retry: { Task { await store.refresh() } }) { records in
            content(records)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search, status:, tag:")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .refreshable { await store.refresh() }
        .polling(.standard, version: changes.version([.nodes, .groups])) { await store.refresh(fromPoll: true) }
        .toolbar { toolbar }
        .environment(\.editMode, $editMode)
        .onAppear {
            if let pending = appState.consumeQuery(FleetScope.nodes.rawValue) { query = pending }
        }
        .onChange(of: appState.pendingQuery[FleetScope.nodes.rawValue]) { _, value in
            if value != nil, let pending = appState.consumeQuery(FleetScope.nodes.rawValue) { query = pending }
        }
        .modifier(FleetFilterSubtitle(query: query))
        .onChange(of: listBusy, initial: true) { _, busy in store.interactionBusy = busy }
    }

    /// A write, confirmation or dialog in progress, or Select mode: reorders wait.
    private var listBusy: Bool {
        runner.isBusy || runner.pendingConfirm != nil || runner.pendingDialog != nil || editMode.isEditing
    }

    // MARK: List

    @ViewBuilder
    private func content(_ records: [FleetNodeRecord]) -> some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let compiled = trimmed.isEmpty ? nil : FleetNodeQuery.compile(trimmed, groupName: groupNameLookup)
        let filtered: [FleetNodeRecord] = switch compiled {
        case .success(let query)?: LatticeQueryEngine.apply(query, to: records, now: Date())
        default: records
        }
        let sorted = trimmed.contains("sort:")
        let sections = sorted
            ? [FleetNodeSection(id: "sorted", title: "Sorted", records: filtered)]
            : FleetNodeGrouping.sections(filtered, by: groupBy, groupName: { store.groupName($0) })
        let canAdmin = store.can("node:admin")

        if records.isEmpty, trimmed.isEmpty {
            emptyFleet
        } else {
            List(selection: $selection) {
                Section {
                    if !trimmed.isEmpty {
                        FilterStateRow(text: filterSentence(trimmed, compiled: compiled)) { query = "" }
                            .selectionDisabled()
                    }
                    if store.held != nil {
                        PendingUpdatesRow(count: store.heldCount) { store.showHeld() }
                    }
                    Text(FleetHeader.sentence(records.map(\.node), allowlist: store.allowlist))
                        .textRole(.rowDetail)
                        .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                        .selectionDisabled()
                    if !store.duplicates.isEmpty {
                        NavigationLink(value: AppRoute.fleet(.duplicates)) {
                            Label {
                                Text(FleetHeader.duplicates(Set(store.duplicates.flatMap(\.nodeIDs)).count))
                                    .foregroundStyle(Color.statusWarnText)
                            } icon: {
                                Image(systemName: "square.on.square").foregroundStyle(Color.statusWarnFill)
                            }
                            .frame(minHeight: Spacing.minimumTarget)
                        }
                        .selectionDisabled()
                    }
                    if case .failure(let error)? = compiled {
                        Label {
                            Text(FleetQueryMessage.sentence(error)).foregroundStyle(Color.statusWarnText)
                        } icon: {
                            Image(systemName: "exclamationmark.magnifyingglass").foregroundStyle(Color.statusWarnFill)
                        }
                        .frame(minHeight: Spacing.minimumTarget)
                        .selectionDisabled()
                    }
                    FleetRefreshError(state: store.nodes, noun: "nodes") { Task { await store.refresh() } }
                }
                if filtered.isEmpty {
                    Section {
                        ContentUnavailableView.search(text: trimmed)
                            .selectionDisabled()
                    }
                }
                ForEach(sections) { section in
                    Section {
                        ForEach(section.records) { record in
                            NavigationLink(value: AppRoute.fleet(.node(id: record.id))) {
                                NodeRow(node: record.node, provider: rowProvider(record))
                            }
                            .tag(record.id)
                            .fleetNodeSwipe(record.node, canAdmin: canAdmin, runner: runner)
                            .fleetNodeMenu(record)
                        }
                    } header: {
                        Text("\(section.title) (\(section.records.count))")
                    } footer: {
                        if section.id == sections.last?.id { FleetFooter(state: store.nodes) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .animation(reduceMotion ? nil : .default, value: sections.map(\.id))
            .onScrollPhaseChange { _, _ in store.noteInteraction() }
            .background(FleetTouchProbe { store.noteInteraction() })
        }
    }

    /// A query that does not compile leaves every node in the list, so the
    /// row must not claim a filter is applied.
    private func filterSentence(_ trimmed: String, compiled: Result<LatticeCompiledQuery<FleetNodeRecord>, LatticeQueryError>?) -> String {
        if case .failure? = compiled { return "Showing all nodes: the filter could not be applied" }
        return "Showing nodes matching \(trimmed)"
    }

    private var groupNameLookup: @Sendable (String) -> String? {
        let names = Dictionary((store.groups?.groups ?? []).map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        return { names[$0] }
    }

    private var emptyFleet: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("No nodes enrolled", systemImage: "server.rack")
            } description: {
                Text("Enrolling a node shows an install command that belongs on the host, so it happens on the web.")
            } actions: {
                Button("Enroll on web") { router.openOnWeb(.nodes) }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Group by", selection: $groupByRaw) {
                    ForEach(FleetNodeGroupBy.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Group by \(groupBy.title)", systemImage: "rectangle.3.group")
            }
            .accessibilityValue(groupBy.title)
        }
        ToolbarItem(placement: .topBarLeading) {
            Button(editMode.isEditing ? "Done" : "Select") {
                withAnimation {
                    editMode = editMode.isEditing ? .inactive : .active
                    if !editMode.isEditing { selection = [] }
                }
            }
            .disabled(store.nodes.value?.isEmpty ?? true)
        }
        if editMode.isEditing {
            let missing = store.missing("node:admin")
            ToolbarItem(placement: .bottomBar) {
                Button(bulkTargets.enable.isEmpty ? "Enable" : "Enable \(bulkTargets.enable.count)") {
                    Task { await bulk(FleetIntents.bulkEnable(bulkTargets.enable)) }
                }
                .disabled(bulkTargets.enable.isEmpty || missing != nil)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            if let missing {
                ToolbarItem(placement: .bottomBar) {
                    Text("Needs \(missing)").font(.footnote).foregroundStyle(.secondary)
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
            }
            ToolbarItem(placement: .bottomBar) {
                Button(bulkTargets.disable.isEmpty ? "Disable" : "Disable \(bulkTargets.disable.count)", role: .destructive) {
                    Task { await bulk(FleetIntents.bulkDisable(bulkTargets.disable)) }
                }
                .disabled(bulkTargets.disable.isEmpty || missing != nil)
            }
        }
    }

    /// The selected nodes each bulk action would touch.
    private var bulkTargets: (disable: [ObjectRef], enable: [ObjectRef]) {
        let chosen = (store.nodes.value ?? []).filter { selection.contains($0.id) }
        return (
            chosen.filter { $0.node.honesty != .disabled }.map { FleetIntents.nodeRef($0.node) },
            chosen.filter { $0.node.honesty == .disabled }.map { FleetIntents.nodeRef($0.node) }
        )
    }

    private func bulk(_ intent: WriteIntent) async {
        let outcome = await runner.run(intent)
        if outcome.isCleanSuccess {
            selection = []
            editMode = .inactive
        }
    }
}

/// The active query as the navigation subtitle, as filters show (section 5.0).
struct FleetFilterSubtitle: ViewModifier {
    let query: String

    func body(content: Content) -> some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            content
        } else {
            content.navigationSubtitle("Filtered: \(trimmed)")
        }
    }
}
