import SwiftUI

/// F-04: server, console, credential and the connection check.
struct ConnectionScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(StepUpCoordinator.self) private var stepUp
    @Environment(NodeDirectory.self) private var nodes
    @Environment(AppState.self) private var appState
    @Environment(Router.self) private var router
    @State private var checks: [CheckLine] = []
    @State private var checking = false
    @State private var confirmingSignOut = false
    @State private var consoleText = ""

    struct CheckLine: Identifiable {
        let id = UUID()
        let label: String
        let ok: Bool
        let detail: String
    }

    var body: some View {
        List {
            Section("Server") {
                DetailRow(label: "Server", value: session.serverURL?.absoluteString ?? "Not set", monospaced: true)
                if !session.isDemo {
                    TextField("Console URL (defaults to the server)", text: $consoleText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(saveConsole)
                }
                if let version = session.serverVersion {
                    DetailRow(label: "Build", value: version.version.isEmpty ? version.shortCommit : "\(version.version) (\(version.shortCommit))")
                }
            }
            Section("Credential") {
                DetailRow(label: "Credential", value: credentialText, copyable: false)
                if let identity = session.primaryIdentity {
                    DetailRow(label: "Actor", value: identity.actorID, monospaced: true)
                }
                DetailRow(label: "Keychain", value: keychainText, copyable: false)
                if session.tokenRejected {
                    Label("Your token was rejected", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(Color.statusFailText)
                }
            }
            Section {
                Button {
                    Task { await check() }
                } label: {
                    HStack {
                        Text("Check connection")
                        if checking { Spacer(); ProgressView() }
                    }
                }
                .disabled(checking)
                ForEach(checks) { line in
                    StatusRow(
                        style: line.ok ? StatusStyle(word: "ok", symbol: "checkmark.circle.fill", tone: .ok)
                                       : StatusStyle(word: "failed", symbol: "xmark.circle.fill", tone: .fail),
                        title: line.label,
                        detail: line.detail
                    )
                }
            }
            Section {
                NavigationLink("Token scopes", value: SettingsRoute.page(.scopes))
                NavigationLink("Session for reveals", value: SettingsRoute.page(.session))
            }
            Section {
                if session.isDemo {
                    Button("Leave demo") {
                        stepUp.reset()
                        nodes.reset()
                        session.leaveDemo()
                    }
                } else {
                    Button("Change credential") {
                        router.dismissPresented { appState.welcomePresented = true }
                    }
                    Button("Switch to demo data") {
                        session.enterDemo(scenario: .normal)
                    }
                    Button("Sign out", role: .destructive) { confirmingSignOut = true }
                }
            }
        }
        .navigationTitle("Connection")
        .onAppear { consoleText = UserDefaults.standard.string(forKey: "session.consoleURL") ?? "" }
        .confirmationDialog("Sign out of \(session.hostName)?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                stepUp.reset()
                nodes.reset()
                Task { await session.signOut() }
            }
        } message: {
            Text("This removes the token and session from this iPhone.")
        }
    }

    private var credentialText: String {
        if session.isDemo { return "Demo data" }
        switch session.credentialKind {
        case .token: return session.revealClient == nil ? "API token" : "API token, with a session for reveals"
        case .session: return "Signed-in session"
        case nil: return "None"
        }
    }

    private var keychainText: String {
        if session.isDemo { return "Not used in demo" }
        let token = KeychainStore.hasPAT ? "token stored" : "no token"
        let kept = KeychainStore.hasKeptSession ? ", session kept" : ""
        return token + kept
    }

    private func saveConsole() {
        let trimmed = consoleText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "session.consoleURL")
        } else if let url = AstraURLNormalizer.latticeDashboardURL(from: trimmed) {
            UserDefaults.standard.set(url.absoluteString, forKey: "session.consoleURL")
            consoleText = url.absoluteString
        }
    }

    /// `/api/health`, `/api/version` and `/api/me` on each client.
    private func check() async {
        checking = true
        defer { checking = false }
        var lines: [CheckLine] = []
        for (name, client) in [("API token", session.client), ("Session", session.revealClient)] {
            guard let client else { continue }
            let label = session.credentialKind == .session && name == "API token" ? "Session" : name
            lines.append(await probe("\(label): health") { try await client.fetchHealth().status })
            lines.append(await probe("\(label): version") { try await client.fetchServerVersion().version })
            lines.append(await probe("\(label): identity") { try await client.fetchIdentity().displayName })
        }
        checks = lines
        await session.refreshIdentity()
    }

    private func probe(_ label: String, _ work: () async throws -> String) async -> CheckLine {
        do {
            return CheckLine(label: label, ok: true, detail: try await work())
        } catch {
            return CheckLine(label: label, ok: false, detail: LatticeAPIError(error).localizedDescription)
        }
    }
}
