import SwiftUI

/// Maps each PlatformRoute case to its screen.
struct PlatformDestination: View {
    let route: PlatformRoute

    var body: some View {
        switch route {
        case .plugins: PluginsScreen()
        case .plugin(let id): PluginDetailScreen(id: id)
        case .extensions: ExtensionsScreen()
        case .extensionPage(let pluginID, let route): ExtensionPageScreen(pluginID: pluginID, route: route)
        case .publishing(let view): PublishingScreen(view: view)
        case .share(let id): ShareDetailScreen(id: id)
        case .binding(let id): BindingDetailScreen(id: id)
        case .storageToken(let id): StorageTokenDetailScreen(id: id)
        case .store: StoreScreen()
        case .bucket(let kind, let name): StoreBucketScreen(kind: kind, name: name)
        case .storeEntry(let kind, let bucket, let key): StoreEntryScreen(kind: kind, bucket: bucket, key: key)
        case .system: SystemScreen()
        }
    }
}
