import Foundation
import AstraCore

public func checkNotify() async throws {
    let transport = MockTransport(responses: [
        "https://lattice.example.com/api/notify/rules": (200, #"{"rules":[{"id":"r1","name":"down","event_types":["monitor.down"],"channel_ids":["c1"],"enabled":true}]}"#.data(using: .utf8)!),
    ])
    let session = LatticeClient(baseURL: URL(string: "https://lattice.example.com")!, credential: LatticeCredential(sessionCookie: "sid", csrfToken: "csrf-token"), transport: transport)

    let rules = try await session.listNotifyRules()
    try expectEqual(rules.map(\.id), ["r1"], "notify rules unwrapped from envelope")
}
