import SwiftUI

/// M12's contribution to Browse search (section 8.5): this operator's
/// terminal sessions by node name, node id, session id, shell or state. The
/// list is read once a minute per server, credential and scope set, only
/// with terminal:open, and a failed read is not kept.
enum TerminalSearch: SearchProvider {
    @MainActor private static var cache: (key: String, at: Date, sessions: [TerminalSession])?

    static func results(for query: LatticeQuery, context: SearchContext) async -> [SearchResult] {
        let session = context.session
        guard let client = session.client, session.missing(TerminalStore.requirement)?.isEmpty ?? true else { return [] }
        let words = query.source.split(whereSeparator: \.isWhitespace).filter { !$0.contains(":") }.joined(separator: " ")
        guard !words.isEmpty else { return [] }
        let identity = session.primaryIdentity
        let key = [client.baseURL.absoluteString, identity?.actorID ?? "", identity?.tokenID ?? "", (identity?.scopes ?? []).joined(separator: " ")].joined(separator: "|")
        if cache == nil || cache?.key != key || Date().timeIntervalSince(cache!.at) > 60 {
            guard let sessions = try? await client.terminalListSessions() else {
                cache = nil
                return []
            }
            cache = (key, Date(), sessions)
        }
        guard let sessions = cache?.sessions, !Task.isCancelled else { return [] }
        let now = Date()
        let ordered = TerminalSessionList.live(sessions) + TerminalSessionList.ended(sessions)
        return ordered.compactMap { item in
            let name = context.nodes.name(for: item.nodeID)
            let transport = TerminalTransport.of(item, runtime: nil, now: now)
            guard TerminalSessionList.matches(item, nodeName: name, transport: transport, query: words) else { return nil }
            let state = TerminalSessionState.of(item)
            return SearchResult(kind: "Terminal sessions", id: item.id, title: name,
                                detail: "\(TerminalWords.shellName(item))\(transport == .unknown ? "" : " · \(transport.word)")",
                                style: .terminal(state), target: .push(.terminal(.transcript(sessionID: item.id))))
        }
    }
}
