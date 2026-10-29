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

/// The largest page `GET /api/monitors/results` serves (`maxMonitorResultsLimit`).
public let monitoringResultsMaxLimit = 2_000

/// Which check answers a path series: a node pair, or one check on a source.
public enum MonitoringSeriesSubject: Sendable, Hashable {
    /// A pair of nodes, whichever check measures it; `check` picks one when several do.
    case pair(source: String, targetNode: String, check: String?)
    /// One monitor on one source; an empty source is a tls check's control-plane path.
    case monitor(id: String, source: String)

    var queryItems: [URLQueryItem] {
        switch self {
        case .pair(let source, let targetNode, let check):
            var items = [URLQueryItem(name: "source", value: source), URLQueryItem(name: "target_node", value: targetNode)]
            if let check, !check.isEmpty { items.append(URLQueryItem(name: "check", value: check)) }
            return items
        case .monitor(let id, let source):
            var items = [URLQueryItem(name: "monitor", value: id)]
            if !source.isEmpty { items.append(URLQueryItem(name: "source", value: source)) }
            return items
        }
    }

    /// The series subject for a path cell of the matrix. A pair names its
    /// definition, or an operator check by its monitor id; a cell of the
    /// unmigrated path set names nothing, since the server keys that series
    /// on no id and answers 404 to its generated monitor's (`PathDetail.vue`).
    public init(path: PathView) {
        if path.targetNode.isEmpty {
            self = .monitor(id: path.monitorID, source: path.source)
        } else {
            let check: String? = !path.checkDefinitionID.isEmpty ? path.checkDefinitionID : (path.managed ? nil : path.monitorID)
            self = .pair(source: path.source, targetNode: path.targetNode, check: check)
        }
    }
}

private struct MonitoringLineChainList: Decodable {
    var chains: [MonitoringLineChain]?
}

public extension LatticeClient {
    // Monitors
    /// `GET /api/monitors`: a bare array from today's server, `{monitors}` from some.
    func listMonitors() async throws -> [Monitor] {
        let data = try await performData(path: "/api/monitors")
        return try LatticeListDecoder.decode(Monitor.self, from: data, key: "monitors")
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

    /// 409 on a generated check; the phone never offers it there.
    func deleteMonitor(id: String) async throws {
        try await performVoid(path: "/api/monitors/delete", body: MachineDeleteRequest(id: id))
    }

    func monitorResults(monitorID: String) async throws -> [MonitorResult] {
        try await monitoringResults(monitorID: monitorID)
    }

    /// `GET /api/monitors/results`, newest first. The endpoint has no offset,
    /// so a longer history is a larger `limit` (1 to 2000, server default 500).
    /// `nodeID` reads one pair; an empty string names a tls check's pair.
    func monitoringResults(monitorID: String, nodeID: String? = nil, limit: Int? = nil) async throws -> [MonitorResult] {
        var query = [URLQueryItem(name: "monitor_id", value: monitorID)]
        if let nodeID { query.append(URLQueryItem(name: "node_id", value: nodeID)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(min(max(limit, 1), monitoringResultsMaxLimit)))) }
        let data = try await performData(path: "/api/monitors/results", query: query)
        return try LatticeListDecoder.decode(MonitorResult.self, from: data, key: "results")
    }

    /// `POST /api/monitors/update {id, version, enabled}`. A stale version is
    /// 409 `version_conflict`; a generated check is 409 too.
    func monitoringSetEnabled(id: String, version: Int64, enabled: Bool) async throws -> Monitor {
        try await perform(Monitor.self, path: "/api/monitors/update", method: "POST", body: MonitoringUpdateRequest(id: id, version: version, enabled: enabled))
    }

    // Series

    /// `GET /api/monitors/series`. `compare` adds the previous period's p50.
    func monitoringPathSeries(_ subject: MonitoringSeriesSubject, window: MonitorWindow, compare: Bool = false) async throws -> MonitoringPathSeries {
        var query = subject.queryItems
        query.append(URLQueryItem(name: "window", value: window.rawValue))
        if compare { query.append(URLQueryItem(name: "compare", value: "previous")) }
        return try await perform(MonitoringPathSeries.self, path: "/api/monitors/series", query: query)
    }

    /// `GET /api/monitors/latency/series`, the latency probe plan's series for
    /// a node pair (servers before the path matrix). 404 when the pair has no probe.
    func monitoringLatencySeries(source: String, target: String, window: String) async throws -> MonitoringLatencySeries {
        try await perform(MonitoringLatencySeries.self, path: "/api/monitors/latency/series", query: [
            URLQueryItem(name: "source", value: source),
            URLQueryItem(name: "target", value: target),
            URLQueryItem(name: "window", value: window),
        ])
    }

    /// `GET /api/monitors/latency/rollups`.
    func monitoringLatencyRollups() async throws -> MonitoringLatencyRollups {
        try await perform(MonitoringLatencyRollups.self, path: "/api/monitors/latency/rollups")
    }

    // Definitions

    func monitoringDefinitions() async throws -> MonitoringDefinitionList {
        try await perform(MonitoringDefinitionList.self, path: "/api/monitors/definitions")
    }

    /// One definition with every monitor it expanded to. 404 when not visible.
    func monitoringDefinition(id: String) async throws -> MonitoringCheckDefinition {
        try await perform(MonitoringCheckDefinition.self, path: "/api/monitors/definitions", query: [URLQueryItem(name: "id", value: id)])
    }

    /// `POST /api/monitors/definitions/delete`. 409 when the version or the
    /// monitor list no longer matches what the server holds.
    func monitoringDeleteDefinition(_ request: MonitoringDefinitionDeleteRequest) async throws -> MonitoringDefinitionDeleteResult {
        try await perform(MonitoringDefinitionDeleteResult.self, path: "/api/monitors/definitions/delete", method: "POST", body: request)
    }

    // Line chains

    /// `GET /api/network/lines/chains` (proxy:read). `{chains}` with `chains`
    /// possibly null, or a bare array.
    func monitoringLineChains() async throws -> [MonitoringLineChain] {
        let data = try await performData(path: "/api/network/lines/chains")
        if let rows = try? JSONDecoder().decode([MonitoringLineChain].self, from: data) { return rows }
        do {
            return try JSONDecoder().decode(MonitoringLineChainList.self, from: data).chains ?? []
        } catch {
            throw LatticeAPIError.invalidResponse
        }
    }
}
