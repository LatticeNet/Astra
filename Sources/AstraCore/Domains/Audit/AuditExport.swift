import Foundation

/// CSV, NDJSON and audit-head export of audit events, built on device the
/// way the console builds them (`AuditView.vue`: `csvCell`, `exportCsv`,
/// `exportNdjson`, `offBoxAnchorRecord`). NDJSON lines are each event's raw
/// JSON slice as the server sent it; CSV cells come from the same slice, so
/// `at` keeps the server's precision and `metadata` its bytes.
public enum AuditExport {
    public static let csvHeaders = ["at", "decision", "action", "scope", "actor_id", "token_id", "node_id", "correlation_id", "reason", "metadata"]

    /// The most pages an export reads before it stops and says so.
    public static let maxPages = 50

    // MARK: CSV

    /// `csvCell`: quoted when the text holds a quote, comma or newline.
    public static func csvCell(_ text: String) -> String {
        guard text.contains(where: { $0 == "\"" || $0 == "," || $0 == "\n" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Header then one row per event, joined with newlines, no trailing newline.
    public static func csv(_ events: [AuditEvent], partial: AuditExportScan? = nil) -> String {
        var lines: [String] = []
        if let partial { lines.append(partial.label) }
        lines.append(csvHeaders.joined(separator: ","))
        for event in events {
            lines.append(csvHeaders.map { csvCell(cellText(event, key: $0)) }.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// The text a cell holds: the string value as JSON parsing would read
    /// it, an object (metadata) as its compact JSON, and "" for null or absent.
    static func cellText(_ event: AuditEvent, key: String) -> String {
        guard !event.rawJSON.isEmpty, let raw = AuditRawJSON.value(of: key, in: event.rawJSON) else {
            return event.rawJSON.isEmpty ? fallbackText(event, key: key) : ""
        }
        switch raw.first {
        case "\"":
            return (try? JSONDecoder().decode(String.self, from: Data(raw.utf8))) ?? ""
        case "n":
            return ""
        default:
            return raw
        }
    }

    /// For an event built without its raw slice: the model's fields, metadata
    /// in Go's key order (sorted).
    static func fallbackText(_ event: AuditEvent, key: String) -> String {
        switch key {
        case "at": event.at.map { AstraDateParser.string(from: $0) } ?? ""
        case "decision": event.decision
        case "action": event.action
        case "scope": event.scope
        case "actor_id": event.actorID
        case "token_id": event.tokenID
        case "node_id": event.nodeID
        case "correlation_id": event.correlationID
        case "reason": event.reason
        case "metadata": event.metadata.isEmpty ? "" : compactJSON(event.metadata)
        default: ""
        }
    }

    // MARK: NDJSON

    /// One event per line, the server's bytes; no trailing newline. A partial
    /// export opens with a JSON line that says so, so every line still parses.
    public static func ndjson(_ events: [AuditEvent], partial: AuditExportScan? = nil) -> String {
        var lines: [String] = []
        if let partial { lines.append(compactJSON(["partial": partial.label])) }
        for event in events {
            lines.append(event.rawJSON.isEmpty ? fallbackJSON(event) : event.rawJSON)
        }
        return lines.joined(separator: "\n")
    }

    static func fallbackJSON(_ event: AuditEvent) -> String {
        var object: [String: Any] = [
            "id": event.id, "at": event.at.map { AstraDateParser.string(from: $0) } ?? "",
            "actor_id": event.actorID, "token_id": event.tokenID, "node_id": event.nodeID,
            "action": event.action, "scope": event.scope, "decision": event.decision,
            "reason": event.reason, "correlation_id": event.correlationID,
        ]
        if !event.metadata.isEmpty { object["metadata"] = event.metadata }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func compactJSON(_ object: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Audit head

    /// The off-box anchor record (`lattice.audit_head.v1`), two-space JSON
    /// plus a newline, or nil when there is no verified, anchored head.
    public static func headRecord(_ status: AuditChainStatus, verifiedAt: Date) -> String? {
        guard status.enabled, status.ok, status.anchored, !status.head.isEmpty else { return nil }
        func string(_ value: String) -> String {
            let data = (try? JSONEncoder.auditExport().encode(value)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        let pending: String = status.anchorPending.map {
            "{\n    \"count\": \($0.count),\n    \"head\": \(string($0.head))\n  }"
        } ?? "null"
        let lines = [
            "  \"type\": \"lattice.audit_head.v1\"",
            "  \"verified_at\": \(string(isoMilliseconds(verifiedAt)))",
            "  \"ok\": \(status.ok)",
            "  \"count\": \(status.count)",
            "  \"head\": \(string(status.head))",
            "  \"anchored\": \(status.anchored)",
            "  \"anchor_count\": \(status.anchorCount.map(String.init) ?? "null")",
            "  \"anchor_head\": \(status.anchorHead.map(string) ?? "null")",
            "  \"anchor_pending\": \(pending)",
        ]
        return "{\n" + lines.joined(separator: ",\n") + "\n}\n"
    }

    /// `Date.prototype.toISOString`: UTC with milliseconds.
    public static func isoMilliseconds(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
    }

    // MARK: Collecting

    /// Reads every page of `query` to the end of its range, at the server's
    /// largest page. `progress` is told how many events are in hand.
    public static func collect(
        _ query: AuditQuery,
        client: LatticeClient,
        maxPages: Int = maxPages,
        progress: @Sendable (Int) async -> Void = { _ in }
    ) async throws -> AuditExportResult {
        var events: [AuditEvent] = []
        var page = query
        page.limit = AuditModel.maxPageSize
        page.offset = 0
        var serverPartial = false
        var scanned = 0
        for _ in 0..<maxPages {
            let answer = try await client.auditPage(page)
            events += answer.events
            serverPartial = serverPartial || answer.isPartial
            scanned = max(scanned, answer.scanned ?? 0)
            page.offset += answer.events.count
            await progress(events.count)
            if answer.events.isEmpty || page.offset >= answer.total {
                return AuditExportResult(events: events, partial: serverPartial ? AuditExportScan(scanned: max(scanned, events.count)) : nil)
            }
        }
        return AuditExportResult(events: events, partial: AuditExportScan(scanned: max(scanned, events.count)))
    }

    /// "lattice-audit.csv", or "lattice-audit-partial.csv" for a partial scan.
    public static func fileName(_ format: AuditExportFormat, partial: Bool) -> String {
        let stem = partial ? "lattice-audit-partial" : "lattice-audit"
        switch format {
        case .csv: return "\(stem).csv"
        case .ndjson: return "\(stem).ndjson"
        case .head: return "lattice-audit-head.json"
        }
    }

    /// The share sheet's title: what the file holds, and when partial, that it is.
    public static func shareTitle(_ format: AuditExportFormat, count: Int, partial: AuditExportScan?) -> String {
        if let partial { return partial.label }
        switch format {
        case .csv: return count == 1 ? "1 audit event, CSV" : "\(count) audit events, CSV"
        case .ndjson: return count == 1 ? "1 audit event, NDJSON" : "\(count) audit events, NDJSON"
        case .head: return "Audit head"
        }
    }
}

public enum AuditExportFormat: String, Sendable, Hashable, CaseIterable {
    case csv, ndjson, head
}

/// A scan the server or the export stopped before the end of the range.
public struct AuditExportScan: Sendable, Hashable {
    public var scanned: Int

    public init(scanned: Int) {
        self.scanned = scanned
    }

    /// "Partial: scanned 10000 events"
    public var label: String { "Partial: scanned \(scanned) events" }
}

public struct AuditExportResult: Sendable {
    public var events: [AuditEvent]
    public var partial: AuditExportScan?
}

extension JSONEncoder {
    /// Strings as JavaScript's JSON.stringify writes them: no escaped slashes.
    static func auditExport() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }
}

/// Reads one top-level value of a JSON object as its exact text.
enum AuditRawJSON {
    static func value(of key: String, in json: String) -> String? {
        let bytes = Array(json.utf8)
        var index = 0
        func skipSpace() { while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 } }
        func skipString() -> Bool {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return false }
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == UInt8(ascii: "\\") { index += 1 } else if byte == UInt8(ascii: "\"") { return true }
            }
            return false
        }
        func skipValue() -> Bool {
            skipSpace()
            guard index < bytes.count else { return false }
            switch bytes[index] {
            case UInt8(ascii: "\""):
                return skipString()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while index < bytes.count {
                    switch bytes[index] {
                    case UInt8(ascii: "\""):
                        guard skipString() else { return false }
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["):
                        depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                        if depth == 0 { index += 1; return true }
                    default:
                        break
                    }
                    index += 1
                }
                return false
            default:
                while index < bytes.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
                return true
            }
        }
        skipSpace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { return nil }
        index += 1
        while true {
            skipSpace()
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: "}") { return nil }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            let nameStart = index
            guard skipString() else { return nil }
            let name = try? JSONDecoder().decode(String.self, from: Data(bytes[nameStart..<index]))
            skipSpace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            index += 1
            skipSpace()
            let valueStart = index
            guard skipValue() else { return nil }
            if name == key { return String(decoding: bytes[valueStart..<index], as: UTF8.self) }
        }
    }
}
