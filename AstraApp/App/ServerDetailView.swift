import SwiftUI

struct ServerDetailView: View {
    @EnvironmentObject private var model: DashboardModel
    var node: LatticeNode

    var body: some View {
        List {
            Section {
                LabeledContent("Status", value: statusText)
                LabeledContent("Node ID", value: node.id)
                LabeledContent("Role", value: node.role ?? "-")
                LabeledContent("Agent", value: node.agentVersion ?? "-")
                if let lastSeen = node.lastSeen {
                    LabeledContent("Last seen", value: lastSeen.formatted(date: .abbreviated, time: .standard))
                }
                if !node.tags.isEmpty {
                    LabeledContent("Tags", value: node.tags.joined(separator: ", "))
                }
            }

            Section("Utilization") {
                DetailMetric(title: "CPU", value: node.metrics.cpuPercent / 100, text: PercentFormatter.percent(node.metrics.cpuPercent), color: .orange)
                DetailMetric(title: "Memory", value: node.memoryUsedFraction ?? 0, text: memoryText, color: .blue)
                DetailMetric(title: "Disk", value: node.diskUsedFraction ?? 0, text: diskText, color: .purple)
                LabeledContent("Load 1", value: formatted(node.metrics.load1))
                LabeledContent("Uptime", value: DurationFormatter.seconds(TimeInterval(node.metrics.uptimeSeconds)))
                if let collectedAt = node.metrics.collectedAt {
                    LabeledContent("Collected", value: collectedAt.formatted(date: .omitted, time: .standard))
                }
            }

            Section("Network") {
                LabeledContent("Public IPv4", value: node.publicIP ?? "-")
                LabeledContent("Public IPv6", value: node.publicIPv6 ?? "-")
                LabeledContent("WireGuard IP", value: node.wireGuardIP ?? "-")
                LabeledContent("WireGuard endpoint", value: node.wireGuardEndpoint ?? "-")
                if let port = node.wireGuardPort {
                    LabeledContent("WireGuard port", value: "\(port)")
                }
                LabeledContent("RX total", value: ByteFormatter.bytes(node.metrics.netRxBytes))
                LabeledContent("TX total", value: ByteFormatter.bytes(node.metrics.netTxBytes))
            }

            Section("Host") {
                LabeledContent("Hostname", value: node.hostFacts.hostname ?? "-")
                LabeledContent("OS", value: node.hostFacts.os ?? "-")
                LabeledContent("Platform", value: platformText)
                LabeledContent("Kernel", value: node.hostFacts.kernelVersion ?? "-")
                LabeledContent("Arch", value: node.hostFacts.arch ?? "-")
                LabeledContent("CPU cores", value: node.hostFacts.cpuCores > 0 ? "\(node.hostFacts.cpuCores)" : "-")
                LabeledContent("CPU model", value: node.hostFacts.cpuModel ?? "-")
                LabeledContent("Swap total", value: node.hostFacts.swapTotal > 0 ? ByteFormatter.bytes(node.hostFacts.swapTotal) : "-")
                LabeledContent("Virtualization", value: node.hostFacts.virtualization ?? "-")
                if let reportedAt = node.hostFacts.reportedAt {
                    LabeledContent("Facts reported", value: reportedAt.formatted(date: .abbreviated, time: .standard))
                }
            }

            if let geo = node.geo {
                Section("Geo") {
                    LabeledContent("Country", value: geo.country ?? "-")
                    LabeledContent("Region", value: geo.region ?? "-")
                    LabeledContent("City", value: geo.city ?? "-")
                    if let lat = geo.lat, let lon = geo.lon {
                        LabeledContent("Coordinates", value: String(format: "%.4f, %.4f", lat, lon))
                    }
                }
            }
        }
        .navigationTitle(node.displayName)
    }

    private var statusText: String {
        if node.disabled {
            return "Disabled"
        }
        return node.isOffline(timeout: model.settings.offlineTimeout) ? "Offline" : "Online"
    }

    private var memoryText: String {
        usageText(used: node.metrics.memoryUsed, total: node.metrics.memoryTotal > 0 ? node.metrics.memoryTotal : node.hostFacts.memoryTotal, fraction: node.memoryUsedFraction)
    }

    private var diskText: String {
        usageText(used: node.metrics.diskUsed, total: node.metrics.diskTotal, fraction: node.diskUsedFraction)
    }

    private var platformText: String {
        let platform = node.hostFacts.platform ?? "-"
        guard let version = node.hostFacts.platformVersion, !version.isEmpty else {
            return platform
        }
        return "\(platform) \(version)"
    }

    private func usageText(used: UInt64, total: UInt64, fraction: Double?) -> String {
        guard total > 0 else {
            return "-"
        }
        return "\(ByteFormatter.bytes(used)) / \(ByteFormatter.bytes(total)) · \(PercentFormatter.fraction(fraction))"
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

struct DetailMetric: View {
    var title: String
    var value: Double
    var text: String
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(text)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: min(max(value, 0), 1))
                .tint(color)
        }
        .padding(.vertical, 3)
    }
}
