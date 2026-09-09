import SwiftUI

/// Glance for a single node: honesty, last report, SSH Guard posture, capability
/// admission, waiting tasks. Host mutation stays on the web console.
struct NodeDetailView: View {
    @EnvironmentObject private var model: DashboardModel
    var nodeID: String

    @State private var cancellingTaskID: String?

    private var node: LatticeNode? { model.node(withID: nodeID) }
    private var glanceKey: String { "glance.\(nodeID)" }

    var body: some View {
        List {
            if let node {
                headerSection(node)
                factsSection(node)
                sshGuardSection
                capabilitiesSection
                tasksSection(node)
                if let error = model.error(for: glanceKey) {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.warning)
                    }
                }
                webSection
            } else {
                Section {
                    AstraEmptyStateView(
                        title: "Node unavailable",
                        systemImage: "questionmark.folder",
                        message: "This node is no longer in the latest snapshot."
                    )
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(node?.displayName ?? nodeID)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await model.refresh()
            await model.loadNodeGlance(nodeID: nodeID)
        }
        .task {
            await model.loadNodeGlance(nodeID: nodeID)
        }
    }

    private func headerSection(_ node: LatticeNode) -> some View {
        let word = node.honestyWord
        return Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.displayName).font(.headline)
                    Text(node.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(
                    text: word,
                    systemImage: model.honestyImage(word),
                    color: Theme.honestyColor(word)
                )
            }
            if !node.statusReason.isEmpty {
                Text(node.statusReason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                miniStat("CPU", PercentFormatter.percent(node.metrics.cpuPercent))
                miniStat("Mem", PercentFormatter.fraction(node.memoryUsedFraction))
                miniStat("Disk", PercentFormatter.fraction(node.diskUsedFraction))
            }
        }
    }

    private func miniStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .rounded).weight(.semibold))
        }
    }

    private func factsSection(_ node: LatticeNode) -> some View {
        Section {
            if let lastSeen = node.lastSeen {
                DetailRow(label: "Last report", value: RelativeDateFormatter.string(from: lastSeen))
            } else {
                DetailRow(label: "Last report", value: "never")
            }
            if let since = node.statusSince {
                DetailRow(label: "Status since", value: RelativeDateFormatter.string(from: since))
            }
            DetailRow(label: "Agent", value: node.agentVersion ?? "unknown", monospaced: true)
            if let role = node.role, !role.isEmpty {
                DetailRow(label: "Role", value: role)
            }
            if let ip = node.publicIP, !ip.isEmpty {
                DetailRow(label: "Public IP", value: ip, monospaced: true, copyable: true)
            }
            if let ip = node.wireGuardIP, !ip.isEmpty {
                DetailRow(label: "WireGuard IP", value: ip, monospaced: true, copyable: true)
            }
            DetailRow(label: "Load (1/5/15m)", value: String(format: "%.2f / %.2f / %.2f", node.metrics.load1, node.metrics.load5, node.metrics.load15))
            if let hostname = node.hostFacts.hostname, !hostname.isEmpty {
                DetailRow(label: "Hostname", value: hostname, monospaced: true)
            }
            if let platform = node.hostFacts.platform ?? node.hostFacts.os {
                DetailRow(label: "Platform", value: "\(platform) \(node.hostFacts.platformVersion ?? "")".trimmingCharacters(in: .whitespaces))
            }
        } header: {
            Text("Facts")
        }
    }

    @ViewBuilder
    private var sshGuardSection: some View {
        let status = model.sshGuardByNode[nodeID]
        Section {
            if model.isLoading(glanceKey), status == nil {
                InlineStatusView(isLoading: true, error: nil)
            } else if let status {
                DetailRow(label: "Enrolled", value: status.enrolled ? "yes" : "no")
                DetailRow(label: "Posture", value: status.posture.state.isEmpty ? "unknown" : status.posture.state)
                DetailRow(label: "Key access", value: status.posture.keyAccess ? "yes" : "no")
                if !status.posture.reason.isEmpty {
                    Text(status.posture.reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let sshd = status.sshd {
                    DetailRow(label: "sshd ports", value: sshd.ports.isEmpty ? "-" : sshd.ports.map(String.init).joined(separator: ", "))
                    DetailRow(label: "Password auth", value: sshd.passwordAuthentication ? "on" : "off")
                    DetailRow(label: "Pubkey auth", value: sshd.pubkeyAuthentication ? "on" : "off")
                    if !sshd.permitRootLogin.isEmpty {
                        DetailRow(label: "PermitRootLogin", value: sshd.permitRootLogin)
                    }
                } else if !status.sshdNote.isEmpty {
                    Text(status.sshdNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                DetailRow(label: "Knock gate", value: status.knockGate ? "armed" : "off")
                if !status.stage.isEmpty {
                    DetailRow(label: "Stage", value: status.stage)
                }
                Text("Knock reveal and arm/confirm stay on the web console. Confirm is a second plan, not a duplicate of arm.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !status.actionableApprovalID.isEmpty {
                    Button("Open related plan") {
                        model.openReview(id: status.actionableApprovalID)
                    }
                }
            } else {
                Text("SSH Guard status is not available for this node.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("SSH Guard")
        }
    }

    @ViewBuilder
    private var capabilitiesSection: some View {
        let caps = model.capabilitiesByNode[nodeID] ?? []
        Section {
            if caps.isEmpty {
                Text("No capability admission facts loaded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(caps) { cap in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(cap.capability)
                                .font(.subheadline.monospaced())
                            Spacer()
                            StatusPill(
                                text: cap.allowed ? "allowed" : "denied",
                                systemImage: cap.allowed ? "checkmark.circle.fill" : "xmark.circle.fill",
                                color: cap.allowed ? Theme.online : Theme.offline
                            )
                        }
                        if !cap.reason.isEmpty {
                            Text(cap.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(cap.source.isEmpty ? "policy" : cap.source)\(cap.enforced ? " · enforced" : "")")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Capabilities")
        }
    }

    private func tasksSection(_ node: LatticeNode) -> some View {
        let related = model.tasks.filter { task in
            task.targets.contains(node.id) || (!task.leasedBy.isEmpty && task.leasedBy == node.id)
        }
        let waiting = model.waitingApprovals.filter { $0.nodeID == node.id }
        return Section {
            if related.isEmpty && waiting.isEmpty {
                Text("No waiting tasks.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(waiting) { approval in
                    Button {
                        model.openReview(id: approval.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(approval.action.isEmpty ? approval.plugin : approval.action)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(approval.waiting?.reason ?? "waiting")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(related) { task in
                    VStack(alignment: .leading, spacing: 6) {
                        TaskRow(task: task)
                        if isCancellable(task) {
                            Button("Cancel task") {
                                Task {
                                    cancellingTaskID = task.id
                                    _ = await model.cancelWaitingTask(id: task.id)
                                    cancellingTaskID = nil
                                    await model.loadNodeGlance(nodeID: nodeID)
                                }
                            }
                            .disabled(cancellingTaskID != nil)
                        }
                    }
                }
            }
        } header: {
            Text("Waiting")
        } footer: {
            Text("Script reveal and rerun stay on the web console.")
        }
    }

    private var webSection: some View {
        Section {
            if let url = model.consoleURL(forNode: nodeID) {
                Link(destination: url) {
                    Label("Open on web", systemImage: "safari")
                }
            }
        }
    }

    private func isCancellable(_ task: LatticeTask) -> Bool {
        switch task.status.lowercased() {
        case "queued", "leased", "running", "pending":
            return true
        default:
            return false
        }
    }
}
