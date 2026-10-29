import Foundation

private struct ResultsEnvelope: Decodable { var results: [NodeGeoResolveResult] }

struct NodeDisableRequest: Encodable {
    var nodeID: String
    var disabled: Bool
    enum CodingKeys: String, CodingKey { case nodeID = "node_id", disabled }
}

struct NodeIDRequest: Encodable {
    var nodeID: String
    enum CodingKeys: String, CodingKey { case nodeID = "node_id" }
}

struct EnrollNodeRequest: Encodable {
    var nodeID: String
    var name: String
    var tags: [String]
    var role: String
    var wireGuardIP: String
    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id", name, tags, role
        case wireGuardIP = "wireguard_ip"
    }
}

struct NodeGeoInput: Encodable {
    var country: String
    var region: String
    var city: String
    var lat: Double
    var lon: Double
    var asOrg: String
    var provider: String
    enum CodingKeys: String, CodingKey {
        case country, region, city, lat, lon, provider
        case asOrg = "as_org"
    }
}

struct NodeGeoSetRequest: Encodable {
    var nodeID: String
    var geo: NodeGeoInput
    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case geo
    }
}

struct NodeGeoResolveRequest: Encodable {
    var nodeID: String?
    var all: Bool
    var missingOnly: Bool
    var overwrite: Bool
    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case all
        case missingOnly = "missing_only"
        case overwrite
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(nodeID, forKey: .nodeID)
        try container.encode(all, forKey: .all)
        try container.encode(missingOnly, forKey: .missingOnly)
        try container.encode(overwrite, forKey: .overwrite)
    }
}

public extension LatticeClient {
    // Nodes: actions
    @discardableResult
    func setNodeDisabled(nodeID: String, disabled: Bool) async throws -> Data {
        try await performVoid(
            path: "/api/nodes/disable",
            body: NodeDisableRequest(nodeID: nodeID, disabled: disabled),
            query: [URLQueryItem(name: "node_id", value: nodeID)]
        )
    }

    func rotateNodeToken(nodeID: String) async throws -> NodeTokenResponse {
        try await perform(
            NodeTokenResponse.self,
            path: "/api/nodes/rotate-token",
            method: "POST",
            body: NodeIDRequest(nodeID: nodeID),
            query: [URLQueryItem(name: "node_id", value: nodeID)]
        )
    }

    func enrollNode(nodeID: String, name: String, tags: [String] = [], role: String = "", wireGuardIP: String = "") async throws -> NodeTokenResponse {
        try await perform(
            NodeTokenResponse.self,
            path: "/api/nodes/enroll-token",
            method: "POST",
            body: EnrollNodeRequest(nodeID: nodeID, name: name, tags: tags, role: role, wireGuardIP: wireGuardIP)
        )
    }

    func setNodeGeo(nodeID: String, country: String, region: String, city: String, lat: Double, lon: Double, asOrg: String = "", provider: String = "") async throws -> NodeGeoView {
        try await perform(
            NodeGeoView.self,
            path: "/api/nodes/geo",
            method: "POST",
            body: NodeGeoSetRequest(
                nodeID: nodeID,
                geo: NodeGeoInput(country: country, region: region, city: city, lat: lat, lon: lon, asOrg: asOrg, provider: provider)
            )
        )
    }

    @discardableResult
    func resolveNodeGeo(nodeID: String? = nil, all: Bool = false, missingOnly: Bool = true, overwrite: Bool = false) async throws -> [NodeGeoResolveResult] {
        let data = try await performData(
            path: "/api/nodes/geo/resolve",
            method: "POST",
            body: NodeGeoResolveRequest(nodeID: nodeID, all: all, missingOnly: missingOnly, overwrite: overwrite)
        )
        let envelope = (try? JSONDecoder().decode(ResultsEnvelope.self, from: data)) ?? ResultsEnvelope(results: [])
        return envelope.results
    }

    /// `GET /api/nodes/capabilities?node_id=` effective admission per capability.
    func fetchNodeCapabilities(nodeID: String) async throws -> [NodeCapabilityEffective] {
        try await perform(
            NodeCapabilitiesResponse.self,
            path: "/api/nodes/capabilities",
            query: [URLQueryItem(name: "node_id", value: nodeID)]
        ).effective
    }
}

// MARK: - M2 endpoints (section 8.4)

public extension LatticeClient {
    /// `GET /api/nodes` with the node facts `LatticeNode` does not decode yet
    /// (agent debug, runtime, provider). Shared owns the endpoint; this reads
    /// the same body once until those fields join the Shared model.
    func fleetFetchNodeRecords() async throws -> [FleetNodeRecord] {
        let data = try await performData(path: "/api/nodes")
        let nodes = try LatticeDecoder.decodeNodes(from: data)
        let facts = (try? LatticeListDecoder.decode(FleetNodeFacts.self, from: data, key: "nodes")) ?? []
        let byID = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return nodes.map { FleetNodeRecord(node: $0, facts: byID[$0.id]) }
    }

    /// `GET /api/nodes/status-history?days=&node_id=`; a node the token cannot read answers 404.
    func fleetStatusHistory(nodeID: String? = nil, days: Int = 7) async throws -> FleetStatusHistoryResponse {
        var query = [URLQueryItem(name: "days", value: String(min(max(days, 1), 30)))]
        if let nodeID { query.append(URLQueryItem(name: "node_id", value: nodeID)) }
        return try await perform(FleetStatusHistoryResponse.self, path: "/api/nodes/status-history", query: query)
    }

    /// `GET /api/nodes/history?node_id=&range=`: cpu, mem, disk, load, rx, tx and beat gap.
    func fleetNodeHistory(nodeID: String, range: FleetMetricsRange) async throws -> FleetMetricsQuery {
        try await perform(
            FleetMetricsQuery.self,
            path: "/api/nodes/history",
            query: [URLQueryItem(name: "node_id", value: nodeID), URLQueryItem(name: "range", value: range.rawValue)]
        )
    }

    /// `GET /api/nodes/network?node_id=&rules=1`.
    func fleetNodeNetwork(nodeID: String, rules: Bool = true) async throws -> FleetNodeNetworkView {
        var query = [URLQueryItem(name: "node_id", value: nodeID)]
        if rules { query.append(URLQueryItem(name: "rules", value: "1")) }
        return try await perform(FleetNodeNetworkView.self, path: "/api/nodes/network", query: query)
    }

    /// `GET /api/nodes/duplicates`: sets of nodes that look like one machine.
    func fleetDuplicates() async throws -> FleetDuplicatesResponse {
        try await perform(FleetDuplicatesResponse.self, path: "/api/nodes/duplicates")
    }

    /// `GET /api/nodes/beacon?node_id=`. Servers older than the beacon answer 404.
    func fleetBeacon(nodeID: String) async throws -> FleetBeaconView {
        try await perform(FleetBeaconView.self, path: "/api/nodes/beacon", query: [URLQueryItem(name: "node_id", value: nodeID)])
    }

    /// `POST /api/nodes/beacon/rotate {node_id}`: a new key epoch, no plan. 409 when the beacon is off.
    func fleetRotateBeacon(nodeID: String) async throws -> FleetBeaconRotateResponse {
        try await perform(FleetBeaconRotateResponse.self, path: "/api/nodes/beacon/rotate", method: "POST", body: NodeIDRequest(nodeID: nodeID))
    }

    /// `POST /api/nodes/capabilities {node_id, capability, state, reason}`.
    func fleetDecideCapability(_ request: FleetCapabilityDecisionRequest) async throws -> FleetNodeCapabilityRecord {
        try await perform(FleetNodeCapabilityRecord.self, path: "/api/nodes/capabilities", method: "POST", body: request)
    }

    /// `GET /api/capabilities`: every gate with what enforcing it would refuse.
    func fleetCapabilityGates() async throws -> [FleetCapabilityImpact] {
        try await perform(FleetCapabilityImpactList.self, path: "/api/capabilities").capabilities
    }

    /// `POST /api/capabilities {capability, enforced}`. A token with a node
    /// allowlist is refused: the gate is fleet-wide.
    func fleetSetGateEnforced(capability: String, enforced: Bool) async throws -> FleetCapabilityImpact {
        try await perform(FleetCapabilityImpact.self, path: "/api/capabilities", method: "POST", body: FleetGateRequest(capability: capability, enforced: enforced))
    }

    /// `POST /api/nodes/update`: name, role, comment and tags, each replaced whole.
    func fleetUpdateNode(_ request: FleetNodeUpdateRequest) async throws -> FleetNodeUpdateResponse {
        try await perform(FleetNodeUpdateResponse.self, path: "/api/nodes/update", method: "POST", body: request)
    }

    /// `POST /api/nodes/delete/plan {node_id}`: the dry run; it changes nothing.
    func fleetPlanNodeDelete(nodeID: String) async throws -> FleetNodeDeleteSummary {
        try await perform(FleetNodeDeleteSummary.self, path: "/api/nodes/delete/plan", method: "POST", body: NodeIDRequest(nodeID: nodeID))
    }

    /// `POST /api/nodes/delete {node_id}`. Not bound to the plan; callers
    /// re-run the plan right before sending.
    func fleetDeleteNode(nodeID: String) async throws -> FleetNodeDeleteSummary {
        try await perform(FleetNodeDeleteSummary.self, path: "/api/nodes/delete", method: "POST", body: NodeIDRequest(nodeID: nodeID))
    }

    /// `POST /api/nodes/debug {node_id, enabled, collect}`; answers the node view.
    func fleetSetAgentDebug(nodeID: String, enabled: Bool, collect: Bool) async throws -> FleetNodeFacts {
        try await perform(FleetNodeFacts.self, path: "/api/nodes/debug", method: "POST", body: FleetDebugRequest(nodeID: nodeID, enabled: enabled, collect: enabled && collect))
    }

    /// `POST /api/nodes/geo {node_id, clear: true}`.
    func fleetClearNodeGeo(nodeID: String) async throws -> NodeGeoView {
        try await perform(NodeGeoView.self, path: "/api/nodes/geo", method: "POST", body: FleetGeoClearRequest(nodeID: nodeID))
    }

    /// `GET /api/groups`: every group with resolved members and health.
    func fleetGroups() async throws -> FleetGroupsResponse {
        try await perform(FleetGroupsResponse.self, path: "/api/groups")
    }

    /// `GET /api/groups/used-by?id=`.
    func fleetGroupUsedBy(groupID: String) async throws -> FleetGroupUsedBy {
        try await perform(FleetGroupUsedBy.self, path: "/api/groups/used-by", query: [URLQueryItem(name: "id", value: groupID)])
    }

    /// `POST /api/groups/delete {id}`; 409 while anything names the group.
    func fleetDeleteGroup(groupID: String) async throws {
        try await performVoid(path: "/api/groups/delete", body: FleetGroupDeleteRequest(id: groupID))
    }

    /// `POST /api/groups/members {group_id, add, remove}`; answers the group.
    func fleetSetGroupMembers(_ request: FleetGroupMembersRequest) async throws -> FleetGroupView {
        try await perform(FleetGroupView.self, path: "/api/groups/members", method: "POST", body: request)
    }
}
