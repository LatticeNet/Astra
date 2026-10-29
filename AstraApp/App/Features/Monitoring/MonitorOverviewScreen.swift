import SwiftUI

/// M3-01 Overview. A scope root, frozen as `init()`. Health verdicts as rows,
/// each opening the segment that explains it, then the recently degraded paths.
struct MonitorOverviewScreen: View {
    @Environment(MonitoringStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(ChangeLog.self) private var changes
    @Environment(NodeDirectory.self) private var nodes
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale

    var body: some View {
        MonitoringResource(state: store.paths, noun: "monitoring", retry: refresh) { response in
            let items = MonitoringPaths.visible(store.pathItems(nodeName: nodeName), showUnmeasured: false)
            List {
                MonitoringRefreshError(state: store.paths, noun: "paths", retry: refresh)
                Section {
                    pathsRow(items)
                    checksRow
                    incidentsRow
                    replansRow(response)
                } header: {
                    Text("Health").accessibilityAddTraits(.isHeader)
                }
                Section {
                    let recent = MonitoringPaths.recentlyDegraded(items)
                    if recent.isEmpty {
                        Label("No path is down or degraded in the last \(appState.monitorWindow.rawValue).", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                            .frame(minHeight: Spacing.minimumTarget)
                    } else {
                        ForEach(recent) { item in
                            NavigationLink(value: AppRoute.monitoring(.cell(item))) {
                                MonitoringPathListRow(item: item)
                            }
                        }
                    }
                } header: {
                    Text("Recently degraded").accessibilityAddTraits(.isHeader)
                } footer: {
                    MonitoringFreshness(state: store.paths, cadence: .monitoring)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await store.refreshOverview(window: appState.monitorWindow) }
        }
        .polling(.monitoring, version: pollVersion) {
            await nodes.refreshIfOlder(than: 60)
            return await store.refreshOverview(window: appState.monitorWindow)
        }
    }

    private var pollVersion: Int {
        changes.version([.paths, .checks, .incidents, .maintenance]) &* 16 &+ (MonitorWindow.allCases.firstIndex(of: appState.monitorWindow) ?? 0)
    }

    private func nodeName(_ id: String) -> String? {
        nodes.nodes[id]?.displayName
    }

    private func refresh() {
        Task { await store.refreshOverview(window: appState.monitorWindow) }
    }

    // MARK: Verdict rows

    private func pathsRow(_ items: [MonitoringPathItem]) -> some View {
        let counts = MonitoringPaths.counts(items)
        let style: StatusStyle = counts.down > 0
            ? StatusStyle(word: "\(counts.down) down", symbol: "xmark.circle.fill", tone: .fail)
            : counts.degraded > 0
                ? StatusStyle(word: "\(counts.degraded) degraded", symbol: "exclamationmark.triangle.fill", tone: .warn)
                : StatusStyle(word: "all measured paths up", symbol: "arrow.right.circle.fill", tone: .ok)
        var parts: [String] = []
        if counts.down > 0, counts.degraded > 0 { parts.append("\(counts.degraded) degraded") }
        parts.append("\(counts.up) up")
        if counts.unknown > 0 { parts.append("\(counts.unknown) unknown") }
        if counts.paused > 0 { parts.append("\(counts.paused) paused") }
        return verdictButton(
            title: counts.paths == 1 ? "1 path" : "\(counts.paths) paths",
            style: style,
            detail: parts.joined(separator: ", "),
            segment: .paths,
            query: counts.problems > 0 ? "state:down OR state:degraded" : nil
        )
    }

    @ViewBuilder
    private var checksRow: some View {
        switch store.monitors {
        case .denied(let scope):
            ScopeDeniedRow(scope: scope)
        case .companionBehind(let surface):
            CompanionBehindRow(surface: surface)
        default:
            if let monitors = store.monitors.value {
                let operatorChecks = monitors.filter { $0.managedBy.isEmpty }
                let failing = operatorChecks.filter { MonitoringHealth.of($0, results: $0.latest, now: Date()).isFailing }.count
                let style = failing > 0
                    ? StatusStyle(word: "\(failing) failing", symbol: "xmark.circle.fill", tone: .fail)
                    : StatusStyle(word: "none failing", symbol: "checkmark.circle.fill", tone: .ok)
                verdictButton(title: "\(operatorChecks.count) checks", style: style, detail: nil, segment: .checks, query: failing > 0 ? "state:failing" : nil)
            } else {
                LoadingRows(label: "Loading checks", count: 1)
            }
        }
    }

    @ViewBuilder
    private var incidentsRow: some View {
        switch store.incidents {
        case .denied(let scope):
            ScopeDeniedRow(scope: scope)
        case .companionBehind(let surface):
            CompanionBehindRow(surface: surface)
        default:
            if let list = store.incidents.value?.incidents {
                let now = Date()
                let open = list.filter { IncidentFilter.open.matches($0, now: now) && $0.maintenance.isEmpty }
                let critical = open.filter { $0.severity == "critical" }.count
                let handled = list.filter { IncidentFilter.active.matches($0, now: now) }.count - open.count
                let style = open.isEmpty
                    ? StatusStyle(word: "none open", symbol: "checkmark.circle.fill", tone: .ok)
                    : StatusStyle(word: "\(open.count) open", symbol: critical > 0 ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill", tone: critical > 0 ? .fail : .warn)
                verdictButton(
                    title: "Incidents",
                    style: style,
                    detail: handled > 0 ? "\(handled) acknowledged, snoozed or held" : nil,
                    segment: .incidents,
                    query: nil
                )
            } else if case .failed(let error, nil, _) = store.incidents {
                ErrorRow(message: "Could not load incidents: \(error.localizedDescription)", retry: refresh)
            } else {
                LoadingRows(label: "Loading incidents", count: 1)
            }
        }
    }

    private func replansRow(_ response: PathsResponse) -> some View {
        let replans = response.beaconReplans
        let style = replans.isEmpty
            ? StatusStyle(word: "none pending", symbol: "checkmark.circle.fill", tone: .ok)
            : StatusStyle(word: "\(replans.count) pending", symbol: "dot.radiowaves.left.and.right", tone: .warn)
        let names = replans.map { $0.name.isEmpty ? (nodeName($0.nodeID) ?? $0.nodeID) : $0.name }
        return verdictButton(
            title: "Beacon replans",
            style: style,
            detail: names.isEmpty ? nil : names.joined(separator: ", "),
            segment: .paths,
            query: nil
        )
    }

    /// A verdict that opens its segment, with the target segment's symbol in place of a chevron (2.4).
    private func verdictButton(title: String, style: StatusStyle, detail: String?, segment: MonitorSegment, query: String?) -> some View {
        Button {
            router.select(tab: .monitor, scope: segment.rawValue, query: query)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                StatusRow(style: style, title: title, detail: detail, accessibilityPhrase: "\(title), \(style.word)")
                if !typeSize.isAccessibilitySize {
                    Text(segment.title)
                        .textRole(.footnote)
                        .accessibilityHidden(true)
                }
            }
        }
        .tint(.primary)
        .accessibilityHint("Opens \(segment.title)")
    }
}
