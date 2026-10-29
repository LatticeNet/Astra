import Foundation
import AstraCore

public func checkMonitoring() async throws {
    try await checkMonitorCreateBody()
    try checkMonitorStats()
}

private func checkMonitorCreateBody() async throws {
    let transport = MockTransport(responses: [
        "https://lattice.example.com/api/monitors": (200, #"{"id":"mon1","name":"api","type":"http","target":"https://x","enabled":true}"#.data(using: .utf8)!),
    ])
    let session = LatticeClient(baseURL: URL(string: "https://lattice.example.com")!, credential: LatticeCredential(sessionCookie: "sid", csrfToken: "csrf-token"), transport: transport)

    try await session.createMonitor(name: "api", type: .http, target: "https://x", intervalSec: 60, timeoutSec: 10, assignAll: true, nodeIDs: [])
    let monitorBody = try await bodyObject(transport.bodies.last ?? nil)
    try expectEqual(Set(monitorBody.keys), ["name", "type", "target", "interval_sec", "timeout_sec", "assign_all", "node_ids"], "monitor create sends exactly the server fields")
    try expectEqual(monitorBody["type"] as? String, "http", "monitor type field")
    try expectEqual(await transport.methods.last ?? nil, "POST", "monitor create is POST")
    try expectEqual(await transport.csrfHeaders.last ?? nil, "csrf-token", "monitor create carries CSRF header")
}

private func checkMonitorStats() throws {
    let now = ISO8601DateFormatter().date(from: "2026-06-17T02:00:00Z")!
    let results = [
        MonitorResult(monitorID: "x", nodeID: "n1", at: now, success: true, latencyMs: 100),
        MonitorResult(monitorID: "x", nodeID: "n1", at: now.addingTimeInterval(60), success: false, latencyMs: 0, error: "timeout"),
        MonitorResult(monitorID: "x", nodeID: "n1", at: now.addingTimeInterval(120), success: true, latencyMs: 200)
    ]
    let stats = MonitorStats(results: results)
    try expectEqual(stats.successCount, 2, "monitor success count")
    try expect(abs((stats.uptimeFraction ?? 0) - 2.0 / 3.0) < 0.001, "monitor uptime fraction")
    try expect(abs((stats.averageLatencyMs ?? 0) - 150) < 0.001, "monitor average latency over successes")
    try expectEqual(stats.lastResult?.latencyMs, 200, "monitor last result by time")
}
