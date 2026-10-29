import SwiftUI

/// M6 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M6 may add cases but must not rename or remove these.
enum NetworkingRoute: Hashable, Codable, Sendable {
    case outboundPolicy
    case policy(id: String)
    case nodePolicy(nodeID: String)
    case dns
    case dnsDeployment(id: String)
    case ddns
    case ddnsProfile(id: String)
    case geoRouting
    case geoRoute(id: String)
    case tunnels
    case tunnel(id: String)
    case inboundFirewall(nodeID: String?)
    case securityGroup(id: String)
    /// Outbound policy opened on one view (`policies`, `nodes`, `matrix`, `matrix-ingress`).
    case outboundPolicyView(view: String)
}

/// M6's demo intents for `-AstraPresent confirm:<id>`, built from the demo
/// fixtures as the screens would decode them:
/// `networking.planAll`, `networking.planNode:<node name>`,
/// `networking.convert:<node name>`, `networking.dnsPlan:<deployment id>`,
/// `networking.dnsPublish:<deployment id>`, `networking.measure:<deployment id>`,
/// `networking.ddnsRun:<profile id>`, `networking.ddnsDelete:<profile id>`,
/// `networking.geoDelete:<routing id>`, `networking.tunnelPlan:<tunnel id>`,
/// `networking.tunnelDelete:<tunnel id>`.
extension NetworkingRoute: DemoHooks {
    static func demoIntent(_ id: String, session: SessionStore) -> WriteIntent? {
        guard session.isDemo, id.hasPrefix("networking.") else { return nil }
        let parts = id.dropFirst("networking.".count).split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        let clock = session.demoClock
        let names = Dictionary(DemoWorld.nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        func decode<T: Decodable>(_ type: T.Type, _ body: String) -> T? {
            try? JSONDecoder().decode(T.self, from: Data(clock.substitute(body).utf8))
        }
        func node(_ name: String) -> ObjectRef? {
            DemoWorld.nodes.first { $0.name == name }.map { ObjectRef(kind: "node", id: $0.id, name: $0.name) }
        }
        let deployments = decode(DemoDeployments.self, NetworkingFixtures.deploymentsBody(published: [], measured: [], request: nil))?.deployments ?? []
        switch parts[0] {
        case "planAll":
            let policies = decode(DemoPolicies.self, NetworkingFixtures.groupPoliciesBody(request: DemoRequest(identity: .pat, method: "GET", path: "/api/group-policies"), extra: []))?.policies ?? []
            let covered = Set(policies.filter(\.enabled).flatMap(\.targetNodeIDs)).map { ObjectRef(kind: "node", id: $0, name: names[$0]) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return NetworkingIntents.planAllGroupPolicies(covered: covered)
        case "planNode":
            return node(argument).map(NetworkingIntents.planNodePolicy)
        case "convert":
            return node(argument).map { NetworkingIntents.convertPolicy($0, name: "\($0.name) egress", priority: 40) }
        case "dnsPlan":
            guard let deployment = deployments.first(where: { $0.id == argument }) else { return nil }
            return NetworkingIntents.planDNS(ObjectRef(kind: "DNS deployment", id: deployment.id, name: deployment.displayName),
                                             node: ObjectRef(kind: "node", id: deployment.nodeID, name: deployment.nodeDisplayName))
        case "dnsPublish":
            return deployments.first { $0.id == argument }.map(NetworkingIntents.publishDNS)
        case "measure":
            return deployments.first { $0.id == argument }.map { NetworkingIntents.measureCert($0, ports: $0.portsToMeasure) }
        case "ddnsRun", "ddnsDelete":
            let profiles = decode([DDNSProfile].self, DemoJSON.array(SharedFixtures.ddnsProfiles).text) ?? []
            guard let profile = profiles.first(where: { $0.id == argument }) else { return nil }
            return parts[0] == "ddnsRun" ? NetworkingIntents.runDDNS(profile) : NetworkingIntents.deleteDDNS(profile)
        case "geoDelete":
            let routings = decode(DemoGeo.self, NetworkingFixtures.geoBody(deleted: []))?.routings ?? []
            let locale = Locale.current
            return routings.first { $0.id == argument }.map { NetworkingIntents.deleteGeo($0, names: names, time: { TimeDisplay.dateTime($0, mode: .local, locale: locale) }) }
        case "tunnelPlan", "tunnelDelete":
            let tunnels = decode([TunnelProfile].self, DemoJSON.array(NetworkingFixtures.tunnels).text) ?? []
            guard let tunnel = tunnels.first(where: { $0.id == argument }) else { return nil }
            let nodeName = names[tunnel.nodeID] ?? tunnel.nodeID
            return parts[0] == "tunnelPlan"
                ? NetworkingIntents.planTunnel(tunnel, node: ObjectRef(kind: "node", id: tunnel.nodeID, name: nodeName))
                : NetworkingIntents.deleteTunnel(tunnel, nodeName: nodeName)
        default:
            return nil
        }
    }

    /// `-AstraPresent networkingPush:<route>` pushes a list screen, which has
    /// no app link: `outbound[:<view>]`, `dns`, `ddns`, `geo`, `tunnels`,
    /// `firewall[:<node name>]`, `securityGroup:<id>`, `nodePolicy:<node name>`.
    static func demoSheet(_ name: String, argument: String?) -> AnyView? {
        guard name == "networkingPush", let argument else { return nil }
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? parts[1] : nil
        let nodeID = value.flatMap { name in DemoWorld.nodes.first { $0.name == name }?.id }
        let route: NetworkingRoute? = switch parts[0] {
        case "outbound": value.map { .outboundPolicyView(view: $0) } ?? .outboundPolicy
        case "dns": .dns
        case "ddns": .ddns
        case "geo": .geoRouting
        case "tunnels": .tunnels
        case "firewall": .inboundFirewall(nodeID: nodeID)
        case "securityGroup": value.map { .securityGroup(id: $0) }
        case "nodePolicy": nodeID.map { .nodePolicy(nodeID: $0) }
        default: nil
        }
        return route.map { AnyView(NetworkingDemoPusher(route: $0)) }
    }

    private struct DemoDeployments: Decodable { var deployments: [NetworkingDNSDeployment] }
    private struct DemoPolicies: Decodable { var policies: [NetworkingGroupPolicy] }
    private struct DemoGeo: Decodable {
        var routings: [NetworkingGeoRouting]
        enum CodingKeys: String, CodingKey { case routings = "geo_routings" }
    }
}

/// Pushes a Networking route from a demo launch, then gets out of the way.
private struct NetworkingDemoPusher: View {
    let route: NetworkingRoute
    @Environment(Router.self) private var router

    var body: some View {
        Color.clear.task {
            router.dismissPresented { router.push(.networking(route)) }
        }
    }
}
