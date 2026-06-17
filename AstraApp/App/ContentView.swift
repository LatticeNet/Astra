import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Nodes", systemImage: "server.rack")
                }

            EventsView()
                .tabItem {
                    Label("Events", systemImage: "bell.badge")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
        }
        .tint(.teal)
    }
}

struct DashboardView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        NavigationStack {
            List {
                SummarySection()

                if !model.configured {
                    Section {
                        Label("Configure a Lattice URL and credentials before starting the monitor.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Nodes") {
                    if model.nodes.isEmpty {
                        AstraEmptyStateView(
                            title: "No nodes loaded",
                            systemImage: "server.rack",
                            message: "Pull to refresh or start polling after configuration."
                        )
                    } else {
                        ForEach(model.nodes) { node in
                            NavigationLink(value: node) {
                                NodeRow(node: node)
                            }
                        }
                    }
                }

                if let lastError = model.lastError {
                    Section {
                        Label(lastError, systemImage: "xmark.octagon")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Lattice")
            .navigationDestination(for: LatticeNode.self) { node in
                ServerDetailView(node: node)
            }
            .refreshable {
                await model.refresh()
            }
            .toolbar {
                ToolbarItemGroup(placement: .automatic) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isBusy || !model.configured)

                    Button {
                        model.togglePolling()
                    } label: {
                        Image(systemName: model.isPolling ? "pause.fill" : "play.fill")
                    }
                    .disabled(!model.configured)
                }
            }
        }
    }
}

struct SummarySection: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(model.onlineCount)")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                    Text("online")
                        .foregroundStyle(.secondary)
                    Spacer()
                    StatusPill(text: model.isPolling ? "Polling" : "Stopped", systemImage: model.isPolling ? "dot.radiowaves.left.and.right" : "pause.circle", color: model.isPolling ? .teal : .secondary)
                }

                HStack(spacing: 12) {
                    SummaryMetric(title: "Total", value: "\(model.nodes.count)", color: .blue)
                    SummaryMetric(title: "Critical", value: "\(model.criticalCount)", color: model.criticalCount > 0 ? .red : .green)
                    SummaryMetric(title: "Interval", value: "\(Int(model.settings.pollInterval))s", color: .purple)
                }

                if let lastRefresh = model.lastRefresh {
                    Text("Last refresh \(lastRefresh.formatted(date: .omitted, time: .standard))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct SummaryMetric: View {
    var title: String
    var value: String
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NodeRow: View {
    @EnvironmentObject private var model: DashboardModel
    var node: LatticeNode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.displayName)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(text: statusText, systemImage: statusImage, color: statusColor)
            }

            VStack(spacing: 7) {
                MetricBar(title: "CPU", value: node.metrics.cpuPercent / 100, text: PercentFormatter.percent(node.metrics.cpuPercent), color: .orange)
                MetricBar(title: "Mem", value: node.memoryUsedFraction ?? 0, text: PercentFormatter.fraction(node.memoryUsedFraction), color: .blue)
                MetricBar(title: "Disk", value: node.diskUsedFraction ?? 0, text: PercentFormatter.fraction(node.diskUsedFraction), color: .purple)
            }
        }
        .padding(.vertical, 6)
    }

    private var subtitle: String {
        let platform = node.hostFacts.platform ?? node.hostFacts.os ?? "unknown"
        let arch = node.hostFacts.arch ?? "-"
        let ip = node.publicIP ?? node.wireGuardIP ?? node.id
        return "\(platform) · \(arch) · \(ip)"
    }

    private var isOffline: Bool {
        node.isOffline(timeout: model.settings.offlineTimeout)
    }

    private var statusText: String {
        if node.disabled {
            return "Disabled"
        }
        return isOffline ? "Offline" : "Online"
    }

    private var statusImage: String {
        if node.disabled {
            return "nosign"
        }
        return isOffline ? "xmark.circle.fill" : "checkmark.circle.fill"
    }

    private var statusColor: Color {
        if node.disabled {
            return .secondary
        }
        return isOffline ? .red : .green
    }
}

struct MetricBar: View {
    var title: String
    var value: Double
    var text: String
    var color: Color

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
            GridRow {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.14))
                        Capsule()
                            .fill(color.gradient)
                            .frame(width: proxy.size.width * min(max(value, 0), 1))
                    }
                }
                .frame(height: 7)
                Text(text)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)
            }
        }
    }
}

struct StatusPill: View {
    var text: String
    var systemImage: String
    var color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct EventsView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        NavigationStack {
            List {
                if model.events.isEmpty {
                    AstraEmptyStateView(
                        title: "No events",
                        systemImage: "bell",
                        message: "Lattice records alerts here when polling detects state changes."
                    )
                } else {
                    ForEach(model.events, id: \.timelineID) { event in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(event.title, systemImage: icon(for: event.kind))
                                    .font(.headline)
                                    .foregroundStyle(color(for: event.kind))
                                Spacer()
                                Text(event.date, style: .time)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(event.body)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
            .navigationTitle("Events")
        }
    }

    private func icon(for kind: MonitorEventKind) -> String {
        switch kind {
        case .offline: "xmark.octagon.fill"
        case .recovered: "checkmark.seal.fill"
        case .cpuCritical: "cpu.fill"
        case .memoryCritical: "memorychip.fill"
        case .diskCritical: "internaldrive.fill"
        }
    }

    private func color(for kind: MonitorEventKind) -> Color {
        switch kind {
        case .recovered: .green
        case .offline: .red
        case .cpuCritical: .orange
        case .memoryCritical: .blue
        case .diskCritical: .purple
        }
    }
}

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
                    Stepper("Poll every \(Int(model.settings.pollInterval))s", value: $model.settings.pollInterval, in: 10...300, step: 5)
                    Stepper("Offline after \(Int(model.settings.offlineTimeout))s", value: $model.settings.offlineTimeout, in: 30...1800, step: 30)
                }

                Section("Alert thresholds") {
                    ThresholdSlider(title: "CPU", value: $model.settings.cpuCritical)
                    ThresholdSlider(title: "Memory", value: $model.settings.memoryCritical)
                    ThresholdSlider(title: "Disk", value: $model.settings.diskCritical)
                    Stepper("Cooldown \(Int(model.settings.alertCooldown / 60))m", value: $model.settings.alertCooldown, in: 60...7200, step: 60)
                }

                Section("Bark") {
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
            .onAppear {
                model.reloadBackgroundRefreshStatus()
            }
            .onDisappear {
                model.saveSettings()
            }
        }
    }
}

private extension BarkInterruptionLevel {
    var settingsTitle: String {
        switch self {
        case .passive: "Passive"
        case .active: "Active"
        case .timeSensitive: "Time Sensitive"
        case .critical: "Critical"
        }
    }
}

struct AstraEmptyStateView: View {
    var title: String
    var systemImage: String
    var message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
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
            Label("Checking...", systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.footnote)
                .foregroundStyle(.red)
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
                    .foregroundStyle(.green)
            } else {
                Label(status.lastError ?? "Background refresh failed.", systemImage: "xmark.octagon.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } else if let startedAt = status.lastStartedAt {
            Label("Background refresh started \(startedAt.formatted(date: .omitted, time: .standard))", systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private extension View {
    @ViewBuilder
    func astraURLInput() -> some View {
        #if os(iOS)
        self
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
            .autocorrectionDisabled()
        #endif
    }

    @ViewBuilder
    func astraPlainInput() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
            .autocorrectionDisabled()
        #endif
    }

    @ViewBuilder
    func astraSecretInput() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
            .autocorrectionDisabled()
        #endif
    }
}
