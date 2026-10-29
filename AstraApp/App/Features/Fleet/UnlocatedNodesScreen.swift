import SwiftUI

/// M2-13 No location: nodes the map cannot place. Locate all and per-row
/// Resolve look locations up from public IPs (T2).
struct UnlocatedNodesScreen: View {
    @Environment(FleetStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner

    var body: some View {
        FleetListState(state: store.geo, noun: "nodes", retry: { Task { await store.refreshMap(window: .oneHour, withPaths: false) } }) { nodes in
            let unlocated = MapClusters.unlocated(nodes)
            let canAdmin = store.can("node:admin")
            List {
                FleetRefreshError(state: store.geo, noun: "locations") { Task { await store.refreshMap(window: .oneHour, withPaths: false) } }
                if unlocated.isEmpty {
                    ContentUnavailableView("Every node has a location", systemImage: "map")
                }
                Section {
                    ForEach(unlocated) { node in
                        let ref = ObjectRef(kind: "node", id: node.id, name: node.displayName)
                        NavigationLink(value: AppRoute.fleet(.node(id: node.id))) {
                            StatusRow(style: StatusStyle.node(NodeHonesty(serverValue: node.status)), title: node.displayName,
                                      detail: node.publicIP.isEmpty ? "No public IP reported" : node.publicIP)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if canAdmin, !node.publicIP.isEmpty {
                                Button("Resolve", systemImage: "location.magnifyingglass") {
                                    Task { await runner.run(FleetIntents.resolveGeo(ref, ip: node.publicIP)) }
                                }
                                .tint(.accentFill)
                            }
                        }
                        .contextMenu {
                            FleetGatedButton(title: "Resolve from public IP", systemImage: "location.magnifyingglass",
                                             missing: canAdmin ? (node.publicIP.isEmpty ? "a public IP" : nil) : "node:admin") {
                                Task { await runner.run(FleetIntents.resolveGeo(ref, ip: node.publicIP)) }
                            }
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Locations come from a GeoIP lookup of each node's public address. Setting one by hand happens on the web.")
                        FleetFooter(state: store.geo)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("No location")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refreshMap(window: .oneHour, withPaths: false) }
        .polling(.standard, version: changes.version(.nodes)) { await store.refreshMap(window: .oneHour, withPaths: false) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let unlocated = MapClusters.unlocated(store.geo.value ?? [])
                Button("Locate all") {
                    Task { await runner.run(FleetIntents.locateAll(unlocated.map { ObjectRef(kind: "node", id: $0.id, name: $0.displayName) })) }
                }
                .disabled(unlocated.isEmpty || !store.can("node:admin"))
                .accessibilityHint(store.can("node:admin") ? "Resolves every node here from its public IP" : "Needs node:admin")
            }
        }
    }
}
