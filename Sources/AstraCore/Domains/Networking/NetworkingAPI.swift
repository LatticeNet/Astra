import Foundation

private struct PoliciesEnvelope: Decodable { var policies: [NetPolicy] }
private struct GroupPoliciesEnvelope: Decodable { var policies: [NetworkingGroupPolicy] }
private struct DeploymentsEnvelope: Decodable { var deployments: [NetworkingDNSDeployment] }
private struct GeoEnvelope: Decodable {
    var routings: [NetworkingGeoRouting]
    enum CodingKeys: String, CodingKey { case routings = "geo_routings" }
}
private struct GuardGroupsEnvelope: Decodable { var groups: [NetworkingSecurityGroup] }
private struct GuardZonesEnvelope: Decodable { var zones: [NetworkingGuardZone] }
private struct GuardNodesEnvelope: Decodable { var nodes: [NetworkingNodeGuard] }
private struct NodeGroupBindingsEnvelope: Decodable { var bindings: [NetworkingNodeGroupBinding] }

/// `POST /api/netpolicy/plan`.
public struct NetworkingPlanNodeBody: Encodable, Equatable, Sendable {
    public var nodeID: String
    public init(nodeID: String) { self.nodeID = nodeID }
    enum CodingKeys: String, CodingKey { case nodeID = "node_id" }
}

/// `POST /api/netpolicy/convert`: name and priority only when given.
public struct NetworkingConvertBody: Encodable, Equatable, Sendable {
    public var targetNodeID: String
    public var name: String?
    public var priority: Int?

    public init(targetNodeID: String, name: String? = nil, priority: Int? = nil) {
        self.targetNodeID = targetNodeID
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = trimmed.isEmpty ? nil : trimmed
        self.priority = priority
    }

    enum CodingKeys: String, CodingKey {
        case name, priority
        case targetNodeID = "target_node_id"
    }
}

/// `POST /api/group-policies/plan` takes an empty object.
public struct NetworkingEmptyBody: Encodable, Equatable, Sendable {
    public init() {}
}

/// `POST /api/dns/plan`: the lockout acceptance is sent only once accepted.
public struct NetworkingDNSPlanBody: Encodable, Equatable, Sendable {
    public var id: String
    public var acceptLockoutRisk: Bool

    public init(id: String, acceptLockoutRisk: Bool = false) {
        self.id = id
        self.acceptLockoutRisk = acceptLockoutRisk
    }

    enum CodingKeys: String, CodingKey {
        case id
        case acceptLockoutRisk = "accept_lockout_risk"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if acceptLockoutRisk { try c.encode(true, forKey: .acceptLockoutRisk) }
    }
}

/// `POST /api/dns/measure-cert`.
public struct NetworkingMeasureCertBody: Encodable, Equatable, Sendable {
    public var id: String
    public var ports: [Int]
    public init(id: String, ports: [Int]) {
        self.id = id
        self.ports = ports
    }
}

/// The DNS plan answer: the filed approval and its non-blocking findings.
public struct NetworkingDNSPlanResponse: Decodable, Sendable {
    public var approval: Approval
    public var findings: [PlanFinding]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        guard let approval = try c.networkingObject(Approval.self, "approval") else {
            throw DecodingError.keyNotFound(LatticeCodingKey("approval"), .init(codingPath: c.codingPath, debugDescription: "approval is required"))
        }
        self.approval = approval
        findings = try c.networkingList(PlanFinding.self, "findings")
    }
}

/// `POST /api/dns/publish`: what the provider now holds.
public struct NetworkingDNSPublishResponse: Decodable, Sendable {
    public var ok: Bool
    public var ipv4: String
    public var ipv6: String
    public var deployment: NetworkingDNSDeployment?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        ok = c.networkingBool("ok")
        ipv4 = c.networkingString("ipv4")
        ipv6 = c.networkingString("ipv6")
        deployment = try c.networkingObject(NetworkingDNSDeployment.self, "deployment")
    }
}

/// `POST /api/dns/measure-cert`: the checks it created and the ones it linked.
public struct NetworkingMeasureCertResponse: Decodable, Sendable {
    public var deployment: NetworkingDNSDeployment?
    public var created: [String]
    public var linked: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        deployment = try c.networkingObject(NetworkingDNSDeployment.self, "deployment")
        created = c.networkingStrings("created")
        linked = c.networkingStrings("linked")
    }
}

public extension LatticeClient {
    // MARK: Outbound policy reads

    /// `GET /api/netpolicy` → `{"policies":[...]}`.
    func listNetPolicies() async throws -> [NetPolicy] {
        let data = try await performData(path: "/api/netpolicy")
        do {
            return try JSONDecoder().decode(PoliciesEnvelope.self, from: data).policies
        } catch {
            throw LatticeAPIError.invalidResponse
        }
    }

    /// `GET /api/netpolicy/graph` → `{nodes,edges,externals}`.
    func netPolicyGraph() async throws -> NetGraph {
        try await perform(NetGraph.self, path: "/api/netpolicy/graph")
    }

    /// `GET /api/group-policies` → `{"policies":[...]}`.
    func networkingGroupPolicies() async throws -> [NetworkingGroupPolicy] {
        try await perform(GroupPoliciesEnvelope.self, path: "/api/group-policies").policies
    }

    /// `GET /api/netpolicy/matrix?direction=egress|ingress`.
    func networkingMatrix(direction: String) async throws -> NetworkingMatrix {
        try await perform(NetworkingMatrix.self, path: "/api/netpolicy/matrix", query: [URLQueryItem(name: "direction", value: direction)])
    }

    // MARK: Outbound policy plans

    /// Files the plan for one node's document; the answer is a bare approval.
    func networkingPlanNodePolicy(nodeID: String) async throws -> Approval {
        let data = try await performData(path: "/api/netpolicy/plan", method: "POST", body: NetworkingPlanNodeBody(nodeID: nodeID))
        return try ApprovalReviewDecoder.decode(data)
    }

    /// Creates an outbound policy from a node's manual document, then files its plan.
    func networkingConvertPolicy(_ body: NetworkingConvertBody) async throws -> NetworkingConvertResult {
        try await perform(NetworkingConvertResult.self, path: "/api/netpolicy/convert", method: "POST", body: body)
    }

    /// Plans every node covered by any enabled outbound policy.
    func networkingPlanGroupPolicies() async throws -> NetworkingGroupPlanResult {
        try await perform(NetworkingGroupPlanResult.self, path: "/api/group-policies/plan", method: "POST", body: NetworkingEmptyBody())
    }

    // MARK: Self-host DNS

    /// `GET /api/dns/deployments` → `{"deployments":[...]}`.
    func networkingDNSDeployments() async throws -> [NetworkingDNSDeployment] {
        try await perform(DeploymentsEnvelope.self, path: "/api/dns/deployments").deployments
    }

    /// Files a DNS plan. A plan the lint blocks answers 409 with findings,
    /// surfaced as `LatticeAPIError.conflict`; resend with the acceptance
    /// only once the operator ticked it.
    func networkingPlanDNS(_ body: NetworkingDNSPlanBody) async throws -> NetworkingDNSPlanResponse {
        try await perform(NetworkingDNSPlanResponse.self, path: "/api/dns/plan", method: "POST", body: body)
    }

    /// Writes the node's current addresses to the external DNS provider.
    func networkingPublishDNS(id: String) async throws -> NetworkingDNSPublishResponse {
        try await perform(NetworkingDNSPublishResponse.self, path: "/api/dns/publish", method: "POST", body: IDBody(id: id))
    }

    /// Creates (or links) tls checks on the deployment's DoT and DoH ports.
    func networkingMeasureCert(_ body: NetworkingMeasureCertBody) async throws -> NetworkingMeasureCertResponse {
        try await perform(NetworkingMeasureCertResponse.self, path: "/api/dns/measure-cert", method: "POST", body: body)
    }

    // MARK: DDNS writes (the list is Shared `listDDNS`)

    /// Runs one profile now; the answer is the profile after the run.
    func networkingRunDDNS(id: String) async throws -> DDNSProfile {
        try await perform(DDNSProfile.self, path: "/api/ddns/run", method: "POST", body: IDBody(id: id))
    }

    func networkingDeleteDDNS(id: String) async throws {
        try await performVoid(path: "/api/ddns/delete", body: IDBody(id: id))
    }

    // MARK: Geo-Routing

    /// `GET /api/geo-routing` → `{"geo_routings":[...]}`.
    func networkingGeoRoutings() async throws -> [NetworkingGeoRouting] {
        try await perform(GeoEnvelope.self, path: "/api/geo-routing").routings
    }

    /// Renders the routing's config without filing anything (a read, geo:read).
    func networkingPreviewGeo(id: String) async throws -> NetworkingGeoPlan {
        try await perform(NetworkingGeoPlan.self, path: "/api/geo-routing/plan", method: "POST", body: IDBody(id: id))
    }

    func networkingDeleteGeo(id: String) async throws {
        try await performVoid(path: "/api/geo-routing/delete", body: IDBody(id: id))
    }

    // MARK: Tunnels

    /// `GET /api/tunnels` → bare array.
    func listTunnels() async throws -> [TunnelProfile] {
        try await perform([TunnelProfile].self, path: "/api/tunnels")
    }

    /// Files the tunnel's plan. The server answers with a raw model.Approval,
    /// which carries no plan_sha256 (only approvalView does), so only the id
    /// is required: Review reloads the approval by id and hashes it there.
    func networkingPlanTunnel(id: String) async throws -> Approval {
        let data = try await performData(path: "/api/tunnels/plan", method: "POST", body: IDBody(id: id))
        let approval = try JSONDecoder().decode(Approval.self, from: data)
        if approval.id.isEmpty { throw LatticeAPIError.invalidResponse }
        return approval
    }

    func networkingDeleteTunnel(id: String) async throws {
        try await performVoid(path: "/api/tunnels/delete", body: IDBody(id: id))
    }

    // MARK: Inbound firewall

    /// `GET /api/netguard/groups`: needs netguard:read on an unconfined credential.
    func networkingGuardGroups() async throws -> [NetworkingSecurityGroup] {
        try await perform(GuardGroupsEnvelope.self, path: "/api/netguard/groups").groups
    }

    /// `GET /api/netguard/zones`: needs netguard:read on an unconfined credential.
    func networkingGuardZones() async throws -> [NetworkingGuardZone] {
        try await perform(GuardZonesEnvelope.self, path: "/api/netguard/zones").zones
    }

    /// `GET /api/netguard/nodes`: each node the credential may read, with its binding.
    func networkingGuardNodes() async throws -> [NetworkingNodeGuard] {
        try await perform(GuardNodesEnvelope.self, path: "/api/netguard/nodes").nodes
    }

    /// `GET /api/netguard/node-group-bindings`: needs netguard:read unconfined and group:read.
    func networkingNodeGroupBindings() async throws -> [NetworkingNodeGroupBinding] {
        try await perform(NodeGroupBindingsEnvelope.self, path: "/api/netguard/node-group-bindings").bindings
    }
}
