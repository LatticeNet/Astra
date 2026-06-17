import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        NavigationStack {
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

                Section("Alert thresholds") {
                    ThresholdSlider(title: "CPU", value: $model.settings.cpuCritical)
                    ThresholdSlider(title: "Memory", value: $model.settings.memoryCritical)
                    ThresholdSlider(title: "Disk", value: $model.settings.diskCritical)
                    Stepper("Cooldown \(Int(model.settings.alertCooldown / 60))m", value: $model.settings.alertCooldown, in: 60...7200, step: 60)
                }

                Section {
                    Toggle("Send Bark notifications", isOn: $model.settings.notificationsEnabled)
                    Toggle("Best-effort background refresh", isOn: $model.settings.backgroundRefreshEnabled)
                    BackgroundRefreshStatusView(status: model.backgroundRefreshStatus)
                    TextField("Bark server", text: $model.settings.barkServerURL)
                        .astraURLInput()
                    SecureField("Device key", text: $model.barkDeviceKey)
                        .astraSecretInput()
                    TextField("Group", text: $model.settings.barkGroup)
                    TextField("Sound", text: $model.settings.barkSound)
                    Picker("Notification level", selection: $model.settings.barkLevel) {
                        ForEach(BarkInterruptionLevel.allCases, id: \.self) { level in
                            Text(level.settingsTitle).tag(level)
                        }
                    }
                    Button {
                        Task { await model.sendTestBark() }
                    } label: {
                        Label("Send test notification", systemImage: "paperplane.fill")
                    }
                    ConnectionStatusView(state: model.barkCheckState)
                } header: {
                    Text("Bark notifications")
                } footer: {
                    Text("iOS limits reliable 24/7 background polling. Bark alerts here are best-effort personal reminders; keep serious always-on alerting on the server.")
                }

                Section {
                    Button {
                        model.saveSettings()
                        Task { await model.refresh(sendNotifications: false) }
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
}

// MARK: - Settings helpers

extension BarkInterruptionLevel {
    var settingsTitle: String {
        switch self {
        case .passive: "Passive"
        case .active: "Active"
        case .timeSensitive: "Time Sensitive"
        case .critical: "Critical"
        }
    }
}

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
