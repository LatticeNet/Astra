import Foundation

/// The one terminal write the phone makes: close a session, T2 in the parity
/// matrix (section 3.2). It runs through `ActionRunner` and is never sent
/// from a deep link, a launch or a poll. Creating a session and typing have
/// no intent: they stay on the web.
public enum TerminalIntents {
    public static func object(_ session: TerminalSession, nodeName: String) -> ObjectRef {
        ObjectRef(kind: "terminal session", id: session.id, name: "the session on \(nodeName)")
    }

    /// T2. Ends the shell and everything running in it; the session cannot be
    /// resumed. Closing an already ended session changes nothing, so a retry
    /// after a lost answer is safe and reads as done.
    public static func close(_ session: TerminalSession, nodeName: String) -> WriteIntent {
        let object = object(session, nodeName: nodeName)
        let sessionID = session.id
        return WriteIntent(
            tier: .t2, verb: "Close", object: object, scopes: [TerminalLimits.scope],
            consequence: "Lattice asks the agent on \(nodeName) to end the shell and everything running in it. The session cannot be resumed.",
            verify: { client in
                let sessions = try await client.terminalListSessions()
                guard let fresh = sessions.first(where: { $0.id == sessionID }) else {
                    return "The server no longer lists the session on \(nodeName)."
                }
                return fresh.isLive ? "The session on \(nodeName) is still \(fresh.status)." : "The session on \(nodeName) is now \(fresh.status)."
            },
            idempotent: true, changes: [.terminal],
            perform: { client, _ in
                do {
                    let closed = try await client.terminalCloseSession(id: sessionID)
                    return outcome(ofClose: closed, nodeName: nodeName)
                } catch {
                    if let outcome = outcome(ofCloseError: LatticeAPIError(error), nodeName: nodeName) { return outcome }
                    throw error
                }
            }
        )
    }

    public static func outcome(ofClose session: TerminalSession, nodeName: String) -> WriteOutcome {
        session.isLive
            ? .done("Close requested for the session on \(nodeName). It ends when the agent stops the shell.")
            : .done("Closed the session on \(nodeName)")
    }

    /// The refusals the close route answers with its own meaning; nil for the
    /// rest, which the write flow maps.
    public static func outcome(ofCloseError error: LatticeAPIError, nodeName: String) -> WriteOutcome? {
        switch error {
        case .server(400, _, let message) where message.localizedCaseInsensitiveContains(TerminalServerMessages.alreadyClosed):
            return .done("The session on \(nodeName) had already ended")
        case .notFound:
            let message = "The server no longer holds the session on \(nodeName). It forgets an ended session after \(TerminalLimits.closedRetentionMinutes) minutes."
            return .refused(.notFound, message)
        case .forbidden(_, let message) where message.localizedCaseInsensitiveContains(TerminalServerMessages.otherOperator):
            let text = "Not closed: another operator opened this session, and only they can close it."
            return .refused(.validation(text), text)
        default:
            return nil
        }
    }
}
