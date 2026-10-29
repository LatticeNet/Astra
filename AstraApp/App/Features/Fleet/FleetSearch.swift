import SwiftUI

/// M2's contribution to Browse search (section 8.5): nodes by the console's
/// node fields, and groups by name. Each list is fetched once per minute,
/// and the lists belong to one server, credential and scope set: a sign out
/// or switch drops them, and a failed read is never kept as an empty fleet.
enum FleetSearch: SearchProvider {
    @MainActor private static var cache: (key: String, at: Date, nodes: [FleetNodeRecord], groups: FleetGroupsResponse?)?

    static func results(for query: LatticeQuery, context: SearchContext) async -> [SearchResult] {
        guard let client = context.session.client else { return [] }
        let canNodes = context.session.missing(ScopeRequirement("node:read"))?.isEmpty ?? true
        let canGroups = context.session.missing(ScopeRequirement("group:read"))?.isEmpty ?? true
        let identity = context.session.primaryIdentity
        let key = [client.baseURL.absoluteString, identity?.actorID ?? "", identity?.tokenID ?? "",
                   (identity?.scopes ?? []).joined(separator: " "), (identity?.serverAllowlist ?? []).joined(separator: " ")].joined(separator: "|")
        if cache == nil || cache?.key != key || Date().timeIntervalSince(cache!.at) > 60 {
            var nodes: [FleetNodeRecord]? = []
            if canNodes { nodes = try? await client.fleetFetchNodeRecords() }
            let groups = canGroups ? (try? await client.fleetGroups()) : nil
            if let nodes, !(canGroups && groups == nil) {
                cache = (key, Date(), nodes, groups)
            } else {
                // Answer from what did load, but keep nothing a retry should replace.
                cache = nil
                return answer(query, nodes: nodes ?? [], groups: groups)
            }
        }
        guard let cache, !Task.isCancelled else { return [] }
        return answer(query, nodes: cache.nodes, groups: cache.groups)
    }

    private static func answer(_ query: LatticeQuery, nodes: [FleetNodeRecord], groups: FleetGroupsResponse?) -> [SearchResult] {
        let names = Dictionary((groups?.groups ?? []).map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        var results: [SearchResult] = []
        if case .success(let compiled) = FleetNodeQuery.compile(query.source, groupName: { names[$0] }), !compiled.isEmpty {
            results += LatticeQueryEngine.apply(compiled, to: nodes, now: Date()).map { record in
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
            results += (groups?.groups ?? []).filter { $0.displayName.lowercased().contains(needle) }.map { group in
                SearchResult(kind: "Groups", id: group.id, title: group.displayName, detail: "\(group.kind.word), \(group.rollup.sentence)",
                             style: nil, target: .push(.fleet(.group(id: group.id))))
            }
        }
        return results
    }
}
