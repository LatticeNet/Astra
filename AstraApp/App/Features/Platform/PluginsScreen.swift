import SwiftUI

/// M8-01 Plugins: every registered plugin with its lifecycle state, runtime
/// health and risk, grouped worst first. Gate audit:read (the server's
/// route wrapper for `/api/plugins`); runtime health needs plugin:admin.
struct PluginsScreen: View {
    static let queryKey = "platform.plugins.query"

    @Environment(PlatformStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(ActionRunner.self) private var runner
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @SceneStorage(PluginsScreen.queryKey) private var query = ""
    @State private var stable = PlatformStableList<PlatformPluginHealth, PlatformPluginRow>()

    var body: some View {
        PlatformListState(state: store.listState, noun: "plugins", retry: { Task { await store.refresh() } }) { rows in
            list(rows)
        }
        .navigationTitle("Plugins")
        .navigationSubtitle(query)
        .searchable(text: $query, prompt: "Search plugins")
        .refreshable {
            await store.refresh()
            offer(force: true)
        }
        .polling(.standard, version: changes.version(.plugins)) { await store.refresh() }
        .onAppear { offer(force: true) }
        .onChange(of: store.listState.value) { offer(force: false) }
        .onChange(of: query) { offer(force: true) }
        .toolbar { toolbar }
    }

    /// The filtered rows grouped worst first, offered to the stable list.
    private func offer(force: Bool) {
        let rows = filtered(store.listState.value ?? []).rows
        let slots = rows.enumerated()
            .sorted { ($0.element.health.rank, $0.offset) < ($1.element.health.rank, $1.offset) }
            .map { PlatformStableList<PlatformPluginHealth, PlatformPluginRow>.Slot(group: $0.element.health, row: $0.element) }
        stable.offer(slots, voiceOver: voiceOver, force: force)
    }

    private func filtered(_ rows: [PlatformPluginRow]) -> (rows: [PlatformPluginRow], error: String?) {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return (rows, nil) }
        switch LatticeQueryEngine.compile(text, provider: PlatformPluginQueryFields.self) {
        case .success(let compiled): return (LatticeQueryEngine.apply(compiled, to: rows, now: Date()), nil)
        case .failure(let error): return (rows, error.localizedDescription)
        }
    }

    @ViewBuilder
    private func list(_ all: [PlatformPluginRow]) -> some View {
        let queryError = filtered(all).error
        let rows = stable.shown.map(\.row)
        List {
            if stable.held != nil, voiceOver {
                Section { PendingUpdatesRow(count: stable.pendingCount) { stable.showHeld() } }
            }
            if let queryError {
                Section {
                    Label(queryError, systemImage: "exclamationmark.magnifyingglass")
                        .foregroundStyle(Color.statusWarnText)
                        .frame(minHeight: Spacing.minimumTarget)
                }
            }
            if let trust = store.trust, trust.warns {
                Section {
                    trustRow(trust)
                }
            }
            PlatformRefreshError(state: store.registered, noun: "plugins") { Task { await store.refresh() } }
            if all.isEmpty {
                Section {
                    ContentUnavailableView("No plugins registered", systemImage: "puzzlepiece.extension")
                }
            } else if rows.isEmpty {
                Section {
                    ContentUnavailableView.search(text: query)
                }
            }
            ForEach(stable.groups, id: \.self) { health in
                Section {
                    ForEach(stable.rows(in: health)) { row in
                        NavigationLink(value: AppRoute.platform(.plugin(id: row.id))) {
                            PlatformPluginRowView(row: row)
                        }
                        .contextMenu { contextMenu(row) }
                        .accessibilityActions { accessibilityActions(row) }
                    }
                } header: {
                    Text(health.platformHeading).accessibilityAddTraits(.isHeader)
                }
            }
            Section {
                NavigationLink(value: AppRoute.platform(.extensions)) {
                    Label("Extensions", systemImage: "square.on.square")
                        .frame(minHeight: Spacing.minimumTarget)
                }
                WebLinkRow(title: "Install or verify a bundle on web", path: .platformPlugins)
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    if case .denied = store.lifecycle {
                        Text("Runtime health needs plugin:admin, so active plugins read as active, never as running.")
                    }
                    Text("Risk is the highest of a plugin's capabilities. Host risk needs a trusted publisher's signature.")
                    FreshnessFooter(state: store.registered, interval: 60)
                }
            }
        }
        .listStyle(.insetGrouped)
        .onScrollPhaseChange { _, phase in
            if phase != .idle { stable.noteActivity() }
        }
    }

    private func trustRow(_ trust: PluginTrust) -> some View {
        let publishers = trust.publishers.isEmpty ? "none named" : trust.publishers.joined(separator: ", ")
        let reason = trust.allowUnsignedHostRisk
            ? "Unsigned host-risk plugins are allowed. Publishers: \(publishers)."
            : "Plugins from non-official publishers are trusted: \(publishers)."
        return StatusRow(style: StatusStyle(word: "trust widened", symbol: "exclamationmark.shield", tone: .warn),
                         title: "Plugin trust", reason: reason)
    }

    @ViewBuilder
    private func contextMenu(_ row: PlatformPluginRow) -> some View {
        Button("Open", systemImage: "arrow.right.circle") { router.push(.platform(.plugin(id: row.id))) }
        Button("Copy link", systemImage: "link") { PlatformCopy.copy(PlatformCopy.pluginLink(row.id)) }
        Button("Copy ID", systemImage: "doc.on.doc") { PlatformCopy.copy(row.id) }
        Button("Open on web", systemImage: "safari") { router.openOnWeb(.plugin(id: row.id)) }
        lifecycleButton(row)
    }

    @ViewBuilder
    private func lifecycleButton(_ row: PlatformPluginRow) -> some View {
        if let target = row.nextLifecycleStates.first, target == "active" || target == "disabled" {
            PlatformGatedButton(title: target == "active" ? "Activate" : "Disable", systemImage: target == "active" ? "play.circle" : "stop.circle",
                                missing: store.adminMissing, role: target == "disabled" ? .destructive : nil) {
                Task { await runner.run(PlatformIntents.lifecycle(pluginID: row.id, name: row.name, to: target)) }
            }
        }
    }

    @ViewBuilder
    private func accessibilityActions(_ row: PlatformPluginRow) -> some View {
        Button("Copy link") { PlatformCopy.copy(PlatformCopy.pluginLink(row.id)) }
        Button("Open on web") { router.openOnWeb(.plugin(id: row.id)) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Extensions", systemImage: "square.on.square") { router.push(.platform(.extensions)) }
                Button("Open on web", systemImage: "safari") { router.openOnWeb(.platformPlugins) }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}

/// One plugin: health symbol and word, name, version, type, publisher and risk.
struct PlatformPluginRowView: View {
    let row: PlatformPluginRow

    var body: some View {
        let style = StatusStyle.platformPlugin(row)
        let detail = detailLine
        let reason = reasonLine
        StatusRow(style: style, title: row.name, detail: detail, reason: reason,
                  accessibilityPhrase: "\(row.name), \(style.word), \(detail)")
    }

    private var detailLine: String {
        var parts: [String] = []
        if !row.version.isEmpty { parts.append("v\(row.version)") }
        if !row.publisher.isEmpty { parts.append(row.publisher) }
        if row.risk != .unknown { parts.append("\(row.risk.platformTitle.lowercased()) risk") }
        if row.status != "active", !row.status.isEmpty, row.health == .unknown || row.health == .missing { parts.append(row.status) }
        return parts.joined(separator: " · ")
    }

    private var reasonLine: String? {
        switch row.health {
        case .failed, .stopped:
            row.runtime.map { $0.message.isEmpty ? "Runtime \($0.state)" : $0.message }
        case .missing:
            "The bundle is no longer in the plugin directory."
        default:
            nil
        }
    }
}
