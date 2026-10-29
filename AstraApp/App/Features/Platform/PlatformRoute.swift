import SwiftUI

/// M8 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M8 may add cases but must not rename or remove these.
enum PlatformRoute: Hashable, Codable, Sendable {
    case plugins
    case plugin(id: String)
    case extensions
    case extensionPage(pluginID: String, route: String)
    case publishing(view: String?)
    case share(id: String)
    case binding(id: String)
    case storageToken(id: String)
    case store
    case bucket(kind: String, name: String)
    case storeEntry(kind: String, bucket: String, key: String)
    case system
}

/// M8's demo intents for `-AstraPresent`: `confirm:platform.activate:<pluginID>`,
/// `confirm:platform.disable:<pluginID>`, `confirm:platform.deleteBinding:<bindingID>`,
/// `confirm:platform.revokeToken:<tokenID>`, `confirm:platform.refreshShare:<shareID>`,
/// `confirm:platform.rotateShare:<shareID>`, `confirm:platform.deleteShare:<shareID>`,
/// and `reveal:platform.shareURL:<shareID>`. Ids are the demo fixture ids
/// (`latticenet.wireguard`, `binding_docs`, `stok_flags_ci`, `share_family`).
/// The module sheet `platformPush:<screen>` pushes a Platform screen onto the
/// selected tab (use with `-AstraTab browse`): `plugins`, `extensions`,
/// `store`, `system`, `plugin:<id>`, `page:<pluginID>:<route>`,
/// `publishing[:<view>]`, `share:<id>`, `binding:<id>`, `token:<id>`,
/// `bucket:<kind>:<name>` and `entry:<kind>:<bucket>|<key>`.
extension PlatformRoute: DemoHooks {
    static func demoIntent(_ id: String, session: SessionStore) -> WriteIntent? {
        guard session.isDemo, let (verb, argument) = demoParts(id) else { return nil }
        switch verb {
        case "activate", "disable":
            guard let plugin = PlatformFixtures.plugins.first(where: { $0.id == argument }) else { return nil }
            return PlatformIntents.lifecycle(pluginID: plugin.id, name: plugin.name, to: verb == "activate" ? "active" : "disabled")
        case "deleteBinding":
            guard let binding = PlatformFixtures.bindings.first(where: { $0.id == argument }), let kind = PlatformStorageKind(rawValue: binding.kind) else { return nil }
            let route = binding.pathPrefix.isEmpty ? binding.hostname : "\(binding.hostname)/\(binding.pathPrefix)"
            return PlatformIntents.deleteBinding(kind: kind, id: binding.id, route: route, bucket: binding.bucket)
        case "revokeToken":
            guard let token = PlatformFixtures.tokens.first(where: { $0.id == argument }), let kind = PlatformStorageKind(rawValue: token.kind) else { return nil }
            let buckets = token.buckets.isEmpty ? "every \(kind.title) bucket" : token.buckets.joined(separator: ", ")
            return PlatformIntents.revokeToken(kind: kind, id: token.id, name: token.name, buckets: buckets)
        case "refreshShare":
            return demoShare(argument).map { PlatformIntents.refreshShare(id: $0.id, slug: $0.slug, sink: PlatformRefreshSink()) }
        case "rotateShare":
            return demoShare(argument).map { PlatformIntents.rotateShare(id: $0.id, slug: $0.slug, rotatedBefore: nil) }
        case "deleteShare":
            return demoShare(argument).map { PlatformIntents.deleteShare(id: $0.id, slug: $0.slug) }
        default:
            return nil
        }
    }

    static func demoReveal(_ id: String) -> RevealIntent? {
        guard let (verb, argument) = demoParts(id), verb == "shareURL", let share = demoShare(argument) else { return nil }
        return PlatformIntents.revealShare(id: share.id, slug: share.slug, origin: DemoWorld.baseURL)
    }

    static func demoSheet(_ name: String, argument: String?) -> AnyView? {
        guard name == "platformPush", let route = argument.flatMap(demoRoute) else { return nil }
        return AnyView(PlatformDemoPusher(route: route))
    }

    private static func demoRoute(_ argument: String) -> PlatformRoute? {
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        let rest = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "plugins": return .plugins
        case "extensions": return .extensions
        case "store": return .store
        case "system": return .system
        case "plugin": return rest.isEmpty ? nil : .plugin(id: rest)
        case "publishing": return .publishing(view: rest.isEmpty ? nil : rest)
        case "share": return rest.isEmpty ? nil : .share(id: rest)
        case "binding": return rest.isEmpty ? nil : .binding(id: rest)
        case "token": return rest.isEmpty ? nil : .storageToken(id: rest)
        case "page":
            let page = rest.split(separator: ":", maxSplits: 1).map(String.init)
            return page.count == 2 ? .extensionPage(pluginID: page[0], route: page[1]) : nil
        case "bucket":
            let bucket = rest.split(separator: ":", maxSplits: 1).map(String.init)
            return bucket.count == 2 ? .bucket(kind: bucket[0], name: bucket[1]) : nil
        case "entry":
            let entry = rest.split(separator: ":", maxSplits: 1).map(String.init)
            guard entry.count == 2 else { return nil }
            let location = entry[1].split(separator: "|", maxSplits: 1).map(String.init)
            return location.count == 2 ? .storeEntry(kind: entry[0], bucket: location[0], key: location[1]) : nil
        default: return nil
        }
    }

    private static func demoParts(_ id: String) -> (String, String)? {
        guard id.hasPrefix("platform.") else { return nil }
        let parts = id.dropFirst("platform.".count).split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    private static func demoShare(_ id: String) -> PlatformFixtures.Share? {
        PlatformFixtures.shares.first { $0.id == id }
    }
}

/// Pushes a Platform screen for a demo screenshot, then gets out of the way.
private struct PlatformDemoPusher: View {
    let route: PlatformRoute
    @Environment(Router.self) private var router

    var body: some View {
        Color.clear.task {
            router.dismissPresented { router.push(.platform(route)) }
        }
    }
}
