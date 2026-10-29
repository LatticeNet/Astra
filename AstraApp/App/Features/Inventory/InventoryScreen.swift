import SwiftUI

/// M5-01 Machines. A scope root, frozen as `init()`. The Upcoming row, the
/// monthly spend, then machines in sections by the Group menu, each with its
/// renewal countdown and monthly equivalent; swipe Renew opens the Renew sheet.
struct InventoryScreen: View {
    static let queryKey = "fleet.machines.query"
    static let groupKey = "fleet.machines.groupBy"

    @Environment(InventoryStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes
    @Environment(AppState.self) private var appState
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @SceneStorage(InventoryScreen.queryKey) private var query = ""
    @SceneStorage(InventoryScreen.groupKey) private var groupRaw = InventoryGroupBy.region.rawValue
    @State private var showsReminders = false

    private var groupBy: InventoryGroupBy { InventoryGroupBy(rawValue: groupRaw) ?? .region }

    var body: some View {
        InventoryListState(state: store.machines, noun: "machines", retry: { Task { await store.refresh() } }) { machines in
            content(machines)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter machines")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .refreshable { await store.refresh() }
        .polling(.standard, version: changes.version([.machines, .upcoming, .nodes, .groups])) { await store.refresh(fromPoll: true) }
        .task { await nodes.refreshIfOlder(than: 60) }
        .toolbar { toolbar }
        .sheet(isPresented: $showsReminders) { RemindersSheet() }
        .onAppear {
            if let pending = appState.consumeQuery(FleetScope.machines.rawValue) { query = pending }
        }
        .onChange(of: appState.pendingQuery[FleetScope.machines.rawValue]) { _, value in
            if value != nil, let pending = appState.consumeQuery(FleetScope.machines.rawValue) { query = pending }
        }
        .modifier(InventoryFilterSubtitle(text: query.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "Filtered: \(query.trimmingCharacters(in: .whitespaces))"))
        .onChange(of: listBusy, initial: true) { _, busy in store.interactionBusy = busy }
        .onChange(of: [groupRaw, query], initial: true) { registerLayout() }
    }

    /// A write, a confirmation or a dialog in progress: reorders wait.
    private var listBusy: Bool {
        runner.isBusy || runner.pendingConfirm != nil || runner.pendingDialog != nil || showsReminders
    }

    // MARK: List

    @ViewBuilder
    private func content(_ machines: [MachineProfile]) -> some View {
        let today = InventoryDay(date: Date())
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let compiled = trimmed.isEmpty ? nil : InventoryQuery.compile(trimmed)
        let (filtered, sections) = Self.arrange(machines, query: trimmed, groupBy: groupBy, nodes: nodes, groupNames: store.groupNames, locale: locale, today: today)

        if machines.isEmpty, trimmed.isEmpty {
            emptyInventory
        } else {
            List {
                Section {
                    InventoryRefreshError(state: store.machines, noun: "machines") { Task { await store.refresh() } }
                    if store.held != nil, store.heldForVoiceOver {
                        PendingUpdatesRow(count: store.heldCount) { store.showHeld() }
                    }
                    InventoryUpcomingRow(state: store.expiring)
                    InventorySpendHeader(machines: machines, confinedTo: store.isConfined ? store.allowlist.count : nil)
                    if case .failure(let error)? = compiled {
                        Label {
                            Text(InventoryQuery.message(error)).foregroundStyle(Color.statusWarnText)
                        } icon: {
                            Image(systemName: "exclamationmark.magnifyingglass").foregroundStyle(Color.statusWarnFill)
                        }
                        .frame(minHeight: Spacing.minimumTarget)
                    }
                }
                if filtered.isEmpty {
                    Section {
                        ContentUnavailableView.search(text: trimmed)
                    }
                }
                ForEach(sections) { section in
                    Section {
                        ForEach(section.machines) { machine in
                            row(machine, today: today)
                        }
                    } header: {
                        InventorySectionHeader(section: section)
                    } footer: {
                        if section.id == sections.last?.id {
                            FreshnessFooter(state: store.machines, interval: 60)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .animation(reduceMotion ? nil : .default, value: sections.map(\.id))
            .onScrollPhaseChange { _, _ in store.noteInteraction() }
            .background(InventoryTouchProbe { store.noteInteraction() })
        }
    }

    /// The rows the filter keeps and the sections they fall in, for the
    /// list and for the store's stable-list check.
    private static func arrange(_ machines: [MachineProfile], query trimmed: String, groupBy: InventoryGroupBy, nodes: NodeDirectory,
                                groupNames: [String: String], locale: Locale, today: InventoryDay) -> ([MachineProfile], [InventorySection]) {
        let facts: (String) -> InventoryNodeFacts? = { nodes.nodes[$0].map(InventoryNodeFacts.init(node:)) }
        let compiled = trimmed.isEmpty ? nil : InventoryQuery.compile(trimmed)
        let filtered: [MachineProfile]
        if case .success(let query)? = compiled {
            let rows = machines.map { machine in
                InventoryQuery.Row(machine: machine, facts: facts(machine.nodeID),
                                   groupNames: (nodes.nodes[machine.nodeID]?.groupIDs ?? []).compactMap { groupNames[$0] }, today: today)
            }
            filtered = LatticeQueryEngine.apply(query, to: rows, now: Date()).map(\.machine)
        } else {
            filtered = machines
        }
        let sections = trimmed.contains("sort:")
            ? [InventorySection(id: "sorted", title: "Sorted", machines: filtered, spend: InventoryCost.aggregate(filtered))]
            : InventoryGrouping.sections(filtered, by: groupBy, today: today, facts: facts, groupName: { groupNames[$0] }, locale: locale)
        return (filtered, sections)
    }

    /// Tells the store where rows sit under the current grouping and filter,
    /// so a poll that only changes values inside rows applies at once.
    private func registerLayout() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let groupBy = groupBy, nodes = nodes, locale = locale
        store.layout = { machines, groupNames in
            let (_, sections) = Self.arrange(machines, query: trimmed, groupBy: groupBy, nodes: nodes, groupNames: groupNames,
                                             locale: locale, today: InventoryDay(date: Date()))
            var slots: [String: InventoryStore.Slot] = [:]
            for section in sections {
                for (index, machine) in section.machines.enumerated() {
                    slots[InventoryStore.rowKey(machine)] = InventoryStore.Slot(section: section.id, index: index)
                }
            }
            return slots
        }
    }

    @ViewBuilder
    private func row(_ machine: MachineProfile, today: InventoryDay) -> some View {
        let missing = store.adminMissing
        NavigationLink(value: AppRoute.inventory(.machine(id: machine.inventoryRouteID))) {
            InventoryMachineRow(machine: machine, today: today, showsRegion: groupBy != .region)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if machine.inventoryCanRenew, missing == nil {
                Button("Renew", systemImage: "calendar.badge.plus") {
                    router.present(.renew(machineID: machine.id))
                }
                .tint(.accentFill)
            }
        }
        .contextMenu {
            Button("Open", systemImage: "arrow.right.circle") { router.push(.inventory(.machine(id: machine.inventoryRouteID))) }
            if machine.inventoryCanRenew {
                InventoryGatedButton(title: "Record renewal", systemImage: "calendar.badge.plus", missing: missing) {
                    router.present(.renew(machineID: machine.id))
                }
            }
            Button("Open node", systemImage: "server.rack") { router.push(.fleet(.node(id: machine.nodeID))) }
            if machine.isProfiled {
                Button("Copy link", systemImage: "link") { InventoryCopy.copy(InventoryCopy.machineLink(machine.id)) }
            }
            Button("Open on web", systemImage: "safari") {
                router.openOnWeb(machine.isProfiled ? .machine(id: machine.id) : LatticeConsolePath(path: "/inventory", query: [URLQueryItem(name: "node", value: machine.nodeID)]))
            }
        }
    }

    /// No nodes at all; VPN users or certificates can still be due, so the Upcoming row stays.
    private var emptyInventory: some View {
        List {
            Section {
                InventoryRefreshError(state: store.machines, noun: "machines") { Task { await store.refresh() } }
                InventoryUpcomingRow(state: store.expiring)
            }
            Section {
                ContentUnavailableView {
                    Label("No machines", systemImage: "server.rack")
                } description: {
                    Text("No nodes are enrolled, or none are visible to this token. Profiles are written on the web.")
                } actions: {
                    Button("New machine on web") { router.openOnWeb(.inventory) }
                        .buttonStyle(.bordered)
                }
            } footer: {
                FreshnessFooter(state: store.machines, interval: 60)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // One leading item: two left no room for the inline title on an iPhone SE at AX5.
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker(selection: $groupRaw) {
                    ForEach(InventoryGroupBy.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                } label: {
                    Label("Group by", systemImage: "rectangle.3.group")
                }
                .pickerStyle(.menu)
                Section {
                    Button("Reminders", systemImage: "bell") { showsReminders = true }
                    Button("New machine on web", systemImage: "safari") { router.openOnWeb(.inventory) }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityValue("Grouped by \(groupBy.title)")
        }
    }
}

/// "Upcoming: 4 due in 30 days, 1 overdue", pushing the Upcoming list. Only
/// the overdue count takes the failure color.
struct InventoryUpcomingRow: View {
    let state: ResourceState<ExpiringResponse>

    var body: some View {
        NavigationLink(value: AppRoute.inventory(.upcoming)) {
            let (detail, overdue, tone) = summary
            // The overdue count is the state word; without one the row is a quiet calendar.
            let style = overdue.map { StatusStyle(word: $0, symbol: "calendar.badge.exclamationmark", tone: .fail) }
                ?? StatusStyle(word: "", symbol: tone.isProblem ? "exclamationmark.triangle.fill" : "calendar", tone: tone.isProblem ? tone : .quiet)
            StatusRow(style: style, title: "Upcoming", detail: detail,
                      accessibilityPhrase: "Upcoming, \(detail)\(overdue.map { ", \($0)" } ?? "")")
        }
    }

    private var summary: (String, String?, StatusTone) {
        switch state {
        case .denied: return ("Hidden from this token", nil, .quiet)
        case .companionBehind: return ("This app is behind the server; could not be read", nil, .warn)
        case .failed(_, nil, _): return ("Could not load", nil, .warn)
        default:
            guard let response = state.value else { return ("Checking what runs out", nil, .quiet) }
            let counts = InventoryUpcoming.headerCounts(response.items)
            var due = "\(counts.due) due in \(InventoryUpcoming.withinDays) days"
            // A failed refresh keeps the last counts; say so rather than read as current.
            if case .failed(_, _?, _) = state { due += ", could not refresh" }
            let stale: StatusTone = if case .failed = state { .warn } else { .quiet }
            return (due, counts.overdue > 0 ? "\(counts.overdue) overdue" : nil, stale)
        }
    }
}

/// The monthly spend in the primary currency, every other currency's total
/// when the inventory is mixed, and the counts behind it.
struct InventorySpendHeader: View {
    let machines: [MachineProfile]
    var confinedTo: Int?
    @Environment(\.locale) private var locale

    var body: some View {
        let spend = InventoryCost.aggregate(machines)
        let profiled = machines.filter(\.isProfiled).count
        let unprofiled = machines.count - profiled
        let unpriced = machines.filter { InventoryCost.billing($0) == .unpriced || InventoryCost.billing($0) == .renewalIncomplete }.count
        let counts = [
            profiled == 1 ? "1 machine" : "\(profiled) machines",
            unprofiled > 0 ? (unprofiled == 1 ? "1 node without a profile" : "\(unprofiled) nodes without a profile") : nil,
            unpriced > 0 ? "\(unpriced) not priced or set up" : nil,
            confinedTo.map { "confined to \($0) nodes" },
        ].compactMap { $0 }.joined(separator: ", ")
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let primary = spend.first {
                Text("\(InventoryCurrency.format(cents: primary.monthlyCents, currency: primary.currency, locale: locale)) a month")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                ForEach(spend.dropFirst(), id: \.currency) { other in
                    Text("\(InventoryCurrency.format(cents: other.monthlyCents, currency: other.currency, locale: locale)) a month")
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                }
            } else {
                Text("No recurring spend").font(.title3.weight(.semibold))
            }
            Text(counts).textRole(.rowDetail)
        }
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel(spend, counts: counts))
    }

    private func spokenLabel(_ spend: [InventorySpend], counts: String) -> String {
        let money = spend.map { "\(InventoryCurrency.format(cents: $0.monthlyCents, currency: $0.currency, locale: locale)) a month" }
        return ((money.isEmpty ? ["No recurring spend"] : ["Monthly spend"] + money) + [counts]).joined(separator: ", ")
    }
}

/// "Tokyo (5)" with the group's monthly spend; the spend wraps under the
/// title when both do not fit.
struct InventorySectionHeader: View {
    let section: InventorySection
    @Environment(\.locale) private var locale

    var body: some View {
        let title = Text("\(section.title) (\(section.machines.count))")
        let spend = section.spend.isEmpty ? nil : section.spend
            .map { "\(InventoryCurrency.format(cents: $0.monthlyCents, currency: $0.currency, locale: locale))/mo" }
            .joined(separator: " · ")
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                title
                Spacer(minLength: Spacing.s)
                if let spend { Text(spend).monospacedDigit() }
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                title
                if let spend { Text(spend).monospacedDigit() }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(.isHeader)
    }

    private var spokenLabel: String {
        let count = section.machines.count == 1 ? "1 machine" : "\(section.machines.count) machines"
        let spend = section.spend.map { "\(InventoryCurrency.format(cents: $0.monthlyCents, currency: $0.currency, locale: locale)) a month" }
        return ([section.title, count] + spend).joined(separator: ", ")
    }
}
