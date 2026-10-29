import Foundation

/// How a state is colored; the app maps it to its status tones.
public enum EvidenceSeverity: Sendable, Hashable {
    case ok, warn, fail, quiet
}

// MARK: Collector readiness (evidenceModel.ts collectorReadiness, design 26 R1)

public indirect enum EvidenceReadiness: Hashable, Sendable {
    /// Nothing asks this node to collect, and its collector says so.
    case off
    /// The Clash API log stream is open and `/connections` answers.
    case ready(level: String)
    /// The collector cannot record. `known` is false for a state this app does
    /// not know; `inferred` when the server worked it out from the agent version.
    case notReady(state: String, known: Bool, detail: String?, inferred: Bool)
    /// The policy or a capture changed after the agent's last report.
    case pending
    /// Collection is wanted and the agent has not reported yet.
    case waiting
    /// The agent has gone quiet; `last` is what it said before that.
    case stale(last: EvidenceReadiness, heardAt: Date?)

    /// The collector states the server knows (lattice-sdk `model.CollectorState`).
    public static let knownStates = ["off", "ready", "no_clash_api", "secret_unreadable", "stream_failing", "agent_too_old"]

    /// The server reports readiness at all: it sends `raw_effective` or a collector on every policy.
    public static func serverReports(_ policy: EvidenceTracePolicy?) -> Bool {
        guard let policy else { return false }
        return policy.rawEffective != nil || !(policy.collector?.state ?? "").isEmpty
    }

    /// One node's readiness from its policy and the running captures that
    /// cover it; nil when the server predates readiness. Never `ready` unless
    /// the agent said ready.
    public static func of(policy: EvidenceTracePolicy?, capturing: Int) -> EvidenceReadiness? {
        guard let policy, serverReports(policy) else { return nil }
        let wants = policy.enabled || capturing > 0
        guard let report = policy.collector, !report.state.isEmpty else { return wants ? .waiting : .off }
        let base: EvidenceReadiness
        switch report.state {
        case "ready":
            base = .ready(level: report.level.isEmpty ? policy.level : report.level)
        case "off":
            // An agent that saw the change and still says off has not applied it.
            base = wants ? .notReady(state: "off", known: true, detail: nil, inferred: false) : .off
        default:
            base = .notReady(state: report.state, known: knownStates.contains(report.state),
                             detail: report.detail.isEmpty ? nil : report.detail, inferred: report.reportedBy == "server")
        }
        if report.stale { return wants ? .stale(last: base, heardAt: report.receivedAt) : .off }
        if report.pending { return .pending }
        return base
    }

    /// The collector state in words, as the console's readiness copy has it.
    public static func stateWord(_ state: String) -> String {
        switch state {
        case "off": "off"
        case "ready": "ready"
        case "no_clash_api": "no Clash API"
        case "secret_unreadable": "Clash API secret unreadable"
        case "stream_failing": "Clash API stream failing"
        case "agent_too_old": "agent too old to report"
        default: "unknown state \"\(state)\""
        }
    }
}

/// What one node's row says about collection, symbol and word first.
public enum EvidenceNodeState: Hashable, Sendable {
    /// Ready, and a running capture covers the node.
    case recording(level: String)
    /// Ready (from a server without readiness reports: the policy is on).
    case ready(level: String, reported: Bool)
    case notReady(reason: String, detail: String?, inferred: Bool)
    case notHeard(last: String, heardAt: Date?)
    case waiting
    /// An agent too old to report readiness.
    case cannotTell
    case off

    public var word: String {
        switch self {
        case .recording: "recording"
        case .ready(_, let reported): reported ? "ready" : "on"
        case .notReady: "not ready"
        case .notHeard: "not heard from"
        case .waiting: "waiting for the agent"
        case .cannotTell: "cannot tell"
        case .off: "off"
        }
    }

    public var symbol: String {
        switch self {
        case .recording: "record.circle"
        case .ready: "checkmark.circle.fill"
        case .notReady: "exclamationmark.triangle.fill"
        case .notHeard: "clock.badge.exclamationmark"
        case .waiting: "hourglass"
        case .cannotTell: "questionmark.circle"
        case .off: "minus.circle"
        }
    }

    public var severity: EvidenceSeverity {
        switch self {
        case .recording, .ready: .ok
        case .notReady, .notHeard: .warn
        case .waiting, .cannotTell, .off: .quiet
        }
    }

    /// The reason line under a problem, or nil.
    public var reason: String? {
        switch self {
        case .notReady(let reason, let detail, let inferred):
            var text = reason.prefix(1).uppercased() + reason.dropFirst()
            if let detail { text += ": \(detail)" }
            if inferred { text += ". Inferred by the server from the agent version" }
            return text + "."
        case .notHeard(let last, _):
            return "No beat from the agent for over 90 seconds. Last report: \(last)."
        case .cannotTell:
            return "The agent is too old to report whether it records."
        default:
            return nil
        }
    }

    public var isRecording: Bool {
        switch self {
        case .recording, .ready: true
        default: false
        }
    }

    public static func of(readiness: EvidenceReadiness?, policy: EvidenceTracePolicy?, capturing: Int) -> EvidenceNodeState {
        let level = policy?.level ?? ""
        guard let readiness else {
            if capturing > 0 { return .recording(level: level) }
            return policy?.enabled == true ? .ready(level: level, reported: false) : .off
        }
        switch readiness {
        case .off: return .off
        case .ready(let level): return capturing > 0 ? .recording(level: level) : .ready(level: level, reported: true)
        case .notReady(let state, _, let detail, let inferred):
            if state == "agent_too_old" { return .cannotTell }
            if state == "off" { return .notReady(reason: "agent reports collection off; it has not applied the policy", detail: nil, inferred: false) }
            return .notReady(reason: EvidenceReadiness.stateWord(state), detail: detail, inferred: inferred)
        case .pending, .waiting: return .waiting
        case .stale(let last, let heardAt):
            let word: String = switch last {
            case .ready: "ready"
            case .notReady(let state, _, _, _): EvidenceReadiness.stateWord(state)
            default: "off"
            }
            return .notHeard(last: word, heardAt: heardAt)
        }
    }
}

// MARK: Coverage (evidenceModel.ts evidenceCoverageRows)

public struct EvidenceCoverageSource: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    /// Lines held; nil when stats were not read.
    public var lines: UInt64?
    public var bytes: UInt64?
    public var lastIngestAt: Date?
    /// No line for more than a day, or never one.
    public var stale: Bool
}

public struct EvidenceCoverageRow: Identifiable, Hashable, Sendable {
    public var nodeID: String
    public var name: String
    /// The stored policy; nil when the policy list did not include this node.
    public var traceEnabled: Bool?
    public var level: String?
    /// Running captures that include this node.
    public var capturing: Int
    /// When the soonest of those captures ends.
    public var captureEndsAt: Date?
    public var sources: [EvidenceCoverageSource]
    public var sourcesKnown: Bool
    /// Lines held across the node's sources; nil when any count is unread.
    public var heldLines: UInt64?
    public var readiness: EvidenceReadiness?
    public var state: EvidenceNodeState
    /// Trace off, no capture, no raw source, nothing held: the row says nothing new.
    public var quiet: Bool

    public var id: String { nodeID }

    /// Wanted, and the collector cannot record or has gone quiet.
    public var needsAttention: Bool {
        guard let readiness, traceEnabled == true || capturing > 0 else { return false }
        switch readiness {
        case .stale: return true
        case .notReady(let state, _, _, _): return state != "agent_too_old"
        default: return false
        }
    }
}

public enum EvidenceCoverage {
    /// A raw source is stale after a day without a line.
    public static let rawStaleInterval: TimeInterval = 86_400

    /// One row per node the operator may see: the policy list (one row per
    /// node with log:read) with the node and source lists folded in. Rows
    /// that need someone lead, then captures, then nodes collecting.
    public static func rows(
        nodes: [(id: String, name: String)],
        policies: [EvidenceTracePolicy]?,
        sessions: [EvidenceTraceSession],
        sources: [LogSource],
        sourcesKnown: Bool = true,
        traceUnavailable: Bool = false,
        stats: [LogSourceStats],
        now: Date
    ) -> [EvidenceCoverageRow] {
        var names: [String: String] = [:]
        for node in nodes { names[node.id] = node.name.isEmpty ? node.id : node.name }
        var ids: [String] = []
        var seen = Set<String>()
        func add(_ id: String) {
            guard !id.isEmpty, seen.insert(id).inserted else { return }
            ids.append(id)
        }
        if let policies { policies.forEach { add($0.nodeID) } } else { nodes.forEach { add($0.id) } }
        sources.forEach { add($0.nodeID) }

        let policyBy = Dictionary((policies ?? []).map { ($0.nodeID, $0) }, uniquingKeysWith: { first, _ in first })
        let statsBy = Dictionary(stats.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        let running = sessions.filter { $0.isActive(now: now) }

        let rows = ids.map { nodeID -> EvidenceCoverageRow in
            let policy = policyBy[nodeID]
            let covering = running.filter { $0.covers(nodeID: nodeID, now: now) }
            let ends = covering.compactMap(\.expiresAt).min()
            let nodeSources = sources.filter { $0.nodeID == nodeID }.map { source -> EvidenceCoverageSource in
                let stat = statsBy[source.id]
                let last = stat?.lastIngestAt
                return EvidenceCoverageSource(
                    id: source.id, name: source.displayName.isEmpty ? source.id : source.displayName, enabled: source.enabled,
                    lines: stat?.lines, bytes: stat?.bytes, lastIngestAt: last,
                    stale: last.map { now.timeIntervalSince($0) > rawStaleInterval } ?? true
                )
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let held: UInt64? = nodeSources.contains { $0.lines == nil } ? nil : nodeSources.reduce(0) { $0 + ($1.lines ?? 0) }
            let readiness = EvidenceReadiness.of(policy: policy, capturing: covering.count)
            let quiet = (policy?.enabled == false || traceUnavailable) && sourcesKnown && covering.isEmpty && nodeSources.isEmpty
            return EvidenceCoverageRow(
                nodeID: nodeID, name: names[nodeID] ?? nodeID, traceEnabled: policy?.enabled, level: policy?.level,
                capturing: covering.count, captureEndsAt: ends, sources: nodeSources, sourcesKnown: sourcesKnown,
                heldLines: sourcesKnown ? held : nil, readiness: readiness,
                state: EvidenceNodeState.of(readiness: readiness, policy: policy, capturing: covering.count),
                quiet: quiet
            )
        }
        func rank(_ row: EvidenceCoverageRow) -> Int {
            if row.needsAttention { return 0 }
            if row.capturing > 0 { return 1 }
            if row.traceEnabled == true { return 2 }
            if !row.sources.isEmpty { return 4 }
            return 5
        }
        return rows.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "4 of 35 nodes recording", "1 asked to record is not recording".
    public static func summary(_ rows: [EvidenceCoverageRow]) -> (recording: Int, needsAttention: Int, total: Int) {
        (rows.filter(\.state.isRecording).count, rows.filter(\.needsAttention).count, rows.count)
    }
}

// MARK: Captures (evidenceModel.ts captureBlock, captureRequest)

public enum EvidenceCapturePreset: Int, CaseIterable, Sendable, Hashable {
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case sixtyMinutes = 3600

    public var seconds: Int { rawValue }
    /// "15 min", for buttons.
    public var title: String { "\(rawValue / 60) min" }
    /// "15 minutes", for sentences.
    public var spoken: String { "\(rawValue / 60) minutes" }
}

public enum EvidenceCaptureBlock: Hashable, Sendable {
    case needsAdmin
    case storeOff
    case sessionsUnread
    case limitTotal
    case limitNode

    public var message: String {
        switch self {
        case .needsAdmin: "Needs \(EvidenceCapture.adminScope)"
        case .storeOff: "Connection tracing is not enabled on this server"
        case .sessionsUnread: "The capture list has not loaded, so the server's limits cannot be checked"
        case .limitTotal: "\(EvidenceCapture.maxActive) captures are running, the server's limit"
        case .limitNode: "This node has \(EvidenceCapture.maxPerNode) captures running, the server's limit"
        }
    }
}

public enum EvidenceCapture {
    /// Starting and stopping a capture needs it on every node the capture names.
    public static let adminScope = "log:admin"
    public static let readScope = "log:read"
    /// debug, the server's `traceDefaultLevel` and the console's capture level:
    /// sing-box logs every close line at debug and none at info.
    public static let defaultLevel = "debug"
    /// Server limits (server_trace.go), checked here to say why before asking.
    public static let maxActive = 16
    public static let maxPerNode = 8

    /// "phone edge-tyo-1 2026-10-28 12:05Z": where, when, and that the phone started it.
    public static func sessionName(nodeName: String, at date: Date) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let text = String(format: "%04d-%02d-%02d %02d:%02dZ", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        return "phone \(nodeName) \(text)"
    }

    public static func request(nodeID: String, nodeName: String, preset: EvidenceCapturePreset, now: Date) -> EvidenceCaptureRequest {
        EvidenceCaptureRequest(name: sessionName(nodeName: nodeName, at: now), filter: EvidenceTraceFilter(nodeIDs: [nodeID]),
                               level: defaultLevel, ttlSeconds: preset.seconds)
    }

    /// Why a capture on the node cannot start, or nil when it can.
    public static func block(canAdmin: Bool, storeReady: Bool, sessions: [EvidenceTraceSession]?, nodeID: String, now: Date) -> EvidenceCaptureBlock? {
        if !canAdmin { return .needsAdmin }
        if !storeReady { return .storeOff }
        guard let sessions else { return .sessionsUnread }
        let running = sessions.filter { $0.isActive(now: now) }
        if running.count >= maxActive { return .limitTotal }
        if running.filter({ $0.filter.nodeIDs.contains(nodeID) }).count >= maxPerNode { return .limitNode }
        return nil
    }
}

// MARK: Connection rows (connTraceModel.ts)

public struct EvidenceCloseState: Hashable, Sendable {
    public var id: String
    public var word: String
    public var symbol: String
    public var severity: EvidenceSeverity
    /// False when the record does not say how the connection ended.
    public var certain: Bool
    /// What the server sent when it was not a value this app knows.
    public var raw: String

    public static let reasons = ["eof", "canceled", "reset", "timeout", "dial_failed", "auth_failed", "handshake_failed", "udp_idle", "core_restart", "unknown"]

    /// An open connection has not ended, so it is its own state rather than "unknown".
    public static func of(_ record: EvidenceConnRecord) -> EvidenceCloseState {
        if record.open {
            return EvidenceCloseState(id: "open", word: "open", symbol: "arrow.left.arrow.right.circle", severity: .quiet, certain: true, raw: "")
        }
        return reason(record.closeReason)
    }

    public static func reason(_ raw: String) -> EvidenceCloseState {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let known = reasons.contains(value)
        let id = known ? value : "unknown"
        let (word, symbol, severity): (String, String, EvidenceSeverity) = switch id {
        case "eof": ("finished", "checkmark.circle", .ok)
        case "canceled": ("canceled", "slash.circle", .quiet)
        case "udp_idle": ("UDP idle", "hourglass.bottomhalf.filled", .quiet)
        case "reset": ("reset by peer", "arrow.uturn.backward.circle", .warn)
        case "timeout": ("timed out", "clock.badge.exclamationmark", .warn)
        case "core_restart": ("core restart", "arrow.clockwise.circle", .warn)
        case "dial_failed": ("dial failed", "xmark.circle.fill", .fail)
        case "auth_failed": ("auth failed", "person.crop.circle.badge.xmark", .fail)
        case "handshake_failed": ("handshake failed", "xmark.octagon.fill", .fail)
        default: ("end not recorded", "questionmark.circle", .quiet)
        }
        return EvidenceCloseState(id: id, word: word, symbol: symbol, severity: severity, certain: id != "unknown",
                                  raw: known ? "" : raw.trimmingCharacters(in: .whitespaces))
    }

    /// "Failed" in the console's last-hour count.
    public var isFailure: Bool { ["dial_failed", "auth_failed", "handshake_failed", "reset", "timeout", "core_restart"].contains(id) }
}

public enum EvidenceBytes {
    /// "↑ 12.0 KB ↓ 1.2 MB", or words for counters nobody sampled: a measured
    /// zero and an unmeasured counter are different answers.
    public static func text(_ record: EvidenceConnRecord) -> String {
        guard record.bytesKnown else { return "bytes not sampled" }
        return "\u{2191} \(ByteFormatter.bytes(UInt64(max(0, record.upload)))) \u{2193} \(ByteFormatter.bytes(UInt64(max(0, record.download))))"
    }

    public static func spoken(_ record: EvidenceConnRecord) -> String {
        guard record.bytesKnown else { return "bytes not sampled" }
        return "\(ByteFormatter.bytes(UInt64(max(0, record.upload)))) up, \(ByteFormatter.bytes(UInt64(max(0, record.download)))) down"
    }
}

public enum EvidenceDuration {
    /// "340 ms", "4 min 12 s", "2 h 5 min"; nil for a connection with no terminal line.
    public static func text(milliseconds: Int64?) -> String? {
        guard let ms = milliseconds, ms >= 0 else { return nil }
        if ms < 1000 { return "\(ms) ms" }
        let seconds = Int((Double(ms) / 1000).rounded())
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s" }
        let minutes = seconds / 60
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// "14 days", "7 days", "12 hours", for retention.
    public static func retention(seconds: Int64) -> String {
        if seconds >= 86_400 {
            let days = seconds / 86_400
            return days == 1 ? "1 day" : "\(days) days"
        }
        let hours = max(1, seconds / 3600)
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }
}

public enum EvidenceUserKind {
    public static let all = ["managed", "legacy", "discovered", "unnamed", "unobserved", "unresolved"]

    public static func word(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "managed": "managed"
        case "legacy": "legacy label"
        case "discovered": "discovered"
        case "unnamed": "unnamed"
        case "unobserved": "not observed"
        case "unresolved": "unresolved"
        default: "unknown"
        }
    }
}

public struct EvidenceHopConfidence: Hashable, Sendable {
    public var id: String
    public var word: String
    public var sentence: String
    public var symbol: String
    public var severity: EvidenceSeverity

    /// Anything short of exact is a join this app reports as inferred; an
    /// unknown value is never downgraded to "none" or read as exact.
    public static func of(_ raw: String) -> EvidenceHopConfidence {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "exact":
            EvidenceHopConfidence(id: "exact", word: "exact", sentence: "An identity carried through the chain, so every hop below is the same connection.", symbol: "link.circle.fill", severity: .ok)
        case "inferred":
            EvidenceHopConfidence(id: "inferred", word: "inferred", sentence: "One candidate matched on destination, time window and declared edge. This join was inferred, not carried.", symbol: "link.badge.plus", severity: .warn)
        case "ambiguous":
            EvidenceHopConfidence(id: "ambiguous", word: "ambiguous", sentence: "Several candidates matched and none could be chosen. The path below is one reading of the evidence, not a fact.", symbol: "questionmark.diamond", severity: .warn)
        case "none":
            EvidenceHopConfidence(id: "none", word: "single hop", sentence: "No downstream record matched, so nothing was joined to this connection.", symbol: "circle", severity: .quiet)
        default:
            EvidenceHopConfidence(id: "unknown", word: "unknown", sentence: "The server reported a confidence this app does not recognise, so the path below cannot be read as exact.", symbol: "questionmark.circle", severity: .quiet)
        }
    }
}

// MARK: The connections query (the console's filter names)

/// The question the Connections list asks. Typed into the search field as
/// tokens (`node:edge-tyo-1 user:u_3f9a dst:example.org line:<uuid> session:<id>`)
/// plus free words, which filter the rows on device. Tokens go to the server
/// under its own names (`node_id`, `user_id`, `dst`, `line_uuid`, `session_id`).
public struct EvidenceConnectionQuery: Hashable, Sendable, Codable {
    public static let pageSize = 200
    public static let keys = ["node", "user", "dst", "line", "session"]

    public var nodeID: String
    public var userID: String
    public var dst: String
    public var lineUUID: String
    public var sessionID: String
    public var text: String
    /// Connections still open are listed too (`include_open`). The phone
    /// starts with them on, since on call the live connection is often the
    /// question; `is:closed` turns them off as the console's default has it.
    public var includeOpen: Bool

    public init(nodeID: String = "", userID: String = "", dst: String = "", lineUUID: String = "", sessionID: String = "", text: String = "", includeOpen: Bool = true) {
        self.nodeID = nodeID
        self.userID = userID
        self.dst = dst
        self.lineUUID = lineUUID
        self.sessionID = sessionID
        self.text = text
        self.includeOpen = includeOpen
    }

    /// Any server-side filter is set.
    public var isFiltered: Bool { !nodeID.isEmpty || !userID.isEmpty || !dst.isEmpty || !lineUUID.isEmpty || !sessionID.isEmpty }

    /// Splits on whitespace, keeping double-quoted runs together.
    static func words(_ input: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        for character in input {
            if character == "\"" { quoted.toggle(); continue }
            if character.isWhitespace && !quoted {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// Reads the field. `nodeID` turns a typed name into an id; a value it
    /// does not know is kept as typed (it may be an id). `dest:` is the
    /// console field's spelling of `dst:`.
    public static func parse(_ input: String, nodeID resolve: (String) -> String? = { _ in nil }) -> EvidenceConnectionQuery {
        var query = EvidenceConnectionQuery()
        var free: [String] = []
        for word in words(input) {
            guard let colon = word.firstIndex(of: ":") else { free.append(word); continue }
            let key = word[..<colon].lowercased()
            let value = String(word[word.index(after: colon)...])
            switch key {
            case "node": query.nodeID = value.split(separator: ",").map { resolve(String($0)) ?? String($0) }.joined(separator: ",")
            case "user": query.userID = value
            case "dst", "dest": query.dst = value
            case "line": query.lineUUID = value
            case "session": query.sessionID = value
            case "is" where value.lowercased() == "closed": query.includeOpen = false
            case "is" where value.lowercased() == "open": query.includeOpen = true
            default: free.append(word)
            }
        }
        query.text = free.joined(separator: " ")
        return query
    }

    /// Writes the field back, nodes by name.
    public func formatted(nodeName: (String) -> String = { $0 }) -> String {
        func quote(_ value: String) -> String { value.contains(where: \.isWhitespace) ? "\"\(value)\"" : value }
        var parts: [String] = []
        if !nodeID.isEmpty { parts.append("node:" + quote(nodeID.split(separator: ",").map { nodeName(String($0)) }.joined(separator: ","))) }
        if !userID.isEmpty { parts.append("user:" + quote(userID)) }
        if !dst.isEmpty { parts.append("dst:" + quote(dst)) }
        if !lineUUID.isEmpty { parts.append("line:" + quote(lineUUID)) }
        if !sessionID.isEmpty { parts.append("session:" + quote(sessionID)) }
        if !includeOpen { parts.append("is:closed") }
        if !text.isEmpty { parts.append(text) }
        return parts.joined(separator: " ")
    }

    /// The request's query, empty values left out so the server sees no constraint.
    public func queryItems(since: Date?, until: Date?, limit: Int, cursor: String?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let since { items.append(URLQueryItem(name: "since", value: AstraDateParser.string(from: since))) }
        if let until { items.append(URLQueryItem(name: "until", value: AstraDateParser.string(from: until))) }
        if !nodeID.isEmpty { items.append(URLQueryItem(name: "node_id", value: nodeID)) }
        if !userID.isEmpty { items.append(URLQueryItem(name: "user_id", value: userID)) }
        if !lineUUID.isEmpty { items.append(URLQueryItem(name: "line_uuid", value: lineUUID)) }
        if !sessionID.isEmpty { items.append(URLQueryItem(name: "session_id", value: sessionID)) }
        if !dst.isEmpty { items.append(URLQueryItem(name: "dst", value: dst)) }
        if includeOpen { items.append(URLQueryItem(name: "include_open", value: "true")) }
        if let cursor, !cursor.isEmpty { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return items
    }

    /// Every free word appears in a field the row shows, case-insensitive.
    public func matchesText(_ record: EvidenceConnRecord, nodeName: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = [nodeName, record.nodeID, record.source, record.destination, record.sniffedDomain, record.dstIP, record.network,
                        record.sniffedProtocol, record.userName, record.outboundTag, record.inboundTag, record.closeReason,
                        EvidenceCloseState.of(record).word].joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}

// MARK: Raw logs (evidenceModel.ts pickLogSource)

public enum EvidenceLogs {
    public static let pageSize = 200

    public static func queryItems(sourceID: String, search: String?, limit: Int, beforeSeq: UInt64?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "source_id", value: sourceID), URLQueryItem(name: "limit", value: String(limit))]
        if let search, !search.trimmingCharacters(in: .whitespaces).isEmpty { items.append(URLQueryItem(name: "q", value: search)) }
        if let beforeSeq, beforeSeq > 0 { items.append(URLQueryItem(name: "before_seq", value: String(beforeSeq))) }
        return items
    }

    /// The named source, else the freshest on the named node, else the
    /// freshest of all. A node with no source gets none: another node's lines
    /// would answer a question nobody asked.
    public static func pickSource(_ sources: [LogSource], sourceID: String?, nodeID: String?, stats: [LogSourceStats]) -> LogSource? {
        let ingest = Dictionary(stats.map { ($0.sourceID, $0.lastIngestAt ?? .distantPast) }, uniquingKeysWith: { first, _ in first })
        let sorted = sources.sorted { a, b in
            if a.enabled != b.enabled { return a.enabled }
            let fa = ingest[a.id] ?? .distantPast, fb = ingest[b.id] ?? .distantPast
            if fa != fb { return fa > fb }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
        if let sourceID, !sourceID.isEmpty, let named = sorted.first(where: { $0.id == sourceID }) { return named }
        if let nodeID, !nodeID.isEmpty { return sorted.first { $0.nodeID == nodeID } }
        return sorted.first
    }

    /// The server answers newest first; the screen reads oldest first, newest at the bottom.
    public static func chronological(_ page: LogQueryResponse) -> [LogLine] {
        page.lines.reversed()
    }

    /// How many older pages one refresh reads to join the newest page to the
    /// lines already shown before it gives up and starts over from the newest.
    public static let gapFillPages = 4

    /// What a refresh did to the lines shown.
    public enum Merge: Equatable, Sendable {
        case unchanged
        /// New lines went below the ones shown.
        case appended(Int)
        /// The lines were replaced: a new question, or too many lines arrived to join up.
        case replaced
    }

    /// Whether newest-first pages read back to `cursor` (their oldest chunk;
    /// nil when they reached the start) join the lines shown. Pages hold whole
    /// chunks, so they cover every chunk from `cursor` up, and they join when
    /// no chunk can sit between the newest line shown and `cursor`.
    public static func joins(cursor: UInt64?, shown: [LogLine]) -> Bool {
        guard let cursor, let newest = shown.last?.seq else { return true }
        return cursor <= newest + 1
    }

    /// The lines after a refresh. `newest` is oldest first and was read back
    /// to `cursor`; `olderCursor` is where "Load older" stood before. When the
    /// pages do not join the lines shown, the shown lines are dropped rather
    /// than kept beside a hole nothing could fill.
    public static func mergingNewest(_ shown: [LogLine], newest: [LogLine], cursor: UInt64?, olderCursor: UInt64?) -> (lines: [LogLine], nextBeforeSeq: UInt64?, merge: Merge) {
        guard !shown.isEmpty, joins(cursor: cursor, shown: shown) else { return (newest, cursor, .replaced) }
        // The pages replace every chunk they cover; a page that reached the start covers them all.
        let kept = shown.filter { $0.seq < (cursor ?? 0) }
        let have = Set(shown.map(\.id))
        let added = newest.filter { !have.contains($0.id) }.count
        return (kept + newest, cursor == nil ? nil : olderCursor, added > 0 ? .appended(added) : .unchanged)
    }

    /// An older page goes above the lines shown, once each.
    public static func prependingOlder(_ shown: [LogLine], page: LogQueryResponse) -> [LogLine] {
        let have = Set(shown.map(\.id))
        return chronological(page).filter { !have.contains($0.id) } + shown
    }

    /// The ids of the lines containing `needle`, case-insensitive, top to bottom.
    public static func matches(_ lines: [LogLine], find needle: String) -> [String] {
        let needle = needle.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return lines.filter { $0.line.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(\.id)
    }

    /// The match after (or before) the current one, wrapping around.
    public static func step(_ matches: [String], from current: String?, forward: Bool) -> String? {
        guard !matches.isEmpty else { return nil }
        guard let current, let index = matches.firstIndex(of: current) else { return forward ? matches.first : matches.last }
        let next = forward ? index + 1 : index - 1
        return matches[(next + matches.count) % matches.count]
    }
}

// MARK: Budgets

public struct EvidenceBudgetLine: Hashable, Sendable {
    public var label: String
    public var value: String
    /// Use against the cap, 0 to 1; nil when there is no measured use.
    public var fraction: Double?
}

public enum EvidenceBudget {
    /// The local evidence budgets and, where the server says, how much of them is used.
    public static func lines(settings: EvidenceSettingsView?, stats: EvidenceTraceStats?, sourceStats: [LogSourceStats]?) -> [EvidenceBudgetLine] {
        var lines: [EvidenceBudgetLine] = []
        let cap = (stats?.scoped == false ? stats?.maxBytes : nil) ?? settings?.settings.traceDBMaxBytes
        if let stats, !stats.scoped, let size = stats.sizeBytes, let cap, cap > 0 {
            lines.append(EvidenceBudgetLine(label: "Connection store", value: "\(bytes(size)) of \(bytes(cap))", fraction: Double(size) / Double(cap)))
        } else if let cap, cap > 0 {
            lines.append(EvidenceBudgetLine(label: "Connection store cap", value: bytes(cap), fraction: nil))
        }
        if let settings {
            let rawCap = settings.settings.rawSourceMaxBytes
            if let largest = sourceStats?.map(\.bytes).max(), rawCap > 0 {
                lines.append(EvidenceBudgetLine(label: "Largest raw log", value: "\(ByteFormatter.bytes(largest)) of \(bytes(rawCap))",
                                                fraction: Double(largest) / Double(rawCap)))
            } else if rawCap > 0 {
                lines.append(EvidenceBudgetLine(label: "Raw log cap per source", value: bytes(rawCap), fraction: nil))
            }
            lines.append(EvidenceBudgetLine(label: "Records kept", value: EvidenceDuration.retention(seconds: settings.settings.recordTTLSeconds), fraction: nil))
            lines.append(EvidenceBudgetLine(label: "Capture lines kept", value: EvidenceDuration.retention(seconds: settings.settings.lineTTLSeconds), fraction: nil))
            lines.append(EvidenceBudgetLine(label: "Rollups kept", value: EvidenceDuration.retention(seconds: settings.settings.rollup5mTTLSeconds), fraction: nil))
        }
        return lines
    }

    private static func bytes(_ value: Int64) -> String { ByteFormatter.bytes(UInt64(max(0, value))) }
}
