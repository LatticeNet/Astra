import Foundation

private struct SourcesEnvelope: Decodable { var sources: [LogSource] }

private struct StatsEnvelope: Decodable { var stats: [LogSourceStats] }

public extension LatticeClient {
    // Logs
    func listLogSources() async throws -> [LogSource] {
        let data = try await performData(path: "/api/logs/sources")
        let envelope = (try? JSONDecoder().decode(SourcesEnvelope.self, from: data)) ?? SourcesEnvelope(sources: [])
        return envelope.sources
    }

    func logStats(sourceID: String? = nil) async throws -> [LogSourceStats] {
        var query: [URLQueryItem] = []
        if let sourceID, !sourceID.isEmpty { query.append(URLQueryItem(name: "source_id", value: sourceID)) }
        let data = try await performData(path: "/api/logs/stats", query: query)
        let envelope = (try? JSONDecoder().decode(StatsEnvelope.self, from: data)) ?? StatsEnvelope(stats: [])
        return envelope.stats
    }

    func queryLogs(sourceID: String, search: String? = nil, limit: Int = 200, beforeSeq: UInt64? = nil) async throws -> LogQueryResponse {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "source_id", value: sourceID),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let search, !search.isEmpty { query.append(URLQueryItem(name: "q", value: search)) }
        if let beforeSeq { query.append(URLQueryItem(name: "before_seq", value: String(beforeSeq))) }
        return try await perform(LogQueryResponse.self, path: "/api/logs/query", query: query)
    }
}
