import SwiftUI
import UIKit

/// A path's series, owned by the detail screen.
@MainActor @Observable
final class MonitoringSeriesModel {
    private(set) var series: ResourceState<MonitoringPathSeries> = .idle
    @ObservationIgnored private var loadedKey: String?

    /// Loads the series; a new subject, window or compare setting starts from placeholders.
    @discardableResult
    func load(_ subject: MonitoringSeriesSubject, window: MonitorWindow, compare: Bool, session: SessionStore) async -> Bool {
        let key = "\(subject)|\(window.rawValue)|\(compare)"
        if loadedKey != key {
            loadedKey = key
            series = .loading(previous: nil, previousAt: nil)
        } else {
            series = series.reloading
        }
        if let missing = session.missing(MonitoringStore.readRequirement), !missing.isEmpty {
            series = .denied(scope: missing.joined(separator: " and "))
            return true
        }
        guard let client = session.client else { return false }
        do {
            let value = try await client.monitoringPathSeries(subject, window: window, compare: compare)
            series = .loaded(value, at: Date())
            return true
        } catch {
            if MonitoringStore.isCancellation(error) { series = series.value.map { .loaded($0, at: series.loadedAt ?? Date()) } ?? .idle; return true }
            let apiError = LatticeAPIError(error)
            if case .invalidResponse = apiError { session.markCompanionBehind("Path series") }
            series = series.failing(apiError, surface: "The path series", missingScope: "monitor:read")
            return false
        }
    }
}

/// M3-04 Path.
struct PathDetailScreen: View {
    let key: String

    static let compareKey = "monitor.path.compare"

    @Environment(MonitoringStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(ChangeLog.self) private var changes
    @Environment(NodeDirectory.self) private var nodes
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @Environment(ActionRunner.self) private var runner
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    @State private var model = MonitoringSeriesModel()
    @SceneStorage(PathDetailScreen.compareKey) private var compare = false

    var body: some View {
        Group {
            if let item {
                detail(item)
            } else {
                missing
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(item.map { StatusStyle.path($0.display).word } ?? "")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { menu } }
        .onAppear {
            // Demo only: `-AstraDemoCompare YES` turns the comparison on for screenshots.
            if session.isDemo, UserDefaults.standard.bool(forKey: "AstraDemoCompare") { compare = true }
        }
        .polling(.paths, version: pollVersion) {
            await nodes.refreshIfOlder(than: 60)
            let incidents = Task { await store.refreshIncidents() }
            let early = item.map { current in
                Task { await model.load(MonitoringSeriesSubject(path: current.path), window: appState.monitorWindow, compare: compare, session: session) }
            }
            let ok = await store.refreshPaths(window: appState.monitorWindow)
            _ = await incidents.value
            if let early { return await early.value && ok }
            guard let item else { return ok }
            return await model.load(MonitoringSeriesSubject(path: item.path), window: appState.monitorWindow, compare: compare, session: session) && ok
        }
    }

    private var pollVersion: Int {
        changes.version([.paths, .incidents]) &* 32 &+ (MonitorWindow.allCases.firstIndex(of: appState.monitorWindow) ?? 0) &* 2 &+ (compare ? 1 : 0)
    }

    private var items: [MonitoringPathItem] {
        store.pathItems { nodes.nodes[$0]?.displayName }
    }

    private var item: MonitoringPathItem? {
        items.first { $0.key == key }
    }

    private var title: String {
        if let item { return item.spokenTitle }
        guard let address = decodePathKey(key) else { return "Path" }
        switch address {
        case .pair(let source, let target): return "\(source.isEmpty ? MonitoringPaths.controlPlaneName : nodes.name(for: source)) to \(nodes.name(for: target))"
        case .check(let source, _): return source.isEmpty ? "Check path" : nodes.name(for: source)
        }
    }

    @ViewBuilder
    private var missing: some View {
        switch store.paths {
        case .loaded, .failed(_, .some, _):
            WholeScreenState {
                ContentUnavailableView {
                    Label("Path not in this window", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                } description: {
                    Text("The matrix for the last \(appState.monitorWindow.rawValue) has no path \(key).")
                } actions: {
                    Button("Open on web") { router.openOnWeb(.path(key: key)) }
                }
            }
        default:
            ResourceView(state: store.paths, noun: "the path", retry: { Task { await store.refreshPaths(window: appState.monitorWindow) } }) { _ in
                EmptyView()
            }
        }
    }

    // MARK: Detail

    private func detail(_ item: MonitoringPathItem) -> some View {
        List {
            MonitoringRefreshError(state: store.paths, noun: "the path", retry: refreshAll)
            headerSection(item)
            chartSection(item)
            factsSection(item)
            relatedSection(item)
            beaconSection(item)
            Section {
                WebLinkRow(path: .path(key: key))
            } footer: {
                MonitoringFreshness(state: store.paths, cadence: .paths)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { refreshAll() }
    }

    private func headerSection(_ item: MonitoringPathItem) -> some View {
        let style = StatusStyle.path(item.display)
        let since = item.path.degraded?.since.map { TimeDisplay.clock($0, mode: mode, locale: locale) }
        return Section {
            MonitoringStateHeader(style: style, reason: item.reason?.sentence)
            if let evidence = MonitoringPathEvidence.sentence(item.path.degraded, since: since) {
                Text(evidence).font(.body)
            }
        }
    }

    private func factsSection(_ item: MonitoringPathItem) -> some View {
        Section {
            DetailRow(label: "Method", value: item.path.method, copyable: false)
            if let figures = MonitoringPaths.figures(item) {
                DetailRow(label: "Over \(appState.monitorWindow.rawValue)", value: figures, copyable: false)
            }
            if let p95 = item.path.p95Ms, item.measuresNow {
                DetailRow(label: "p95", value: MonitoringFormat.milliseconds(p95), copyable: false)
            }
            DetailRow(label: "Runs heard", value: "\(item.path.samples) of \(item.path.expected)", copyable: false)
            if let last = item.path.lastAt {
                DetailRow(label: "Last run", value: TimeDisplay.relative(last, now: Date(), locale: locale), secondary: TimeDisplay.dateTime(last, mode: mode, locale: locale), copyable: false)
            }
        }
    }

    @ViewBuilder
    private func chartSection(_ item: MonitoringPathItem) -> some View {
        Section {
            switch model.series {
            case .denied(let scope):
                ScopeDeniedRow(scope: scope)
            case .companionBehind(let surface):
                CompanionBehindRow(surface: surface)
            case .failed(let error, nil, _):
                ErrorRow(message: "Could not load the series: \(error.localizedDescription)", retry: refreshAll)
            default:
                if let series = model.series.value {
                    MonitoringRefreshError(state: model.series, noun: "the series", retry: refreshAll)
                    if MonitoringSeriesSegments.isEmpty(series) {
                        noData(item, series: series)
                    } else {
                        stripRow(series)
                        PathCharts(series: series, problem: isProblem(item), degradedSince: item.path.degraded?.since,
                                   maintenance: maintenance(for: item), compare: compare)
                            .padding(.vertical, Spacing.s)
                        Toggle("Compare previous window", isOn: $compare)
                            .frame(minHeight: Spacing.minimumTarget)
                    }
                } else {
                    LoadingRows(label: "Loading the latency chart", count: 2)
                }
            }
        } header: {
            Text("Latency and loss").accessibilityAddTraits(.isHeader)
        }
    }

    private func stripRow(_ series: MonitoringPathSeries) -> some View {
        let cells = MonitoringStrip.cells(series)
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            StateStrip(cells: cells.map(MonitoringStyle.cell), height: 18)
            HStack {
                Text("\(series.window) ago")
                Spacer()
                Text("now")
            }
            .textRole(.chartAxis)
            .foregroundStyle(.secondary)
            MonitoringStripLegendRow()
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MonitoringStrip.summary(cells))
    }

    /// The chart is replaced by a sentence when nothing was heard in the window.
    private func noData(_ item: MonitoringPathItem, series: MonitoringPathSeries) -> some View {
        let sourceNode = nodes.nodes[item.path.source]
        let offline = item.reason?.rawValue == "agent_offline" || sourceNode?.honesty == .offline
        let since = sourceNode?.lastSeen ?? item.path.lastAt
        let time = since.map { TimeDisplay.clock($0, mode: mode, locale: locale) }
        let sentence = offline
            ? "No data since \(time ?? "before this window"): source offline"
            : "No data in the last \(series.window)" + (item.reason.map { ": \($0.sentence)" } ?? "")
        return VStack(alignment: .leading, spacing: Spacing.s) {
            Label {
                Text(sentence).foregroundStyle(offline ? Color.statusWarnText : .primary)
            } icon: {
                Image(systemName: offline ? "wifi.slash" : "chart.line.flattrend.xyaxis")
                    .foregroundStyle(offline ? Color.statusWarnFill : Color.statusQuiet)
            }
            if !item.path.source.isEmpty {
                Button("Open \(item.sourceName)") { router.push(.fleet(.node(id: item.path.source))) }
                    .frame(minHeight: Spacing.minimumTarget)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    @ViewBuilder
    private func relatedSection(_ item: MonitoringPathItem) -> some View {
        Section {
            if let reverse = MonitoringPaths.reverse(of: item, in: items) {
                NavigationLink(value: AppRoute.monitoring(.path(key: reverse.key))) {
                    StatusRow(style: .path(reverse.display), title: "Reverse: \(reverse.spokenTitle)",
                              trailing: MonitoringStyle.figures(reverse), accessibilityPhrase: "Reverse direction, \(reverse.spokenTitle), \(StatusStyle.path(reverse.display).word)")
                }
            }
            if !item.path.source.isEmpty {
                nodeRow(label: "Source", id: item.path.source, name: item.sourceName)
            } else {
                DetailRow(label: "Source", value: "Control plane", copyable: false)
            }
            if !item.path.targetNode.isEmpty {
                nodeRow(label: "Target", id: item.path.targetNode, name: item.targetName)
            }
            DetailRow(label: "Dials", value: item.path.target, monospaced: true)
            if !item.path.monitorID.isEmpty {
                NavigationLink(value: AppRoute.monitoring(.check(id: item.path.monitorID))) {
                    LabeledContent("Check", value: store.monitor(id: item.path.monitorID)?.displayName ?? item.path.monitorID)
                        .frame(minHeight: Spacing.minimumTarget)
                }
            }
            if !item.path.checkDefinitionID.isEmpty {
                NavigationLink(value: AppRoute.monitoring(.definition(id: item.path.checkDefinitionID))) {
                    LabeledContent("Definition", value: definitionName(item.path.checkDefinitionID))
                        .frame(minHeight: Spacing.minimumTarget)
                }
            }
            ForEach(incidents(for: item)) { incident in
                NavigationLink(value: AppRoute.monitoring(.incident(id: incident.id))) {
                    IncidentRow(incident: incident)
                }
            }
        } header: {
            Text("Related").accessibilityAddTraits(.isHeader)
        }
    }

    private func nodeRow(label: String, id: String, name: String) -> some View {
        NavigationLink(value: AppRoute.fleet(.node(id: id))) {
            HStack {
                LabeledContent(label, value: name)
                if let node = nodes.nodes[id] {
                    StatusGlyph(style: .node(node.honesty), font: .body)
                }
            }
            .frame(minHeight: Spacing.minimumTarget)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label), \(name)" + (nodes.nodes[id].map { ", \(StatusStyle.node($0.honesty).word)" } ?? ""))
        }
    }

    @ViewBuilder
    private func beaconSection(_ item: MonitoringPathItem) -> some View {
        let replans = (store.paths.value?.beaconReplans ?? []).filter { $0.nodeID == item.path.targetNode || $0.nodeID == item.path.source }
        if item.path.method == "beacon" || !replans.isEmpty {
            let request = replans.first { $0.nodeID == item.path.targetNode }?.request ?? replans.first?.request
                ?? BeaconPlanRequest(nodeID: item.path.targetNode.isEmpty ? item.path.source : item.path.targetNode, action: .change)
            let missing = store.missing(ScopeRequirement("monitor:admin", "node:admin", "network:plan"))
            Section {
                ForEach(replans, id: \.nodeID) { replan in
                    StatusRow(
                        style: StatusStyle(word: PathReason.sentence(for: replan.reason), symbol: "dot.radiowaves.left.and.right", tone: .warn),
                        title: "\(replan.name.isEmpty ? nodes.name(for: replan.nodeID) : replan.name) beacon",
                        detail: replanDetail(replan)
                    )
                }
                Button {
                    Task { await runner.run(Self.replanIntent(request, nodeName: nodes.name(for: request.nodeID))) }
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Label("Plan beacon replan", systemImage: "doc.badge.plus")
                        if !missing.isEmpty {
                            Text("Needs \(missing.joined(separator: ", "))").textRole(.footnote)
                        }
                    }
                    .frame(minHeight: Spacing.minimumTarget)
                }
                .disabled(!missing.isEmpty)
            } header: {
                Text("Beacon").accessibilityAddTraits(.isHeader)
            }
        }
    }

    private func replanDetail(_ replan: PathBeaconReplan) -> String {
        var parts: [String] = []
        if !replan.added.isEmpty { parts.append("new sources: " + replan.added.map { nodes.name(for: $0) }.joined(separator: ", ")) }
        if !replan.removed.isEmpty { parts.append("gone: " + replan.removed.map { nodes.name(for: $0) }.joined(separator: ", ")) }
        if !replan.pendingApprovalID.isEmpty { parts.append("a plan is already waiting") }
        return parts.joined(separator: "; ")
    }

    /// Plan beacon replan (P): files a change plan; the approval is the gate.
    nonisolated static func replanIntent(_ request: BeaconPlanRequest, nodeName: String) -> WriteIntent {
        let node = ObjectRef(kind: "node", id: request.nodeID, name: nodeName)
        return WriteIntent(
            tier: .plan, verb: "Plan beacon replan for", object: node,
            scopes: ["monitor:admin", "node:admin", "network:plan"],
            consequence: "Files a beacon change plan for \(nodeName) so its sources match what probes it. Nothing changes until the plan is approved.",
            affected: [node],
            changes: [.approvals, .paths],
            perform: { client, _ in
                let response = try await client.planBeacon(request)
                return .filed(approvalIDs: response.filedApprovalIDs, refused: [], notes: response.findings.map(\.message))
            }
        )
    }

    private var menu: some View {
        Menu {
            Button("Open on web", systemImage: "safari") { router.openOnWeb(.path(key: key)) }
            Button("Copy link", systemImage: "link") { UIPasteboard.general.url = LatticeDeepLink.path(key: key).customURL }
            Button("Copy path key", systemImage: "number") { UIPasteboard.general.string = key }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    // MARK: Helpers

    private func isProblem(_ item: MonitoringPathItem) -> Bool {
        switch item.display {
        case .down, .degraded: true
        default: false
        }
    }

    private func incidents(for item: MonitoringPathItem) -> [Incident] {
        let list = store.incidents.value?.incidents ?? []
        return list.filter { IncidentFilter.isActive($0) || $0.state == "pending" }
            .filter { MonitoringIncidentLink.pathKey(for: $0, in: items) == item.key }
    }

    /// Windows that name either end of the path.
    private func maintenance(for item: MonitoringPathItem) -> [MaintenanceWindow] {
        store.maintenanceWindows.filter { $0.nodeIDs.contains(item.path.source) || $0.nodeIDs.contains(item.path.targetNode) }
    }

    private func definitionName(_ id: String) -> String {
        store.definitions.value?.definitions.first { $0.id == id }?.displayName ?? id
    }

    private func refreshAll() {
        Task {
            await store.refreshPaths(window: appState.monitorWindow)
            if let item {
                await model.load(MonitoringSeriesSubject(path: item.path), window: appState.monitorWindow, compare: compare, session: session)
            }
        }
    }
}

/// The strip's legend, always shown under the path's strip.
struct MonitoringStripLegendRow: View {
    var body: some View {
        HStack(spacing: Spacing.m) {
            ForEach([MonitoringStripCell.up, .degraded, .down, .unknown], id: \.self) { cell in
                HStack(spacing: Spacing.xs) {
                    StateStrip(cells: [MonitoringStyle.cell(cell)], height: 10).frame(width: 8)
                    Text(cell == .unknown ? "no data" : cell.rawValue)
                }
            }
        }
        .textRole(.chartAxis)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}
