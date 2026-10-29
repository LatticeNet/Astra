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
    // Nodes — actions
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
