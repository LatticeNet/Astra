import SwiftUI

/// M8-03 Extension page: a third-party plugin page of kind table or detail
/// drawn natively from its manifest (the `PluginView.vue` model), with data
/// from `/api/plugins/call`. Manifest actions write, so they open on the
/// web; secrets stay masked; unknown kinds open on the web. The source is
/// called only when declared a read, once on open, on a plugins change and
/// on pull to refresh; like the console, the page does not poll.
struct ExtensionPageScreen: View {
    let pluginID: String
    let route: String

    @Environment(PlatformStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(\.locale) private var locale
    @Environment(\.timeZoneMode) private var mode

    @State private var model = PlatformExtensionModel()
    @State private var query = ""

    private var page: ExtensionPageModel.Page? {
        store.plugin(id: pluginID).flatMap { ExtensionPageModel.page(plugin: $0, route: route) }
    }

    var body: some View {
        content
            .navigationTitle(page?.view.title.isEmpty == false ? page!.view.title : "Plugin page")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(page?.pluginName ?? "")
            .refreshable { await reload() }
            .task(id: changes.version(.plugins)) { await reload() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Open on web", systemImage: "safari") { router.openOnWeb(LatticeConsolePath(path: "/plugins/\(pluginID)/\(route)")) }
                        Button("Plugin details", systemImage: "puzzlepiece.extension") { router.push(.platform(.plugin(id: pluginID))) }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
    }

    private var missingScopes: String? {
        guard let page, !page.requiredScopes.isEmpty,
              let missing = session.missing(ScopeRequirement(groups: page.requiredScopes.map { [$0] })), !missing.isEmpty else { return nil }
        return missing.joined(separator: " and ")
    }

    @discardableResult
    private func reload() async -> Bool {
        if store.contributions.value == nil { await store.refreshContributions() }
        guard let page, page.kind != .web, page.sourceIsRead, missingScopes == nil, let client = session.client else { return true }
        return await model.load(client: client, pluginID: pluginID, source: page.view.source!)
    }

    @ViewBuilder
    private var content: some View {
        if store.contributions.value == nil {
            PlatformListState(state: store.contributions, noun: "the plugin page", retry: { Task { await store.refreshContributions() } }) { _ in EmptyView() }
        } else if let page {
            if let missing = missingScopes {
                ScopeDeniedScreen(scope: missing)
            } else if page.kind == .web {
                webOnly(page)
            } else if !page.hasSource {
                webOnly(page, reason: "This page declares no data source, so it has nothing to show here.")
            } else if !page.sourceIsRead {
                webOnly(page, reason: "\(page.pluginName) fills this page from a method that is not declared a read, so opening it here could change something. Open it on the web, where the console shows what it does.")
            } else {
                PlatformListState(state: model.data, noun: "\(page.view.title.isEmpty ? "the page" : page.view.title)", retry: { Task { await reload() } }) { data in
                    loaded(page, data: data)
                }
            }
        } else {
            WholeScreenState {
                ContentUnavailableView {
                    Label("Page not available", systemImage: "square.dashed")
                } description: {
                    Text("This plugin is not active, or it contributes no page here that this token may see.")
                } actions: {
                    Button("Open on web") { router.openOnWeb(LatticeConsolePath(path: "/plugins/\(pluginID)/\(route)")) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func webOnly(_ page: ExtensionPageModel.Page, reason: String? = nil) -> some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("This page opens on the web", systemImage: "safari")
            } description: {
                Text(reason ?? "\(page.pluginName) draws this page as a \(page.view.kind.isEmpty ? "custom" : page.view.kind) page, which this app does not render.")
            } actions: {
                Button("Open on web") { router.openOnWeb(LatticeConsolePath(path: page.consolePath)) }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func loaded(_ page: ExtensionPageModel.Page, data: PlatformJSONValue) -> some View {
        List {
            PlatformRefreshError(state: model.data, noun: "the page") { Task { await reload() } }
            switch page.kind {
            case .table: tableSections(page, data: data)
            case .detail: detailSection(page, data: data)
            case .web: EmptyView()
            }
            actionsSection(page)
            Section {
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Provided by \(page.pluginName). Pull to refresh. Secrets stay masked here; copy them on the web.")
                    FreshnessFooter(state: model.data, interval: 60)
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Search rows")
    }

    @ViewBuilder
    private func tableSections(_ page: ExtensionPageModel.Page, data: PlatformJSONValue) -> some View {
        let table = ExtensionPageModel.tableRows(view: page.view, data: data, now: Date(), locale: locale)
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = text.isEmpty ? table.rows : table.rows.filter { row in
            row.cells.contains { !$0.isSecret && $0.text.lowercased().contains(text) }
        }
        Section {
            if table.rows.isEmpty {
                ContentUnavailableView("No rows", systemImage: "tablecells", description: Text("\(page.pluginName) returned an empty list."))
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: query)
            }
            ForEach(rows) { row in
                PlatformExtensionRowView(row: row)
            }
        } header: {
            Text(table.rows.count == 1 ? "1 row" : "\(table.rows.count) rows")
        }
    }

    @ViewBuilder
    private func detailSection(_ page: ExtensionPageModel.Page, data: PlatformJSONValue) -> some View {
        let cells = ExtensionPageModel.detailCells(view: page.view, data: data, now: Date(), locale: locale)
        Section {
            if cells.isEmpty {
                ContentUnavailableView("Nothing to show", systemImage: "list.bullet.rectangle", description: Text("\(page.pluginName) returned no fields."))
            }
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                DetailRow(label: PlatformFormat.breakable(cell.label), value: cell.text.isEmpty ? "None" : TimeDisplay.localizingStamps(in: cell.text, mode: mode, locale: locale),
                          monospaced: cell.isCode, copyable: !cell.isSecret && !cell.text.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func actionsSection(_ page: ExtensionPageModel.Page) -> some View {
        if !page.view.actions.isEmpty {
            Section {
                ForEach(Array(page.view.actions.enumerated()), id: \.offset) { _, action in
                    WebLinkRow(title: action.label.isEmpty ? action.method : action.label, path: LatticeConsolePath(path: page.consolePath))
                }
            } header: {
                Text("Actions")
            } footer: {
                Text("Plugin actions change data, so they run on the web where the console confirms them.")
            }
        }
    }
}

/// One table row: the first value as its title, then each other column as
/// a label and value line. Secrets show masked.
struct PlatformExtensionRowView: View {
    let row: ExtensionPageModel.Row

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        let title = row.title
        let rest = row.otherCells
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(PlatformFormat.breakable(title)).textRole(.rowTitle).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            ForEach(Array(rest.enumerated()), id: \.offset) { _, cell in
                line(cell)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .topLeading)
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([title] + rest.map { "\($0.label), \($0.isSecret ? "masked" : ($0.text.isEmpty ? "none" : $0.text))" }).joined(separator: ", "))
    }

    @ViewBuilder
    private func line(_ cell: ExtensionPageModel.Cell) -> some View {
        let value = cell.text.isEmpty ? "None" : TimeDisplay.localizingStamps(in: cell.text, mode: mode, locale: locale)
        let valueText = Text(value)
            .font(cell.isCode || cell.isSecret ? TextRole.identifierInRow.font : .subheadline)
            .foregroundStyle(.primary)
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 0) {
                Text(PlatformFormat.breakable(cell.label)).font(.subheadline).foregroundStyle(.secondary)
                valueText
            }
        } else {
            Text("\(Text(PlatformFormat.breakable(cell.label)).foregroundStyle(.secondary).font(.subheadline))  \(valueText)")
                .lineLimit(2)
        }
    }
}

/// The page's data, held by the screen only (a view-owned detail model).
@MainActor @Observable
final class PlatformExtensionModel {
    private(set) var data: ResourceState<PlatformJSONValue> = .idle

    func load(client: LatticeClient, pluginID: String, source: PlatformViewSource) async -> Bool {
        data = data.reloading
        do {
            data = .loaded(try await client.platformExtensionData(pluginID: pluginID, source: source), at: Date())
            return true
        } catch {
            data = data.failing(LatticeAPIError(error), surface: "This plugin page")
            return false
        }
    }
}
