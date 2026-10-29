import SwiftUI

/// M2-02 Possible duplicates: each set of nodes that look like one machine,
/// with their last report and addresses. Resolving happens on the web.
struct DuplicatesScreen: View {
    @Environment(FleetStore.self) private var store
    @Environment(ChangeLog.self) private var changes

    var body: some View {
        FleetListState(state: store.nodes, noun: "nodes", retry: { Task { await store.refresh() } }) { records in
            let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            List {
                if store.duplicates.isEmpty {
                    ContentUnavailableView("No possible duplicates", systemImage: "square.on.square",
                                           description: Text("No two nodes this token can read share a key, address or host fingerprint."))
                }
                ForEach(store.duplicates) { group in
                    Section {
                        ForEach(group.nodeIDs, id: \.self) { id in
                            if let record = byID[id] {
                                NavigationLink(value: AppRoute.fleet(.node(id: id))) {
                                    StatusRow(
                                        style: StatusStyle.node(record.node.honesty),
                                        title: record.node.displayName,
                                        detail: detail(record.node),
                                        titleIsIdentifier: false
                                    )
                                }
                                .fleetNodeMenu(record)
                            } else {
                                StatusRow(style: StatusStyle(word: "not visible", symbol: "eye.slash", tone: .quiet), title: id, titleIsIdentifier: true)
                            }
                        }
                    } header: {
                        Text(group.reasonSentence)
                    } footer: {
                        Text("\(group.confidence.capitalized) confidence. Shared value: \(group.signal)")
                    }
                }
                Section {
                    WebLinkRow(title: "Resolve duplicates on web", path: .nodes)
                } footer: {
                    FleetFooter(state: store.nodes)
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Possible duplicates")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .polling(.standard, version: changes.version(.nodes)) { await store.refresh(fromPoll: true) }
    }

    private func detail(_ node: LatticeNode) -> String {
        var parts: [String] = []
        if let seen = node.lastSeen { parts.append("seen \(FleetAge.short(seen) ?? "") ago") } else { parts.append("never seen") }
        let addresses = [node.publicIP, node.internalIP.isEmpty ? nil : node.internalIP].compactMap { $0 }.filter { !$0.isEmpty }
        if !addresses.isEmpty { parts.append(addresses.joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }
}
