import Foundation

// M12 owns GET terminal/sessions, terminal/sessions/{id}/events and
// POST terminal/sessions/{id}/close (section 8.4). Every one needs
// terminal:open on the session's node, and the per-session routes also need
// the caller to be the operator who opened it. No input path exists by
// design: creating a session, typing, resizing and attaching stay on the web.

private struct TerminalSessionsEnvelope: Decodable {
    var sessions: [TerminalSession]

    enum CodingKeys: String, CodingKey { case sessions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decodeIfPresent([TerminalSession].self, forKey: .sessions) ?? []
    }
}

/// The close request body: `{}`.
public struct TerminalEmptyBody: Encodable, Equatable, Sendable {
    public init() {}
}

/// The server's answer to a close of a session that already ended.
public enum TerminalServerMessages {
    public static let alreadyClosed = "terminal session is closed"
    public static let otherOperator = "belongs to another operator"
    public static let notFound = "terminal session not found"
}

public extension LatticeClient {
    /// `GET /api/terminal/sessions`: this operator's sessions on nodes the
    /// credential may open shells on, live and recently ended.
    func terminalListSessions() async throws -> [TerminalSession] {
        try await perform(TerminalSessionsEnvelope.self, path: "/api/terminal/sessions").sessions
    }

    /// `GET /api/terminal/sessions/{id}/events?cursor=`: the session now and
    /// every retained output event with a sequence above `cursor`. It is the
    /// only read of one session by id: a 404 means the server forgot it, a
    /// 403 that another operator opened it.
    func terminalEvents(sessionID: String, cursor: Int64 = 0) async throws -> TerminalEventsResponse {
        try await perform(
            TerminalEventsResponse.self,
            path: "/api/terminal/sessions/\(sessionID)/events",
            query: [URLQueryItem(name: "cursor", value: String(max(0, cursor)))]
        )
    }

    /// `POST /api/terminal/sessions/{id}/close {}`: asks the agent to end the
    /// shell. The server marks the session closed at once and answers it.
    func terminalCloseSession(id: String) async throws -> TerminalSession {
        try await perform(TerminalSession.self, path: "/api/terminal/sessions/\(id)/close", method: "POST", body: TerminalEmptyBody())
    }
}
