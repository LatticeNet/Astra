import SwiftUI

/// A check's result history. The endpoint has no offset, so a longer
/// history is a larger page, up to the server's 2000.
@MainActor @Observable
final class MonitoringResultsModel {
    private(set) var results: ResourceState<[MonitorResult]> = .idle
    private(set) var limit = 100
    static let steps = [100, 500, monitoringResultsMaxLimit]

    var canLoadMore: Bool {
        guard let count = results.value?.count else { return false }
        return count >= limit && limit < monitoringResultsMaxLimit
    }

    @discardableResult
    func load(monitorID: String, nodeID: String?, session: SessionStore, more: Bool = false) async -> Bool {
        if more, let next = Self.steps.first(where: { $0 > limit }) { limit = next }
        if let missing = session.missing(MonitoringStore.readRequirement), !missing.isEmpty {
            results = .denied(scope: missing.joined(separator: " and "))
            return true
        }
        guard let client = session.client else { return false }
        results = results.reloading
        do {
            results = .loaded(try await client.monitoringResults(monitorID: monitorID, nodeID: nodeID, limit: limit), at: Date())
            return true
        } catch {
            results = results.failing(LatticeAPIError(error), surface: "Check results", missingScope: "monitor:read")
            return false
        }
    }
}

/// M3-08 All results, filterable by node and outcome.
struct CheckResultsScreen: View {
    let checkID: String

    @Environment(MonitoringStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(NodeDirectory.self) private var nodes
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    @State private var model = MonitoringResultsModel()
    @State private var node = CheckResultsScreen.allNodes
    @State private var outcome = CheckResultsScreen.allOutcomes

    private static let allNodes = "All nodes"
    private static let allOutcomes = "All outcomes"

    var body: some View {
        ResourceView(state: model.results, noun: "results", retry: reload) { results in
            let rows = results.filter { outcome == Self.allOutcomes || $0.outcome.rawValue == outcome }
            List {
                MonitoringRefreshError(state: model.results, noun: "results", retry: reload)
                if node != Self.allNodes || outcome != Self.allOutcomes {
                    FilterStateRow(text: "Showing \(filterText)") {
                        node = Self.allNodes
                        outcome = Self.allOutcomes
                    }
                }
                if rows.isEmpty {
                    ContentUnavailableView("No results", systemImage: "list.bullet.rectangle", description: Text("Nothing matches these filters in the newest \(model.limit)."))
                }
                Section {
                    ForEach(rows) { result in resultRow(result) }
                    if model.canLoadMore {
                        Button("Load more") { Task { await model.load(monitorID: checkID, nodeID: nodeFilter, session: session, more: true) } }
                            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget)
                    }
                } header: {
                    Text("Newest first").accessibilityAddTraits(.isHeader)
                } footer: {
                    MonitoringFreshness(state: model.results, cadence: .standard)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.load(monitorID: checkID, nodeID: nodeFilter, session: session) }
        }
        .navigationTitle("All results")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(store.monitor(id: checkID)?.displayName ?? checkID)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                FilterMenu(sections: [
                    FilterMenuSection(title: "Node", options: [Self.allNodes] + nodeOptions.map(\.name), defaultOption: Self.allNodes, selection: $node),
                    FilterMenuSection(title: "Outcome", options: [Self.allOutcomes] + MonitoringResultOutcome.allCases.map(\.rawValue), defaultOption: Self.allOutcomes, selection: $outcome),
                ])
            }
        }
        .onChange(of: node) { reload() }
        .polling(.standard, version: changes.version(.checks)) {
            await nodes.refreshIfOlder(than: 60)
            if store.monitor(id: checkID) == nil { await store.refreshChecks() }
            return await model.load(monitorID: checkID, nodeID: nodeFilter, session: session)
        }
    }

    private var nodeOptions: [(id: String, name: String)] {
        guard let monitor = store.monitor(id: checkID) else { return [] }
        let ids = Array(Set(monitor.nodeIDs + monitor.latest.map(\.nodeID))).sorted()
        return ids.map { ($0, $0.isEmpty ? MonitoringPaths.controlPlaneName : nodes.name(for: $0)) }
    }

    private var nodeFilter: String? {
        node == Self.allNodes ? nil : nodeOptions.first { $0.name == node }?.id
    }

    private var filterText: String {
        [node == Self.allNodes ? nil : node, outcome == Self.allOutcomes ? nil : outcome].compactMap { $0 }.joined(separator: ", ")
    }

    private func reload() {
        Task { await model.load(monitorID: checkID, nodeID: nodeFilter, session: session) }
    }

    private func resultRow(_ result: MonitorResult) -> some View {
        let style = MonitoringStyle.result(result.outcome)
        let name = result.nodeID.isEmpty ? MonitoringPaths.controlPlaneName : nodes.name(for: result.nodeID)
        let time = result.at.map { TimeDisplay.dateTime($0, mode: mode, locale: locale) } ?? "unknown time"
        var reason: String?
        if !result.reason.isEmpty { reason = PathReason.sentence(for: result.reason) } else if let error = result.error, !error.isEmpty { reason = error }
        var detail = time
        if let received = result.receivedAt, let at = result.at, received.timeIntervalSince(at) > 120 {
            detail += ", arrived \(RelativeDateFormatter.shortDuration(received.timeIntervalSince(at))) late"
        }
        if result.sent > 0 { detail += ", \(result.sent - result.lost) of \(result.sent) echoes" }
        return StatusRow(
            style: style,
            title: name,
            detail: detail,
            reason: reason,
            trailing: result.success ? MonitoringFormat.milliseconds(result.latencyMs) : nil,
            accessibilityPhrase: "\(name), \(style.word), \(time)"
        )
    }
}
