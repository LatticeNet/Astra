import SwiftUI

/// M11-06 SSO provider. Its fields (the client secret is write-only, so only
/// whether one is stored) and what to know about it. Edit, delete and the
/// discovery test are on the web; the server keeps no test result to show.
struct SSOProviderScreen: View {
    let id: String

    @Environment(AccessStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router

    var body: some View {
        ResourceView(state: store.providers, noun: "the provider", retry: refresh) { providers in
            if let provider = providers.first(where: { $0.id == id }) {
                detail(provider, providers: providers)
            } else {
                notFound
            }
        }
        .navigationTitle(store.provider(id: id)?.title ?? "Provider")
        .navigationSubtitle(store.provider(id: id).map { StatusStyle.accountProvider($0).word.accountCapitalized } ?? "")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Copy ID", systemImage: "number") { AccountCopy.copy(id) }
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.accountSSO) }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .polling(.standard, version: changes.version([.account])) {
            await store.refreshProviders()
        }
    }

    private func detail(_ provider: AccessSSOProvider, providers: [AccessSSOProvider]) -> some View {
        let lastEnabled = provider.enabled && providers.filter(\.enabled).count == 1
        return List {
            AccountRefreshError(state: store.providers, noun: "the provider", retry: refresh)
            Section {
                AccountProviderRow(provider: provider)
                ForEach(AccessSSO.notices(provider), id: \.self) { notice in
                    AccountNoticeRow(text: notice)
                }
                if lastEnabled {
                    AccountNoticeRow(text: "The only enabled provider. Turning it off removes single sign-on from the login screen.", symbol: "info.circle", tone: .quiet)
                }
            }

            Section {
                DetailRow(label: "Display name", value: provider.displayName.isEmpty ? "None, the issuer is shown" : provider.displayName, copyable: !provider.displayName.isEmpty)
                DetailRow(label: "Issuer", value: provider.issuer, monospaced: true)
                DetailRow(label: "Client ID", value: provider.clientID, monospaced: true)
                DetailRow(label: "Client secret", value: provider.hasSecret ? "Stored, write-only" : "None", copyable: false)
                DetailRow(label: "Scopes", value: provider.scopes.isEmpty ? "Server default" : provider.scopes.joined(separator: ", "), copyable: false)
                DetailRow(label: "Allowed domains", value: AccessSSO.domains(provider), copyable: false)
                DetailRow(label: "On the login screen", value: provider.enabled ? "Offered" : "Not offered", copyable: false)
                DetailRow(label: "Authenticator code after sign-in", value: provider.skipLocalTOTP ? "Skipped" : "Asked", copyable: false)
                DetailRow(label: "Provider ID", value: provider.id, monospaced: true)
            } header: {
                Text("Provider").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("The client secret is never returned by the server.")
            }

            Section {
                WebLinkRow(title: "Test on web", path: .accountSSO)
                WebLinkRow(title: "Edit on web", path: .accountSSO)
                WebLinkRow(title: "Delete on web", path: .accountSSO)
            } header: {
                Text("Actions").accessibilityAddTraits(.isHeader)
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Last test: none recorded. The test reads the issuer's discovery document; it does not check the client ID or secret, and the server keeps no result.")
                    FreshnessFooter(state: store.providers, interval: Polling.standard.interval(lowPower: false))
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refreshProviders() }
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Provider not found", systemImage: "person.badge.key")
            } description: {
                Text("It was deleted, or this server does not hold it.")
            } actions: {
                Button("Open on web") { router.openOnWeb(.accountSSO) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func refresh() {
        Task { await store.refreshProviders() }
    }
}
