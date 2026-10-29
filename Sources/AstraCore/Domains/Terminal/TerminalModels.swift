import Foundation

// Terminal sessions and transcript events, shaped as `model.TerminalSession`
// and `model.TerminalEvent` in lattice-sdk and served by
// lattice-server/internal/server/server_terminal.go. The console's
// derivations come from views/operations/terminalModel.ts.

/// One PTY session the server brokers. The list holds only the caller's own
/// sessions (`terminalSessionOwnedBy`), and an ended one stays listed for 30
/// minutes. The session does not record its transport.
public struct TerminalSession: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var nodeID: String
    public var actorID: String
    public var tokenID: String
    public var shell: String
    public var cols: Int
    public var rows: Int
    /// `pending`, `open`, `closed` or `failed`.
    public var status: String
    /// Why an ended session ended, in the server's words.
    public var error: String
    /// Bytes the server relayed in each direction; the streaming transport
    /// bypasses the broker, so a streamed session keeps both at zero.
    public var bytesIn: Int64
    public var bytesOut: Int64
    public var createdAt: Date?
    public var openedAt: Date?
    public var closedAt: Date?
    public var lastSeen: Date?

    public init(id: String, nodeID: String, actorID: String = "", tokenID: String = "", shell: String = "", cols: Int = 0, rows: Int = 0,
                status: String, error: String = "", bytesIn: Int64 = 0, bytesOut: Int64 = 0,
                createdAt: Date? = nil, openedAt: Date? = nil, closedAt: Date? = nil, lastSeen: Date? = nil) {
        self.id = id
        self.nodeID = nodeID
        self.actorID = actorID
        self.tokenID = tokenID
        self.shell = shell
        self.cols = cols
        self.rows = rows
        self.status = status
        self.error = error
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.createdAt = createdAt
        self.openedAt = openedAt
        self.closedAt = closedAt
        self.lastSeen = lastSeen
    }

    enum CodingKeys: String, CodingKey {
        case id, shell, cols, rows, status, error
        case nodeID = "node_id", actorID = "actor_id", tokenID = "token_id"
        case bytesIn = "bytes_in", bytesOut = "bytes_out"
        case createdAt = "created_at", openedAt = "opened_at", closedAt = "closed_at", lastSeen = "last_seen"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        actorID = try c.decodeIfPresent(String.self, forKey: .actorID) ?? ""
        tokenID = try c.decodeIfPresent(String.self, forKey: .tokenID) ?? ""
        shell = try c.decodeIfPresent(String.self, forKey: .shell) ?? ""
        cols = try c.decodeIfPresent(Int.self, forKey: .cols) ?? 0
        rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 0
        status = try c.decode(String.self, forKey: .status)
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
        bytesIn = try c.decodeIfPresent(Int64.self, forKey: .bytesIn) ?? 0
        bytesOut = try c.decodeIfPresent(Int64.self, forKey: .bytesOut) ?? 0
        // Go writes a zero time as year one; the parser reads it as absent.
        createdAt = try DateValue.decodeIfPresent(from: c, forKey: .createdAt)
        openedAt = try DateValue.decodeIfPresent(from: c, forKey: .openedAt)
        closedAt = try DateValue.decodeIfPresent(from: c, forKey: .closedAt)
        lastSeen = try DateValue.decodeIfPresent(from: c, forKey: .lastSeen)
    }

    /// Pending or open: the shell is (or is about to be) running.
    public var isLive: Bool { status != "closed" && status != "failed" }

    /// The shell the server normalized to (`normalizeTerminalShell`).
    public var shellPath: String { shell.isEmpty ? "/bin/sh" : shell }

    /// The most recent moment the session showed life.
    public var lastActivity: Date? { closedAt ?? lastSeen ?? openedAt ?? createdAt }
}

/// One output chunk of a polled session. `seq` grows by one per event and is
/// the cursor of the next read.
public struct TerminalEvent: Decodable, Equatable, Hashable, Sendable {
    public var seq: Int64
    /// `output` for everything the agent sends today.
    public var kind: String
    public var data: String
    public var createdAt: Date?

    public init(seq: Int64, kind: String = "output", data: String, createdAt: Date? = nil) {
        self.seq = seq
        self.kind = kind
        self.data = data
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case seq, kind, data
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int64.self, forKey: .seq)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "output"
        data = try c.decodeIfPresent(String.self, forKey: .data) ?? ""
        createdAt = try DateValue.decodeIfPresent(from: c, forKey: .createdAt)
    }
}

/// `GET /api/terminal/sessions/{id}/events?cursor=`: the session as it is now
/// and every retained event after the cursor.
public struct TerminalEventsResponse: Decodable, Equatable, Sendable {
    public var session: TerminalSession
    public var events: [TerminalEvent]

    public init(session: TerminalSession, events: [TerminalEvent]) {
        self.session = session
        self.events = events
    }

    enum CodingKeys: String, CodingKey { case session, events }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decode(TerminalSession.self, forKey: .session)
        events = try c.decodeIfPresent([TerminalEvent].self, forKey: .events) ?? []
    }
}

/// The caps the server enforces, copied from server_terminal.go as the
/// console's `TERMINAL_LIMITS` does. They are printed, never fetched.
public enum TerminalLimits {
    public static let scope = "terminal:open"
    public static let maxSessions = 128
    public static let maxPerNode = 4
    public static let pendingMinutes = 10
    public static let idleMinutes = 30
    public static let absoluteHours = 8
    public static let detachGraceSeconds = 90
    /// An ended session stays listed this long.
    public static let closedRetentionMinutes = 30
    /// Output the server keeps per session.
    public static let maxEvents = 600
    public static let maxSessionKiB = 512

    /// One sentence for the list footer.
    public static var sentence: String {
        "The server ends a session after \(idleMinutes) minutes without activity, \(absoluteHours) hours in all, or \(detachGraceSeconds) seconds after its viewer leaves, allows \(maxPerNode) live sessions per node, and forgets an ended session after \(closedRetentionMinutes) minutes."
    }
}

/// What a session row says about its state.
public enum TerminalSessionState: String, Sendable, Equatable, CaseIterable {
    /// Waiting for the node agent to pick it up.
    case pending
    case open
    /// Closed by an operator, the agent or a node delete.
    case closed
    /// Ended by one of the server's time limits: routine cleanup, not a fault.
    case expired
    case failed

    public static func of(_ session: TerminalSession) -> TerminalSessionState {
        switch session.status {
        case "pending": return .pending
        case "closed": return .closed
        case "failed":
            switch TerminalCloseReason.of(session)?.kind {
            case .pendingExpired, .maxDuration, .idle, .viewerLeft: return .expired
            default: return .failed
            }
        default:
            // "open" and any status this app does not know yet read as live.
            return .open
        }
    }

    public var word: String {
        switch self {
        case .pending: "pending"
        case .open: "open"
        case .closed: "closed"
        case .expired: "expired"
        case .failed: "failed"
        }
    }

    public var isLive: Bool { self == .pending || self == .open }
}

/// Why an ended session ended (`closeReason` in terminalModel.ts, plus the
/// reaper's viewer and node-delete reasons the console folds into "closed").
public struct TerminalCloseReason: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case pendingExpired
        case maxDuration
        case idle
        case viewerLeft
        case nodeOffline
        case nodeDeleted
        case closed
        case failed
    }

    public var kind: Kind
    /// The server's own words when they say more than the kind does.
    public var detail: String?

    public init(kind: Kind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }

    // Server strings from the failTerminalSession and markClosed callers,
    // matched as substrings so a prefix or suffix does not defeat them.
    private static let patterns: [(String, Kind)] = [
        ("expired before node accepted it", .pendingExpired),
        ("reached maximum duration", .maxDuration),
        ("expired after inactivity", .idle),
        ("viewer disconnected", .viewerLeft),
        ("agent did not connect", .nodeOffline),
        ("node deleted", .nodeDeleted),
    ]

    /// Nil while the session is live.
    public static func of(_ session: TerminalSession) -> TerminalCloseReason? {
        guard !session.isLive else { return nil }
        let error = session.error.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = error.lowercased()
        for (needle, kind) in patterns where lowered.contains(needle) {
            return TerminalCloseReason(kind: kind)
        }
        return TerminalCloseReason(kind: session.status == "failed" ? .failed : .closed, detail: error.isEmpty ? nil : error)
    }

    public var sentence: String {
        switch kind {
        case .pendingExpired: "The node agent did not pick it up within \(TerminalLimits.pendingMinutes) minutes."
        case .maxDuration: "It reached the \(TerminalLimits.absoluteHours) hour limit."
        case .idle: "It expired after \(TerminalLimits.idleMinutes) minutes without activity."
        case .viewerLeft: "Its viewer disconnected and did not return within \(TerminalLimits.detachGraceSeconds) seconds."
        case .nodeOffline: "The node agent did not connect."
        case .nodeDeleted: "The node was deleted."
        case .closed: detail.map { "Closed: \($0)." } ?? "Closed by an operator or by the agent."
        case .failed: detail.map { "Failed: \($0)." } ?? "The session failed."
        }
    }
}

/// How a session's bytes travel. The session does not say; the console picks
/// it from the node's reported runtime, and the byte counters prove it.
public enum TerminalTransport: String, Sendable, Equatable {
    /// WebSocket between the browser and the node: the server keeps no output.
    case stream
    /// HTTP polling through the server, which keeps the recent output.
    case poll
    case unknown

    /// After this long open without a byte through the server, a session is
    /// streaming: a polled shell prints its prompt within a second.
    public static let silentStreamSeconds: TimeInterval = 60

    /// Bytes through the server prove polling; otherwise the node's reported
    /// runtime decides, and a long silence on an opened session means stream.
    public static func of(_ session: TerminalSession, runtime: String?, now: Date) -> TerminalTransport {
        if session.bytesOut > 0 || session.bytesIn > 0 { return .poll }
        if runtime == "stream" { return .stream }
        if let opened = session.openedAt {
            let end = session.closedAt ?? now
            if end.timeIntervalSince(opened) >= silentStreamSeconds { return .stream }
        }
        if runtime == "poll" { return .poll }
        return .unknown
    }

    public var word: String {
        switch self {
        case .stream: "stream"
        case .poll: "poll"
        case .unknown: "transport not reported"
        }
    }
}

/// Which credential opened a session, for the row's creator line. The
/// server lists only the caller's own sessions, so the actor is always this
/// operator; the token tells this phone from a browser or another token.
public enum TerminalOpener: Sendable, Equatable {
    case thisToken
    case otherToken(String)
    case signedInSession

    public static func of(_ session: TerminalSession, currentTokenID: String?) -> TerminalOpener {
        if session.tokenID.isEmpty { return .signedInSession }
        if let currentTokenID, !currentTokenID.isEmpty, session.tokenID == currentTokenID { return .thisToken }
        return .otherToken(session.tokenID)
    }

    public var phrase: String {
        switch self {
        case .thisToken: "opened with this token"
        case .otherToken(let id): "opened with token \(id)"
        case .signedInSession: "opened from a browser"
        }
    }
}

/// Session list ordering and grouping.
public enum TerminalSessionList {
    /// Live sessions, newest first.
    public static func live(_ sessions: [TerminalSession]) -> [TerminalSession] {
        sessions.filter(\.isLive).sorted(by: newestFirst)
    }

    /// Ended sessions, most recently ended first.
    public static func ended(_ sessions: [TerminalSession]) -> [TerminalSession] {
        sessions.filter { !$0.isLive }.sorted {
            let a = $0.closedAt ?? $0.createdAt ?? .distantPast
            let b = $1.closedAt ?? $1.createdAt ?? .distantPast
            return a != b ? a > b : $0.id < $1.id
        }
    }

    private static func newestFirst(_ a: TerminalSession, _ b: TerminalSession) -> Bool {
        let left = a.createdAt ?? .distantPast
        let right = b.createdAt ?? .distantPast
        return left != right ? left > right : a.id < b.id
    }

    /// Plain words matched against node name, id, session id, shell, state and transport.
    public static func matches(_ session: TerminalSession, nodeName: String, transport: TerminalTransport, query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let fields = [nodeName, session.nodeID, session.id, session.shellPath, TerminalSessionState.of(session).word, transport.rawValue]
            .joined(separator: " ").lowercased()
        return words.allSatisfy { fields.contains($0) }
    }

    /// "1 live, 3 ended"
    public static func summary(_ sessions: [TerminalSession]) -> String {
        let live = sessions.filter(\.isLive).count
        let ended = sessions.count - live
        return "\(live) live, \(ended) ended"
    }
}

/// What the transcript screen tells the operator besides the lines.
public enum TerminalTranscriptNotice: Sendable, Equatable {
    /// The agent has not picked the session up yet.
    case waitingForAgent
    /// A full-screen program holds the screen; its frames are not lines.
    case fullScreenRunning
    /// The session streams around the server, which keeps no output.
    case streamed
    /// Opened, polled, and nothing printed yet.
    case noOutputYet
    /// The server dropped older output to stay under its cap.
    case truncated

    /// The notices for one session and its cleaned transcript, in display order.
    public static func of(_ session: TerminalSession, transport: TerminalTransport, cleaner: TranscriptCleaner, firstSeq: Int64?) -> [TerminalTranscriptNotice] {
        var notices: [TerminalTranscriptNotice] = []
        if let firstSeq, firstSeq > 1 { notices.append(.truncated) }
        if session.status == "pending" {
            notices.append(.waitingForAgent)
        } else if cleaner.fullScreenActive, session.isLive {
            notices.append(.fullScreenRunning)
        } else if cleaner.isEmpty {
            notices.append(transport == .stream ? .streamed : .noOutputYet)
        }
        return notices
    }
}
