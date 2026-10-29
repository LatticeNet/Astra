import SwiftUI
import UIKit

/// One check definition read by id, with every monitor it expanded to.
@MainActor @Observable
final class MonitoringDefinitionModel {
    private(set) var definition: ResourceState<MonitoringCheckDefinition> = .idle

    @discardableResult
    func load(id: String, session: SessionStore) async -> Bool {
        if let missing = session.missing(MonitoringStore.readRequirement), !missing.isEmpty {
            definition = .denied(scope: missing.joined(separator: " and "))
            return true
        }
        guard let client = session.client else { return false }
        definition = definition.reloading
        do {
            definition = .loaded(try await client.monitoringDefinition(id: id), at: Date())
            return true
        } catch {
            let apiError = LatticeAPIError(error)
            if case .invalidResponse = apiError { session.markCompanionBehind("Check definition") }
            definition = definition.failing(apiError, surface: "The check definition", missingScope: "monitor:read")
            return false
        }
    }
}

/// M3-09 Definition: its fields, the pairs it generates, the paused ones and
/// why, and Delete (T4) with every monitor that goes listed first.
struct DefinitionDetailScreen: View {
    let id: String

    @Environment(MonitoringStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    @State private var model = MonitoringDefinitionModel()

    var body: some View {
        content
            .navigationTitle(model.definition.value?.displayName ?? "Definition")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(model.definition.value.map { $0.enabled ? "enabled" : "paused" } ?? "")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { menu } }
            .polling(.standard, version: changes.version([.definitions, .checks])) {
                await nodes.refreshIfOlder(than: 60)
                if store.paths.value == nil { await store.refreshPaths(window: appState.monitorWindow) }
                return await model.load(id: id, session: session)
            }
    }

    @ViewBuilder
    private var content: some View {
        if case .failed(.notFound, nil, _) = model.definition {
            WholeScreenState {
                ContentUnavailableView {
                    Label("Definition not found", systemImage: "square.stack.3d.up.slash")
                } description: {
                    Text("No check definition \(id) is visible to this token. It may have been deleted.")
                } actions: {
                    Button("Open on web") { router.openOnWeb(.definition(id: id)) }
                }
            }
        } else {
            ResourceView(state: model.definition, noun: "the definition", retry: reload) { definition in
                detail(definition)
            }
        }
    }

    private func detail(_ definition: MonitoringCheckDefinition) -> some View {
        let monitors = definition.monitors ?? []
        let inSet = monitors.filter(\.inSet)
        let pausedTargets = monitors.filter { !$0.inSet }
        let skipped = store.pathItems { nodes.nodes[$0]?.displayName }.filter { $0.path.checkDefinitionID == definition.id && $0.display.measure != .measured }
        return List {
            MonitoringRefreshError(state: model.definition, noun: "the definition", retry: reload)
            Section {
                DetailRow(label: "Method", value: definition.type, copyable: false)
                DetailRow(label: "Sources", value: selector(definition.sources, emptyWord: "Control plane"), copyable: false)
                if !definition.targets.isEmpty {
                    DetailRow(label: "Targets", value: selector(definition.targets, emptyWord: "None"), copyable: false)
                }
                if !definition.addresses.isEmpty {
                    DetailRow(label: "Addresses", value: definition.addresses.joined(separator: "\n"), monospaced: true)
                }
                DetailRow(label: "Every", value: TimeDisplay.duration(TimeInterval(definition.intervalSec), locale: locale), copyable: false)
                DetailRow(label: "Timeout", value: TimeDisplay.duration(TimeInterval(definition.timeoutSec), locale: locale), copyable: false)
                DetailRow(label: "State", value: definition.enabled ? "Enabled" : "Paused", copyable: false)
                DetailRow(label: "Version", value: String(definition.version), copyable: false)
                if let updated = definition.updatedAt {
                    DetailRow(label: "Changed", value: TimeDisplay.relative(updated, now: Date(), locale: locale),
                              secondary: [definition.updatedBy.isEmpty ? nil : "by \(definition.updatedBy)", TimeDisplay.dateTime(updated, mode: mode, locale: locale)].compactMap { $0 }.joined(separator: ", "),
                              copyable: false)
                }
            } header: {
                Text("Definition").accessibilityAddTraits(.isHeader)
            }
            if let summary = definition.summary {
                Section {
                    DetailRow(label: "Checks", value: String(summary.monitors), copyable: false)
                    DetailRow(label: "Paths", value: String(summary.paths), copyable: false)
                    DetailRow(label: "Paused targets", value: summary.pausedTargets == 0 ? "None" : "\(summary.pausedTargets), \(summary.pausedRuns.formatted()) results kept", copyable: false)
                } header: {
                    Text("What it holds").accessibilityAddTraits(.isHeader)
                }
            }
            Section {
                if inSet.isEmpty {
                    Text("It generates no checks right now.").foregroundStyle(.secondary)
                }
                ForEach(inSet) { monitor in
                    NavigationLink(value: AppRoute.monitoring(.check(id: monitor.monitorID))) {
                        StatusRow(
                            style: monitor.enabled ? StatusStyle(word: monitor.method, symbol: "checklist", tone: .quiet)
                                : StatusStyle(word: "paused", symbol: "pause.circle", tone: .quiet),
                            title: monitor.targetNode.isEmpty ? monitor.target : nodes.name(for: monitor.targetNode),
                            detail: sourcesText(monitor.sources),
                            trailing: monitor.runs.formatted(),
                            accessibilityPhrase: "Check to \(monitor.targetNode.isEmpty ? monitor.target : nodes.name(for: monitor.targetNode)), \(monitor.runs) results"
                        )
                    }
                }
            } header: {
                Text("Checks it generates").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("The trailing number is the results each check has recorded.")
            }
            if !pausedTargets.isEmpty || !skipped.isEmpty || !definition.excludedPairs.isEmpty {
                Section {
                    ForEach(pausedTargets) { monitor in
                        StatusRow(
                            style: StatusStyle(word: "paused", symbol: "pause.circle", tone: .quiet),
                            title: monitor.targetNode.isEmpty ? monitor.target : nodes.name(for: monitor.targetNode),
                            detail: "Target left the set; \(monitor.runs.formatted()) results kept",
                            accessibilityPhrase: "Paused target \(monitor.targetNode.isEmpty ? monitor.target : nodes.name(for: monitor.targetNode)), it left the set"
                        )
                    }
                    ForEach(skipped) { item in
                        NavigationLink(value: AppRoute.monitoring(.path(key: item.key))) {
                            MonitoringPathListRow(item: item)
                        }
                    }
                    ForEach(definition.excludedPairs, id: \.self) { pair in
                        StatusRow(
                            style: StatusStyle(word: "excluded", symbol: "minus.circle", tone: .quiet),
                            title: "\(nodes.name(for: pair.source)) → \(nodes.name(for: pair.target))",
                            detail: "Never measured: stop measuring this pair",
                            accessibilityPhrase: "\(nodes.name(for: pair.source)) to \(nodes.name(for: pair.target)), excluded"
                        )
                    }
                } header: {
                    Text("Paused pairs and why").accessibilityAddTraits(.isHeader)
                }
            }
            Section {
                Button(role: .destructive) {
                    Task { await runner.run(MonitoringIntents.deleteDefinition(id: definition.id, name: definition.displayName)) }
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Label("Delete definition", systemImage: "trash")
                        let missing = store.missing(ScopeRequirement(MonitoringStore.adminScope))
                        if !missing.isEmpty { Text("Needs \(missing.joined(separator: ", "))").textRole(.footnote) }
                    }
                    .frame(minHeight: Spacing.minimumTarget)
                }
                .disabled(!store.missing(ScopeRequirement(MonitoringStore.adminScope)).isEmpty)
                WebLinkRow(title: "Edit, preview or forget on web", path: .definition(id: definition.id))
            } header: {
                Text("Actions").accessibilityAddTraits(.isHeader)
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Deleting removes \(monitors.count == 1 ? "its check" : "all \(monitors.count) of its checks") with their history.")
                    MonitoringFreshness(state: model.definition, cadence: .standard)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.load(id: id, session: session) }
    }

    private func selector(_ selector: MonitoringTargetSelector, emptyWord: String) -> String {
        var parts: [String] = []
        if selector.all { parts.append("Every node") }
        if !selector.nodes.isEmpty { parts.append(selector.nodes.map { nodes.name(for: $0) }.joined(separator: ", ")) }
        if !selector.groups.isEmpty { parts.append("groups " + selector.groups.joined(separator: ", ")) }
        if !selector.exclude.isEmpty { parts.append("except " + selector.exclude.map { nodes.name(for: $0) }.joined(separator: ", ")) }
        return parts.isEmpty ? emptyWord : parts.joined(separator: "; ")
    }

    private func sourcesText(_ sources: [String]) -> String {
        if sources.isEmpty { return "from the control plane" }
        if sources.count <= 2 { return "from " + sources.map { nodes.name(for: $0) }.joined(separator: ", ") }
        return "from \(sources.count) sources"
    }

    private var menu: some View {
        Menu {
            Button("Open on web", systemImage: "safari") { router.openOnWeb(.definition(id: id)) }
            Button("Copy link", systemImage: "link") { UIPasteboard.general.url = LatticeDeepLink.definition(id: id).customURL }
            Button("Copy ID", systemImage: "number") { UIPasteboard.general.string = id }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    private func reload() {
        Task { await model.load(id: id, session: session) }
    }
}
