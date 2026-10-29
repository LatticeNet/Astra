import SwiftUI
import UIKit

/// M3-13 Maintenance window: its facts, the incidents it holds, End now
/// and Delete (both T2).
struct MaintenanceWindowScreen: View {
    let id: String

    @Environment(MonitoringStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content
            .navigationTitle(store.window(id: id)?.name ?? "Maintenance window")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(store.window(id: id).map { stateWord($0) } ?? "")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Edit on web", systemImage: "safari") { router.openOnWeb(.maintenance) }
                        Button("Copy link", systemImage: "link") { UIPasteboard.general.url = LatticeDeepLink.maintenanceWindow(id: id).customURL }
                        Button("Copy ID", systemImage: "number") { UIPasteboard.general.string = id }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .polling(.standard, version: changes.version([.maintenance, .incidents])) {
                await nodes.refreshIfOlder(than: 60)
                return await store.refreshIncidents()
            }
    }

    private func stateWord(_ window: MaintenanceWindow) -> String {
        let now = Date()
        if window.isActive(now: now) { return "active" }
        if let start = window.startsAt, start > now { return "scheduled" }
        return "ended"
    }

    @ViewBuilder
    private var content: some View {
        if let window = store.window(id: id) {
            detail(window)
        } else if store.windows.value != nil {
            WholeScreenState {
                ContentUnavailableView {
                    Label("Window not found", systemImage: "wrench.and.screwdriver")
                } description: {
                    Text("It may have ended or been deleted.")
                } actions: {
                    Button("Open on web") { router.openOnWeb(.maintenance) }
                }
            }
        } else {
            ResourceView(state: store.windows, noun: "the window", retry: { Task { await store.refreshIncidents() } }) { _ in EmptyView() }
        }
    }

    private func detail(_ window: MaintenanceWindow) -> some View {
        let held = (store.incidents.value?.incidents ?? []).filter { MonitoringMaintenance.holds(window, $0) && $0.state != "resolved" }
        let active = window.isActive(now: Date())
        let missing = store.missing(ScopeRequirement(MonitoringStore.adminScope))
        return List {
            MonitoringRefreshError(state: store.windows, noun: "the window") { Task { await store.refreshIncidents() } }
            Section {
                StatusRow(style: active ? StatusStyle(word: "active", symbol: "wrench.and.screwdriver", tone: .quiet)
                                        : StatusStyle(word: stateWord(window), symbol: "calendar", tone: .quiet),
                          title: window.name, accessibilityPhrase: "\(window.name), \(stateWord(window))")
                ForEach(window.nodeIDs, id: \.self) { nodeID in
                    NavigationLink(value: AppRoute.fleet(.node(id: nodeID))) {
                        LabeledContent("Node", value: nodes.name(for: nodeID)).frame(minHeight: Spacing.minimumTarget)
                    }
                }
                ForEach(window.groupIDs, id: \.self) { groupID in
                    NavigationLink(value: AppRoute.fleet(.group(id: groupID))) {
                        LabeledContent("Group", value: groupID).frame(minHeight: Spacing.minimumTarget)
                    }
                }
                if let start = window.startsAt {
                    DetailRow(label: "Starts", value: TimeDisplay.dateTime(start, mode: mode, locale: locale), secondary: TimeDisplay.otherZone(start, mode: mode, locale: locale), copyable: false)
                }
                if let end = window.endsAt {
                    DetailRow(label: "Ends", value: TimeDisplay.dateTime(end, mode: mode, locale: locale),
                              secondary: "\(TimeDisplay.relative(end, now: Date(), locale: locale)), \(TimeDisplay.otherZone(end, mode: mode, locale: locale))", copyable: false)
                }
                if !window.reason.isEmpty {
                    DetailRow(label: "Note", value: window.reason, copyable: false)
                }
                if !window.createdBy.isEmpty {
                    DetailRow(label: "Created by", value: window.createdBy, monospaced: true)
                }
            }
            Section {
                if held.isEmpty {
                    Text("It holds no open incident.").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
                }
                ForEach(held) { incident in
                    NavigationLink(value: AppRoute.monitoring(.incident(id: incident.id))) {
                        IncidentRow(incident: incident)
                    }
                }
            } header: {
                Text("Incidents it holds").accessibilityAddTraits(.isHeader)
            }
            Section {
                if active {
                    Button {
                        Task { await runner.run(MonitoringIntents.endMaintenance(window)) }
                    } label: {
                        actionLabel("End now", symbol: "stop.circle", missing: missing)
                    }
                    .disabled(!missing.isEmpty)
                }
                Button(role: .destructive) {
                    Task {
                        if case .done = await runner.run(MonitoringIntents.deleteMaintenance(window)) { dismiss() }
                    }
                } label: {
                    actionLabel("Delete window", symbol: "trash", missing: missing)
                }
                .disabled(!missing.isEmpty)
                WebLinkRow(title: "Edit on web", path: .maintenance)
            } header: {
                Text("Actions").accessibilityAddTraits(.isHeader)
            } footer: {
                MonitoringFreshness(state: store.windows, cadence: .standard)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refreshIncidents() }
    }

    private func actionLabel(_ title: String, symbol: String, missing: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Label(title, systemImage: symbol)
            if !missing.isEmpty { Text("Needs \(missing.joined(separator: ", "))").textRole(.footnote) }
        }
        .frame(minHeight: Spacing.minimumTarget)
    }
}
