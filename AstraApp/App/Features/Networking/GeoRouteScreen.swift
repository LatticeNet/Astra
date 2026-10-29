import SwiftUI

/// M6-09 Geo routing: hostname, strategy, participating and DNS nodes,
/// delegation and the rendered config (read). Delete (T4); edit on web.
struct GeoRouteScreen: View {
    let id: String

    @Environment(NetworkingStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    @State private var preview: ResourceState<NetworkingGeoPlan> = .idle

    var body: some View {
        NetworkingListState(state: store.geo, noun: "the geo routing", web: .geoRoute(id: id),
                            retry: { Task { await store.refreshGeo() } }) { routings in
            if let routing = routings.first(where: { $0.id == id }) {
                detail(routing)
            } else {
                notFound
            }
        }
        .navigationTitle(routing?.displayName ?? "Geo routing")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(routing.map { StatusStyle.networkingGeo($0).word.networkingCapitalized } ?? "")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NetworkingMoreMenu(link: NetworkingCopy.link(.geoRoute(id: id), fallback: "lattice://geo-routes/\(id)"), web: .geoRoute(id: id)) {
                    if let routing {
                        Button("Preview config", systemImage: "doc.text.magnifyingglass") { Task { await loadPreview() } }
                        Button("Edit on web", systemImage: "square.and.pencil") { router.openOnWeb(.geoRoute(id: id)) }
                        Section {
                            NetworkingGatedButton(title: "Delete routing", systemImage: "trash", blocked: deleteBlocked, role: .destructive) { delete(routing) }
                        }
                    }
                }
            }
        }
        .refreshable { await store.refreshGeo() }
        .polling(.standard, version: changes.version([.geo, .nodes])) {
            await nodes.refreshIfOlder(than: 60)
            return await store.refreshGeo()
        }
    }

    private var routing: NetworkingGeoRouting? { store.geo.value?.first { $0.id == id } }
    private var deleteBlocked: String? { store.blocked([NetworkingIntents.geoAdmin]) }

    @ViewBuilder
    private func detail(_ routing: NetworkingGeoRouting) -> some View {
        List {
            Section {
                NetworkingRefreshError(state: store.geo, noun: "the geo routing") { Task { await store.refreshGeo() } }
                NetworkingGeoRow(routing: routing)
            }

            Section("Routing") {
                DetailRow(label: "Hostname", value: routing.hostname, monospaced: true)
                DetailRow(label: "Answers with", value: routing.strategyWords.networkingCapitalized, copyable: false)
                if routing.ttl > 0 { DetailRow(label: "TTL", value: "\(routing.ttl) s", copyable: false) }
                if !routing.geoIPDBPath.isEmpty { DetailRow(label: "GeoIP database", value: routing.geoIPDBPath, monospaced: true) }
            }

            Section {
                if routing.dnsNodeIDs.isEmpty {
                    Text("No DNS node answers this hostname yet.").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
                }
                ForEach(routing.dnsNodeIDs, id: \.self) { NetworkingNodeLink(nodeID: $0) }
            } header: {
                Text("DNS nodes (\(routing.dnsNodeIDs.count))")
            } footer: {
                Text("These run self-host DNS and answer \(routing.hostname).")
            }

            Section("Targets (\(routing.nodeIDs.count))") {
                ForEach(routing.nodeIDs, id: \.self) { NetworkingNodeLink(nodeID: $0) }
            }

            Section("Delegation and apply") {
                DetailRow(label: "Parent zone NS", value: routing.publishNS ? "Published through DDNS profile \(ddnsName(routing.ddnsProfileID))" : "Not published", copyable: false)
                if let delegated = routing.lastDelegatedAt {
                    DetailRow(label: "Delegated", value: TimeDisplay.dateTime(delegated, mode: mode, locale: locale), copyable: false)
                }
                if let applied = routing.lastAppliedAt {
                    DetailRow(label: "Applied", value: TimeDisplay.dateTime(applied, mode: mode, locale: locale),
                              secondary: TimeDisplay.otherZone(applied, mode: mode, locale: locale), copyable: false)
                } else {
                    DetailRow(label: "Applied", value: "Never", copyable: false)
                }
                if !routing.lastRenderedSHA.isEmpty {
                    DetailRow(label: "Rendered config", value: routing.lastRenderedSHA, monospaced: true)
                }
                if !routing.lastError.isEmpty {
                    DetailRow(label: "Last error", value: routing.lastError)
                }
            }

            previewSection(routing)

            Section {
                WebLinkRow(title: "Edit on web", path: .geoRoute(id: routing.id))
                NetworkingActionRow(title: "Delete routing", systemImage: "trash", detail: nil, blocked: deleteBlocked, role: .destructive) { delete(routing) }
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    if routing.lastAppliedAt != nil { Text("Deleting removes only the record. Each DNS node keeps answering with the zone it was given.") }
                    FreshnessFooter(state: store.geo, interval: Polling.standard.interval(lowPower: false))
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func previewSection(_ routing: NetworkingGeoRouting) -> some View {
        Section {
            switch preview {
            case .idle:
                NetworkingActionRow(title: "Preview config", systemImage: "doc.text.magnifyingglass",
                                    detail: "Renders the config the DNS nodes would get. Nothing is filed.", blocked: store.blocked([NetworkingStore.geoRead])) {
                    Task { await loadPreview() }
                }
            case .loading:
                HStack(spacing: Spacing.m) {
                    ProgressView()
                    Text("Rendering the config").foregroundStyle(.secondary)
                }
                .frame(minHeight: Spacing.minimumTarget)
            case .failed(let error, _, _):
                ErrorRow(message: "Could not render the config: \(error.localizedDescription)") { Task { await loadPreview() } }
            case .denied(let scope):
                ScopeDeniedRow(scope: scope)
            case .companionBehind(let surface):
                CompanionBehindRow(surface: surface)
            case .loaded(let plan, _):
                ForEach(plan.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.statusWarnText)
                        .frame(minHeight: Spacing.minimumTarget)
                }
                ForEach(plan.continentChoice.sorted { $0.key < $1.key }, id: \.key) { continent, node in
                    DetailRow(label: continentName(continent), value: nodes.name(for: node), copyable: false)
                }
                ScrollView(.horizontal) {
                    Text(plan.config)
                        .textRole(.code)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.vertical, Spacing.s)
                }
                .accessibilityLabel("Rendered config")
                .accessibilityValue(plan.config)
                DetailRow(label: "SHA-256", value: plan.sha256, monospaced: true)
            }
        } header: {
            Text("Config")
        }
    }

    private func continentName(_ code: String) -> String {
        switch code {
        case "AS": "Asia"
        case "EU": "Europe"
        case "NA": "North America"
        case "SA": "South America"
        case "AF": "Africa"
        case "OC": "Oceania"
        case "AN": "Antarctica"
        default: code
        }
    }

    private func ddnsName(_ id: String) -> String {
        store.ddns.value?.first { $0.id == id }?.name ?? (id.isEmpty ? "none" : id)
    }

    private func loadPreview() async {
        if let missing = session.missing(ScopeRequirement(NetworkingStore.geoRead)), !missing.isEmpty {
            preview = .denied(scope: missing.joined(separator: " and "))
            return
        }
        guard let client = session.client else { return }
        preview = preview.reloading
        do {
            preview = .loaded(try await client.networkingPreviewGeo(id: id), at: Date())
        } catch {
            preview = preview.failing(LatticeAPIError(error), surface: "The geo config", missingScope: NetworkingStore.geoRead)
        }
    }

    private func delete(_ routing: NetworkingGeoRouting) {
        let names = Dictionary(nodes.nodes.values.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let timeMode = mode
        let timeLocale = locale
        Task {
            let outcome = await runner.run(NetworkingIntents.deleteGeo(routing, names: names, time: { TimeDisplay.dateTime($0, mode: timeMode, locale: timeLocale) }))
            if case .done = outcome { dismiss() }
        }
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Not found", systemImage: "questionmark.square.dashed")
            } description: {
                Text("This geo routing was deleted.")
            } actions: {
                Button("Open on web") { router.openOnWeb(.geoRoute(id: id)) }.buttonStyle(.bordered)
            }
        }
    }
}
