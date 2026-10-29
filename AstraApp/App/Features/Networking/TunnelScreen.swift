import SwiftUI

/// M6-11 Tunnel: ingress rules, node and the last plan filed for it.
/// Plan (P), Delete (T4), create on web.
struct TunnelScreen: View {
    let id: String

    @Environment(NetworkingStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var plans: ResourceState<[Approval]> = .idle

    var body: some View {
        NetworkingListState(state: store.tunnels, noun: "the tunnel", web: .tunnel(id: id),
                            retry: { Task { await store.refreshTunnels() } }) { tunnels in
            if let tunnel = tunnels.first(where: { $0.id == id }) {
                detail(tunnel)
            } else {
                notFound
            }
        }
        .navigationTitle(tunnel?.displayName ?? "Tunnel")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(tunnel.map { nodes.name(for: $0.nodeID) } ?? "")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NetworkingMoreMenu(link: NetworkingCopy.link(.tunnel(id: id), fallback: "lattice://tunnels/\(id)"), web: .tunnel(id: id)) {
                    if let tunnel {
                        NetworkingGatedButton(title: "Plan", systemImage: "doc.badge.gearshape", blocked: adminBlocked) { plan(tunnel) }
                        Section {
                            NetworkingGatedButton(title: "Delete tunnel", systemImage: "trash", blocked: adminBlocked, role: .destructive) { delete(tunnel) }
                        }
                    }
                }
            }
        }
        .refreshable {
            await store.refreshTunnels()
            await loadPlans()
        }
        .polling(.standard, version: changes.version([.tunnels, .nodes, .approvals])) {
            await nodes.refreshIfOlder(than: 60)
            let ok = await store.refreshTunnels()
            await loadPlans()
            return ok
        }
    }

    private var tunnel: TunnelProfile? { store.tunnels.value?.first { $0.id == id } }
    private var adminBlocked: String? { store.blocked([NetworkingIntents.tunnelAdmin]) }

    @ViewBuilder
    private func detail(_ tunnel: TunnelProfile) -> some View {
        List {
            Section {
                NetworkingRefreshError(state: store.tunnels, noun: "the tunnel") { Task { await store.refreshTunnels() } }
                NetworkingTunnelRow(tunnel: tunnel)
            }

            Section {
                ForEach(tunnel.ingress) { rule in
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(rule.hostname.isEmpty ? "Any hostname" : rule.hostname).textRole(.rowTitle)
                        Text("to \(rule.service)").textRole(.identifierInRow).foregroundStyle(.secondary)
                        if !rule.path.isEmpty {
                            Text("path \(rule.path)").textRole(.identifierInRow).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .contextMenu {
                        Button("Copy hostname", systemImage: "doc.on.doc") { NetworkingCopy.copy(rule.hostname) }
                        Button("Copy service", systemImage: "doc.on.doc") { NetworkingCopy.copy(rule.service) }
                    }
                }
            } header: {
                Text("Ingress (\(tunnel.ingress.count))")
            } footer: {
                Text("Anything that matches no rule gets 404 from cloudflared.")
            }

            Section("Tunnel") {
                NetworkingNodeLink(nodeID: tunnel.nodeID, label: "Node")
                DetailRow(label: "Cloudflare tunnel", value: tunnel.tunnelID, monospaced: true)
                if !tunnel.credentialsFile.isEmpty {
                    DetailRow(label: "Credentials file", value: tunnel.credentialsFile, monospaced: true, secondary: "On the node; the server never holds it")
                }
            }

            Section {
                switch plans {
                case .loaded(let list, _) where list.isEmpty:
                    Text("No plan has been filed for this node's tunnels.").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                case .denied(let scope):
                    ScopeDeniedRow(scope: scope)
                case .failed(let error, nil, _):
                    ErrorRow(message: "Could not load plans: \(error.localizedDescription)") { Task { await loadPlans() } }
                default:
                    if let latest = plans.value?.first {
                        Button { router.present(.review(.single(latest.id))) } label: { ApprovalRow(approval: latest, nodeName: nodes.name(for: tunnel.nodeID)) }
                            .tint(.primary)
                    } else {
                        LoadingRows(label: "Loading the last plan", count: 1)
                    }
                }
                NetworkingActionRow(title: "Plan", systemImage: "doc.badge.gearshape",
                                    detail: "Files the cloudflared config for approval", blocked: adminBlocked) { plan(tunnel) }
            } header: {
                Text("Last plan")
            } footer: {
                Text("The newest cftunnel approval for \(nodes.name(for: tunnel.nodeID)).")
            }

            Section {
                WebLinkRow(title: "Create a tunnel on web", path: LatticeConsolePath(path: "/network/tunnels"))
                NetworkingActionRow(title: "Delete tunnel", systemImage: "trash", detail: nil, blocked: adminBlocked, role: .destructive) { delete(tunnel) }
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Deleting removes only the profile. cloudflared keeps running on the node with its last config.")
                    FreshnessFooter(state: store.tunnels, interval: Polling.standard.interval(lowPower: false))
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func loadPlans() async {
        guard let tunnel, let client = session.client else { return }
        let visibility = ScopeRequirement("tunnel:admin")
        if let missing = session.missing(visibility), !missing.isEmpty {
            plans = .denied(scope: missing.joined(separator: " and "))
            return
        }
        do {
            let page = try await client.listApprovals(query: ApprovalQuery(plugin: "cftunnel", nodeID: tunnel.nodeID, includeDismissed: true, limit: 5))
            plans = .loaded(page.approvals.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }, at: Date())
        } catch {
            plans = plans.failing(LatticeAPIError(error), surface: "Tunnel plans", missingScope: "tunnel:admin")
        }
    }

    private func plan(_ tunnel: TunnelProfile) {
        Task { await runner.run(NetworkingIntents.planTunnel(tunnel, node: ObjectRef(kind: "node", id: tunnel.nodeID, name: nodes.name(for: tunnel.nodeID)))) }
    }

    private func delete(_ tunnel: TunnelProfile) {
        Task {
            let outcome = await runner.run(NetworkingIntents.deleteTunnel(tunnel, nodeName: nodes.name(for: tunnel.nodeID)))
            if case .done = outcome { dismiss() }
        }
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Not found", systemImage: "questionmark.square.dashed")
            } description: {
                Text("This tunnel was deleted, or it is on a node this token cannot read.")
            } actions: {
                Button("Token scopes") { router.openSettings([.page(.scopes)]) }.buttonStyle(.bordered)
                Button("Open on web") { router.openOnWeb(.tunnel(id: id)) }
            }
        }
    }
}
