import SwiftUI

/// M11's contribution to Browse search (section 8.5): access tokens and
/// operator accounts, by name, id or scope, with the token grammar
/// (`is:revoked`, `scope:"task:run"`). Each list is read only when the token
/// holds its scope, once a minute per server, credential and scope set, and
/// a failed read is not kept. Results open in the Settings sheet.
enum AccountSearch: SearchProvider {
    private struct Snapshot {
        var tokens: [LatticeToken]
        var users: [AccessUser]
    }

    @MainActor private static var cache: (key: String, at: Date, snapshot: Snapshot)?

    static func results(for query: LatticeQuery, context: SearchContext) async -> [SearchResult] {
        let session = context.session
        guard let client = session.client, !query.source.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let canTokens = session.missing(AccessStore.tokensRequirement)?.isEmpty ?? false
        let canUsers = session.missing(AccessStore.usersRequirement)?.isEmpty ?? false
        guard canTokens || canUsers else { return [] }
        let identity = session.primaryIdentity
        let key = [client.baseURL.absoluteString, identity?.actorID ?? "", identity?.tokenID ?? "", (identity?.scopes ?? []).joined(separator: " ")].joined(separator: "|")
        if cache == nil || cache?.key != key || Date().timeIntervalSince(cache!.at) > 60 {
            async let tokens = canTokens ? client.listTokens() : []
            async let users = canUsers ? client.accessListUsers() : []
            guard let snapshot = try? await Snapshot(tokens: tokens, users: users) else {
                cache = nil
                return []
            }
            cache = (key, Date(), snapshot)
        }
        guard let snapshot = cache?.snapshot, !Task.isCancelled else { return [] }
        var results: [SearchResult] = []
        if case .success(let compiled) = LatticeQueryEngine.compile(query.source, provider: AccessTokenQueryFields.self) {
            for token in LatticeQueryEngine.apply(compiled, to: AccessTokens.sorted(snapshot.tokens), now: Date()) {
                let own = session.credentialKind == .token && AccessTokens.isOwn(token, identity: identity)
                results.append(SearchResult(
                    kind: "Access tokens", id: token.id, title: token.displayName,
                    detail: (own ? "This iPhone. " : "") + AccessTokens.detail(token),
                    style: .accountToken(token),
                    target: .settings([.account(.access(view: "tokens")), .account(.token(id: token.id))])
                ))
            }
        }
        if case .success(let compiled) = LatticeQueryEngine.compile(query.source, provider: AccessUserQueryFields.self) {
            for user in LatticeQueryEngine.apply(compiled, to: AccessUsers.sorted(snapshot.users), now: Date()) {
                results.append(SearchResult(
                    kind: "Users", id: user.id, title: user.displayName,
                    detail: "\(AccessUsers.role(user)), \(AccessUsers.signIn(user))",
                    style: .accountUser(user),
                    target: .settings([.account(.access(view: "users")), .account(.user(id: user.id))])
                ))
            }
        }
        return results
    }
}
