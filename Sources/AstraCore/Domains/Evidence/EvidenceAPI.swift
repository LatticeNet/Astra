import Foundation

private struct EvidenceSourcesEnvelope: Decodable { var sources: [LogSource] }
private struct EvidenceStatsEnvelope: Decodable { var stats: [LogSourceStats] }
private struct EvidenceSessionsEnvelope: Decodable { var sessions: [EvidenceTraceSession] }
private struct EvidencePoliciesEnvelope: Decodable { var policies: [EvidenceTracePolicy] }
private struct EvidenceMarkersEnvelope: Decodable { var markers: [EvidenceMarker] }

/// The M10 endpoints (section 8.4). Every read needs log:read and is
/// narrowed by the server to the nodes the caller may see; starting and
/// stopping a capture needs log:admin on every node it names.
public extension LatticeClient {
    // MARK: Raw logs

    /// `GET /api/logs/sources`. A body that does not decode is the app
    /// being behind the server, never an empty list.
    func listLogSources() async throws -> [LogSource] {
        try await perform(EvidenceSourcesEnvelope.self, path: "/api/logs/sources").sources
    }

    /// `GET /api/logs/stats[?source_id=]`.
    func logStats(sourceID: String? = nil) async throws -> [LogSourceStats] {
        var query: [URLQueryItem] = []
        if let sourceID, !sourceID.isEmpty { query.append(URLQueryItem(name: "source_id", value: sourceID)) }
        return try await perform(EvidenceStatsEnvelope.self, path: "/api/logs/stats", query: query).stats
    }

    /// `GET /api/logs/query`: a newest-first page; `beforeSeq` pages older.
    func queryLogs(sourceID: String, search: String? = nil, limit: Int = 200, beforeSeq: UInt64? = nil) async throws -> LogQueryResponse {
        try await perform(LogQueryResponse.self, path: "/api/logs/query", query: EvidenceLogs.queryItems(sourceID: sourceID, search: search, limit: limit, beforeSeq: beforeSeq))
    }

    // MARK: Capture sessions

    /// `GET /api/trace/sessions`: every capture this caller may see, expired ones expired on read.
    func evidenceListSessions() async throws -> [EvidenceTraceSession] {
        try await perform(EvidenceSessionsEnvelope.self, path: "/api/trace/sessions").sessions
    }

    /// `POST /api/trace/sessions`; answers the session as stored, with its resolved node set.
    func evidenceStartCapture(_ request: EvidenceCaptureRequest) async throws -> EvidenceTraceSession {
        try await perform(EvidenceTraceSession.self, path: "/api/trace/sessions", method: "POST", body: request)
    }

    /// `POST /api/trace/sessions/stop {id}`; stopping a session that already ended answers it unchanged.
    func evidenceStopCapture(id: String) async throws -> EvidenceTraceSession {
        try await perform(EvidenceTraceSession.self, path: "/api/trace/sessions/stop", method: "POST", body: IDBody(id: id))
    }

    // MARK: Connection records

    /// `GET /api/trace/connections`, one keyset page.
    func evidenceConnections(_ query: EvidenceConnectionQuery, since: Date?, until: Date?, limit: Int = EvidenceConnectionQuery.pageSize, cursor: String? = nil) async throws -> EvidenceConnectionsPage {
        try await perform(EvidenceConnectionsPage.self, path: "/api/trace/connections",
                          query: query.queryItems(since: since, until: until, limit: limit, cursor: cursor))
    }

    /// `GET /api/trace/hops`: the stitched path through the record the key names, with the record itself.
    func evidenceHops(_ key: EvidenceRecordKey) async throws -> EvidenceHopsResponse {
        try await perform(EvidenceHopsResponse.self, path: "/api/trace/hops", query: [
            URLQueryItem(name: "node_id", value: key.nodeID),
            URLQueryItem(name: "core_generation", value: String(key.coreGeneration)),
            URLQueryItem(name: "log_id", value: String(key.logID)),
            URLQueryItem(name: "started_at", value: key.startedAtText),
        ])
    }

    /// `GET /api/trace/markers`: restarts, applies and capture edges in a window (server default the last 6 hours).
    func evidenceMarkers(nodeIDs: [String] = [], since: Date? = nil, until: Date? = nil) async throws -> [EvidenceMarker] {
        var query: [URLQueryItem] = []
        if let since { query.append(URLQueryItem(name: "since", value: AstraDateParser.string(from: since))) }
        if let until { query.append(URLQueryItem(name: "until", value: AstraDateParser.string(from: until))) }
        if !nodeIDs.isEmpty { query.append(URLQueryItem(name: "node_id", value: nodeIDs.joined(separator: ","))) }
        return try await perform(EvidenceMarkersEnvelope.self, path: "/api/trace/markers", query: query).markers
    }

    // MARK: Collection state

    /// `GET /api/trace/policy`: one row per node this caller may read, with the collector's readiness.
    func evidencePolicies() async throws -> [EvidenceTracePolicy] {
        try await perform(EvidencePoliciesEnvelope.self, path: "/api/trace/policy").policies
    }

    /// `GET /api/trace/stats`.
    func evidenceTraceStats() async throws -> EvidenceTraceStats {
        try await perform(EvidenceTraceStats.self, path: "/api/trace/stats")
    }

    /// `GET /api/evidence/settings`: the local budgets.
    func evidenceSettings() async throws -> EvidenceSettingsView {
        try await perform(EvidenceSettingsView.self, path: "/api/evidence/settings")
    }
}
