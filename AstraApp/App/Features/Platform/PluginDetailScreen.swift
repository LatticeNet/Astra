import SwiftUI

/// M8-02 Plugin: manifest facts, capabilities with their risk, scopes per
/// interface method, contributed pages, lifecycle history and runtime
/// health. Activate or Disable is T3 (plugin:admin); install and verify
/// stay on the web.
struct PluginDetailScreen: View {
    let id: String

    @Environment(PlatformStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(ActionRunner.self) private var runner
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        PlatformListState(state: store.listState, noun: "the plugin", retry: { Task { await store.refresh() } }) { rows in
            if let row = rows.first(where: { $0.id == id }) {
                detail(row)
            } else {
                notFound
            }
        }
        .navigationTitle(store.row(id: id)?.name ?? "Plugin")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(store.row(id: id).map { StatusStyle.platformPlugin($0).word } ?? "")
        .refreshable { await store.refresh() }
        .polling(.standard, version: changes.version(.plugins)) { await store.refresh() }
        .toolbar { toolbar }
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(_ row: PlatformPluginRow) -> some View {
        let style = StatusStyle.platformPlugin(row)
        List {
            Section {
                StatusRow(style: style, title: row.name, detail: IdentifierText.breakable(row.id), reason: runtimeReason(row),
                          accessibilityPhrase: "\(row.name), \(style.word)")
                PlatformRefreshError(state: store.registered, noun: "the plugin") { Task { await store.refresh() } }
                lifecycleAction(row)
            } footer: {
                if row.health == .failed, row.lifecycleRead {
                    Text("Disable and activate it again to restart the runtime, or check the bundle on the web.")
                }
            }

            Section("Plugin") {
                DetailRow(label: "Version", value: row.version.isEmpty ? "Not stated" : row.version, copyable: !row.version.isEmpty)
                DetailRow(label: "Type", value: typeWord(row.type), copyable: false)
                DetailRow(label: "Publisher", value: row.publisher.isEmpty ? "Not stated" : row.publisher, copyable: false)
                DetailRow(label: "Lifecycle", value: row.status.isEmpty ? "Unknown" : row.status.platformCapitalized, copyable: false)
                DetailRow(label: "Risk", value: row.risk.platformTitle, secondary: row.risk.platformSentence, copyable: false)
                if !row.artifactSHA256.isEmpty {
                    DetailRow(label: "Artifact digest", value: row.artifactSHA256, monospaced: true)
                }
            }

            runtimeSection(row)
            capabilitiesSection(row)
            interfacesSection(row)
            pagesSection(row)

            if !row.transitions.isEmpty {
                Section("Lifecycle history") {
                    ForEach(row.transitions, id: \.key) { transition in
                        DetailRow(label: transition.key.platformCapitalized, value: TimeDisplay.dateTime(transition.at, mode: mode, locale: locale),
                                  secondary: TimeDisplay.relative(transition.at, now: Date(), locale: locale), copyable: false)
                    }
                }
            }

            Section {
                WebLinkRow(title: "Install, verify or upgrade on web", path: .plugin(id: row.id))
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Installing and verifying need the bundle file and the signing ceremony, so they stay on the web.")
                    FreshnessFooter(state: store.registered, interval: 60)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func runtimeReason(_ row: PlatformPluginRow) -> String? {
        guard row.health == .failed || row.health == .stopped || row.health == .missing else { return nil }
        if row.health == .missing { return "The bundle is no longer in the plugin directory." }
        return row.runtime.flatMap { $0.message.isEmpty ? nil : $0.message }
    }

    @ViewBuilder
    private func lifecycleAction(_ row: PlatformPluginRow) -> some View {
        if let target = row.nextLifecycleStates.first {
            if target == "active" || target == "disabled" {
                PlatformActionRow(title: target == "active" ? "Activate \(row.name)" : "Disable \(row.name)",
                                  systemImage: target == "active" ? "play.circle" : "stop.circle",
                                  note: target == "active" ? "Starts its runtime" : "Stops its runtime at once",
                                  missing: store.adminMissing, role: target == "disabled" ? .destructive : nil) {
                    Task { await runner.run(PlatformIntents.lifecycle(pluginID: row.id, name: row.name, to: target)) }
                }
            } else {
                WebLinkRow(title: "Install on web", path: .plugin(id: row.id))
            }
        }
    }

    @ViewBuilder
    private func runtimeSection(_ row: PlatformPluginRow) -> some View {
        Section {
            if let runtime = row.runtime {
                DetailRow(label: "Runtime", value: runtime.state.platformCapitalized, copyable: false)
                if !runtime.runner.isEmpty {
                    DetailRow(label: "Runner", value: runtime.runner, copyable: false)
                }
                if let started = runtime.startedAt, runtime.state != "stopped" {
                    DetailRow(label: "Started", value: TimeDisplay.dateTime(started, mode: mode, locale: locale),
                              secondary: TimeDisplay.relative(started, now: Date(), locale: locale), copyable: false)
                }
                if let stopped = runtime.stoppedAt, runtime.state == "stopped" {
                    DetailRow(label: "Stopped", value: TimeDisplay.dateTime(stopped, mode: mode, locale: locale),
                              secondary: TimeDisplay.relative(stopped, now: Date(), locale: locale), copyable: false)
                }
                if !runtime.message.isEmpty {
                    DetailRow(label: "Message", value: runtime.message, copyable: true)
                }
            } else if case .denied(let scope) = store.lifecycle {
                ScopeDeniedRow(scope: scope)
            } else if row.lifecycleRead {
                DetailRow(label: "Runtime", value: "Not started", copyable: false)
            } else {
                PlatformSectionState(state: store.lifecycle, noun: "runtime health") { Task { await store.refresh() } }
            }
        } header: {
            Text("Health")
        }
    }

    @ViewBuilder
    private func capabilitiesSection(_ row: PlatformPluginRow) -> some View {
        Section {
            if row.capabilities.isEmpty {
                Text("No capabilities listed").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
            }
            ForEach(row.capabilities, id: \.self) { capability in
                let risk = PlatformCapabilityRisk.of(capability)
                DetailRow(label: capability, value: "\(risk.platformTitle) risk", copyable: false)
            }
        } header: {
            Text("Capabilities")
        } footer: {
            Text("What the plugin's own code may do through the broker. The server checks every call.")
        }
    }

    @ViewBuilder
    private func interfacesSection(_ row: PlatformPluginRow) -> some View {
        ForEach(row.interfaces, id: \.service) { contract in
            Section {
                ForEach(contract.methods, id: \.name) { method in
                    let scopes = contract.scopes(for: method.name)
                    DetailRow(label: IdentifierText.breakable(method.name),
                              value: scopes.isEmpty ? "No scope" : scopes.joined(separator: ", "),
                              secondary: method.effect.isEmpty ? nil : method.effect.platformCapitalized,
                              copyable: false)
                }
            } header: {
                Text(IdentifierText.breakable(contract.service))
                    .textCase(nil)
                    .accessibilityLabel("Interface \(contract.service)")
            } footer: {
                if contract.backing == "core" {
                    Text("Served by the control plane on the plugin's behalf.")
                }
            }
        }
    }

    @ViewBuilder
    private func pagesSection(_ row: PlatformPluginRow) -> some View {
        if !row.pages.isEmpty {
            Section {
                ForEach(row.pages) { page in
                    if page.isNative {
                        NavigationLink(value: AppRoute.platform(.extensionPage(pluginID: row.id, route: page.route))) {
                            Label(page.title, systemImage: page.kind == "detail" ? "list.bullet.rectangle" : "tablecells")
                                .frame(minHeight: Spacing.minimumTarget)
                        }
                    } else {
                        WebLinkRow(title: page.title, path: LatticeConsolePath(path: page.consolePath))
                    }
                }
            } header: {
                Text("Pages")
            } footer: {
                Text("Table and detail pages open here. Other kinds open on the web.")
            }
        } else if row.status == "active" {
            Section("Pages") {
                Text("This plugin contributes no pages you can see.").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
            }
        }
    }

    private func typeWord(_ type: String) -> String {
        switch type {
        case "system": "System (runs in the control plane)"
        case "wasm": "WebAssembly (sandboxed)"
        case "worker": "Worker"
        case "": "Not stated"
        default: type
        }
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Plugin not found", systemImage: "puzzlepiece.extension")
            } description: {
                Text("No registered plugin has this id. It may have been removed from the plugin directory.")
            } actions: {
                Button("Open on web") { router.openOnWeb(.plugin(id: id)) }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let row = store.row(id: id), let target = row.nextLifecycleStates.first, target == "active" || target == "disabled" {
                    PlatformGatedButton(title: target == "active" ? "Activate" : "Disable", systemImage: target == "active" ? "play.circle" : "stop.circle",
                                        missing: store.adminMissing, role: target == "disabled" ? .destructive : nil) {
                        Task { await runner.run(PlatformIntents.lifecycle(pluginID: row.id, name: row.name, to: target)) }
                    }
                }
                Section {
                    Button("Copy link", systemImage: "link") { PlatformCopy.copy(PlatformCopy.pluginLink(id)) }
                    Button("Copy ID", systemImage: "doc.on.doc") { PlatformCopy.copy(id) }
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.plugin(id: id)) }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}

extension String {
    /// "Activated" from "activated".
    var platformCapitalized: String {
        prefix(1).uppercased() + dropFirst()
    }
}
