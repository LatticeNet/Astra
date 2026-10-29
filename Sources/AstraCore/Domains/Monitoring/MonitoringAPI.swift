import Foundation

struct MonitorCreateRequest: Encodable {
    var name: String
    var type: String
    var target: String
    var intervalSec: Int
    var timeoutSec: Int
    var assignAll: Bool
    var nodeIDs: [String]
    enum CodingKeys: String, CodingKey {
        case name, type, target
        case intervalSec = "interval_sec"
        case timeoutSec = "timeout_sec"
        case assignAll = "assign_all"
        case nodeIDs = "node_ids"
    }
}

public extension LatticeClient {
    // Monitors
    func listMonitors() async throws -> [Monitor] {
        try await perform([Monitor].self, path: "/api/monitors")
    }

    func createMonitor(name: String, type: MonitorType, target: String, intervalSec: Int, timeoutSec: Int, assignAll: Bool, nodeIDs: [String]) async throws {
        try await performVoid(
            path: "/api/monitors",
            body: MonitorCreateRequest(
                name: name, type: type.rawValue, target: target,
                intervalSec: intervalSec, timeoutSec: timeoutSec,
                assignAll: assignAll, nodeIDs: nodeIDs
            )
        )
    }

    func deleteMonitor(id: String) async throws {
        try await performVoid(path: "/api/monitors/delete", body: MachineDeleteRequest(id: id))
    }

    func monitorResults(monitorID: String) async throws -> [MonitorResult] {
        try await perform(
            [MonitorResult].self,
            path: "/api/monitors/results",
            query: [URLQueryItem(name: "monitor_id", value: monitorID)]
        )
    }
}
