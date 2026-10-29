import Foundation

/// `GET /api/audit/verify` (`handleAuditVerify`). A broken chain answers 200
/// with `ok: false` and the first inconsistency in `error`, so it can be
/// shown rather than surfacing as a request failure.
public struct AuditChainStatus: Decodable, Sendable, Hashable {
    public var enabled: Bool
    public var ok: Bool
    public var count: Int
    public var error: String?
    /// The verified head hash of the WAL.
    public var head: String = ""
    /// Whether a sidecar anchor guards the end of the log against truncation.
    public var anchored: Bool = false
    public var anchorCount: Int?
    public var anchorHead: String?
    public var anchorPending: AuditAnchorCheckpoint?

    public init(enabled: Bool = false, ok: Bool = false, count: Int = 0, error: String? = nil) {
        self.enabled = enabled
        self.ok = ok
        self.count = count
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case enabled, ok, count, error, head, anchored
        case anchorCount = "anchor_count"
        case anchorHead = "anchor_head"
        case anchorPending = "anchor_pending"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 0
        error = try container.decodeIfPresent(String.self, forKey: .error)
        head = try container.decodeIfPresent(String.self, forKey: .head) ?? ""
        anchored = try container.decodeIfPresent(Bool.self, forKey: .anchored) ?? false
        anchorCount = try container.decodeIfPresent(Int.self, forKey: .anchorCount)
        anchorHead = try container.decodeIfPresent(String.self, forKey: .anchorHead)
        anchorPending = try container.decodeIfPresent(AuditAnchorCheckpoint.self, forKey: .anchorPending)
    }
}

/// A recorded WAL head (`audit.AnchorCheckpoint`).
public struct AuditAnchorCheckpoint: Codable, Sendable, Hashable {
    public var count: Int
    public var head: String

    public init(count: Int, head: String) {
        self.count = count
        self.head = head
    }
}

/// One page of `GET /api/audit` with what the server says about its scan.
public struct AuditPage: Sendable {
    public var events: [AuditEvent]
    public var total: Int
    public var limit: Int
    public var offset: Int
    /// Records the server examined for `total`.
    public var scanned: Int?
    /// False when the server's scan cap stopped the walk: `total` then counts
    /// only the newest `scanned` events. Nil from a server that does not say.
    public var complete: Bool?

    public init(events: [AuditEvent], total: Int, limit: Int, offset: Int, scanned: Int? = nil, complete: Bool? = nil) {
        self.events = events
        self.total = total
        self.limit = limit
        self.offset = offset
        self.scanned = scanned
        self.complete = complete
    }

    /// True when the scan stopped early.
    public var isPartial: Bool { complete == false }

    private struct Meta: Decodable {
        var scanned: Int?
        var complete: Bool?
    }

    /// Decodes events (each keeping its raw JSON slice) and the scan facts.
    public static func decode(_ data: Data, query: AuditQuery) throws -> AuditPage {
        let decoder = JSONDecoder()
        var response: AuditQueryResponse
        var meta = Meta()
        if let events = try? decoder.decode([AuditEvent].self, from: data) {
            response = AuditQueryResponse(events: events, total: events.count, limit: query.limit, offset: query.offset)
        } else {
            guard let decoded = try? decoder.decode(AuditQueryResponse.self, from: data) else { throw LatticeAPIError.invalidResponse }
            response = decoded
            meta = (try? decoder.decode(Meta.self, from: data)) ?? Meta()
        }
        if let slices = JSONArraySlicer.elements(of: data, key: "events"), slices.count == response.events.count {
            for index in response.events.indices {
                response.events[index].rawJSON = String(decoding: slices[index], as: UTF8.self)
            }
        }
        return AuditPage(events: response.events, total: response.total, limit: response.limit, offset: response.offset, scanned: meta.scanned, complete: meta.complete)
    }
}

public extension LatticeClient {
    func verifyAuditChain() async throws -> AuditChainStatus {
        try await perform(AuditChainStatus.self, path: "/api/audit/verify")
    }

    /// `GET /api/audit` keeping `scanned` and `complete`, which the Shared
    /// `fetchAudit(query:)` drops.
    /// yagni: folds into Shared `fetchAudit(query:)` at the next integration window.
    func auditPage(_ query: AuditQuery) async throws -> AuditPage {
        let data = try await performData(path: "/api/audit", query: query.queryItems)
        return try AuditPage.decode(data, query: query)
    }

    /// One event by id. `/api/audit` has no id filter, so this pages the
    /// list at `limit=100` for up to `maxPages` pages (section 2.5).
    func auditFind(id: String, maxPages: Int = 10) async throws -> AuditEvent? {
        var offset = 0
        for _ in 0..<maxPages {
            let page = try await auditPage(AuditQuery(limit: AuditModel.lookupPageSize, offset: offset))
            if let event = page.events.first(where: { $0.id == id }) { return event }
            offset += page.events.count
            if page.events.isEmpty || offset >= page.total { return nil }
        }
        return nil
    }

    /// Every event sharing a correlation id, oldest first, up to `maxPages` pages.
    func auditTrace(correlationID: String, maxPages: Int = 5) async throws -> (events: [AuditEvent], truncated: Bool, scanStopped: Bool) {
        var events: [AuditEvent] = []
        var offset = 0
        // The server stops at auditScanCap records and says complete=false:
        // events older than that are not missing, they were never read.
        var scanStopped = false
        for _ in 0..<maxPages {
            let page = try await auditPage(AuditQuery(correlationID: correlationID, limit: AuditModel.maxPageSize, offset: offset))
            events += page.events
            offset += page.events.count
            scanStopped = scanStopped || page.isPartial
            if page.events.isEmpty || offset >= page.total { return (AuditModel.orderTimeline(events), false, scanStopped) }
        }
        return (AuditModel.orderTimeline(events), true, scanStopped)
    }
}
