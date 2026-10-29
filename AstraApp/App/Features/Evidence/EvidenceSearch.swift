import SwiftUI

/// M10's contribution to Browse search (section 8.5): capture sessions by
/// name and raw log sources by name or path. The two lists are read once a
/// minute per server, credential and scope set; a failed read is not kept.
enum EvidenceSearch: SearchProvider {
    private struct Snapshot {
        var sessions: [EvidenceTraceSession]
        var sources: [LogSource]
    }

    @MainActor private static var cache: (key: String, at: Date, snapshot: Snapshot)?

    static func results(for query: LatticeQuery, context: SearchContext) async -> [SearchResult] {
        let session = context.session
        guard let client = session.client, session.missing(EvidenceStore.requirement)?.isEmpty ?? true else { return [] }
        let identity = session.primaryIdentity
        let key = [client.baseURL.absoluteString, identity?.actorID ?? "", identity?.tokenID ?? "", (identity?.scopes ?? []).joined(separator: " ")].joined(separator: "|")
        if cache == nil || cache?.key != key || Date().timeIntervalSince(cache!.at) > 60 {
            // Either list may be off on the server (503); the other still answers.
            async let sessions = try? client.evidenceListSessions()
            async let sources = try? client.listLogSources()
            let (s, l) = await (sessions, sources)
            guard s != nil || l != nil else {
                cache = nil
                return []
            }
            cache = (key, Date(), Snapshot(sessions: s ?? [], sources: l ?? []))
        }
        guard let snapshot = cache?.snapshot, !Task.isCancelled else { return [] }
        let words = query.source.lowercased().split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.contains(":") }
        guard !words.isEmpty else { return [] }
        func matches(_ fields: [String]) -> Bool {
            let text = fields.joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        let now = Date()
        var results: [SearchResult] = []
        for capture in snapshot.sessions where matches([capture.name, capture.id]) {
            let names = capture.filter.nodeIDs.map { context.nodes.name(for: $0) }
            results.append(SearchResult(kind: "Captures", id: capture.id, title: capture.name.isEmpty ? capture.id : capture.name,
                                        detail: names.isEmpty ? "Every node" : names.joined(separator: ", "),
                                        style: .evidenceSession(capture, now: now),
                                        target: .push(.evidence(.connections(filter: "session:\(capture.id)")))))
        }
        for source in snapshot.sources where matches([source.displayName, source.path, context.nodes.name(for: source.nodeID)]) {
            results.append(SearchResult(kind: "Raw logs", id: source.id, title: source.displayName,
                                        detail: context.nodes.name(for: source.nodeID),
                                        target: .push(.evidence(.logSource(id: source.id)))))
        }
        return results
    }
}
