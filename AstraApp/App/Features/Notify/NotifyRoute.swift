import SwiftUI

/// M9 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M9 may add cases but must not rename or remove these.
enum NotifyRoute: Hashable, Codable, Sendable {
    case notifications(view: String?)
    case delivery(id: String)
    case channel(id: String)
    case rule(id: String)
    case webhooks
    case webhook(id: String)
}

/// M9's demo intents and sheets for `-AstraPresent`:
/// `confirm:notify.channelTest:<channelID>`, `confirm:notify.channelDelete:<channelID>`,
/// `confirm:notify.webhookTest:<webhookID>`, `confirm:notify.webhookDelete:<webhookID>`,
/// `confirm:notify.witnessRemove:<nodeName>`, `confirm:notify.witnessPlan:<nodeName>`,
/// the module sheet `witnessPlan[:<nodeName>]`, and `notifyPush:<page>`,
/// which pushes a page no link reaches (`notifications`, `notifications:sent`,
/// `webhooks`, `rule:<ruleID>`) onto the selected tab; pair it with
/// `-AstraTab browse`. Ids are the demo's (`ch_bark`, `ch_mail`, `wh_ups`, `home-nas`).
extension NotifyRoute: DemoHooks {
    static func demoIntent(_ id: String, session: SessionStore) -> WriteIntent? {
        guard session.isDemo, id.hasPrefix("notify.") else { return nil }
        let parts = id.dropFirst("notify.".count).split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "channelTest":
            return demoChannel(argument).map(NotifyIntents.testChannel)
        case "channelDelete":
            return demoChannel(argument).map { NotifyIntents.deleteChannel($0, rules: demoRules, channels: demoChannels) }
        case "webhookTest":
            return demoWebhook(argument).map(NotifyIntents.testWebhook)
        case "webhookDelete":
            return demoWebhook(argument).map(NotifyIntents.deleteWebhook)
        case "witnessRemove":
            let node = DemoWorld.node(argument)
            return NotifyIntents.removeWitness(node: ObjectRef(kind: "node", id: node.id, name: node.name))
        case "witnessPlan":
            let node = DemoWorld.node(argument)
            guard let bark = demoChannel("ch_bark") else { return nil }
            return NotifyIntents.planWitness(node: ObjectRef(kind: "node", id: node.id, name: node.name), channel: bark,
                                             barkURL: "http://127.0.0.1:8080", status: NotifyWitnessStatus(healthURL: "https://lattice.example.net/readyz"))
        default:
            return nil
        }
    }

    static func demoSheet(_ name: String, argument: String?) -> AnyView? {
        switch name {
        case "witnessPlan":
            return AnyView(NotifyWitnessPlanSheet(nodeID: argument.map { DemoWorld.node($0).id }))
        case "notifyPush":
            let parts = (argument ?? "").split(separator: ":", maxSplits: 1).map(String.init)
            let route: NotifyRoute? = switch parts.first {
            case "notifications": .notifications(view: parts.count > 1 ? parts[1] : nil)
            case "webhooks": .webhooks
            case "rule": parts.count > 1 ? .rule(id: parts[1]) : nil
            default: nil
            }
            return route.map { AnyView(NotifyDemoPusher(route: $0)) }
        default:
            return nil
        }
    }

    private static var demoChannels: [NotifyChannel] {
        NotifyFixtures.channels.map { NotifyChannel(id: $0.id, name: $0.name, kind: $0.kind, configKeys: $0.keys, enabled: $0.enabled, fallbackChannelID: $0.fallback) }
    }

    private static var demoRules: [NotifyRule] {
        NotifyFixtures.rules.map { NotifyRule(id: $0.id, name: $0.name, eventTypes: $0.events, channelIDs: $0.channels, enabled: $0.enabled, fallbackChannelID: $0.fallback) }
    }

    private static func demoChannel(_ id: String) -> NotifyChannel? {
        demoChannels.first { $0.id == id }
    }

    private static func demoWebhook(_ id: String) -> NotifyWebhook? {
        NotifyFixtures.webhooks.first { $0.id == id }.map { NotifyWebhook(id: $0.id, name: $0.name, eventType: $0.event, enabled: $0.enabled) }
    }
}

/// Pushes a page with no app link, then gets out of the way (demo only).
private struct NotifyDemoPusher: View {
    let route: NotifyRoute
    @Environment(Router.self) private var router

    var body: some View {
        Color.clear.task {
            router.dismissPresented { router.push(.notify(route)) }
        }
    }
}
