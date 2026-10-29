import Foundation

private struct PluginCallBody: Encodable {
    var id: String
    var service: String
    var method: String
    var payload: AnyEncodable?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: LatticeCodingKey.self)
        try container.encode(id, forKey: LatticeCodingKey("id"))
        try container.encode(service, forKey: LatticeCodingKey("service"))
        try container.encode(method, forKey: LatticeCodingKey("method"))
        if let payload {
            try container.encode(payload, forKey: LatticeCodingKey("payload"))
        }
    }
}

public extension LatticeClient {
    /// `POST /api/plugins/call {id, service, method, payload}`. Plugin RPC
    /// payloads are not versioned, so the raw answer is returned and each
    /// caller decodes it; a decode failure is companion behind, never empty.
    func callPlugin(id: String, service: String, method: String, body: (any Encodable & Sendable)? = nil) async throws -> Data {
        let request = PluginCallBody(id: id, service: service, method: method, payload: body.map(AnyEncodable.init))
        return try await performData(path: "/api/plugins/call", method: "POST", body: request)
    }

    /// `callPlugin` decoded as `T`, mapping a decode failure to `.invalidResponse`.
    func callPlugin<T: Decodable>(_ type: T.Type, id: String, service: String, method: String, body: (any Encodable & Sendable)? = nil) async throws -> T {
        let data = try await callPlugin(id: id, service: service, method: method, body: body)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LatticeAPIError.invalidResponse
        }
    }
}
