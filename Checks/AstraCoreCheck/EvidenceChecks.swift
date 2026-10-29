import Foundation
import AstraCore

public func checkEvidence() async throws {
    let transport = MockTransport(responses: [
        "https://lattice.example.com/api/logs/query?source_id=s1&limit=200": (
            200,
            #"{"lines":[{"source_id":"s1","node_id":"node-a","seq":42,"at":"2026-06-17T02:00:00Z","line":"hello"}],"truncated":true,"next_before_seq":41}"#.data(using: .utf8)!
        )
    ])
    let session = LatticeClient(baseURL: URL(string: "https://lattice.example.com")!, credential: LatticeCredential(sessionCookie: "sid", csrfToken: "csrf-token"), transport: transport)

    let logs = try await session.queryLogs(sourceID: "s1", limit: 200)
    try expectEqual(logs.lines.first?.line, "hello", "log line text")
    try expectEqual(logs.nextBeforeSeq, 41, "log pagination cursor")
    try expect(logs.truncated, "log truncated flag")
}
