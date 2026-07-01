import SwiftUI

/// Network & security read-only surface: pending approvals (with a gated
/// approve), per-node NetPolicy rules + a reachability view, nft baseline
/// inputs, and Cloudflare tunnel topology. Dangerous authoring (creating
/// policies, planning nft/wireguard, applying) stays on the web dashboard;
/// the one write action here is approving an already-reviewed plan.
///
/// Pushed inside MoreHub's NavigationStack — not wrapped in its own.
struct NetworkView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        List {
            approvalsSection
            policiesSection
            reachabilitySection
            nftSection
            tunnelsSection

            Section {
                InlineStatusView(isLoading: model.isLoading("network"), error: model.error(for: "network"))
            } footer: {
                Text("Read-only. Authoring network policy, nft/WireGuard plans, and tunnels stays on the web dashboard. Approving here applies an already-reviewed plan.")
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Network")
        .task { if model.configured { await model.loadNetwork() } }
        .refreshable { await model.loadNetwork() }
    }

    // MARK: - Approvals

    @ViewBuilder
    private var approvalsSection: some View {
        let pending = model.approvals.filter { $0.isPending }
        let others = model.approvals.filter { !$0.isPending }
        Section {
            if model.approvals.isEmpty {
                if !model.isLoading("network") {
                    Text("No approvals.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(pending) { approval in
                    NavigationLink { ApprovalDetailView(approvalID: approval.id) } label: { ApprovalRow(approval: approval) }
                }
                ForEach(others.prefix(8)) { approval in
                    NavigationLink { ApprovalDetailView(approvalID: approval.id) } label: { ApprovalRow(approval: approval) }
                }
            }
        } header: {
            SectionHeaderView(
                "Approvals",
                systemImage: "checkmark.shield.fill",
                accessory: model.pendingApprovalCount > 0 ? "\(model.pendingApprovalCount) pending" : nil
            )
        }
    }

    // MARK: - Policies

    @ViewBuilder
    private var policiesSection: some View {
        Section {
            if model.netPolicies.isEmpty {
                if !model.isLoading("network") {
                    Text("No network policies.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.netPolicies) { policy in
                    NavigationLink { NetPolicyDetailView(policyID: policy.id) } label: { NetPolicyRow(policy: policy) }
                }
            }
        } header: {
            SectionHeaderView("Network policies", systemImage: "lock.shield", accessory: model.netPolicies.isEmpty ? nil : "\(model.netPolicies.count)")
        }
    }

    // MARK: - Reachability

    @ViewBuilder
    private var reachabilitySection: some View {
        if let graph = model.netGraph, !graph.isEmpty {
            Section {
                NavigationLink { ReachabilityGraphView() } label: {
                    HStack {
                        Label("Reachability map", systemImage: "point.3.connected.trianglepath.dotted")
                        Spacer()
                        Text("\(graph.edges.count + graph.externals.count) edges")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - nft inputs

    @ViewBuilder
    private var nftSection: some View {
        if !model.nftInputs.isEmpty {
            Section {
                ForEach(model.nftInputs) { inputs in
                    NavigationLink { NFTInputsDetailView(nodeID: inputs.nodeID) } label: { NFTInputsRow(inputs: inputs) }
                }
            } header: {
                SectionHeaderView("nft baseline", systemImage: "shield.lefthalf.filled", accessory: "\(model.nftInputs.count)")
            }
        }
    }

    // MARK: - Tunnels

    @ViewBuilder
    private var tunnelsSection: some View {
        if !model.tunnels.isEmpty {
            Section {
                ForEach(model.tunnels) { tunnel in
                    NavigationLink { TunnelDetailView(tunnelID: tunnel.id) } label: { TunnelRow(tunnel: tunnel) }
                }
            } header: {
                SectionHeaderView("Cloudflare tunnels", systemImage: "arrow.triangle.branch", accessory: "\(model.tunnels.count)")
            }
        }
    }
}

// MARK: - Rows

struct ApprovalRow: View {
    var approval: Approval

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if approval.isStale {
                    StatusPill(text: "stale", systemImage: "exclamationmark.triangle.fill", color: Theme.warning)
                }
                StatusPill(text: approval.status.isEmpty ? "unknown" : approval.status, systemImage: statusIcon, color: statusColor)
                Spacer(minLength: 8)
                if let created = approval.createdAt {
                    Text(RelativeDateFormatter.string(from: created))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(approval.action.isEmpty ? approval.plugin : approval.action)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Label("\(approval.plugin) · \(approval.nodeID)", systemImage: "cpu")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: String {
        if approval.isStale { return "exclamationmark.triangle.fill" }
        switch approval.status.lowercased() {
        case "pending": return "clock.fill"
        case "approved": return "checkmark.seal.fill"
        case "applied": return "checkmark.circle.fill"
        case "rejected": return "xmark.octagon.fill"
        default: return "circle.dashed"
        }
    }

    private var statusColor: Color {
        if approval.isStale { return Theme.warning }
        switch approval.status.lowercased() {
        case "pending": return Theme.warning
        case "approved": return Theme.online
        case "applied": return Theme.accent
        case "rejected": return Theme.offline
        default: return Theme.secondary
        }
    }
}

struct NetPolicyRow: View {
    var policy: NetPolicy

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(policy.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                StatusPill(
                    text: policy.enabled ? "enabled" : "disabled",
                    systemImage: policy.enabled ? "checkmark.circle.fill" : "pause.circle.fill",
                    color: policy.enabled ? Theme.online : Theme.disabled
                )
            }
            Text("\(policy.activeRules.count) active rule\(policy.activeRules.count == 1 ? "" : "s")\(policy.lastError.isEmpty ? "" : " · error")")
                .font(.caption)
                .foregroundStyle(policy.lastError.isEmpty ? .secondary : Theme.offline)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

struct NFTInputsRow: View {
    var inputs: NFTInputs

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(inputs.displayName)
                .font(.subheadline.weight(.semibold))
            Text("TCP \(NFTInputs.portList(inputs.publicTCP)) · iface \(inputs.interfaceName.isEmpty ? "—" : inputs.interfaceName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

struct TunnelRow: View {
    var tunnel: TunnelProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tunnel.displayName)
                .font(.subheadline.weight(.semibold))
            Text("\(tunnel.nodeID) · \(tunnel.ingress.count) ingress")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Approval detail (gated approve)

struct ApprovalDetailView: View {
    @EnvironmentObject private var model: DashboardModel
    var approvalID: String

    @State private var queueApply = true
    @State private var confirming = false
    @State private var working = false

    private var approval: Approval? { model.approvals.first { $0.id == approvalID } }

    var body: some View {
        ScrollView {
            if let approval {
                VStack(spacing: 16) {
                    headerCard(approval)
                    if approval.isStale {
                        staleCard(approval)
                    }
                    planCard(approval)
                    if approval.isApprovable {
                        approveCard(approval)
                    }
                }
                .padding(16)
            } else {
                AstraEmptyStateView(title: "Approval unavailable", systemImage: "checkmark.shield", message: "This approval is no longer pending.")
                    .padding(.top, 60)
            }
        }
        .navigationTitle("Approval")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Approve this plan?", isPresented: $confirming, titleVisibility: .visible) {
            Button(queueApply ? "Approve & apply" : "Approve only", role: .destructive) {
                guard let approval else { return }
                Task {
                    working = true
                    _ = await model.approve(approval, queueApply: queueApply)
                    working = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(queueApply
                 ? "Lattice will apply this reviewed plan on the target node. The plan hash is checked, so a changed plan is rejected."
                 : "Marks the plan approved without queuing the apply task.")
        }
    }

    private func headerCard(_ approval: Approval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(approval.action.isEmpty ? approval.plugin : approval.action)
                    .font(.headline)
                Spacer()
                StatusPill(
                    text: approval.isStale ? "stale" : approval.status,
                    systemImage: approval.isStale ? "exclamationmark.triangle.fill" : approval.isPending ? "clock.fill" : "checkmark.seal.fill",
                    color: approval.isStale ? Theme.warning : approval.isPending ? Theme.warning : Theme.online
                )
            }
            DetailRow(label: "Plugin", value: approval.plugin)
            DetailRow(label: "Node", value: approval.nodeID, monospaced: true, copyable: true)
            if !approval.actorID.isEmpty { DetailRow(label: "Requested by", value: approval.actorID) }
            if !approval.reason.isEmpty { DetailRow(label: "Reason", value: approval.reason) }
            if let created = approval.createdAt {
                DetailRow(label: "Created", value: RelativeDateFormatter.string(from: created))
            }
        }
        .latticeCard()
    }

    private func staleCard(_ approval: Approval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView("Stale approval", systemImage: "exclamationmark.triangle.fill")
            Text("This approval no longer matches the current server policy or target state. Re-plan in the web dashboard before approving.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !approval.reason.isEmpty {
                DetailRow(label: "Server reason", value: approval.reason)
            }
            if !approval.staleCode.isEmpty {
                DetailRow(label: "Stale code", value: approval.staleCode, monospaced: true, copyable: true)
            }
        }
        .latticeCard()
    }

    private func planCard(_ approval: Approval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeaderView("Reviewed plan", systemImage: "doc.plaintext")
            Text(approval.plan.isEmpty ? "(empty plan)" : approval.plan)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .textSelection(.enabled)
            DetailRow(label: "Plan SHA-256", value: String(approval.planHash.prefix(16)) + "…", monospaced: true, copyable: true)
        }
        .latticeCard()
    }

    private func approveCard(_ approval: Approval) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView("Approve", systemImage: "checkmark.shield.fill")
            Toggle(isOn: $queueApply) {
                Label("Queue apply after approval", systemImage: "bolt.fill")
            }
            .tint(Theme.accent)
            Button {
                confirming = true
            } label: {
                HStack {
                    if working { ProgressView() }
                    Label("Approve plan", systemImage: "checkmark.seal.fill")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.online)
            .disabled(working || !approval.isApprovable)
            Text("The app sends the SHA-256 of the plan above; the server rejects approval if the plan changed since it was reviewed.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .latticeCard()
    }
}

// MARK: - NetPolicy detail

struct NetPolicyDetailView: View {
    @EnvironmentObject private var model: DashboardModel
    var policyID: String

    private var policy: NetPolicy? { model.netPolicies.first { $0.id == policyID } }

    var body: some View {
        ScrollView {
            if let policy {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(policy.displayName).font(.headline)
                            Spacer()
                            StatusPill(
                                text: policy.enabled ? "enabled" : "disabled",
                                systemImage: policy.enabled ? "checkmark.circle.fill" : "pause.circle.fill",
                                color: policy.enabled ? Theme.online : Theme.disabled
                            )
                        }
                        DetailRow(label: "Target node", value: policy.targetNodeID, monospaced: true, copyable: true)
                        if !policy.lastError.isEmpty {
                            Label(policy.lastError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.offline)
                        }
                        if let updated = policy.updatedAt {
                            DetailRow(label: "Updated", value: RelativeDateFormatter.string(from: updated))
                        }
                    }
                    .latticeCard()

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeaderView("Rules", systemImage: "list.number", accessory: "\(policy.rules.count)")
                        if policy.rules.isEmpty {
                            Text("No rules.").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            ForEach(policy.rules) { rule in
                                NetRuleRowView(rule: rule)
                                if rule.id != policy.rules.last?.id { Divider() }
                            }
                        }
                    }
                    .latticeCard()
                }
                .padding(16)
            } else {
                AstraEmptyStateView(title: "Policy unavailable", systemImage: "lock.shield", message: "This policy is no longer present.")
                    .padding(.top, 60)
            }
        }
        .navigationTitle(policy?.displayName ?? "Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NetRuleRowView: View {
    var rule: NetRule

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: rule.direction.lowercased() == "ingress" ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill")
                .foregroundStyle(rule.isAllow ? Theme.online : Theme.offline)
                .opacity(rule.disabled ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.isAllow ? "ALLOW" : "DENY")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(rule.isAllow ? Theme.online : Theme.offline)
                    Text(rule.direction)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if rule.disabled {
                        Text("disabled").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Text("\(rule.proto.uppercased()) · \(rule.portsText) → \(rule.remote.displayText)")
                    .font(.caption.monospaced())
                    .lineLimit(2)
                if !rule.comment.isEmpty {
                    Text(rule.comment).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .opacity(rule.disabled ? 0.55 : 1)
    }
}

// MARK: - Reachability graph (readable adjacency view)

struct ReachabilityGraphView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        List {
            if let graph = model.netGraph, !graph.isEmpty {
                ForEach(graph.nodes) { node in
                    let outgoing = graph.edges.filter { $0.from == node.id }
                    let externals = graph.externals.filter { $0.targetNodeID == node.id }
                    if !outgoing.isEmpty || !externals.isEmpty {
                        Section {
                            ForEach(outgoing) { edge in
                                edgeRow(
                                    icon: "arrow.right",
                                    allow: edge.isAllow,
                                    title: "→ \(nodeName(edge.to, in: graph))",
                                    detail: "\(edge.direction) · \(edge.proto.uppercased()) · \(portsText(edge.ports))"
                                )
                            }
                            ForEach(externals) { ext in
                                edgeRow(
                                    icon: "globe",
                                    allow: ext.isAllow,
                                    title: ext.remote,
                                    detail: "\(ext.direction) · \(ext.proto.uppercased()) · \(portsText(ext.ports))"
                                )
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Circle().fill(node.online ? Theme.online : Theme.offline).frame(width: 8, height: 8)
                                Text(node.displayName)
                            }
                        }
                    }
                }
            } else {
                Section {
                    AstraEmptyStateView(title: "No reachability data", systemImage: "point.3.connected.trianglepath.dotted", message: "No network policy edges to visualize.")
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Reachability")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func edgeRow(icon: String, allow: Bool, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(allow ? Theme.online : Theme.offline)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).lineLimit(1)
                Text(detail).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(allow ? "allow" : "deny")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(allow ? Theme.online : Theme.offline)
        }
        .padding(.vertical, 2)
    }

    private func nodeName(_ id: String, in graph: NetGraph) -> String {
        graph.nodes.first { $0.id == id }?.displayName ?? id
    }

    private func portsText(_ ports: [Int]) -> String {
        ports.isEmpty ? "all ports" : ports.map(String.init).joined(separator: ",")
    }
}

// MARK: - nft inputs detail

struct NFTInputsDetailView: View {
    @EnvironmentObject private var model: DashboardModel
    var nodeID: String

    private var inputs: NFTInputs? { model.nftInputs.first { $0.nodeID == nodeID } }

    var body: some View {
        ScrollView {
            if let inputs {
                VStack(spacing: 16) {
                    VStack(spacing: 0) {
                        SectionHeaderView("Interface", systemImage: "network").padding(.bottom, 4)
                        DetailRow(label: "Interface", value: inputs.interfaceName.isEmpty ? "—" : inputs.interfaceName, monospaced: true)
                        Divider()
                        DetailRow(label: "WireGuard CIDR", value: inputs.wireGuardCIDR.isEmpty ? "—" : inputs.wireGuardCIDR, monospaced: true, copyable: true)
                    }
                    .latticeCard()

                    VStack(spacing: 0) {
                        SectionHeaderView("Open ports", systemImage: "shield.lefthalf.filled").padding(.bottom, 4)
                        DetailRow(label: "Public TCP", value: NFTInputs.portList(inputs.publicTCP), monospaced: true)
                        Divider()
                        DetailRow(label: "Public UDP", value: NFTInputs.portList(inputs.publicUDP), monospaced: true)
                        Divider()
                        DetailRow(label: "WireGuard TCP", value: NFTInputs.portList(inputs.wireGuardTCP), monospaced: true)
                        Divider()
                        DetailRow(label: "WireGuard UDP", value: NFTInputs.portList(inputs.wireGuardUDP), monospaced: true)
                    }
                    .latticeCard()
                }
                .padding(16)
            } else {
                AstraEmptyStateView(title: "Inputs unavailable", systemImage: "shield", message: "No nft baseline for this node.")
                    .padding(.top, 60)
            }
        }
        .navigationTitle(inputs?.displayName ?? "nft inputs")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Tunnel detail

struct TunnelDetailView: View {
    @EnvironmentObject private var model: DashboardModel
    var tunnelID: String

    private var tunnel: TunnelProfile? { model.tunnels.first { $0.id == tunnelID } }

    var body: some View {
        ScrollView {
            if let tunnel {
                VStack(spacing: 16) {
                    VStack(spacing: 0) {
                        SectionHeaderView("Tunnel", systemImage: "arrow.triangle.branch").padding(.bottom, 4)
                        DetailRow(label: "Name", value: tunnel.displayName)
                        Divider()
                        DetailRow(label: "Node", value: tunnel.nodeID, monospaced: true, copyable: true)
                        Divider()
                        DetailRow(label: "Tunnel ID", value: tunnel.tunnelID, monospaced: true, copyable: true)
                    }
                    .latticeCard()

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeaderView("Ingress", systemImage: "arrow.down.right.circle", accessory: "\(tunnel.ingress.count)")
                        if tunnel.ingress.isEmpty {
                            Text("No ingress rules.").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            ForEach(tunnel.ingress) { ingress in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ingress.hostname.isEmpty ? "(catch-all)" : ingress.hostname)
                                        .font(.subheadline.weight(.semibold))
                                    Text("→ \(ingress.service)\(ingress.path.isEmpty ? "" : " (\(ingress.path))")")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if ingress.id != tunnel.ingress.last?.id { Divider() }
                            }
                        }
                    }
                    .latticeCard()
                }
                .padding(16)
            } else {
                AstraEmptyStateView(title: "Tunnel unavailable", systemImage: "arrow.triangle.branch", message: "This tunnel is no longer present.")
                    .padding(.top, 60)
            }
        }
        .navigationTitle(tunnel?.displayName ?? "Tunnel")
        .navigationBarTitleDisplayMode(.inline)
    }
}
