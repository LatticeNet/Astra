import SwiftUI

/// M9's contribution to Browse search (section 8.5): notification channels,
/// rules and inbound webhooks by name, kind or event type. The lists are
/// read once a minute per server, credential and scope set, never for a
/// confined token (the server refuses it), and a failed read is not kept.
enum NotifySearch: SearchProvider {
    private struct Snapshot {
        var channels: [NotifyChannel]
        var rules: [NotifyRule]
        var webhooks: [NotifyWebhook]
    }

    @MainActor private static var cache: (key: String, at: Date, snapshot: Snapshot)?

    static func results(for query: LatticeQuery, context: SearchContext) async -> [SearchResult] {
        let session = context.session
        guard let client = session.client, !(session.tokenScopes?.isConfined ?? false),
              session.missing(NotifyStore.requirement)?.isEmpty ?? true else { return [] }
        let identity = session.primaryIdentity
        let key = [client.baseURL.absoluteString, identity?.actorID ?? "", identity?.tokenID ?? "", (identity?.scopes ?? []).joined(separator: " ")].joined(separator: "|")
        if cache == nil || cache?.key != key || Date().timeIntervalSince(cache!.at) > 60 {
            async let channels = client.listNotifyChannels()
            async let rules = client.listNotifyRules()
            async let webhooks = client.notifyListWebhooks()
            guard let snapshot = try? await Snapshot(channels: channels, rules: rules, webhooks: webhooks) else {
                cache = nil
                return []
            }
            cache = (key, Date(), snapshot)
        }
        guard let snapshot = cache?.snapshot, !Task.isCancelled else { return [] }
        let words = query.source.lowercased().split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.contains(":") }
        guard !words.isEmpty else { return [] }
        func matches(_ fields: [String]) -> Bool {
            let text = fields.joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        var results: [SearchResult] = []
        for channel in snapshot.channels where matches([channel.displayName, channel.kind, NotifyKind.label(channel.kind)]) {
            results.append(SearchResult(kind: "Notification channels", id: channel.id, title: channel.displayName,
                                        detail: NotifyKind.label(channel.kind), style: .notifyChannel(channel),
                                        target: .push(.notify(.channel(id: channel.id)))))
        }
        for rule in snapshot.rules where matches([rule.displayName] + rule.eventTypes) {
            results.append(SearchResult(kind: "Notification rules", id: rule.id, title: rule.displayName,
                                        detail: NotifyRules.matchesEverything(rule) ? "Every event" : rule.eventTypes.joined(separator: ", "),
                                        style: .notifyRule(rule, channels: snapshot.channels), target: .push(.notify(.rule(id: rule.id)))))
        }
        for hook in snapshot.webhooks where matches([hook.displayName, hook.eventType]) {
            let nobody = NotifyWebhookRouting.reachesNobody(hook, channels: snapshot.channels, rules: snapshot.rules)
            results.append(SearchResult(kind: "Webhooks", id: hook.id, title: hook.displayName, detail: hook.eventType,
                                        style: .notifyWebhook(hook, reachesNobody: nobody), target: .push(.notify(.webhook(id: hook.id)))))
        }
        return results
    }
}
