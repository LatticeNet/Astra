import Foundation

// MARK: Raw log sources (server_logs.go)

public struct LogSource: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var nodeID: String
    public var path: String
    public var enabled: Bool
    public var createdAt: Date?
    public var updatedAt: Date?
    public var maxLineBytes: Int = 0
    public var maxBatchLines: Int = 0
    /// The server owns the sing-box and agent-debug sources (`logSourceView.Managed`).
    public var managed: Bool = false

    public init(id: String, name: String = "", nodeID: String = "", path: String = "", enabled: Bool = false, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.nodeID = nodeID
        self.path = path
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayName: String { name.isEmpty ? path : name }

    enum CodingKeys: String, CodingKey {
        case id, name, path, enabled, managed
        case nodeID = "node_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case maxLineBytes = "max_line_bytes"
        case maxBatchLines = "max_batch_lines"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        createdAt = try DateValue.decodeIfPresent(from: container, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: container, forKey: .updatedAt)
        maxLineBytes = try container.decodeIfPresent(Int.self, forKey: .maxLineBytes) ?? 0
        maxBatchLines = try container.decodeIfPresent(Int.self, forKey: .maxBatchLines) ?? 0
        managed = try container.decodeIfPresent(Bool.self, forKey: .managed) ?? false
    }
}

public struct LogLine: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var sourceID: String
    public var nodeID: String
    public var path: String
    public var seq: UInt64
    public var at: Date?
    public var line: String
    public var truncated: Bool
    /// The agent's byte offset after this line in the source file. The
    /// server's own producers leave it 0, so it never identifies a line.
    public var offset: UInt64 = 0
    /// The line's place in its chunk, oldest first. Every line of one ingest
    /// batch shares a `seq`, and the server always returns whole chunks, so
    /// this ordinal is stable for a given source and search.
    public var ordinal = 0

    public init(sourceID: String, nodeID: String = "", path: String = "", seq: UInt64 = 0, at: Date? = nil, line: String = "", truncated: Bool = false, ordinal: Int = 0) {
        self.sourceID = sourceID
        self.nodeID = nodeID
        self.path = path
        self.seq = seq
        self.at = at
        self.line = line
        self.truncated = truncated
        self.ordinal = ordinal
    }

    public var id: String { "\(sourceID).\(seq).\(ordinal)" }

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case nodeID = "node_id"
        case path, seq, at, line, truncated, offset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID) ?? ""
        nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        seq = try container.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
        offset = try container.decodeIfPresent(UInt64.self, forKey: .offset) ?? 0
        at = try DateValue.decodeIfPresent(from: container, forKey: .at)
        line = try container.decodeIfPresent(String.self, forKey: .line) ?? ""
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

/// A newest-first page of one source (`logstore.Query`).
public struct LogQueryResponse: Decodable, Sendable {
    public var lines: [LogLine]
    /// A stored chunk failed to decode and was skipped.
    public var truncated: Bool
    /// Pass back as `before_seq` for the next older page; nil when there is none.
    public var nextBeforeSeq: UInt64?

    public init(lines: [LogLine] = [], truncated: Bool = false, nextBeforeSeq: UInt64? = nil) {
        self.lines = Self.numbered(lines)
        self.truncated = truncated
        self.nextBeforeSeq = nextBeforeSeq
    }

    enum CodingKeys: String, CodingKey {
        case lines, truncated
        case nextBeforeSeq = "next_before_seq"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lines = Self.numbered(try container.decodeIfPresent([LogLine].self, forKey: .lines) ?? [])
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        nextBeforeSeq = try container.decodeIfPresent(UInt64.self, forKey: .nextBeforeSeq)
    }

    /// Numbers the lines of each chunk from its oldest. The page is newest
    /// first, so a chunk's lines arrive newest first too.
    static func numbered(_ lines: [LogLine]) -> [LogLine] {
        var counts: [UInt64: Int] = [:]
        var out = lines
        for index in out.indices.reversed() {
            let seq = out[index].seq
            out[index].ordinal = counts[seq, default: 0]
            counts[seq, default: 0] += 1
        }
        return out
    }
}

public struct LogSourceStats: Identifiable, Decodable, Equatable, Hashable, Sendable {
    public var sourceID: String
    public var nodeID: String
    public var name: String
    public var path: String
    public var enabled: Bool
    public var lines: UInt64
    public var bytes: UInt64
    public var firstAt: Date?
    public var lastAt: Date?
    public var lastIngestAt: Date?
    public var rotID: String = ""

    public var id: String { sourceID }

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case nodeID = "node_id"
        case name, path, enabled, lines, bytes
        case firstAt = "first_at"
        case lastAt = "last_at"
        case lastIngestAt = "last_ingest_at"
        case rotID = "rot_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID) ?? ""
        nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        lines = try container.decodeIfPresent(UInt64.self, forKey: .lines) ?? 0
        bytes = try container.decodeIfPresent(UInt64.self, forKey: .bytes) ?? 0
        firstAt = try DateValue.decodeIfPresent(from: container, forKey: .firstAt)
        lastAt = try DateValue.decodeIfPresent(from: container, forKey: .lastAt)
        lastIngestAt = try DateValue.decodeIfPresent(from: container, forKey: .lastIngestAt)
        rotID = try container.decodeIfPresent(String.self, forKey: .rotID) ?? ""
    }
}

// MARK: Capture sessions (server_trace.go, model.TraceSession)

public struct EvidenceTraceFilter: Codable, Equatable, Hashable, Sendable {
    public var userIDs: [String]
    public var lineUUIDs: [String]
    public var nodeIDs: [String]
    public var dstPatterns: [String]

    public init(userIDs: [String] = [], lineUUIDs: [String] = [], nodeIDs: [String] = [], dstPatterns: [String] = []) {
        self.userIDs = userIDs
        self.lineUUIDs = lineUUIDs
        self.nodeIDs = nodeIDs
        self.dstPatterns = dstPatterns
    }

    enum CodingKeys: String, CodingKey {
        case userIDs = "user_ids"
        case lineUUIDs = "line_uuids"
        case nodeIDs = "node_ids"
        case dstPatterns = "dst_patterns"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userIDs = try container.decodeIfPresent([String].self, forKey: .userIDs) ?? []
        lineUUIDs = try container.decodeIfPresent([String].self, forKey: .lineUUIDs) ?? []
        nodeIDs = try container.decodeIfPresent([String].self, forKey: .nodeIDs) ?? []
        dstPatterns = try container.decodeIfPresent([String].self, forKey: .dstPatterns) ?? []
    }

    /// Empty lists are left out, as Go's `omitempty` writes them.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !userIDs.isEmpty { try container.encode(userIDs, forKey: .userIDs) }
        if !lineUUIDs.isEmpty { try container.encode(lineUUIDs, forKey: .lineUUIDs) }
        if !nodeIDs.isEmpty { try container.encode(nodeIDs, forKey: .nodeIDs) }
        if !dstPatterns.isEmpty { try container.encode(dstPatterns, forKey: .dstPatterns) }
    }
}

public struct EvidenceTraceSession: Identifiable, Decodable, Equatable, Hashable, Sendable {
    public static let running = "running"
    public static let expired = "expired"
    public static let stopped = "stopped"

    public var id: String
    public var name: String
    public var filter: EvidenceTraceFilter
    public var level: String
    public var startedAt: Date?
    public var expiresAt: Date?
    public var endedAt: Date?
    public var state: String
    public var startedBy: String
    public var correlationID: String
    public var lines: UInt64
    public var records: UInt64
    public var dropped: UInt64

    public init(id: String, name: String = "", filter: EvidenceTraceFilter = EvidenceTraceFilter(), level: String = "debug", startedAt: Date? = nil,
                expiresAt: Date? = nil, endedAt: Date? = nil, state: String = EvidenceTraceSession.running, startedBy: String = "",
                correlationID: String = "", lines: UInt64 = 0, records: UInt64 = 0, dropped: UInt64 = 0) {
        self.id = id
        self.name = name
        self.filter = filter
        self.level = level
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.endedAt = endedAt
        self.state = state
        self.startedBy = startedBy
        self.correlationID = correlationID
        self.lines = lines
        self.records = records
        self.dropped = dropped
    }

    enum CodingKeys: String, CodingKey {
        case id, name, filter, level, state, lines, records, dropped
        case startedAt = "started_at"
        case expiresAt = "expires_at"
        case endedAt = "ended_at"
        case startedBy = "started_by"
        case correlationID = "correlation_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        filter = try container.decodeIfPresent(EvidenceTraceFilter.self, forKey: .filter) ?? EvidenceTraceFilter()
        level = try container.decodeIfPresent(String.self, forKey: .level) ?? ""
        startedAt = try DateValue.decodeIfPresent(from: container, forKey: .startedAt)
        expiresAt = try DateValue.decodeIfPresent(from: container, forKey: .expiresAt)
        endedAt = try DateValue.decodeIfPresent(from: container, forKey: .endedAt)
        state = try container.decode(String.self, forKey: .state)
        startedBy = try container.decodeIfPresent(String.self, forKey: .startedBy) ?? ""
        correlationID = try container.decodeIfPresent(String.self, forKey: .correlationID) ?? ""
        lines = try container.decodeIfPresent(UInt64.self, forKey: .lines) ?? 0
        records = try container.decodeIfPresent(UInt64.self, forKey: .records) ?? 0
        dropped = try container.decodeIfPresent(UInt64.self, forKey: .dropped) ?? 0
    }

    /// Running and not past its deadline, as the server's `ActiveTraceSessions(now)` counts.
    public func isActive(now: Date) -> Bool {
        guard state == Self.running else { return false }
        guard let expiresAt else { return true }
        return expiresAt > now
    }

    /// A running capture that includes the node; an empty node list is the whole fleet.
    public func covers(nodeID: String, now: Date) -> Bool {
        isActive(now: now) && (filter.nodeIDs.isEmpty || filter.nodeIDs.contains(nodeID))
    }
}

/// `POST /api/trace/sessions`.
public struct EvidenceCaptureRequest: Encodable, Equatable, Sendable {
    public var name: String
    public var filter: EvidenceTraceFilter
    public var level: String
    public var ttlSeconds: Int

    public init(name: String, filter: EvidenceTraceFilter, level: String, ttlSeconds: Int) {
        self.name = name
        self.filter = filter
        self.level = level
        self.ttlSeconds = ttlSeconds
    }

    enum CodingKeys: String, CodingKey {
        case name, filter, level
        case ttlSeconds = "ttl_seconds"
    }
}

// MARK: Connection records (model.ConnRecord, tracestore.RecordPage)

/// The identity of a record: node, core generation, log id and start time.
/// sing-box draws the log id at random, so only all four name one record.
public struct EvidenceRecordKey: Hashable, Sendable, Decodable {
    public var nodeID: String
    public var coreGeneration: UInt64
    public var logID: UInt32
    /// The start time exactly as the server wrote it; the hops lookup matches it to the nanosecond.
    public var startedAtText: String

    public init(nodeID: String, coreGeneration: UInt64, logID: UInt32, startedAtText: String) {
        self.nodeID = nodeID
        self.coreGeneration = coreGeneration
        self.logID = logID
        self.startedAtText = startedAtText
    }

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case coreGeneration = "core_generation"
        case logID = "log_id"
        case startedAt = "started_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        coreGeneration = try container.decodeIfPresent(UInt64.self, forKey: .coreGeneration) ?? 0
        logID = try container.decodeIfPresent(UInt32.self, forKey: .logID) ?? 0
        startedAtText = try container.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
    }

    /// `node:generation:log:started_at`, the console's `connRecordKey` and the app link id.
    public var string: String { "\(nodeID):\(coreGeneration):\(logID):\(startedAtText)" }

    /// Reads `string` back. The start time has colons of its own, so only the first three split.
    public static func parse(_ raw: String) -> EvidenceRecordKey? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, !parts[0].isEmpty, let generation = UInt64(parts[1]), let log = UInt32(parts[2]) else { return nil }
        return EvidenceRecordKey(nodeID: parts[0], coreGeneration: generation, logID: log, startedAtText: parts[3])
    }

    public var startedAt: Date? { AstraDateParser.date(from: startedAtText) }

    /// The same record, allowing the start time to be spelled differently
    /// ("Z" against "+00:00") as long as it is the same instant.
    public func names(_ other: EvidenceRecordKey) -> Bool {
        guard nodeID == other.nodeID, coreGeneration == other.coreGeneration, logID == other.logID else { return false }
        if startedAtText == other.startedAtText { return true }
        guard let mine = startedAt, let theirs = other.startedAt else { return false }
        return abs(mine.timeIntervalSince(theirs)) < 0.001
    }
}

public struct EvidenceConnRecord: Identifiable, Decodable, Equatable, Hashable, Sendable {
    public var nodeID: String
    public var lineUUID: String
    public var lineHashID: String
    public var inboundTag: String
    public var inboundType: String
    public var userName: String
    public var userID: String
    public var userKind: String
    public var logID: UInt32
    public var network: String
    public var srcIP: String
    public var srcPort: Int
    public var dstHost: String
    public var dstIP: String
    public var dstPort: Int
    public var sniffedProtocol: String
    public var sniffedDomain: String
    public var ruleIndex: Int
    public var ruleText: String
    public var outboundTag: String
    public var outboundType: String
    public var chainEdgeUUID: String
    public var startedAtText: String
    public var startedAt: Date?
    public var endedAt: Date?
    public var durationMS: Int64?
    public var open: Bool
    public var upload: Int64
    public var download: Int64
    public var bytesKnown: Bool
    public var closeReason: String
    public var closeError: String
    public var stalledAt: Date?
    public var coreGeneration: UInt64
    public var sessionIDs: [String]
    public var hopPathID: String

    public var key: EvidenceRecordKey {
        EvidenceRecordKey(nodeID: nodeID, coreGeneration: coreGeneration, logID: logID, startedAtText: startedAtText)
    }

    public var id: String { key.string }

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id", lineUUID = "line_uuid", lineHashID = "line_hash_id", inboundTag = "inbound_tag", inboundType = "inbound_type"
        case userName = "user_name", userID = "user_id", userKind = "user_kind", logID = "log_id", network
        case srcIP = "src_ip", srcPort = "src_port", dstHost = "dst_host", dstIP = "dst_ip", dstPort = "dst_port"
        case sniffedProtocol = "sniffed_protocol", sniffedDomain = "sniffed_domain", ruleIndex = "rule_index", ruleText = "rule_text"
        case outboundTag = "outbound_tag", outboundType = "outbound_type", chainEdgeUUID = "chain_edge_uuid"
        case startedAt = "started_at", endedAt = "ended_at", durationMS = "duration_ms", open, upload, download
        case bytesKnown = "bytes_known", closeReason = "close_reason", closeError = "close_error", stalledAt = "stalled_at"
        case coreGeneration = "core_generation", sessionIDs = "session_ids", hopPathID = "hop_path_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) throws -> String { try c.decodeIfPresent(String.self, forKey: key) ?? "" }
        nodeID = try c.decode(String.self, forKey: .nodeID)
        lineUUID = try text(.lineUUID)
        lineHashID = try text(.lineHashID)
        inboundTag = try text(.inboundTag)
        inboundType = try text(.inboundType)
        userName = try text(.userName)
        userID = try text(.userID)
        userKind = try text(.userKind)
        logID = try c.decodeIfPresent(UInt32.self, forKey: .logID) ?? 0
        network = try text(.network)
        srcIP = try text(.srcIP)
        srcPort = try c.decodeIfPresent(Int.self, forKey: .srcPort) ?? 0
        dstHost = try text(.dstHost)
        dstIP = try text(.dstIP)
        dstPort = try c.decodeIfPresent(Int.self, forKey: .dstPort) ?? 0
        sniffedProtocol = try text(.sniffedProtocol)
        sniffedDomain = try text(.sniffedDomain)
        ruleIndex = try c.decodeIfPresent(Int.self, forKey: .ruleIndex) ?? 0
        ruleText = try text(.ruleText)
        outboundTag = try text(.outboundTag)
        outboundType = try text(.outboundType)
        chainEdgeUUID = try text(.chainEdgeUUID)
        startedAtText = try text(.startedAt)
        startedAt = AstraDateParser.date(from: startedAtText)
        endedAt = try DateValue.decodeIfPresent(from: c, forKey: .endedAt)
        durationMS = try c.decodeIfPresent(Int64.self, forKey: .durationMS)
        open = try c.decodeIfPresent(Bool.self, forKey: .open) ?? false
        upload = try c.decodeIfPresent(Int64.self, forKey: .upload) ?? 0
        download = try c.decodeIfPresent(Int64.self, forKey: .download) ?? 0
        bytesKnown = try c.decodeIfPresent(Bool.self, forKey: .bytesKnown) ?? false
        closeReason = try text(.closeReason)
        closeError = try text(.closeError)
        stalledAt = try DateValue.decodeIfPresent(from: c, forKey: .stalledAt)
        coreGeneration = try c.decodeIfPresent(UInt64.self, forKey: .coreGeneration) ?? 0
        sessionIDs = try c.decodeIfPresent([String].self, forKey: .sessionIDs) ?? []
        hopPathID = try text(.hopPathID)
    }

    /// Where it went as logged, then the port: "api.example.org:443".
    public var destination: String {
        let host = dstHost.isEmpty ? dstIP : dstHost
        guard !host.isEmpty else { return "" }
        return dstPort > 0 ? "\(host):\(dstPort)" : host
    }

    /// Where it came from: "198.51.100.23:51034".
    public var source: String {
        guard !srcIP.isEmpty else { return "" }
        let host = srcIP.contains(":") ? "[\(srcIP)]" : srcIP
        return srcPort > 0 ? "\(host):\(srcPort)" : srcIP
    }

    /// The user as logged; empty when nothing was.
    public var userLabel: String { userName }
}

public struct EvidenceConnectionsPage: Decodable, Sendable {
    public var records: [EvidenceConnRecord]
    public var nextCursor: String?
    /// Records held for every node this caller may see, before the filter.
    public var collectedTotal: Int64
    public var collectedNewestAt: Date?

    public init(records: [EvidenceConnRecord] = [], nextCursor: String? = nil, collectedTotal: Int64 = 0, collectedNewestAt: Date? = nil) {
        self.records = records
        self.nextCursor = nextCursor
        self.collectedTotal = collectedTotal
        self.collectedNewestAt = collectedNewestAt
    }

    enum CodingKeys: String, CodingKey {
        case records
        case nextCursor = "next_cursor"
        case collectedTotal = "collected_total"
        case collectedNewestAt = "collected_newest_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records = try c.decodeIfPresent([EvidenceConnRecord].self, forKey: .records) ?? []
        let cursor = try c.decodeIfPresent(String.self, forKey: .nextCursor) ?? ""
        nextCursor = cursor.isEmpty ? nil : cursor
        collectedTotal = try c.decodeIfPresent(Int64.self, forKey: .collectedTotal) ?? 0
        collectedNewestAt = try DateValue.decodeIfPresent(from: c, forKey: .collectedNewestAt)
    }
}

// MARK: Hops and markers (server_trace_timeline.go)

public struct EvidenceHopPath: Decodable, Equatable, Hashable, Sendable {
    public var id: String
    public var confidence: String
    public var recordKeys: [EvidenceRecordKey]
    public var candidates: [EvidenceRecordKey]

    enum CodingKeys: String, CodingKey {
        case id, confidence, candidates
        case recordKeys = "record_keys"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        confidence = try c.decodeIfPresent(String.self, forKey: .confidence) ?? ""
        recordKeys = try c.decodeIfPresent([EvidenceRecordKey].self, forKey: .recordKeys) ?? []
        candidates = try c.decodeIfPresent([EvidenceRecordKey].self, forKey: .candidates) ?? []
    }
}

public struct EvidenceHopsResponse: Decodable, Sendable {
    public var path: EvidenceHopPath
    /// The path's records in order, the anchor among them.
    public var records: [EvidenceConnRecord]
    public var candidates: [EvidenceConnRecord]
    /// False when the stitcher stopped at its page cap; the server then calls the path ambiguous.
    public var candidatesComplete: Bool

    enum CodingKeys: String, CodingKey {
        case path, records, candidates
        case candidatesComplete = "candidates_complete"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(EvidenceHopPath.self, forKey: .path)
        records = try c.decodeIfPresent([EvidenceConnRecord].self, forKey: .records) ?? []
        candidates = try c.decodeIfPresent([EvidenceConnRecord].self, forKey: .candidates) ?? []
        candidatesComplete = try c.decodeIfPresent(Bool.self, forKey: .candidatesComplete) ?? false
    }

    /// The record the key names, when the server returned it.
    public func record(for key: EvidenceRecordKey) -> EvidenceConnRecord? {
        records.first { $0.key.names(key) } ?? candidates.first { $0.key.names(key) }
    }
}

public struct EvidenceMarker: Identifiable, Decodable, Equatable, Hashable, Sendable {
    public static let coreRestart = "core_restart"
    public static let configApply = "config_apply"
    public static let subFetch = "sub_fetch"
    public static let session = "session"

    public var kind: String
    public var at: Date?
    public var atText: String
    public var nodeID: String
    public var userID: String
    public var title: String
    public var detail: String
    public var count: Int
    public var correlationID: String

    public var id: String { [kind, atText, nodeID, title, detail].joined(separator: "|") }

    enum CodingKeys: String, CodingKey {
        case kind, at, title, detail, count
        case nodeID = "node_id"
        case userID = "user_id"
        case correlationID = "correlation_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        atText = try c.decodeIfPresent(String.self, forKey: .at) ?? ""
        at = AstraDateParser.date(from: atText)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        correlationID = try c.decodeIfPresent(String.self, forKey: .correlationID) ?? ""
    }
}

// MARK: Trace policy and collector readiness (tracePolicyView, traceCollectorView)

public struct EvidenceCollectorView: Decodable, Equatable, Hashable, Sendable {
    public var state: String
    public var since: Date?
    public var level: String
    public var clashAPIAddr: String
    public var addrSource: String
    public var detail: String
    public var rawLines: Bool
    public var linesPerSec: Double
    public var budgetLinesPerSec: Int
    public var shedConnections: UInt64
    public var unparsed: UInt64
    public var countersSince: Date?
    /// "agent", or "server" when the server inferred the state from the agent version.
    public var reportedBy: String
    public var collectedAt: Date?
    public var receivedAt: Date?
    public var stale: Bool
    public var pending: Bool

    public init(state: String, level: String = "", detail: String = "", reportedBy: String = "agent", receivedAt: Date? = nil, stale: Bool = false, pending: Bool = false) {
        self.state = state
        self.level = level
        self.detail = detail
        self.reportedBy = reportedBy
        self.receivedAt = receivedAt
        self.stale = stale
        self.pending = pending
        since = nil
        clashAPIAddr = ""
        addrSource = ""
        rawLines = false
        linesPerSec = 0
        budgetLinesPerSec = 0
        shedConnections = 0
        unparsed = 0
        countersSince = nil
        collectedAt = nil
    }

    enum CodingKeys: String, CodingKey {
        case state, since, level, detail, unparsed, stale, pending
        case clashAPIAddr = "clash_api_addr", addrSource = "addr_source", rawLines = "raw_lines", linesPerSec = "lines_per_sec"
        case budgetLinesPerSec = "budget_lines_per_sec", shedConnections = "shed_connections", countersSince = "counters_since"
        case reportedBy = "reported_by", collectedAt = "collected_at", receivedAt = "received_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        since = try DateValue.decodeIfPresent(from: c, forKey: .since)
        level = try c.decodeIfPresent(String.self, forKey: .level) ?? ""
        clashAPIAddr = try c.decodeIfPresent(String.self, forKey: .clashAPIAddr) ?? ""
        addrSource = try c.decodeIfPresent(String.self, forKey: .addrSource) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        rawLines = try c.decodeIfPresent(Bool.self, forKey: .rawLines) ?? false
        linesPerSec = try c.decodeIfPresent(Double.self, forKey: .linesPerSec) ?? 0
        budgetLinesPerSec = try c.decodeIfPresent(Int.self, forKey: .budgetLinesPerSec) ?? 0
        shedConnections = try c.decodeIfPresent(UInt64.self, forKey: .shedConnections) ?? 0
        unparsed = try c.decodeIfPresent(UInt64.self, forKey: .unparsed) ?? 0
        countersSince = try DateValue.decodeIfPresent(from: c, forKey: .countersSince)
        reportedBy = try c.decodeIfPresent(String.self, forKey: .reportedBy) ?? ""
        collectedAt = try DateValue.decodeIfPresent(from: c, forKey: .collectedAt)
        receivedAt = try DateValue.decodeIfPresent(from: c, forKey: .receivedAt)
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
        pending = try c.decodeIfPresent(Bool.self, forKey: .pending) ?? false
    }
}

public struct EvidenceTracePolicy: Identifiable, Decodable, Equatable, Hashable, Sendable {
    public var nodeID: String
    public var enabled: Bool
    public var level: String
    public var budgetLinesPerSec: Int
    public var clashAPIAddr: String
    /// The stored raw-lines switch; nil on a policy written before the switch existed.
    public var rawEnabled: Bool?
    public var updatedAt: Date?
    public var lastCoreGeneration: UInt64
    /// Raw lines take effect; nil from a server that predates readiness.
    public var rawEffective: Bool?
    public var collector: EvidenceCollectorView?

    public var id: String { nodeID }

    public init(nodeID: String, enabled: Bool, level: String = "debug", rawEffective: Bool? = nil, collector: EvidenceCollectorView? = nil) {
        self.nodeID = nodeID
        self.enabled = enabled
        self.level = level
        self.rawEffective = rawEffective
        self.collector = collector
        budgetLinesPerSec = 0
        clashAPIAddr = ""
        rawEnabled = nil
        updatedAt = nil
        lastCoreGeneration = 0
    }

    private struct RawSwitch: Decodable { var enabled: Bool? }

    enum CodingKeys: String, CodingKey {
        case enabled, level, raw, collector
        case nodeID = "node_id", budgetLinesPerSec = "budget_lines_per_sec", clashAPIAddr = "clash_api_addr"
        case updatedAt = "updated_at", lastCoreGeneration = "last_core_generation", rawEffective = "raw_effective"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decode(String.self, forKey: .nodeID)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        level = try c.decodeIfPresent(String.self, forKey: .level) ?? ""
        budgetLinesPerSec = try c.decodeIfPresent(Int.self, forKey: .budgetLinesPerSec) ?? 0
        clashAPIAddr = try c.decodeIfPresent(String.self, forKey: .clashAPIAddr) ?? ""
        rawEnabled = try c.decodeIfPresent(RawSwitch.self, forKey: .raw)?.enabled
        updatedAt = try DateValue.decodeIfPresent(from: c, forKey: .updatedAt)
        lastCoreGeneration = try c.decodeIfPresent(UInt64.self, forKey: .lastCoreGeneration) ?? 0
        rawEffective = try c.decodeIfPresent(Bool.self, forKey: .rawEffective)
        collector = try c.decodeIfPresent(EvidenceCollectorView.self, forKey: .collector)
    }
}

// MARK: Budgets (evidence_settings.go) and the store (tracestore.Stats)

public struct EvidenceSettings: Decodable, Equatable, Sendable {
    public var traceDBMaxBytes: Int64
    public var recordTTLSeconds: Int64
    public var lineTTLSeconds: Int64
    public var rollup5mTTLSeconds: Int64
    public var rawSourceMaxBytes: Int64
    public var version: Int64
    public var updatedAt: Date?
    public var updatedBy: String

    enum CodingKeys: String, CodingKey {
        case version
        case traceDBMaxBytes = "trace_db_max_bytes", recordTTLSeconds = "record_ttl_seconds", lineTTLSeconds = "line_ttl_seconds"
        case rollup5mTTLSeconds = "rollup_5m_ttl_seconds", rawSourceMaxBytes = "raw_source_max_bytes"
        case updatedAt = "updated_at", updatedBy = "updated_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        traceDBMaxBytes = try c.decodeIfPresent(Int64.self, forKey: .traceDBMaxBytes) ?? 0
        recordTTLSeconds = try c.decodeIfPresent(Int64.self, forKey: .recordTTLSeconds) ?? 0
        lineTTLSeconds = try c.decodeIfPresent(Int64.self, forKey: .lineTTLSeconds) ?? 0
        rollup5mTTLSeconds = try c.decodeIfPresent(Int64.self, forKey: .rollup5mTTLSeconds) ?? 0
        rawSourceMaxBytes = try c.decodeIfPresent(Int64.self, forKey: .rawSourceMaxBytes) ?? 0
        version = try c.decodeIfPresent(Int64.self, forKey: .version) ?? 0
        updatedAt = try DateValue.decodeIfPresent(from: c, forKey: .updatedAt)
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy) ?? ""
    }
}

public struct EvidenceSettingsView: Decodable, Equatable, Sendable {
    public var settings: EvidenceSettings
    /// False when the server runs on its built-in limits.
    public var stored: Bool
    public var invalidStored: Bool
    public var envIgnored: [String]
    /// Each field's [minimum, maximum].
    public var bounds: [String: [Int64]]

    enum CodingKeys: String, CodingKey {
        case settings, stored, bounds
        case invalidStored = "invalid_stored", envIgnored = "env_ignored"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = try c.decode(EvidenceSettings.self, forKey: .settings)
        stored = try c.decodeIfPresent(Bool.self, forKey: .stored) ?? false
        invalidStored = try c.decodeIfPresent(Bool.self, forKey: .invalidStored) ?? false
        envIgnored = try c.decodeIfPresent([String].self, forKey: .envIgnored) ?? []
        bounds = try c.decodeIfPresent([String: [Int64]].self, forKey: .bounds) ?? [:]
    }
}

/// `GET /api/trace/stats`: the whole store for an operator who sees every
/// node, `{scoped, schema_version, cipher_enabled}` for anyone narrower.
public struct EvidenceTraceStats: Decodable, Equatable, Sendable {
    public var scoped: Bool
    public var schemaVersion: Int
    public var cipherEnabled: Bool
    public var records: Int64?
    public var openRecords: Int64?
    public var lines: Int64?
    public var oldestRecordAt: Date?
    public var newestRecordAt: Date?
    public var sizeBytes: Int64?
    public var maxBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case scoped, records, lines
        case schemaVersion = "schema_version", cipherEnabled = "cipher_enabled", openRecords = "open_records"
        case oldestRecordAt = "oldest_record_at", newestRecordAt = "newest_record_at", sizeBytes = "size_bytes", maxBytes = "max_bytes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scoped = try c.decodeIfPresent(Bool.self, forKey: .scoped) ?? false
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        cipherEnabled = try c.decodeIfPresent(Bool.self, forKey: .cipherEnabled) ?? false
        records = try c.decodeIfPresent(Int64.self, forKey: .records)
        openRecords = try c.decodeIfPresent(Int64.self, forKey: .openRecords)
        lines = try c.decodeIfPresent(Int64.self, forKey: .lines)
        oldestRecordAt = try DateValue.decodeIfPresent(from: c, forKey: .oldestRecordAt)
        newestRecordAt = try DateValue.decodeIfPresent(from: c, forKey: .newestRecordAt)
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        maxBytes = try c.decodeIfPresent(Int64.self, forKey: .maxBytes)
    }
}
