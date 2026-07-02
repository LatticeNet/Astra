import SwiftUI
import Charts

/// Rich detail for a single node. Bound to the node id so it always reflects the
/// latest poll snapshot from the model rather than a stale captured value.
struct NodeDetailView: View {
    @EnvironmentObject private var model: DashboardModel
    var nodeID: String

    @State private var showRotateConfirm = false
    @State private var tokenResult: NodeTokenResponse?
    @State private var working = false

    private var node: LatticeNode? { model.node(withID: nodeID) }

    var body: some View {
        ScrollView {
            if let node {
                VStack(spacing: 16) {
                    header(node)
                    liveCharts(node)
                    quickFacts(node)
                    networkCard(node)
                    hostFactsCard(node)
                    if let geo = node.geo { geoCard(geo) }
                    actionsCard(node)
                }
                .padding(16)
            } else {
                AstraEmptyStateView(title: "Node unavailable", systemImage: "questionmark.folder", message: "This node is no longer in the latest snapshot.")
                    .padding(.top, 60)
            }
        }
        .navigationTitle(node?.displayName ?? nodeID)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh() }
        .sheet(item: $tokenResult) { result in
            TokenRevealSheet(title: "New node token", token: result.token, command: result.command)
        }
        .confirmationDialog("Rotate this node's token?", isPresented: $showRotateConfirm, titleVisibility: .visible) {
            Button("Rotate token", role: .destructive) {
                Task {
                    working = true
                    tokenResult = await model.rotateNodeToken(nodeID: nodeID)
                    working = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The existing agent token stops working immediately. You must update the agent with the new token.")
        }
    }

    // MARK: - Sections

    private func header(_ node: LatticeNode) -> some View {
        let offline = node.isOffline(timeout: model.settings.offlineTimeout)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.displayName).font(.title2.weight(.bold))
                    Text(node.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(
                    text: node.disabled ? "Disabled" : (offline ? "Offline" : "Online"),
                    systemImage: node.disabled ? "nosign" : (offline ? "xmark.circle.fill" : "checkmark.circle.fill"),
                    color: node.disabled ? Theme.disabled : (offline ? Theme.offline : Theme.online)
                )
            }
            HStack(spacing: 18) {
                miniStat("CPU", PercentFormatter.percent(node.metrics.cpuPercent), Theme.usageColor(fraction: node.metrics.cpuPercent / 100))
                miniStat("Mem", PercentFormatter.fraction(node.memoryUsedFraction), Theme.usageColor(fraction: node.memoryUsedFraction ?? 0))
                miniStat("Disk", PercentFormatter.fraction(node.diskUsedFraction), Theme.usageColor(fraction: node.diskUsedFraction ?? 0))
                if node.metrics.uptimeSeconds > 0 {
                    miniStat("Up", UptimeFormatter.string(seconds: node.metrics.uptimeSeconds), Theme.accent)
                }
            }
        }
        .latticeCard(padding: 18)
    }

    private func miniStat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .rounded).weight(.semibold)).foregroundStyle(color)
        }
    }

    private func liveCharts(_ node: LatticeNode) -> some View {
        let samples = model.samples(forNode: node.id)
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeaderView("Live trends", systemImage: "chart.xyaxis.line", accessory: samples.count >= 2 ? "\(samples.count) pts" : nil)
            chartRow("CPU", color: Theme.warning) { Sparkline(samples: samples, keyPath: \.cpu.normalizedToHundred, color: Theme.warning) }
            chartRow("Memory", color: Theme.secondary) { Sparkline(samples: samples, keyPath: \.memory, color: Theme.secondary) }
            chartRow("Disk", color: Theme.violet) { Sparkline(samples: samples, keyPath: \.disk, color: Theme.violet) }
        }
        .latticeCard()
    }

    private func chartRow<Content: View>(_ title: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func quickFacts(_ node: LatticeNode) -> some View {
        VStack(spacing: 0) {
            DetailRow(label: "Load (1/5/15m)", value: loadAverageText(node.metrics))
            Divider()
            DetailRow(label: "Memory", value: "\(ByteFormatter.bytes(node.metrics.memoryUsed)) / \(ByteFormatter.bytes(memoryTotal(node)))")
            Divider()
            DetailRow(label: "Disk", value: "\(ByteFormatter.bytes(node.metrics.diskUsed)) / \(ByteFormatter.bytes(node.metrics.diskTotal))")
            Divider()
            DetailRow(label: "Net ↓ / ↑", value: networkText(node.metrics))
            if let lastSeen = node.lastSeen {
                Divider()
                DetailRow(label: "Last seen", value: RelativeDateFormatter.string(from: lastSeen))
            }
        }
        .latticeCard()
    }

    private func loadAverageText(_ metrics: LatticeMetrics) -> String {
        String(format: "%.2f / %.2f / %.2f", metrics.load1, metrics.load5, metrics.load15)
    }

    private func networkText(_ metrics: LatticeMetrics) -> String {
        if metrics.netRxSpeed > 0 || metrics.netTxSpeed > 0 {
            return "\(ByteFormatter.speed(metrics.netRxSpeed)) / \(ByteFormatter.speed(metrics.netTxSpeed))"
        }
        return "\(ByteFormatter.bytes(metrics.netRxBytes)) / \(ByteFormatter.bytes(metrics.netTxBytes))"
    }

    private func networkCard(_ node: LatticeNode) -> some View {
        VStack(spacing: 0) {
            SectionHeaderView("Network", systemImage: "network").padding(.bottom, 4)
            group(rows: [
                node.publicIP.map { ("Public IP", $0) },
                node.publicIPv6.map { ("Public IPv6", $0) },
                node.wireGuardIP.map { ("WireGuard IP", $0) },
                node.wireGuardEndpoint.map { ("WG endpoint", $0) },
                node.wireGuardPort.map { ("WG port", String($0)) },
                node.agentVersion.map { ("Agent", $0) },
                node.role.map { ("Role", $0) }
            ])
        }
        .latticeCard()
    }

    private func hostFactsCard(_ node: LatticeNode) -> some View {
        let facts = node.hostFacts
        return VStack(spacing: 0) {
            SectionHeaderView("Host", systemImage: "cpu").padding(.bottom, 4)
            group(rows: [
                facts.hostname.map { ("Hostname", $0) },
                facts.os.map { ("OS", $0) },
                facts.platform.map { p in ("Platform", "\(p) \(facts.platformVersion ?? "")".trimmingCharacters(in: .whitespaces)) },
                facts.kernelVersion.map { ("Kernel", $0) },
                facts.arch.map { ("Arch", $0) },
                facts.cpuModel.map { ("CPU", "\($0) (\(facts.cpuCores) cores)") },
                facts.memoryTotal > 0 ? ("Memory", ByteFormatter.bytes(facts.memoryTotal)) : nil,
                facts.virtualization.map { ("Virtualization", $0) }
            ])
        }
        .latticeCard()
    }

    private func geoCard(_ geo: LatticeGeo) -> some View {
        VStack(spacing: 0) {
            SectionHeaderView("Location", systemImage: "mappin.and.ellipse").padding(.bottom, 4)
            group(rows: [
                geo.city.map { ("City", $0) },
                geo.region.map { ("Region", $0) },
                geo.country.map { ("Country", $0) },
                (geo.lat != nil && geo.lon != nil) ? ("Coordinates", String(format: "%.3f, %.3f", geo.lat ?? 0, geo.lon ?? 0)) : nil
            ])
        }
        .latticeCard()
    }

    private func actionsCard(_ node: LatticeNode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView("Actions", systemImage: "wrench.and.screwdriver.fill")
            Toggle(isOn: Binding(
                get: { !node.disabled },
                set: { enabled in
                    Task { await model.setNodeDisabled(nodeID: node.id, disabled: !enabled) }
                }
            )) {
                Label("Enabled in Lattice", systemImage: "power")
            }
            .tint(Theme.online)
            .disabled(working)

            Button {
                showRotateConfirm = true
            } label: {
                Label("Rotate agent token", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Theme.warning)
            .disabled(working)

            if let url = model.dashboardURL {
                Link(destination: url) {
                    Label("Open in Lattice dashboard", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .latticeCard()
    }

    // MARK: - Helpers

    private func memoryTotal(_ node: LatticeNode) -> UInt64 {
        node.metrics.memoryTotal > 0 ? node.metrics.memoryTotal : node.hostFacts.memoryTotal
    }

    @ViewBuilder
    private func group(rows: [(String, String)?]) -> some View {
        let visible = rows.compactMap { $0 }
        if visible.isEmpty {
            Text("No data").font(.footnote).foregroundStyle(.tertiary)
        } else {
            ForEach(Array(visible.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider() }
                DetailRow(label: row.0, value: row.1, monospaced: true, copyable: true)
            }
        }
    }
}

private extension Double {
    /// MetricSample.cpu is already 0...100; the Sparkline expects 0...1.
    var normalizedToHundred: Double { self / 100 }
}
