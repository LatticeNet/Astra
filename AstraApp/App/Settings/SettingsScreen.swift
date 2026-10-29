import SwiftUI

/// F-03: the Settings sheet, with its own stack of `SettingsRoute`. Each
/// change applies when made, so there is no save button.
struct SettingsScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var appState = appState
        NavigationStack(path: $appState.settingsPath) {
            List {
                if session.isDemo {
                    Section {
                        NavigationLink(value: SettingsRoute.page(.demo)) {
                            SettingsRow(title: "Demo data", symbol: "theatermasks", value: session.demoScenario.title)
                        }
                    } footer: {
                        Text("Everything you see is invented.")
                    }
                }
                if session.tokenRejected {
                    Section {
                        Label("Your token was rejected", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(Color.statusFailText)
                        NavigationLink("Change credential", value: SettingsRoute.page(.connection))
                    }
                }
                Section {
                    NavigationLink(value: SettingsRoute.page(.connection)) {
                        SettingsRow(title: session.hostName, symbol: "server.rack", value: connectionSummary, titleIsIdentifier: true)
                    }
                    NavigationLink(value: SettingsRoute.page(.session)) {
                        SettingsRow(title: "Session for reveals", symbol: "person.badge.key", value: sessionSummary)
                    }
                }
                Section {
                    NavigationLink(value: SettingsRoute.page(.deviceSecurity)) {
                        SettingsRow(title: "Device security", symbol: "faceid")
                    }
                    NavigationLink(value: SettingsRoute.page(.badge)) {
                        SettingsRow(title: "Badge refresh", symbol: "app.badge", value: BackgroundRefresh.isEnabled ? "On" : "Off")
                    }
                    NavigationLink(value: SettingsRoute.page(.display)) {
                        SettingsRow(title: "Display", symbol: "clock")
                    }
                    NavigationLink(value: SettingsRoute.page(.diagnostics)) {
                        SettingsRow(title: "Diagnostics", symbol: "stethoscope")
                    }
                    NavigationLink(value: SettingsRoute.page(.about)) {
                        SettingsRow(title: "About", symbol: "info.circle")
                    }
                }
                Section("Account") {
                    NavigationLink(value: SettingsRoute.account(.security)) {
                        SettingsRow(title: "Security & 2FA", symbol: "lock")
                    }
                    NavigationLink(value: SettingsRoute.account(.access(view: nil))) {
                        SettingsRow(title: "Access", symbol: "person.2.badge.key")
                    }
                }
                Section {
                } footer: {
                    Text("Lattice \(AppVersion.display)")
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsRoute.self) { SettingsDestination(route: $0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .actionHost(inSheet: true)
        }
        .presentationDetents([.large])
    }

    private var connectionSummary: String {
        if session.isDemo { return "Demo data" }
        let credential = session.credentialKind == .session ? "Session" : "API token"
        guard let identity = session.primaryIdentity else { return credential }
        return "\(credential), \(identity.displayName), \(identity.scopes.count) scopes"
    }

    private var sessionSummary: String {
        if session.sessionExpired { return "Expired" }
        return session.revealClient == nil ? "Not signed in" : "Signed in"
    }
}

/// A Settings row: symbol, title and an optional trailing value.
private struct SettingsRow: View {
    let title: String
    let symbol: String
    var value: String?
    /// A host name wraps by character, never with an inserted hyphen, which
    /// is a legal host name character and would show a different host (4.5).
    var titleIsIdentifier = false

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xxs))
            : AnyLayout(HStackLayout(spacing: Spacing.m))
        layout {
            // At accessibility sizes the icon would squeeze the title into hyphenated fragments.
            if typeSize.isAccessibilitySize {
                Text(titleIsIdentifier ? DetailRow.breakable(title) : title)
                    .accessibilityLabel(title)
            } else {
                Label(title, systemImage: symbol)
                Spacer(minLength: Spacing.s)
            }
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
        }
        .frame(minHeight: Spacing.minimumTarget)
    }
}
