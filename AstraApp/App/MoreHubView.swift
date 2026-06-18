import SwiftUI

struct MoreHubView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        NavigationStack {
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

                Section("Control plane") {
                    NavigationLink { ActivityView() } label: { Label("Activity & audit", systemImage: "list.bullet.rectangle") }
                    NavigationLink { NetworkView() } label: {
                        HStack {
                            Label("Network & security", systemImage: "lock.shield")
                            if model.pendingApprovalCount > 0 {
                                Spacer()
                                Text("\(model.pendingApprovalCount)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Theme.warning, in: Capsule())
                            }
                        }
                    }
                    NavigationLink { NotificationsView() } label: { Label("Notifications", systemImage: "bell.badge") }
                    NavigationLink { LogsView() } label: { Label("Logs", systemImage: "doc.text.magnifyingglass") }
                    NavigationLink { TasksView() } label: { Label("Tasks", systemImage: "terminal") }
                }

                Section("Account") {
                    NavigationLink { AccountView() } label: { Label("Identity & tokens", systemImage: "person.badge.key") }
                    NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape") }
                }

                Section {
                    NavigationLink { AboutView() } label: { Label("About Lattice", systemImage: "info.circle") }
                }
            }
            .navigationTitle("More")
            .task {
                if model.configured, model.identity == nil { await model.loadAccount() }
            }
            .task {
                if model.configured, model.approvals.isEmpty { await model.loadNetwork() }
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
                    Text("Phone-first client for your self-hosted Lattice control plane.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
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
                    Link(destination: url) { Label("Open web dashboard", systemImage: "safari") }
                }
            } footer: {
                Text("Advanced operator surfaces (network policy, proxy, DNS, storage, plugins) remain on the web dashboard.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
