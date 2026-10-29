import SwiftUI
import UIKit

/// M3-07 Check. A generated check shows no pause, resume or delete and
/// points at the definition or configuration that owns it.
struct CheckDetailScreen: View {
    let id: String

    @Environment(MonitoringStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(ChangeLog.self) private var changes
    @Environment(NodeDirectory.self) private var nodes
    @Environment(SessionStore.self) private var session
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    @State private var series = MonitoringSeriesModel()
    @State private var source: String?

    var body: some View {
        content
            .navigationTitle(store.monitor(id: id)?.displayName ?? "Check")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(store.monitor(id: id).map { MonitoringStyle.check(health($0)).word } ?? "")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { menu } }
            .polling(.standard, version: changes.version([.checks, .incidents, .paths]) &* 8 &+ (MonitorWindow.allCases.firstIndex(of: appState.monitorWindow) ?? 0)) {
                await nodes.refreshIfOlder(than: 60)
                let incidents = Task { await store.refreshIncidents() }
                let paths = Task { await store.refreshPaths(window: appState.monitorWindow) }
                let ok = await store.refreshChecks()
                _ = await incidents.value
                _ = await paths.value
                return await loadSeries() && ok
            }
            .onChange(of: source) { Task { await loadSeries() } }
    }

    @ViewBuilder
    private var content: some View {
        if let monitor = store.monitor(id: id) {
            detail(monitor)
        } else if store.definitions.value?.definitions.contains(where: { $0.id == id }) == true {
            // `lattice://definitions/{id}` on the console parses back as a check.
            DefinitionDetailScreen(id: id)
        } else if store.monitors.value != nil {
            WholeScreenState {
                ContentUnavailableView {
                    Label("Check not found", systemImage: "checklist")
                } description: {
                    Text("No check \(id) is visible to this token.")
                } actions: {
                    Button("Open on web") { router.openOnWeb(.check(id: id)) }
                }
            }
        } else {
            MonitoringResource(state: store.monitors, noun: "the check", retry: { Task { await store.refreshChecks() } }) { _ in EmptyView() }
        }
    }

    private func health(_ monitor: Monitor) -> MonitoringHealth {
        store.health(of: monitor)
    }

    private func sources(_ monitor: Monitor) -> [String] {
        let ids = monitor.latest.map(\.nodeID) + monitor.nodeIDs
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }

    @discardableResult
    private func loadSeries() async -> Bool {
        guard let monitor = store.monitor(id: id) else { return true }
        let chosen = source ?? sources(monitor).first ?? ""
        return await series.load(.monitor(id: monitor.id, source: monitor.type == .tls ? "" : chosen), window: appState.monitorWindow, compare: false, session: session)
    }

    // MARK: Detail

    private func detail(_ monitor: Monitor) -> some View {
        let style = MonitoringStyle.check(health(monitor))
        return List {
            MonitoringRefreshError(state: store.monitors, noun: "the check") { Task { await store.refreshChecks() } }
            Section {
                // The title truncates a long generated name; the full name leads the content (5.0).
                Text(monitor.displayName)
                    .textRole(.detailHeader)
                    .accessibilityAddTraits(.isHeader)
                MonitoringStateHeader(style: style)
            }
            if monitor.isGenerated { generatedSection(monitor) }
            resultsSection(monitor)
            chartSection(monitor)
            incidentsSection(monitor)
            Section {
                DetailRow(label: "Type", value: MonitorType(rawValue: monitor.typeRaw)?.displayName ?? monitor.typeRaw, copyable: false)
                DetailRow(label: "Target", value: monitor.target, monospaced: true)
                if !monitor.targetNode.isEmpty {
                    DetailRow(label: "Resolved from", value: nodes.name(for: monitor.targetNode), copyable: false)
                }
                if !monitor.dnsName.isEmpty {
                    DetailRow(label: "Asks for", value: "\(monitor.dnsName) \(monitor.dnsType)", monospaced: true)
                }
                DetailRow(label: "Every", value: duration(monitor.intervalSec), copyable: false)
                DetailRow(label: "Timeout", value: duration(monitor.timeoutSec), copyable: false)
                if monitor.thresholdDays > 0 {
                    DetailRow(label: "Fails within", value: "\(monitor.thresholdDays) days of expiry", copyable: false)
                }
                DetailRow(label: "Runs on", value: runsOn(monitor), copyable: false)
                DetailRow(label: "State", value: monitor.enabled ? "Running" : "Paused", copyable: false)
                if !monitor.alert.isEmpty {
                    DetailRow(label: "Alerts", value: alertWords(monitor), copyable: false)
                }
            } header: {
                Text("Configuration").accessibilityAddTraits(.isHeader)
            }
            if !monitor.isGenerated { actionsSection(monitor) }
            Section {
                WebLinkRow(title: monitor.isGenerated ? "Open on web" : "Edit on web", path: .check(id: monitor.id))
            } footer: {
                MonitoringFreshness(state: store.monitors, cadence: .monitoring)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await store.refreshChecks()
            await loadSeries()
        }
    }

    @ViewBuilder
    private func generatedSection(_ monitor: Monitor) -> some View {
        Section {
            if !monitor.checkDefinitionID.isEmpty {
                let name = store.definitions.value?.definitions.first { $0.id == monitor.checkDefinitionID }?.displayName ?? monitor.checkDefinitionID
                NavigationLink(value: AppRoute.monitoring(.definition(id: monitor.checkDefinitionID))) {
                    Label {
                        Text("Generated by definition \(name): change it on web")
                    } icon: {
                        Image(systemName: "square.stack.3d.up").foregroundStyle(Color.statusQuiet)
                    }
                    .frame(minHeight: Spacing.minimumTarget)
                }
            } else {
                Label {
                    Text("Generated by the \(monitor.managedBy) probe configuration: change it on web")
                } icon: {
                    Image(systemName: "gearshape.2").foregroundStyle(Color.statusQuiet)
                }
                .frame(minHeight: Spacing.minimumTarget)
            }
        } footer: {
            Text("The server refuses pause, resume and delete on a generated check.")
        }
    }

    private func resultsSection(_ monitor: Monitor) -> some View {
        Section {
            if monitor.latest.isEmpty {
                Label(monitor.enabled ? "No results yet" : "Paused: no new results", systemImage: monitor.enabled ? "circle.dashed" : "pause.circle")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: Spacing.minimumTarget)
            }
            ForEach(monitor.latest, id: \.nodeID) { latest in
                latestRow(latest, monitor: monitor)
            }
            NavigationLink(value: AppRoute.monitoring(.checkResults(id: monitor.id))) {
                Text("All results").frame(minHeight: Spacing.minimumTarget)
            }
        } header: {
            Text("Last result per source").accessibilityAddTraits(.isHeader)
        }
    }

    private func latestRow(_ latest: MonitoringLatest, monitor: Monitor) -> some View {
        let outcome: MonitoringResultOutcome = !latest.reason.isEmpty ? .unmeasured : (latest.success ? .passed : .failed)
        let style = MonitoringStyle.result(outcome)
        let name = latest.nodeID.isEmpty ? MonitoringPaths.controlPlaneName : nodes.name(for: latest.nodeID)
        let age = latest.at.map { RelativeDateFormatter.string(from: $0) }
        var reason: String?
        if !latest.reason.isEmpty {
            reason = PathReason.sentence(for: latest.reason)
        } else if !latest.success {
            reason = [latest.error, latest.failStreak > 1 ? "\(latest.failStreak) failures in a row" : nil].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
        }
        var detailParts = [age].compactMap { $0 }
        if let expiry = latest.certNotAfter {
            detailParts.append("certificate until \(TimeDisplay.dateTime(expiry, mode: mode, locale: locale))")
        }
        if latest.sent > 0 { detailParts.append("\(latest.sent - latest.lost) of \(latest.sent) echoes") }
        return StatusRow(
            style: style,
            title: name,
            detail: detailParts.joined(separator: ", "),
            reason: reason,
            trailing: latest.success ? latest.latencyMs.map(MonitoringFormat.milliseconds) : nil,
            accessibilityPhrase: "\(name), \(style.word)" + (age.map { ", \($0)" } ?? "")
        )
    }

    @ViewBuilder
    private func chartSection(_ monitor: Monitor) -> some View {
        let options = sources(monitor)
        Section {
            if monitor.type != .tls, options.count > 1 {
                Picker("Source", selection: Binding(get: { source ?? options.first ?? "" }, set: { source = $0 })) {
                    ForEach(options, id: \.self) { Text(nodes.name(for: $0)).tag($0) }
                }
                .frame(minHeight: Spacing.minimumTarget)
            }
            switch series.series {
            case .denied(let scope):
                ScopeDeniedRow(scope: scope)
            case .failed(let error, nil, _):
                ErrorRow(message: "Could not load the series: \(error.localizedDescription)") { Task { await loadSeries() } }
            default:
                if let value = series.series.value {
                    if MonitoringSeriesSegments.isEmpty(value) {
                        Label("No results in the last \(value.window)", systemImage: "chart.line.flattrend.xyaxis")
                            .foregroundStyle(.secondary)
                            .frame(minHeight: Spacing.minimumTarget)
                    } else {
                        PathCharts(series: value, problem: health(monitor).isFailing)
                            .padding(.vertical, Spacing.s)
                    }
                } else {
                    LoadingRows(label: "Loading the latency chart", count: 2)
                }
            }
        } header: {
            Text("Latency, last \(appState.monitorWindow.rawValue)").accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func incidentsSection(_ monitor: Monitor) -> some View {
        let incidents = (store.incidents.value?.incidents ?? []).filter { $0.monitorID == monitor.id && $0.state != "resolved" }
        if !incidents.isEmpty {
            Section {
                ForEach(incidents) { incident in
                    NavigationLink(value: AppRoute.monitoring(.incident(id: incident.id))) {
                        IncidentRow(incident: incident, canAdmin: store.canAdmin)
                    }
                }
            } header: {
                Text("Incidents").accessibilityAddTraits(.isHeader)
            }
        }
    }

    @ViewBuilder
    private func actionsSection(_ monitor: Monitor) -> some View {
        let missing = store.missing(ScopeRequirement(MonitoringStore.adminScope))
        Section {
            if monitor.isEditable && store.serverEditsChecks {
                Button {
                    Task { await runner.run(MonitoringIntents.setEnabled(monitor, enabled: !monitor.enabled)) }
                } label: {
                    actionLabel(monitor.enabled ? "Pause check" : "Resume check", symbol: monitor.enabled ? "pause.circle" : "play.circle", missing: missing)
                }
                .disabled(!missing.isEmpty)
            } else {
                Label("This server cannot pause checks from the phone. Edit on web.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                Task { await runner.run(MonitoringIntents.deleteCheck(monitor)) }
            } label: {
                actionLabel("Delete check", symbol: "trash", missing: missing)
            }
            .disabled(!missing.isEmpty)
        } header: {
            Text("Actions").accessibilityAddTraits(.isHeader)
        }
    }

    private func actionLabel(_ title: String, symbol: String, missing: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Label(title, systemImage: symbol)
            if !missing.isEmpty {
                Text("Needs \(missing.joined(separator: ", "))").textRole(.footnote)
            }
        }
        .frame(minHeight: Spacing.minimumTarget)
    }

    private var menu: some View {
        Menu {
            Button("Open on web", systemImage: "safari") { router.openOnWeb(.check(id: id)) }
            Button("Copy link", systemImage: "link") { UIPasteboard.general.url = LatticeDeepLink.check(id: id).customURL }
            Button("Copy ID", systemImage: "number") { UIPasteboard.general.string = id }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    private func duration(_ seconds: Int) -> String {
        TimeDisplay.duration(TimeInterval(seconds), locale: locale)
    }

    private func runsOn(_ monitor: Monitor) -> String {
        if monitor.type == .tls { return "Control plane" }
        if monitor.assignAll { return "Every node" }
        let count = monitor.nodeIDs.count
        let paused = monitor.pausedNodeIDs.count
        let base = count == 1 ? nodes.name(for: monitor.nodeIDs[0]) : "\(count) nodes"
        return paused > 0 ? "\(base), \(paused) paused" : base
    }

    private func alertWords(_ monitor: Monitor) -> String {
        let after = monitor.alertAfter > 0 ? monitor.alertAfter : 2
        switch monitor.alert {
        case "off": return "Never"
        case "down_and_degraded": return "Down after \(after) failures, and degraded"
        default: return "Down after \(after) failures"
        }
    }
}
