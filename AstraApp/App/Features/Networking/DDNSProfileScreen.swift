import SwiftUI

/// M6-07 DDNS profile: records, type, provider, node and the last run.
/// Run now (T3, with the record preview computed on this iPhone), Delete
/// (T4), save on web.
struct DDNSProfileScreen: View {
    let id: String

    @Environment(NetworkingStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NetworkingListState(state: store.ddns, noun: "the DDNS profile", web: .ddnsProfile(id: id),
                            retry: { Task { await store.refreshDDNS() } }) { profiles in
            if let profile = profiles.first(where: { $0.id == id }) {
                detail(profile)
            } else {
                notFound
            }
        }
        .navigationTitle(profile.map { $0.name.isEmpty ? $0.id : $0.name } ?? "DDNS profile")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(row.map { $0.health.rawValue.networkingCapitalized } ?? "")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NetworkingMoreMenu(link: NetworkingCopy.link(.ddnsProfile(id: id), fallback: "lattice://ddns/\(id)"), web: .ddnsProfile(id: id)) {
                    if let profile {
                        NetworkingGatedButton(title: "Run now", systemImage: "play.circle", blocked: runBlocked) { run(profile) }
                        Button("Edit on web", systemImage: "square.and.pencil") { router.openOnWeb(.ddnsProfile(id: id)) }
                        Section {
                            NetworkingGatedButton(title: "Delete profile", systemImage: "trash", blocked: adminBlocked, role: .destructive) { delete(profile) }
                        }
                    }
                }
            }
        }
        .refreshable {
            await nodes.refreshIfOlder(than: 0)
            await store.refreshDDNS()
        }
        .polling(.standard, version: changes.version([.ddns, .nodes])) {
            await nodes.refreshIfOlder(than: 60)
            return await store.refreshDDNS()
        }
    }

    private var profile: DDNSProfile? { store.ddns.value?.first { $0.id == id } }
    private var row: NetworkingDDNSRow? { profile.map { NetworkingDDNSRow(profile: $0, node: nodes.nodes[$0.nodeID], now: Date()) } }
    private var adminBlocked: String? { store.blocked([NetworkingIntents.ddnsAdmin]) }
    private var runBlocked: String? { store.blocked(NetworkingIntents.ddnsRunScopes) }

    @ViewBuilder
    private func detail(_ profile: DDNSProfile) -> some View {
        let row = NetworkingDDNSRow(profile: profile, node: nodes.nodes[profile.nodeID], now: Date())
        let node = nodes.nodes[profile.nodeID]
        List {
            Section {
                NetworkingRefreshError(state: store.ddns, noun: "the DDNS profile") { Task { await store.refreshDDNS() } }
                NetworkingDDNSRowView(row: row)
            }

            Section("Records") {
                ForEach(profile.domains, id: \.self) { domain in
                    DetailRow(label: profile.isCNAME ? "CNAME" : "Record", value: domain, monospaced: true)
                }
                DetailRow(label: "Type", value: profile.isCNAME ? "CNAME to \(DDNSProfile.normalizeHost(profile.cnameTarget))" : addressFamilies(profile), copyable: false)
                DetailRow(label: "Provider", value: profile.provider.networkingCapitalized, secondary: profile.hasCredential ? "Credential stored on the server" : "No credential stored", copyable: false)
                DetailRow(label: "TTL", value: "\(profile.ttl) s", copyable: false)
                DetailRow(label: "Checked every", value: TimeDisplay.duration(Double(profile.effectiveIntervalSeconds), locale: locale), copyable: false)
                NetworkingNodeLink(nodeID: profile.nodeID, label: "Node")
            }

            Section("Last run") {
                if let ran = profile.lastRunAt {
                    DetailRow(label: "Ran", value: TimeDisplay.dateTime(ran, mode: mode, locale: locale),
                              secondary: TimeDisplay.otherZone(ran, mode: mode, locale: locale), copyable: false)
                } else {
                    DetailRow(label: "Ran", value: "Never", copyable: false)
                }
                if profile.isCNAME {
                    DetailRow(label: "Confirmed target", value: profile.lastTarget.isEmpty ? "None yet" : profile.lastTarget, monospaced: !profile.lastTarget.isEmpty)
                } else {
                    if profile.enableIPv4 { DetailRow(label: "Wrote A", value: profile.lastIPv4.isEmpty ? "Nothing yet" : profile.lastIPv4, monospaced: !profile.lastIPv4.isEmpty) }
                    if profile.enableIPv6 { DetailRow(label: "Wrote AAAA", value: profile.lastIPv6.isEmpty ? "Nothing yet" : profile.lastIPv6, monospaced: !profile.lastIPv6.isEmpty) }
                }
                if !profile.lastError.isEmpty {
                    DetailRow(label: "Last error", value: NetworkingDDNSPreview.errorText(profile.lastError))
                }
            }

            Section {
                let records = NetworkingDDNSPreview.records(profile, publicIPv4: node?.publicIP, publicIPv6: node?.publicIPv6)
                if records.isEmpty {
                    Text(node == nil ? "The node's address is not loaded yet." : "The node reports no address for the enabled families, so a run writes nothing.")
                        .foregroundStyle(.secondary)
                        .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                }
                ForEach(records, id: \.self) { record in
                    DetailRow(label: "\(record.domain) \(record.type)", value: record.previous.isEmpty ? "\(record.value), new" : (record.previous == record.value ? "\(record.value), unchanged" : "\(record.value), was \(record.previous)"), copyable: false)
                }
                NetworkingActionRow(title: "Run now", systemImage: "play.circle",
                                    detail: "Writes these records at the provider now", blocked: runBlocked) { run(profile) }
            } header: {
                Label("Run now writes, computed on this iPhone", systemImage: "iphone")
            } footer: {
                Text("From the node's reported address. The server sweeps every minute on its own and writes only when the address moved.")
            }

            Section {
                WebLinkRow(title: "Edit on web", path: .ddnsProfile(id: profile.id))
                NetworkingActionRow(title: "Delete profile", systemImage: "trash", detail: nil, blocked: adminBlocked, role: .destructive) { delete(profile) }
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Deleting stops updates; the records stay at the provider.")
                    FreshnessFooter(state: store.ddns, interval: Polling.standard.interval(lowPower: false))
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func addressFamilies(_ profile: DDNSProfile) -> String {
        switch (profile.enableIPv4, profile.enableIPv6) {
        case (true, true): "A and AAAA from the node's address"
        case (true, false): "A from the node's address"
        case (false, true): "AAAA from the node's address"
        case (false, false): "No address family enabled"
        }
    }

    private func run(_ profile: DDNSProfile) {
        Task { await runner.run(NetworkingIntents.runDDNS(profile)) }
    }

    private func delete(_ profile: DDNSProfile) {
        Task {
            let outcome = await runner.run(NetworkingIntents.deleteDDNS(profile))
            if case .done = outcome { dismiss() }
        }
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Not found", systemImage: "questionmark.square.dashed")
            } description: {
                Text("This DDNS profile was deleted, or it is on a node this token cannot read.")
            } actions: {
                Button("Token scopes") { router.openSettings([.page(.scopes)]) }.buttonStyle(.bordered)
                Button("Open on web") { router.openOnWeb(.ddnsProfile(id: id)) }
            }
        }
    }
}
