import SwiftUI

/// M11-01 Security & 2FA, pushed inside the Settings sheet. Two-factor state,
/// whether enrollment is required, and the signed-in operator's passkeys.
/// Every one of these is a session endpoint: with an API token alone the
/// screen explains that and links to Session for reveals (F-06). Password,
/// TOTP and passkey enrollment are on the web.
struct SecurityScreen: View {
    @Environment(AccessStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        Group {
            if store.hasSession {
                signedIn
            } else {
                needsSession
            }
        }
        .navigationTitle("Security & 2FA")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.settingsSecurity) }
                    NavigationLink(value: SettingsRoute.page(.session)) {
                        Label("Session for reveals", systemImage: "person.badge.key")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
    }

    // MARK: Without a session

    private var needsSession: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Needs a signed-in session", systemImage: "person.badge.key")
            } description: {
                Text(session.sessionExpired
                     ? "The session expired. The server shows two-factor state and passkeys only to a signed-in session, never to an API token. Sign in again to see them."
                     : "The server shows two-factor state and passkeys only to a signed-in session, never to an API token. Sign in with your password and authenticator code to see them.")
            } actions: {
                NavigationLink(value: SettingsRoute.page(.session)) {
                    Text("Sign in for reveals")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentFill)
                if session.keepSession {
                    Button("Use the kept session") {
                        Task { await session.loadKeptSessionIfNeeded() }
                    }
                    .buttonStyle(.bordered)
                }
                Button("Open on web") { router.openOnWeb(.settingsSecurity) }
            }
        }
    }

    // MARK: Signed in

    private var signedIn: some View {
        List {
            twoFactorSection
            passkeysSection
            accountSection
            Section {
                WebLinkRow(title: "Change password on web", path: .settingsSecurity)
            } footer: {
                Text("Changing the password signs every browser session of this account out. API tokens keep working.")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await refreshAll() }
        .polling(.standard, version: changes.version([.account, .session])) {
            await refreshAll()
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        if let identity = store.sessionIdentity {
            Section {
                DetailRow(label: "Signed in as", value: identity.displayName, copyable: false)
                DetailRow(label: "Actor", value: identity.actorID, monospaced: true)
                if let expires = session.revealSession?.expiresAt {
                    TimeRow(label: "Session ends", date: expires)
                }
            } header: {
                Text("Account").accessibilityAddTraits(.isHeader)
            }
        }
    }

    @ViewBuilder
    private var twoFactorSection: some View {
        Section {
            if let identity = store.sessionIdentity {
                if case .failed(let error, _, _) = store.identity {
                    ErrorRow(message: "Could not refresh two-factor state: \(error.localizedDescription)") { refreshIdentity() }
                }
                let style = StatusStyle.accountTwoFactor(enabled: identity.totpEnabled, required: identity.mfaRequired)
                StatusRow(
                    style: style,
                    title: "Authenticator app",
                    detail: identity.totpEnabled ? "A code is asked after password sign-in" : nil,
                    reason: identity.mfaRequired
                        ? "This server requires two-factor before anything else works. Enroll on the web."
                        : (identity.totpEnabled ? nil : "Password-only sign-in is active."),
                    accessibilityPhrase: "Two-factor, \(style.word)"
                )
                if identity.totpPolicyRequired, !identity.mfaRequired {
                    DetailRow(label: "Server policy", value: "Two-factor required for every account", copyable: false)
                }
                WebLinkRow(title: identity.totpEnabled ? "Disable or reset on web" : "Set up on web", path: .settingsSecurity)
            } else if case .companionBehind(let surface) = store.identity {
                CompanionBehindRow(surface: surface)
            } else if !network.isSatisfied {
                AccountNoticeRow(text: "Not read: this iPhone is offline.", symbol: "wifi.slash")
            } else if case .failed(let error, _, _) = store.identity {
                ErrorRow(message: "Could not load two-factor state: \(error.localizedDescription)") { refreshIdentity() }
            } else {
                LoadingRows(label: "Loading two-factor state", count: 1)
            }
        } header: {
            Text("Two-factor").accessibilityAddTraits(.isHeader)
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Enrollment shows a setup key and recovery codes once, so it stays on the web.")
                if store.sessionIdentity != nil, store.identity.loadedAt != nil || isFailed(store.identity) {
                    FreshnessFooter(state: store.identity, interval: Polling.standard.interval(lowPower: false))
                }
            }
        }
    }

    private func isFailed<Value>(_ state: ResourceState<Value>) -> Bool {
        if case .failed = state { return true }
        return false
    }

    @ViewBuilder
    private var passkeysSection: some View {
        Section {
            switch store.passkeys {
            case .idle where !network.isSatisfied, .loading(nil, _) where !network.isSatisfied:
                AccountNoticeRow(text: "Not read: this iPhone is offline.", symbol: "wifi.slash")
            case .idle:
                LoadingRows(label: "Loading passkeys", count: 2)
            case .companionBehind(let surface):
                CompanionBehindRow(surface: surface)
            case .denied(let scope):
                ScopeDeniedRow(scope: scope)
            case .failed(let error, nil, _):
                ErrorRow(message: "Could not load passkeys: \(error.localizedDescription)") { refresh() }
            default:
                if let passkeys = store.passkeys.value {
                    if case .failed(let error, _, _) = store.passkeys {
                        ErrorRow(message: "Could not refresh passkeys: \(error.localizedDescription)") { refresh() }
                    }
                    if passkeys.isEmpty {
                        Text("No passkeys yet.")
                            .foregroundStyle(.secondary)
                            .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                    }
                    ForEach(AccessPasskeys.sorted(passkeys)) { passkey in
                        NavigationLink(value: SettingsRoute.account(.passkey(id: passkey.id))) {
                            AccountPasskeyRow(passkey: passkey)
                        }
                    }
                } else {
                    LoadingRows(label: "Loading passkeys", count: 2)
                }
            }
            WebLinkRow(title: "Add a passkey on web", path: .settingsSecurity)
        } header: {
            Text(store.passkeys.value.map { $0.count == 1 ? "Passkeys (1)" : "Passkeys (\($0.count))" } ?? "Passkeys")
                .accessibilityAddTraits(.isHeader)
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("A passkey signs in to the console with Face ID, Touch ID or a security key. This app cannot create one yet.")
                if case .companionBehind = store.passkeys {} else {
                    FreshnessFooter(state: store.passkeys, interval: Polling.standard.interval(lowPower: false))
                }
            }
        }
    }

    private func refresh() {
        Task { await store.refreshPasskeys() }
    }

    private func refreshIdentity() {
        Task { await store.refreshIdentity() }
    }

    @discardableResult
    private func refreshAll() async -> Bool {
        let identityRead = await store.refreshIdentity()
        let passkeysRead = await store.refreshPasskeys()
        return identityRead && passkeysRead
    }
}
