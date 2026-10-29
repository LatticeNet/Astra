import SwiftUI

/// M8's contribution to Browse search (section 8.5): plugins (audit:read)
/// and shares (an unconfined proxy:admin), each fetched once a minute per
/// server, credential and scope set. A failed read is never kept as an empty list.
enum PlatformSearch: SearchProvider {
    @MainActor private static var pluginCache: (key: String, at: Date, rows: [PlatformPluginRow])?
    @MainActor private static var shareCache: (key: String, at: Date, shares: [PlatformShare])?

    static func results(for query: LatticeQuery, context: SearchContext) async -> [SearchResult] {
        guard let client = context.session.client else { return [] }
        let identity = context.session.primaryIdentity
        let key = [client.baseURL.absoluteString, identity?.actorID ?? "", identity?.tokenID ?? "",
                   (identity?.scopes ?? []).joined(separator: " "), (identity?.serverAllowlist ?? []).joined(separator: " ")].joined(separator: "|")
        let plugins = await pluginResults(query, client: client, session: context.session, key: key)
        let shares = await shareResults(query, client: client, session: context.session, key: key)
        return plugins + shares
    }

    private static func fresh(_ cached: (key: String, at: Date)?, key: String) -> Bool {
        guard let cached else { return false }
        return cached.key == key && Date().timeIntervalSince(cached.at) <= 60
    }

    private static func pluginResults(_ query: LatticeQuery, client: LatticeClient, session: SessionStore, key: String) async -> [SearchResult] {
        guard session.missing(ScopeRequirement(PlatformStore.readScope))?.isEmpty ?? true else { return [] }
        if !fresh(pluginCache.map { ($0.key, $0.at) }, key: key) {
            guard let registered = try? await client.platformPlugins() else {
                pluginCache = nil
                return []
            }
            let contributions = try? await client.platformContributions()
            pluginCache = (key, Date(), PlatformPluginRows.merge(registered: registered, lifecycle: nil, contributions: contributions))
        }
        guard let rows = pluginCache?.rows, !Task.isCancelled,
              case .success(let compiled) = LatticeQueryEngine.compile(query.source, provider: PlatformPluginQueryFields.self), !compiled.isEmpty else { return [] }
        return LatticeQueryEngine.apply(compiled, to: rows, now: Date()).map { row in
            SearchResult(kind: "Plugins", id: row.id, title: row.name,
                         detail: [row.version.isEmpty ? nil : "v\(row.version)", row.publisher.isEmpty ? nil : row.publisher].compactMap { $0 }.joined(separator: " · "),
                         style: .platformPlugin(row), target: .push(.platform(.plugin(id: row.id))))
        }
    }

    private static func shareResults(_ query: LatticeQuery, client: LatticeClient, session: SessionStore, key: String) async -> [SearchResult] {
        guard session.missing(ScopeRequirement(PublishingStore.shareScope))?.isEmpty ?? true,
              session.primaryIdentity?.scopeSet.isConfined != true else { return [] }
        if !fresh(shareCache.map { ($0.key, $0.at) }, key: key) {
            guard let shares = try? await client.platformShares() else {
                shareCache = nil
                return []
            }
            shareCache = (key, Date(), shares)
        }
        guard let shares = shareCache?.shares, !Task.isCancelled,
              case .success(let compiled) = LatticeQueryEngine.compile(query.source, provider: PlatformShareQueryFields.self), !compiled.isEmpty else { return [] }
        let now = Date()
        return LatticeQueryEngine.apply(compiled, to: shares, now: now).map { share in
            SearchResult(kind: "Shares", id: share.id, title: share.slug, detail: PlatformShares.sourceLabel(share),
                         style: PlatformShareRow.style(share, state: PlatformShareState.of(share, now: now)), target: .push(.platform(.share(id: share.id))))
        }
    }
}
