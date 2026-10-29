import SwiftUI

/// M5's contribution to Browse search (section 8.5): machine profiles by
/// the Machines query fields. The list is fetched once a minute per server,
/// credential and scope set, and a failed read is never kept as an empty inventory.
enum InventorySearch: SearchProvider {
    @MainActor private static var cache: (key: String, at: Date, machines: [MachineProfile])?

    static func results(for query: LatticeQuery, context: SearchContext) async -> [SearchResult] {
        guard let client = context.session.client,
              context.session.missing(ScopeRequirement(InventoryStore.readScope))?.isEmpty ?? true else { return [] }
        let identity = context.session.primaryIdentity
        let key = [client.baseURL.absoluteString, identity?.actorID ?? "", identity?.tokenID ?? "",
                   (identity?.scopes ?? []).joined(separator: " "), (identity?.serverAllowlist ?? []).joined(separator: " ")].joined(separator: "|")
        if cache == nil || cache?.key != key || Date().timeIntervalSince(cache!.at) > 60 {
            guard let machines = try? await client.listMachines() else {
                cache = nil
                return []
            }
            cache = (key, Date(), machines)
        }
        guard let machines = cache?.machines, !Task.isCancelled else { return [] }
        return answer(query, machines: machines, nodes: context.nodes)
    }

    @MainActor
    private static func answer(_ query: LatticeQuery, machines: [MachineProfile], nodes: NodeDirectory) -> [SearchResult] {
        guard case .success(let compiled) = InventoryQuery.compile(query.source), !compiled.isEmpty else { return [] }
        let today = InventoryDay(date: Date())
        let rows = machines.filter(\.isProfiled).map { machine in
            InventoryQuery.Row(machine: machine, facts: nodes.nodes[machine.nodeID].map(InventoryNodeFacts.init(node:)), today: today)
        }
        return LatticeQueryEngine.apply(compiled, to: rows, now: Date()).map { row in
            let state = InventoryRenewalState.of(row.machine, today: today)
            return SearchResult(
                kind: "Machines", id: row.machine.id, title: row.machine.inventoryName,
                detail: [row.machine.vendor, row.machine.region].filter { !$0.isEmpty }.joined(separator: ", "),
                style: .inventoryRenewal(state),
                target: .push(.inventory(.machine(id: row.machine.id)))
            )
        }
    }
}
