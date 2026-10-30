import SwiftUI

/// The Incidents search scopes, applied on device to one unfiltered fetch.
enum MonitoringIncidentScope: String, CaseIterable, Hashable {
    case active, acknowledged, snoozed, pending, resolved, all

    var title: String {
        switch self {
        case .active: "Active"
        case .acknowledged: "Acknowledged"
        case .snoozed: "Snoozed"
        case .pending: "Pending"
        case .resolved: "Resolved"
        case .all: "All"
        }
    }

    var filter: IncidentFilter {
        switch self {
        case .active: .active
        case .acknowledged: .acknowledged
        case .snoozed: .snoozed
        case .pending: .pending
        case .resolved: .resolved
        case .all: .all
        }
    }
}

/// M3-10 Incidents. A scope root, frozen as `init()`.
struct IncidentsScreen: View {
    @Environment(MonitoringStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(ChangeLog.self) private var changes
    @Environment(NodeDirectory.self) private var nodes
    @Environment(Router.self) private var router
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    /// Always starts at the broadest working scope (section 2.6).
    @State private var scope = MonitoringIncidentScope.active
    @State private var query = ""
    @State private var snoozeTarget: Incident?
    @State private var stable = MonitoringStableList<MonitoringIncidentItem>()

    var body: some View {
        MonitoringResource(state: store.incidents, noun: "incidents", retry: refresh) { _ in
            list
        }
        .searchable(text: $query, prompt: "kind:, node:, state:")
        .searchScopes($scope, activation: .onSearchPresentation) {
            ForEach(MonitoringIncidentScope.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Show", selection: $scope) {
                        ForEach(MonitoringIncidentScope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Start maintenance", systemImage: "wrench.and.screwdriver") { router.present(.maintenanceStart(nodeID: nil)) }
                        .disabled(!store.canAdmin)
                } label: {
                    Label("Filter and maintenance", systemImage: scope == .active ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityValue(scope.title)
            }
        }
        .incidentSnoozeDialog($snoozeTarget)
        .onChange(of: snoozeTarget == nil) { _, closed in stable.setBusy(!closed) }
        .onAppear {
            consumeQuery()
            offer(force: true)
        }
        .onChange(of: appState.pendingQuery) { consumeQuery() }
        .onChange(of: appState.monitorView) { consumeQuery() }
        .onChange(of: store.incidents.loadedAt) { offer(force: false) }
        .onChange(of: scope) { offer(force: true) }
        .onChange(of: query) { offer(force: true) }
        .polling(.monitoring, version: changes.version([.incidents, .maintenance])) {
            await nodes.refreshIfOlder(than: 60)
            return await store.refreshIncidents()
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if scope != .active { parts.append(scope.title) }
        if !query.isEmpty { parts.append(query) }
        return parts.joined(separator: ", ")
    }

    private var items: [MonitoringIncidentItem] {
        let now = Date()
        let all = (store.incidents.value?.incidents ?? [])
            .filter { scope.filter.matches($0, now: now) }
            .sorted { IncidentFilter.areInIncreasingOrder($0, $1, now: now) }
            .map { MonitoringIncidentItem(incident: $0, now: now) }
        return MonitoringQuery.filter(all, query: query, provider: MonitoringIncidentQueryFields.self, now: now).rows
    }

    private func offer(force: Bool) {
        stable.offer(items, voiceOver: voiceOver, force: force)
    }

    private var list: some View {
        let shown = stable.shown
        let pathItems = store.pathItems { nodes.nodes[$0]?.displayName }
        let queryError = MonitoringQuery.filter([MonitoringIncidentItem](), query: query, provider: MonitoringIncidentQueryFields.self, now: Date()).error
        return List {
            MonitoringRefreshError(state: store.incidents, noun: "incidents", retry: refresh)
            if scope != .active {
                FilterStateRow(text: "Showing \(scope.title.lowercased()) incidents") { scope = .active }
            }
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                FilterStateRow(text: "Showing incidents matching \(query)") { query = "" }
            }
            if let queryError { Section { MonitoringQueryErrorRow(message: queryError) } }
            if stable.held != nil, voiceOver {
                Section { PendingUpdatesRow(count: stable.pendingCount) { stable.showHeld() } }
            }
            Section {
                if shown.isEmpty {
                    emptyState
                }
                ForEach(shown) { item in
                    let incident = item.incident
                    NavigationLink(value: AppRoute.monitoring(.incident(id: incident.id))) {
                        IncidentRow(incident: incident, canAdmin: store.canAdmin) { snoozeTarget = $0 }
                    }
                    .contextMenu {
                        MonitoringIncidentMenu(incident: incident, path: MonitoringIncidentLink.item(for: incident, in: pathItems),
                                               canAdmin: store.canAdmin) { snoozeTarget = $0 }
                    } preview: {
                        MonitoringIncidentGlance(incident: incident)
                    }
                }
            } header: {
                Text("\(scope.title) (\(shown.count))").accessibilityAddTraits(.isHeader)
            } footer: {
                if store.incidents.value?.durable == false {
                    Label("Incidents are lost on a server restart", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.statusWarnText)
                }
            }
            maintenanceSection
            Section {} footer: { MonitoringFreshness(state: store.incidents, cadence: .monitoring) }
        }
        .listStyle(.insetGrouped)
        .onScrollPhaseChange { _, phase in
            if phase != .idle { stable.noteActivity() }
        }
        .refreshable {
            await store.refreshIncidents()
            offer(force: true)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if scope == .active {
            ContentUnavailableView("No active incidents", systemImage: "checkmark.circle", description: Text("Nothing is open or acknowledged."))
        } else {
            ContentUnavailableView("No \(scope.title.lowercased()) incidents", systemImage: "tray")
        }
    }

    @ViewBuilder
    private var maintenanceSection: some View {
        let windows = store.maintenanceWindows
        Section {
            if case .denied(let scope) = store.windows {
                ScopeDeniedRow(scope: scope)
            } else if windows.isEmpty {
                Text("No maintenance window is active or scheduled.")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: Spacing.minimumTarget)
            }
            ForEach(windows) { window in
                NavigationLink(value: AppRoute.monitoring(.maintenanceWindow(id: window.id))) {
                    MonitoringWindowRow(window: window)
                }
            }
            Button {
                router.present(.maintenanceStart(nodeID: nil))
            } label: {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Label("Start maintenance", systemImage: "wrench.and.screwdriver")
                    if !store.canAdmin { Text("Needs monitor:admin").textRole(.footnote) }
                }
                .frame(minHeight: Spacing.minimumTarget)
            }
            .disabled(!store.canAdmin)
        } header: {
            Text("Maintenance").accessibilityAddTraits(.isHeader)
        }
    }

    private func consumeQuery() {
        if let linked = appState.monitorView, let wanted = MonitoringIncidentScope(rawValue: linked) {
            scope = wanted
            appState.monitorView = nil
        }
        if let pending = appState.consumeQuery(MonitorSegment.incidents.rawValue) { query = pending }
    }

    private func refresh() {
        Task { await store.refreshIncidents() }
    }
}

/// A maintenance window: active or scheduled, with its span.
struct MonitoringWindowRow: View {
    let window: MaintenanceWindow

    @Environment(NodeDirectory.self) private var nodes
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        let active = window.isActive(now: Date())
        let style = active
            ? StatusStyle(word: "active", symbol: "wrench.and.screwdriver", tone: .quiet)
            : StatusStyle(word: "scheduled", symbol: "calendar", tone: .quiet)
        StatusRow(
            style: style,
            title: window.name,
            detail: [subject, span(active: active)].filter { !$0.isEmpty }.joined(separator: ", "),
            accessibilityPhrase: "Maintenance window \(window.name), \(style.word)"
        )
    }

    private var subject: String {
        let names = window.nodeIDs.map { nodes.name(for: $0) } + window.groupIDs.map { "group \(nodes.groupName(for: $0))" }
        return names.count > 2 ? "\(names.count) subjects" : names.joined(separator: ", ")
    }

    private func span(active: Bool) -> String {
        if active, let end = window.endsAt { return "until \(TimeDisplay.dateTime(end, mode: mode, locale: locale))" }
        if let start = window.startsAt { return "from \(TimeDisplay.dateTime(start, mode: mode, locale: locale))" }
        return ""
    }
}

/// The compact preview an incident row's context menu shows.
struct MonitoringIncidentGlance: View {
    let incident: Incident

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            IncidentRow(incident: incident)
            if !incident.detail.isEmpty { Text(incident.detail).textRole(.rowDetail) }
            if !incident.nodeName.isEmpty { Text("Node \(incident.nodeName)").textRole(.rowDetail) }
            Text(incident.kind).textRole(.identifierInRow).foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 320, alignment: .leading)
    }
}
