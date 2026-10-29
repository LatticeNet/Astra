import SwiftUI

/// M8-12 Extensions: every page an active plugin contributes and this token
/// may see (`/api/plugin-contributions`, any signed-in caller), grouped by
/// plugin. Table and detail pages push M8-03; every other kind opens on the web.
struct ExtensionsScreen: View {
    @Environment(PlatformStore.self) private var store
    @Environment(ChangeLog.self) private var changes

    var body: some View {
        PlatformListState(state: store.contributions, noun: "plugin pages", retry: { Task { await store.refreshContributions() } }) { plugins in
            list(plugins.filter { !PlatformPluginPages.pages(pluginID: $0.id, ui: $0.ui).isEmpty })
        }
        .navigationTitle("Extensions")
        .refreshable { await store.refreshContributions() }
        .polling(.standard, version: changes.version(.plugins)) { await store.refreshContributions() }
    }

    @ViewBuilder
    private func list(_ plugins: [PlatformPlugin]) -> some View {
        if plugins.isEmpty {
            WholeScreenState {
                ContentUnavailableView {
                    Label("No plugin pages", systemImage: "square.on.square")
                } description: {
                    Text("No active plugin contributes a page this token may see.")
                }
            }
        } else {
            List {
                PlatformRefreshError(state: store.contributions, noun: "plugin pages") { Task { await store.refreshContributions() } }
                ForEach(plugins.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { plugin in
                    Section {
                        ForEach(PlatformPluginPages.pages(pluginID: plugin.id, ui: plugin.ui)) { page in
                            if page.isNative {
                                NavigationLink(value: AppRoute.platform(.extensionPage(pluginID: plugin.id, route: page.route))) {
                                    PlatformPageLabel(page: page)
                                }
                            } else {
                                WebLinkRow(title: page.title, path: LatticeConsolePath(path: page.consolePath))
                            }
                        }
                    } header: {
                        Text(plugin.name.isEmpty ? plugin.id : plugin.name)
                            .accessibilityAddTraits(.isHeader)
                    } footer: {
                        if !plugin.publisher.isEmpty, plugin.publisher != "latticenet" {
                            Text("From \(plugin.publisher), a non-official publisher.")
                        }
                    }
                }
                Section {
                } footer: {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Table and detail pages open here. Forms, sandboxed pages and other kinds open on the web, and so does every action a page offers.")
                        FreshnessFooter(state: store.contributions, interval: 60)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

/// A native page row: its kind's symbol, title and kind word.
struct PlatformPageLabel: View {
    let page: PlatformPluginPage

    var body: some View {
        let detail = page.kind == "detail"
        StatusRow(style: StatusStyle(word: detail ? "detail" : "table", symbol: detail ? "list.bullet.rectangle" : "tablecells", tone: .quiet),
                  title: page.title, accessibilityPhrase: "\(page.title), \(detail ? "detail page" : "table page")")
    }
}
