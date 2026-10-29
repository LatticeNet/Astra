import SwiftUI

/// M6's contribution to Browse search (section 8.5): outbound policies, DNS
/// deployments, DDNS profiles, geo routings and tunnels, each read only with
/// its scope, once a minute per server, credential and scope set. A failed
/// read is never kept as an empty list.
enum NetworkingSearch: SearchProvider {
    private struct Lists {
        var policies: [NetworkingGroupPolicy] = []
        var deployments: [NetworkingDNSDeployment] = []
        var ddns: [DDNSProfile] = []
        var geo: [NetworkingGeoRouting] = []
        var tunnels: [TunnelProfile] = []
    }

    @MainActor private static var cache: (key: String, at: Date, lists: Lists)?

    static func results(for query: LatticeQuery, context: SearchContext) async -> [SearchResult] {
        guard let client = context.session.client else { return [] }
        let identity = context.session.primaryIdentity
        let key = [client.baseURL.absoluteString, identity?.actorID ?? "", identity?.tokenID ?? "",
                   (identity?.scopes ?? []).joined(separator: " "), (identity?.serverAllowlist ?? []).joined(separator: " ")].joined(separator: "|")
        if cache == nil || cache?.key != key || Date().timeIntervalSince(cache!.at) > 60 {
            let lists = await read(client, session: context.session)
            cache = (key, Date(), lists)
        }
        guard let lists = cache?.lists, !Task.isCancelled else { return [] }
        return answer(query.source, lists: lists, nodes: context.nodes)
    }

    @MainActor
    private static func allowed(_ scope: String, _ session: SessionStore) -> Bool {
        session.missing(ScopeRequirement(scope))?.isEmpty ?? true
    }

    @MainActor
    private static func read(_ client: LatticeClient, session: SessionStore) async -> Lists {
        let policy = allowed(NetworkingStore.policyRead, session)
        let dns = allowed(NetworkingStore.dnsRead, session)
        let ddns = allowed(NetworkingStore.ddnsRead, session)
        let geo = allowed(NetworkingStore.geoRead, session)
        let tunnel = allowed(NetworkingStore.tunnelRead, session)
        async let policies = policy ? (try? await client.networkingGroupPolicies()) ?? [] : []
        async let deployments = dns ? (try? await client.networkingDNSDeployments()) ?? [] : []
        async let profiles = ddns ? (try? await client.listDDNS()) ?? [] : []
        async let routings = geo ? (try? await client.networkingGeoRoutings()) ?? [] : []
        async let tunnels = tunnel ? (try? await client.listTunnels()) ?? [] : []
        return await Lists(policies: policies, deployments: deployments, ddns: profiles, geo: routings, tunnels: tunnels)
    }

    @MainActor
    private static func answer(_ source: String, lists: Lists, nodes: NodeDirectory) -> [SearchResult] {
        var results: [SearchResult] = []
        let now = Date()
        if case .success(let compiled) = NetworkingQuery.policies(source), !compiled.isEmpty {
            results += LatticeQueryEngine.apply(compiled, to: lists.policies, now: now).map { policy in
                SearchResult(kind: "Outbound policies", id: policy.id, title: policy.displayName,
                             detail: NetworkingText.plural(policy.targetNodeIDs.count, "node"),
                             style: StatusStyle(word: policy.enabled ? "enabled" : "disabled", symbol: "arrow.up.forward.circle", tone: .quiet),
                             target: .push(.networking(.policy(id: policy.id))))
            }
        }
        if case .success(let compiled) = NetworkingQuery.dns(source), !compiled.isEmpty {
            results += LatticeQueryEngine.apply(compiled, to: lists.deployments, now: now).map { deployment in
                SearchResult(kind: "DNS deployments", id: deployment.id, title: deployment.displayName, detail: deployment.nodeDisplayName,
                             style: .networkingDNS(deployment.health(now: now)), target: .push(.networking(.dnsDeployment(id: deployment.id))))
            }
        }
        if case .success(let compiled) = NetworkingQuery.ddns(source), !compiled.isEmpty {
            let rows = lists.ddns.map { NetworkingDDNSRow(profile: $0, node: nodes.nodes[$0.nodeID], now: now) }
            let kept = Set(LatticeQueryEngine.apply(compiled, to: rows.map(\.queryRow), now: now).map(\.profile.id))
            results += rows.filter { kept.contains($0.id) }.map { row in
                SearchResult(kind: "DDNS profiles", id: row.id, title: row.name, detail: row.recordText,
                             style: .networkingDDNS(row.health), target: .push(.networking(.ddnsProfile(id: row.id))))
            }
        }
        if case .success(let compiled) = NetworkingQuery.geo(source), !compiled.isEmpty {
            results += LatticeQueryEngine.apply(compiled, to: lists.geo, now: now).map { routing in
                SearchResult(kind: "Geo routings", id: routing.id, title: routing.displayName, detail: routing.hostname,
                             style: .networkingGeo(routing), target: .push(.networking(.geoRoute(id: routing.id))))
            }
        }
        if case .success(let compiled) = NetworkingQuery.tunnels(source), !compiled.isEmpty {
            let rows = lists.tunnels.map { NetworkingQuery.TunnelRow(tunnel: $0, nodeName: nodes.name(for: $0.nodeID)) }
            results += LatticeQueryEngine.apply(compiled, to: rows, now: now).map { row in
                SearchResult(kind: "Tunnels", id: row.tunnel.id, title: row.tunnel.displayName, detail: row.nodeName,
                             style: .networkingTunnel, target: .push(.networking(.tunnel(id: row.tunnel.id))))
            }
        }
        return results
    }
}
