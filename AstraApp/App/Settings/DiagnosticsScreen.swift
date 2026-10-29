import SwiftUI
import UIKit

/// F-10: recent request errors, trust state, polling cadence and network path.
/// No headers, no bodies, no tokens.
struct DiagnosticsScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(NetworkMonitor.self) private var network
    @Environment(PowerMonitor.self) private var power
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @State private var errors: [RequestRecord] = []
    @State private var demoRequests: [RequestRecord] = []
    @State private var trust: PluginTrust?

    var body: some View {
        List {
            Section("State") {
                DetailRow(label: "Network", value: network.isSatisfied ? "Connected" : "Offline", copyable: false)
                DetailRow(label: "Polling", value: power.isLowPower ? "Low Power (slower)" : "Normal", copyable: false)
                DetailRow(label: "Plugin trust", value: trustText, copyable: false)
                if !session.companionBehind.isEmpty {
                    DetailRow(label: "App behind server", value: session.companionBehind.sorted().joined(separator: ", "), copyable: false)
                }
            }
            Section("Recent request errors") {
                if errors.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(errors) { record in row(record) }
            }
            if session.isDemo {
                Section("Demo requests") {
                    ForEach(demoRequests) { record in row(record) }
                }
            }
            Section {
                Button("Copy diagnostics", systemImage: "doc.on.doc") { UIPasteboard.general.string = report() }
                #if DEBUG
                NavigationLink("Status sampler", value: SettingsRoute.page(.statusSampler))
                #endif
            }
        }
        .navigationTitle("Diagnostics")
        .task { await load() }
        .refreshable { await load() }
    }

    private var trustText: String {
        guard let trust else { return "Unknown" }
        return trust.warns ? "Warns" : "Official plugins only"
    }

    private func row(_ record: RequestRecord) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack {
                Text("\(record.method) \(record.path)").textRole(.identifierInRow)
                Spacer()
                Text(record.status.map(String.init) ?? "no answer").textRole(.stamp)
            }
            Text(TimeDisplay.clock(record.at, mode: mode, locale: locale) + (record.message.isEmpty ? "" : ", \(record.message)"))
                .textRole(.footnote)
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        let snapshot = await session.diagnostics.snapshot()
        errors = snapshot.errors
        demoRequests = snapshot.demo
        trust = try? await session.client?.fetchPluginTrust()
    }

    /// A text report with every credential redacted: it lists only methods,
    /// paths, statuses and the envelope messages.
    private func report() -> String {
        var lines = [
            "Lattice diagnostics",
            "Server: \(session.isDemo ? "demo" : session.hostName)",
            "Build: \(session.serverVersion?.version ?? "unknown")",
            "Network: \(network.isSatisfied ? "connected" : "offline")",
            "Polling: \(power.isLowPower ? "low power" : "normal")",
            "Plugin trust: \(trustText)",
            "Errors:",
        ]
        lines += errors.map { "  \($0.method) \($0.path) \($0.status.map(String.init) ?? "-") \($0.message)" }
        return lines.joined(separator: "\n")
    }
}
