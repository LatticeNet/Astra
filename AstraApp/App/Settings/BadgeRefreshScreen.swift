import SwiftUI
import UIKit
import UserNotifications

/// F-08: background badge refresh. Turning it on is the only place the app
/// asks for notification permission, and only for the badge (section 6.10).
struct BadgeRefreshScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @State private var enabled = BackgroundRefresh.isEnabled
    @State private var authorization: UNAuthorizationStatus = .notDetermined
    @State private var badgeAllowed = false

    var body: some View {
        List {
            Section {
                Toggle("Refresh the badge in the background", isOn: toggleBinding)
            } footer: {
                Text("The server's notify channels alert you. This only refreshes the badge when iOS allows, which may be hours apart.")
            }
            if authorization == .denied || (authorization == .authorized && !badgeAllowed) {
                Section {
                    Label("Badges are turned off for Lattice in iOS Settings.", systemImage: "app.badge")
                        .foregroundStyle(Color.statusWarnText)
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
            Section("Last background refresh") {
                if let at = BackgroundRefresh.lastRunAt {
                    DetailRow(label: "When", value: TimeDisplay.dateTime(at, mode: mode, locale: locale), copyable: false)
                    DetailRow(label: "Outcome", value: BackgroundRefresh.lastOutcome ?? "", copyable: false)
                } else {
                    Text("Not run yet").foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(blindSpots, id: \.self) { Text($0) }
            } header: {
                Text("What the badge cannot see")
            } footer: {
                Text("The badge counts approvals that need a person and open, unacknowledged warning or critical incidents.")
            }
        }
        .navigationTitle("Badge refresh")
        .task { await readAuthorization() }
    }

    private var blindSpots: [String] {
        guard let scopes = session.tokenScopes else { return ["Unknown until this token's scopes load."] }
        var lines: [String] = []
        if !scopes.allows("monitor:read") { lines.append("Incidents: this token lacks monitor:read, so the badge counts approvals only.") }
        let hidden = ApprovalVisibility.hiddenPlugins(scopes: scopes)
        if !hidden.isEmpty { lines.append("Approvals hidden from this token: \(hidden.joined(separator: ", ")).") }
        if session.credentialKind != .token { lines.append("Background refresh reads only an API token; this iPhone has none.") }
        return lines.isEmpty ? ["Nothing: this token can see every approval plugin and incident."] : lines
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { enabled },
            set: { on in
                Task {
                    if on {
                        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.badge])) ?? false
                        await readAuthorization()
                        enabled = granted
                    } else {
                        enabled = false
                    }
                    BackgroundRefresh.isEnabled = enabled
                    await BackgroundRefresh.schedule()
                }
            }
        )
    }

    private func readAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorization = settings.authorizationStatus
        badgeAllowed = settings.badgeSetting == .enabled
    }
}
