import SwiftUI

/// M7's contribution to Browse search (section 8.5). Bare words already
/// find nodes through Fleet, so SSH Guard answers only queries that use its
/// own fields (`posture:`, `state:`, `knock:`, `is:reverting`, ...), and
/// Agent Updates only queries that use its fields (`is:behind`, `policy:`,
/// `standing:`, ...). Each list is fetched once a minute per credential.
enum SSHGuardSearch: SearchProvider {
    @MainActor private static var cache: (key: String, at: Date, guardRows: [SSHGuardNodeStatus]?, policies: [AgentUpdatesPolicy]?, latest: String?)?

    static let guardFields: Set<String> = ["posture", "state", "coverage", "stage", "scope", "knock", "port", "ports", "sshd", "password",
                                           "observed", "snapshot", "gate", "gated", "reverting", "armable"]
    static let agentFields: Set<String> = ["standing", "policy", "target", "planned", "last_planned", "behind", "failed", "error", "version", "agent"]

    static func results(for query: LatticeQuery, context: SearchContext) async -> [SearchResult] {
        let words = fieldWords(query.source)
        let wantsGuard = !words.isDisjoint(with: guardFields)
        let wantsAgent = !words.isDisjoint(with: agentFields)
        guard wantsGuard || wantsAgent, let client = context.session.client else { return [] }
        let canGuard = context.session.missing(SSHGuardStore.readRequirement)?.isEmpty ?? true
        let canAgent = context.session.missing(AgentUpdatesStore.gate)?.isEmpty ?? true
        let identity = context.session.primaryIdentity
        let key = [client.baseURL.absoluteString, identity?.tokenID ?? "", (identity?.scopes ?? []).joined(separator: " ")].joined(separator: "|")
        if cache == nil || cache?.key != key || Date().timeIntervalSince(cache!.at) > 60 {
            var rows: [SSHGuardNodeStatus]?
            var policies: [AgentUpdatesPolicy]?
            var latest: String?
            if canGuard { rows = try? await client.fetchSSHGuardStatus() }
            if canAgent {
                policies = try? await client.agentUpdatesPolicies()
                latest = (try? await client.agentUpdatesReleaseInfo())?.latestVersion
            }
            // A failed read is never kept as an empty answer.
            cache = (canGuard && rows == nil) || (canAgent && policies == nil) ? nil : (key, Date(), rows, policies, latest)
            if cache == nil { return [] }
        }
        await context.nodes.refreshIfOlder(than: 60)
        guard let cache, !Task.isCancelled else { return [] }
        let now = Date()
        var results: [SearchResult] = []
        if wantsGuard, let statuses = cache.guardRows,
           case .success(let compiled) = LatticeQueryEngine.compile(query.source, provider: SSHGuardBoardQueryFields.self) {
            let rows = statuses.map { SSHGuardBoardRow(status: $0, node: context.nodes.nodes[$0.nodeID], now: now) }
            results += LatticeQueryEngine.apply(compiled, to: rows, now: now).map { row in
                SearchResult(kind: "SSH Guard", id: "sshguard:\(row.id)", title: row.name,
                             detail: "\(StatusStyle.coverage(row.coverage).word), \(SSHGuardKnockWords.word(row.knock))",
                             style: row.isReverting ? StatusStyle.coverage(row.coverage) : StatusStyle.posture(row.posture),
                             target: .push(.sshGuard(.node(id: row.id))))
            }
        }
        if wantsAgent, let policies = cache.policies,
           case .success(let compiled) = LatticeQueryEngine.compile(query.source, provider: AgentUpdatesQueryFields.self) {
            let byNode = Dictionary(policies.map { ($0.nodeID, $0) }, uniquingKeysWith: { first, _ in first })
            let rows = context.nodes.nodes.values.map { AgentUpdatesNodeRow(node: $0, policy: byNode[$0.id], latest: cache.latest) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            results += LatticeQueryEngine.apply(compiled, to: rows, now: now).map { row in
                SearchResult(kind: "Agent Updates", id: "agent:\(row.nodeID)", title: row.name,
                             detail: row.running.isEmpty ? "not reported" : "runs \(row.running)",
                             style: SSHGuardAgentWords.style(row.standing),
                             target: .push(.sshGuard(.agentUpdates(view: "nodes", nodeID: row.nodeID))))
            }
        }
        return results
    }

    /// The field names a query uses, with `is:` flags read as their field.
    private static func fieldWords(_ source: String) -> Set<String> {
        var words = Set<String>()
        for token in source.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ")" }) {
            var text = token.drop { $0 == "-" }
            guard let colon = text.firstIndex(where: { $0 == ":" || $0 == ">" || $0 == "<" || $0 == "=" }) else { continue }
            let field = String(text[..<colon])
            text = text[text.index(after: colon)...]
            if field == "is" || field == "has" { words.insert(String(text)) } else { words.insert(field) }
        }
        return words
    }
}
