import SwiftUI

struct MoreHubView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        NavigationStack(path: $model.morePath) {
            List {
                if let identity = model.identity {
                    Section {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle().fill(Theme.brandGradient).frame(width: 46, height: 46)
                                Text(initials(identity.displayName))
                                    .font(.headline)
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(identity.displayName).font(.headline)
                                Text("\(identity.scopes.count) scopes\(identity.totpEnabled ? " · 2FA on" : "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("On this phone") {
                    NavigationLink { ActivityView() } label: { Label("Audit", systemImage: "list.bullet.rectangle") }
                    NavigationLink { TasksView() } label: { Label("Tasks", systemImage: "checklist") }
                    NavigationLink(value: MoreDestination.inventory) { Label("Inventory", systemImage: "shippingbox") }
                    NavigationLink(value: MoreDestination.monitors) { Label("Monitors", systemImage: "waveform.path.ecg") }
                    NavigationLink { LogsView() } label: { Label("Logs", systemImage: "doc.text.magnifyingglass") }
                    NavigationLink { NetworkView() } label: { Label("Network (read)", systemImage: "lock.shield") }
                    NavigationLink { NotificationsView() } label: { Label("Notify channels", systemImage: "bell") }
                }

                Section("Account") {
                    NavigationLink { AccountView() } label: { Label("Identity & tokens", systemImage: "person.badge.key") }
                    NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape") }
                }

                Section {
                    NavigationLink { AboutView() } label: { Label("About Lattice", systemImage: "info.circle") }
                    if let url = model.dashboardURL {
                        Link(destination: url) { Label("Open console", systemImage: "safari") }
                    }
                }
            }
            .navigationTitle("More")
            .navigationDestination(for: MoreDestination.self) { destination in
                switch destination {
                case .monitors:
                    MonitorsView()
                case .monitor(let id):
                    MonitorDetailView(monitorID: id)
                case .inventory:
                    InventoryView()
                }
            }
            .task {
                if model.configured, model.identity == nil { await model.loadAccount() }
            }
        }
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        if let first = parts.first?.first {
            if parts.count > 1, let second = parts[1].first {
                return "\(first)\(second)".uppercased()
            }
            return String(first).uppercased()
        }
        return "L"
    }
}

struct AboutView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.3x3.topleft.filled")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.brandGradient)
                    Text("Lattice").font(.title2.weight(.bold))
                    Text("Phone approval device for the Lattice control plane. Plugin authoring, Terminal, and host mutation stay on the web.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            if model.companionBehindServer {
                Section {
                    Label("Companion is behind this server. Approve stays disabled until this app can decode the approval view.", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.warning)
                }
            }

            if let version = model.serverVersion {
                Section("Server") {
                    DetailRow(label: "Version", value: version.version.isEmpty ? "unknown" : version.version)
                    if !version.shortCommit.isEmpty {
                        DetailRow(label: "Commit", value: version.shortCommit, monospaced: true)
                    }
                    if !version.date.isEmpty {
                        DetailRow(label: "Built", value: version.date)
                    }
                }
            }

            Section {
                if let url = model.dashboardURL {
                    Link(destination: url) { Label("Open web console", systemImage: "safari") }
                }
            } footer: {
                Text("Custom URL scheme lattice:// opens a plan, node, or monitor. Universal Links wait for a signed build.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model.configured, model.serverVersion == nil { await model.loadAccount() }
        }
    }
}
