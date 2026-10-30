import SwiftUI
import UIKit

/// M3-05 Chain: hops in order with each hop's path state and latency, the
/// lines it is made of, and the VPN line detail for each.
struct ChainDetailScreen: View {
    let id: String

    @Environment(MonitoringStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(ChangeLog.self) private var changes
    @Environment(NodeDirectory.self) private var nodes
    @Environment(Router.self) private var router

    var body: some View {
        content
            .navigationTitle(chain.map(title) ?? "Chain")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(chain.map { MonitoringStyle.chain($0.state).word } ?? "")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Graph on web", systemImage: "safari") { router.openOnWeb(.monitoring(view: "topology")) }
                        Button("Copy entry line", systemImage: "number") { UIPasteboard.general.string = id }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
            .polling(.paths, version: changes.version([.paths, .vpn]) &* 8 &+ (MonitorWindow.allCases.firstIndex(of: appState.monitorWindow) ?? 0)) {
                await nodes.refreshIfOlder(than: 60)
                let matrix = Task { await store.refreshPaths(window: appState.monitorWindow) }
                let ok = await store.refreshChains()
                _ = await matrix.value
                return ok
            }
    }

    private var chain: MonitoringChain? {
        MonitoringChain.compose(store.chains.value ?? []).first { $0.id == id }
    }

    private func title(_ chain: MonitoringChain) -> String {
        guard let first = chain.hops.first, let last = chain.hops.last else { return "Chain" }
        return chain.hops.count > 1 ? "\(nodes.name(for: first.nodeID)) to \(nodes.name(for: last.nodeID))" : nodes.name(for: first.nodeID)
    }

    @ViewBuilder
    private var content: some View {
        if let chain {
            detail(chain)
        } else if case .denied(let scope) = store.chains {
            ScopeDeniedScreen(scope: scope)
        } else if store.chains.value != nil {
            WholeScreenState {
                ContentUnavailableView("Chain not found", systemImage: "link", description: Text("No line chain starts at \(id) now."))
            }
        } else {
            MonitoringResource(state: store.chains, noun: "the chain", retry: { Task { await store.refreshChains() } }) { _ in EmptyView() }
        }
    }

    private func detail(_ chain: MonitoringChain) -> some View {
        let items = store.pathItems { nodes.nodes[$0]?.displayName }
        return List {
            MonitoringRefreshError(state: store.chains, noun: "the chain") { Task { await store.refreshChains() } }
            Section {
                StatusRow(style: MonitoringStyle.chain(chain.state), title: title(chain), detail: "\(chain.hops.count) hops",
                          accessibilityPhrase: "Chain \(title(chain)), \(MonitoringStyle.chain(chain.state).word)")
                ForEach(chain.hops.compactMap(\.route).filter { !$0.lastError.isEmpty || $0.attempt?.error.isEmpty == false }, id: \.id) { route in
                    Label(route.lastError.isEmpty ? (route.attempt?.error ?? "") : route.lastError.replacingOccurrences(of: "_", with: " "), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.statusWarnText)
                }
            }
            Section {
                ForEach(Array(chain.hops.enumerated()), id: \.element.id) { index, hop in
                    let next = index + 1 < chain.hops.count ? chain.hops[index + 1] : nil
                    MonitoringHopRow(hop: hop, name: nodes.name(for: hop.nodeID), next: next, nextName: next.map { nodes.name(for: $0.nodeID) }, items: items)
                }
            } header: {
                Text("Hops").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Each hop shows the path from that node to the next as the latency checks measure it.")
            }
            Section {
                ForEach(chain.hops) { hop in
                    NavigationLink(value: AppRoute.vpn(.line(id: hop.lineUUID))) {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("\(hop.role.rawValue.capitalized) line on \(nodes.name(for: hop.nodeID))")
                            Text(DetailRow.breakable(hop.lineUUID)).textRole(.identifierInRow).foregroundStyle(.secondary)
                            if let route = hop.route {
                                Text("Route \(route.status.replacingOccurrences(of: "_", with: " "))").textRole(.rowDetail)
                            }
                        }
                        .frame(minHeight: Spacing.minimumTarget)
                        .accessibilityElement(children: .combine)
                    }
                }
            } header: {
                Text("Lines").accessibilityAddTraits(.isHeader)
            } footer: {
                MonitoringFreshness(state: store.chains, cadence: .paths)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refreshChains() }
    }
}
