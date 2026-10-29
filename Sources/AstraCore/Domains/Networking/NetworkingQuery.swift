import Foundation

/// The query fields of each Networking list (section 6.14). Unknown fields
/// are refused by the engine with the field named, as in the console.
public enum NetworkingQuery {
    static func optional(_ value: String) -> LatticeQueryFieldValue {
        value.isEmpty ? .none : .string(value)
    }

    public static let policyFields: [LatticeQueryField<NetworkingGroupPolicy>] = [
        LatticeQueryField(key: "name", type: .string, get: { .string($0.displayName) }),
        LatticeQueryField(key: "enabled", type: .bool, flag: true, sortable: false, get: { .bool($0.enabled) }),
        LatticeQueryField(key: "priority", type: .number, get: { .number(Double($0.priority)) }),
        LatticeQueryField(key: "nodes", type: .number, get: { .number(Double($0.targetNodeIDs.count)) }),
        LatticeQueryField(key: "rules", type: .number, get: { .number(Double($0.rules.count)) }),
        LatticeQueryField(key: "fleet", type: .bool, flag: true, sortable: false, get: { .bool($0.target.all) }),
    ]

    public static func policies(_ source: String) -> Result<LatticeCompiledQuery<NetworkingGroupPolicy>, LatticeQueryError> {
        LatticeQueryEngine.compile(source, fields: policyFields, text: { [$0.displayName, $0.name, $0.scopeGroupName].filter { !$0.isEmpty } })
    }

    public static let nodeFields: [LatticeQueryField<NetworkingNodePolicyRow>] = [
        LatticeQueryField(key: "node", aliases: ["name"], type: .string, get: { .string($0.nodeName) }),
        LatticeQueryField(key: "kind", aliases: ["policy"], type: .enumeration, values: NetworkingNodePolicyKind.allCases.map(\.rawValue),
                          get: { .string($0.kind.rawValue) }),
        LatticeQueryField(key: "state", aliases: ["status"], type: .enumeration, values: NetworkingPolicyState.allCases.map(\.rawValue),
                          valueAliases: ["failing": "failed", "pending": "planned", "disabled": "off"],
                          get: { $0.state.map { .string($0.rawValue) } ?? .none }),
    ]

    public static func nodes(_ source: String) -> Result<LatticeCompiledQuery<NetworkingNodePolicyRow>, LatticeQueryError> {
        LatticeQueryEngine.compile(source, fields: nodeFields, text: { [$0.nodeName, $0.nodeID] })
    }

    public static let dnsFields: [LatticeQueryField<NetworkingDNSDeployment>] = [
        LatticeQueryField(key: "name", type: .string, get: { .string($0.displayName) }),
        LatticeQueryField(key: "node", type: .list, get: { .strings([$0.nodeName, $0.nodeID].filter { !$0.isEmpty }) }),
        LatticeQueryField(key: "engine", type: .enumeration, values: ["coredns", "external"], get: { .string($0.isExternal ? "external" : "coredns") }),
        LatticeQueryField(key: "status", type: .string, get: { optional($0.status) }),
        LatticeQueryField(key: "exposure", type: .enumeration, values: ["mesh", "public"], get: { optional($0.exposure) }),
        LatticeQueryField(key: "hostname", aliases: ["host"], type: .string, get: { optional($0.hostname) }),
        LatticeQueryField(key: "drift", type: .bool, flag: true, sortable: false, get: { .bool($0.drift?.status == "drift") }),
    ]

    public static func dns(_ source: String) -> Result<LatticeCompiledQuery<NetworkingDNSDeployment>, LatticeQueryError> {
        LatticeQueryEngine.compile(source, fields: dnsFields, text: { [$0.displayName, $0.nodeName, $0.hostname].filter { !$0.isEmpty } })
    }

    /// A DDNS profile with the health the list groups it by.
    public struct DDNSRow: Sendable {
        public var profile: DDNSProfile
        public var nodeName: String
        public var health: DDNSHealth

        public init(profile: DDNSProfile, nodeName: String, health: DDNSHealth) {
            self.profile = profile
            self.nodeName = nodeName
            self.health = health
        }
    }

    public static let ddnsFields: [LatticeQueryField<DDNSRow>] = [
        LatticeQueryField(key: "name", type: .string, get: { .string($0.profile.name) }),
        LatticeQueryField(key: "node", type: .list, get: { .strings([$0.nodeName, $0.profile.nodeID].filter { !$0.isEmpty }) }),
        LatticeQueryField(key: "provider", type: .string, get: { optional($0.profile.provider) }),
        LatticeQueryField(key: "domain", aliases: ["record"], type: .list, get: { .strings($0.profile.domains) }),
        LatticeQueryField(key: "type", type: .enumeration, values: ["address", "cname"], get: { .string($0.profile.isCNAME ? "cname" : "address") }),
        LatticeQueryField(key: "state", aliases: ["status"], type: .enumeration, values: DDNSHealth.allCases.map(\.rawValue), get: { .string($0.health.rawValue) }),
        LatticeQueryField(key: "last_run", type: .time, get: { $0.profile.lastRunAt.map { .time($0) } ?? .none }),
    ]

    public static func ddns(_ source: String) -> Result<LatticeCompiledQuery<DDNSRow>, LatticeQueryError> {
        LatticeQueryEngine.compile(source, fields: ddnsFields, text: { [$0.profile.name, $0.nodeName] + $0.profile.domains })
    }

    public static let geoFields: [LatticeQueryField<NetworkingGeoRouting>] = [
        LatticeQueryField(key: "name", type: .string, get: { .string($0.displayName) }),
        LatticeQueryField(key: "hostname", aliases: ["host"], type: .string, get: { .string($0.hostname) }),
        LatticeQueryField(key: "strategy", type: .enumeration, values: ["geoip", "all-healthy"], get: { optional($0.strategy) }),
        LatticeQueryField(key: "status", type: .string, get: { optional($0.status) }),
        LatticeQueryField(key: "applied", type: .bool, flag: true, sortable: false, get: { .bool($0.lastAppliedAt != nil) }),
    ]

    public static func geo(_ source: String) -> Result<LatticeCompiledQuery<NetworkingGeoRouting>, LatticeQueryError> {
        LatticeQueryEngine.compile(source, fields: geoFields, text: { [$0.displayName, $0.hostname] })
    }

    /// A tunnel with its node's name.
    public struct TunnelRow: Sendable {
        public var tunnel: TunnelProfile
        public var nodeName: String

        public init(tunnel: TunnelProfile, nodeName: String) {
            self.tunnel = tunnel
            self.nodeName = nodeName
        }
    }

    public static let tunnelFields: [LatticeQueryField<TunnelRow>] = [
        LatticeQueryField(key: "name", type: .string, get: { .string($0.tunnel.displayName) }),
        LatticeQueryField(key: "node", type: .list, get: { .strings([$0.nodeName, $0.tunnel.nodeID].filter { !$0.isEmpty }) }),
        LatticeQueryField(key: "hostname", aliases: ["host"], type: .list, get: { .strings($0.tunnel.ingress.map(\.hostname)) }),
        LatticeQueryField(key: "ingress", type: .number, get: { .number(Double($0.tunnel.ingress.count)) }),
    ]

    public static func tunnels(_ source: String) -> Result<LatticeCompiledQuery<TunnelRow>, LatticeQueryError> {
        LatticeQueryEngine.compile(source, fields: tunnelFields, text: { [$0.tunnel.displayName, $0.nodeName] + $0.tunnel.ingress.map(\.hostname) })
    }

    public static let guardNodeFields: [LatticeQueryField<NetworkingNodeGuard>] = [
        LatticeQueryField(key: "node", aliases: ["name"], type: .string, get: { .string($0.displayName) }),
        LatticeQueryField(key: "state", aliases: ["status"], type: .enumeration, values: NetworkingGuardState.allCases.map(\.rawValue), get: { .string($0.state.rawValue) }),
        LatticeQueryField(key: "managed", type: .bool, flag: true, sortable: false, get: { .bool($0.binding.managed) }),
        LatticeQueryField(key: "group", aliases: ["groups"], type: .list, get: { .strings(($0.groups + $0.derivedGroups).map(\.displayName)) }),
    ]

    public static func guardNodes(_ source: String) -> Result<LatticeCompiledQuery<NetworkingNodeGuard>, LatticeQueryError> {
        LatticeQueryEngine.compile(source, fields: guardNodeFields, text: { [$0.displayName, $0.nodeID] + $0.groups.map(\.displayName) })
    }

    /// One sentence for a query the engine refused, naming the list.
    public static func message(_ error: LatticeQueryError, noun: String) -> String {
        let field = error.params["field"] ?? ""
        let hint = error.params["suggestion"].flatMap { $0.isEmpty ? nil : " Did you mean \($0)?" } ?? ""
        switch error.code {
        case .unknownField: return "\(noun) have no field \"\(field)\".\(hint)"
        case .unknownSort: return "\(noun) cannot sort by \"\(field)\".\(hint)"
        default: return "This query cannot be read at character \(error.start + 1)."
        }
    }
}
