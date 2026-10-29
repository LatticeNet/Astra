import SwiftUI

/// M13's contribution to Browse search (section 8.5): VPN identities by
/// email, name, group or id, and the query fields of the users list
/// (`status:expiring`). The list is read once a minute per server,
/// credential and scope set, only when the token may read it, and a failed
/// read is not kept.
enum VPNSearch: SearchProvider {
    @MainActor private static var cache: (key: String, at: Date, users: [VPNUser])?

    static func results(for query: LatticeQuery, context: SearchContext) async -> [SearchResult] {
        let session = context.session
        guard let client = session.client, let scopes = session.tokenScopes,
              scopes.allows(VPNStore.readRequirement), !scopes.isConfined else { return [] }
        guard case .success(let compiled) = LatticeQueryEngine.compile(query.source, provider: VPNUserQueryFields.self), !compiled.isEmpty else { return [] }
        let identity = session.primaryIdentity
        let key = [client.baseURL.absoluteString, identity?.actorID ?? "", identity?.tokenID ?? "", (identity?.scopes ?? []).joined(separator: " ")].joined(separator: "|")
        if cache == nil || cache?.key != key || Date().timeIntervalSince(cache!.at) > 60 {
            guard let listing = try? await client.vpnListUsers() else {
                cache = nil
                return []
            }
            cache = (key, Date(), listing.users)
        }
        guard let users = cache?.users, !Task.isCancelled else { return [] }
        let now = Date()
        return LatticeQueryEngine.apply(compiled, to: VPNIdentity.ordered(users, now: now), now: now).map { user in
            let style = VPNStyle.identity(user, now: now)
            let detail = [user.name == user.displayName ? "" : user.name, user.group].filter { !$0.isEmpty }.joined(separator: " · ")
            return SearchResult(kind: "VPN identities", id: user.id, title: user.displayName, detail: detail.isEmpty ? nil : detail,
                                style: style, target: .push(.vpn(.user(id: user.id))))
        }
    }
}
