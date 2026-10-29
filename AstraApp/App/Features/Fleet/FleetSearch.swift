import SwiftUI

/// M2's contribution to Browse search (section 8.5): nodes by the console's
/// node fields, and groups by name. Each list is fetched once per minute.
enum FleetSearch: SearchProvider {
    @MainActor private static var cache: (at: Date, nodes: [FleetNodeRecord], groups: FleetGroupsResponse?)?

    static func results(for query: LatticeQuery, context: SearchContext) async -> [SearchResult] {
        guard let client = context.session.client else { return [] }
        let canNodes = context.session.missing(ScopeRequirement("node:read"))?.isEmpty ?? true
        let canGroups = context.session.missing(ScopeRequirement("group:read"))?.isEmpty ?? true
        if cache == nil || Date().timeIntervalSince(cache!.at) > 60 {
            let nodes = canNodes ? ((try? await client.fleetFetchNodeRecords()) ?? []) : []
            let groups = canGroups ? (try? await client.fleetGroups()) : nil
            cache = (Date(), nodes, groups)
        }
        guard let cache, !Task.isCancelled else { return [] }
        let names = Dictionary((cache.groups?.groups ?? []).map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        var results: [SearchResult] = []
        if case .success(let compiled) = FleetNodeQuery.compile(query.source, groupName: { names[$0] }), !compiled.isEmpty {
            results += LatticeQueryEngine.apply(compiled, to: cache.nodes, now: Date()).map { record in
                SearchResult(
                    kind: "Nodes", id: record.id, title: record.node.displayName,
                    detail: [record.node.geo?.city, record.node.agentVersion.map { "agent \($0)" }].compactMap { $0 }.joined(separator: ", "),
                    style: StatusStyle.node(record.node.honesty),
                    target: .push(.fleet(.node(id: record.id)))
                )
            }
        }
        let needle = query.source.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty, !needle.contains(":") {
            results += (cache.groups?.groups ?? []).filter { $0.displayName.lowercased().contains(needle) }.map { group in
                SearchResult(kind: "Groups", id: group.id, title: group.displayName, detail: "\(group.kind.word), \(group.rollup.sentence)",
                             style: nil, target: .push(.fleet(.group(id: group.id))))
            }
        }
        return results
    }
}
