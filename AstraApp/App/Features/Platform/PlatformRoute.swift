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

/// M8 registers its demo intents and sheets for `-AstraPresent` here.
extension PlatformRoute: DemoHooks {}
