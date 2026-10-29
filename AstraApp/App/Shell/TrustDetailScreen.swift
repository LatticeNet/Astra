import SwiftUI

/// Plugin trust findings (F-17), pushed from the Inbox trust row.
struct TrustDetailScreen: View {
    @Environment(SessionStore.self) private var session
    @State private var state: ResourceState<PluginTrust> = .idle

    var body: some View {
        ResourceView(state: state, noun: "plugin trust", retry: { Task { await load() } }) { trust in
            List {
                Section {
                    if trust.nonOfficial {
                        finding("Plugins from publishers other than LatticeNet are installed.", tone: .warn)
                    }
                    if trust.allowUnsignedHostRisk {
                        finding("The server allows unsigned plugins with host risk.", tone: .fail)
                    }
                    if !trust.warns {
                        Label("Only official, signed plugins are installed.", systemImage: "checkmark.shield")
                            .foregroundStyle(.secondary)
                    }
                }
                if !trust.publishers.isEmpty {
                    Section("Publishers") {
                        ForEach(trust.publishers, id: \.self) { publisher in
                            Text(publisher)
                        }
                    }
                }
                Section {
                    NavigationLink("Plugins", value: AppRoute.platform(.plugins))
                    WebLinkRow(path: LatticeConsolePath(path: "/platform/plugins"))
                } footer: {
                    FreshnessFooter(state: state, interval: 60)
                }
            }
        }
        .navigationTitle("Plugin trust")
        .task { await load() }
        .refreshable { await load() }
    }

    private func finding(_ text: String, tone: StatusTone) -> some View {
        Label {
            Text(text).foregroundStyle(tone.word)
        } icon: {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(tone.glyph)
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        state = state.reloading
        do {
            state = .loaded(try await client.fetchPluginTrust(), at: Date())
        } catch {
            state = state.failing(LatticeAPIError(error), surface: "Plugin trust")
        }
    }
}
