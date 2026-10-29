import Foundation
import AstraCore

public func checkFleet() async throws {
    try await checkNodeWrites()
    try checkFleetSummaries()
}

private func checkNodeWrites() async throws {
    let transport = MockTransport(responses: [
        "https://lattice.example.com/api/nodes/disable?node_id=node-a": (200, #"{"ok":true,"disabled":true}"#.data(using: .utf8)!),
        "https://lattice.example.com/api/nodes/rotate-token?node_id=node-a": (200, #"{"node_id":"node-a","token":"tok.secret"}"#.data(using: .utf8)!),
        "https://lattice.example.com/api/nodes/capabilities?node_id=node-a": (
            200,
            #"{"node_id":"node-a","effective":[{"capability":"sshguard","enforced":true,"mutates":true,"allowed":true,"source":"record","state":"enrolled"}]}"#.data(using: .utf8)!
        ),
    ])
    let session = LatticeClient(baseURL: URL(string: "https://lattice.example.com")!, credential: LatticeCredential(sessionCookie: "sid", csrfToken: "csrf-token"), transport: transport)

    try await session.setNodeDisabled(nodeID: "node-a", disabled: true)
    let disableBody = try await bodyObject(transport.bodies.last ?? nil)
    try expectEqual(disableBody["node_id"] as? String, "node-a", "disable node id body")
    try expectEqual(disableBody["disabled"] as? Bool, true, "disable flag body")

    let rotate = try await session.rotateNodeToken(nodeID: "node-a")
    try expectEqual(rotate.token, "tok.secret", "rotate returns one-time token")

    let caps = try await session.fetchNodeCapabilities(nodeID: "node-a")
    try expectEqual(caps.first?.capability, "sshguard", "capability id")
    try expect(caps.first?.allowed == true, "capability allowed")
}

private func checkFleetSummaries() throws {
    let now = ISO8601DateFormatter().date(from: "2026-06-17T02:00:00Z")!
    let healthy = LatticeNode(id: "n1", name: "h", online: true, lastSeen: now, metrics: LatticeMetrics(cpuPercent: 20, memoryUsed: 20, memoryTotal: 100), hostFacts: LatticeHostFacts())
    let hot = LatticeNode(id: "n2", name: "hot", online: true, lastSeen: now, metrics: LatticeMetrics(cpuPercent: 95, memoryUsed: 50, memoryTotal: 100), hostFacts: LatticeHostFacts())
    let down = LatticeNode(id: "n3", name: "down", online: false, lastSeen: now.addingTimeInterval(-9999), metrics: LatticeMetrics(), hostFacts: LatticeHostFacts())

    let summary = FleetSummary(nodes: [healthy, hot, down], thresholds: FleetThresholds(), now: now)
    try expectEqual(summary.total, 3, "fleet total")
    try expectEqual(summary.online, 2, "fleet online")
    try expectEqual(summary.offline, 1, "fleet offline")
    try expectEqual(summary.critical, 2, "fleet critical counts hot cpu + offline")
    try expect(abs(summary.averageCPU - 57.5) < 0.001, "fleet average cpu over online nodes")

    var history = MetricsHistory(capacity: 2)
    history.record(nodes: [healthy, hot], at: now)
    history.record(nodes: [healthy, hot], at: now.addingTimeInterval(30))
    history.record(nodes: [healthy], at: now.addingTimeInterval(60))
    try expectEqual(history.samples(for: "n1").count, 2, "history respects capacity")
    try expectEqual(history.samples(for: "n2").count, 0, "history prunes missing nodes")
    try expectEqual(history.samples(for: "n1").last?.cpu, 20, "history records latest cpu")

    let worldwide = try expectUnwrapped(
        FleetMapRegion.fitting(latitudes: [37.77, 35.68], longitudes: [-122.4, 139.7]),
        "worldwide pair fits"
    )
    try expect(worldwide.longitudeDelta <= 360, "worldwide longitude span stays inside MapKit's 360 cap")
    try expect(worldwide.latitudeDelta <= 180, "latitude span stays inside MapKit's 180 cap")
    try expect(FleetMapRegion.fitting(latitudes: [.nan], longitudes: [1]) == nil, "NaN pair is rejected")
}
