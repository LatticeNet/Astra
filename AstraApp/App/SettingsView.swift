import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        Form {
                Section("Lattice") {
                    TextField("Server URL", text: $model.settings.latticeBaseURL)
                        .astraURLInput()
                    SecureField("Personal access token", text: $model.latticeToken)
                        .astraSecretInput()
                    TextField("Username", text: $model.loginUsername)
                        .astraPlainInput()
                    SecureField("Password", text: $model.loginPassword)
                        .astraSecretInput()
                    SecureField("TOTP code", text: $model.loginTOTPCode)
                        .astraSecretInput()
                    Button {
                        Task { await model.loginToLattice() }
                    } label: {
                        Label("Login and save session", systemImage: "key.fill")
                    }
                    Button {
                        Task { await model.testLatticeConnection() }
                    } label: {
                        Label("Test Lattice connection", systemImage: "network")
                    }
                    ConnectionStatusView(state: model.latticeCheckState)
                    if model.identity != nil || !model.latticeToken.isEmpty || !model.latticeSessionCookie.isEmpty {
                        Button(role: .destructive) {
                            model.signOut()
                        } label: {
                            Label("Sign out / clear credentials", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }

                Section("Polling") {
                    Stepper("Poll every \(Int(model.settings.pollInterval))s", value: $model.settings.pollInterval, in: 10...300, step: 5)
                    Stepper("Offline after \(Int(model.settings.offlineTimeout))s", value: $model.settings.offlineTimeout, in: 30...1800, step: 30)
                }

                Section {
                    Toggle("Background Inbox badge", isOn: $model.settings.backgroundRefreshEnabled)
                    BackgroundRefreshStatusView(status: model.backgroundRefreshStatus)
                } header: {
                    Text("Background refresh")
                } footer: {
                    Text("The system decides if this runs. When it does, it only refreshes the Inbox badge. Always-on alerting is the Lattice server notify channel (Bark on the server), not this app.")
                }

                Section {
                    Button {
                        model.saveSettings()
                        Task { await model.refresh(); await model.refreshInbox() }
                    } label: {
                        Label("Save and refresh", systemImage: "checkmark.circle.fill")
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear { model.reloadBackgroundRefreshStatus() }
            .onDisappear { model.saveSettings() }
    }
}

// MARK: - Settings helpers

struct ThresholdSlider: View {
    var title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(PercentFormatter.percent(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: 50...100, step: 1)
        }
    }
}

struct ConnectionStatusView: View {
    var state: ConnectionCheckState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .checking:
            Label("Checking…", systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.online)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.footnote)
                .foregroundStyle(Theme.offline)
        }
    }
}

struct BackgroundRefreshStatusView: View {
    var status: BackgroundRefreshStatus

    var body: some View {
        if let lastSuccess = status.lastSuccess, let completedAt = status.lastCompletedAt {
            if lastSuccess {
                Label("Last background refresh \(completedAt.formatted(date: .omitted, time: .standard))", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.online)
            } else {
                Label(status.lastError ?? "Background refresh failed.", systemImage: "xmark.octagon.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.offline)
            }
        } else if let startedAt = status.lastStartedAt {
            Label("Background refresh started \(startedAt.formatted(date: .omitted, time: .standard))", systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

extension View {
    @ViewBuilder
    func astraURLInput() -> some View {
        #if os(iOS)
        self.keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

    @ViewBuilder
    func astraPlainInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

    @ViewBuilder
    func astraSecretInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
