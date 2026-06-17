import SwiftUI

enum NodeFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case online = "Online"
    case offline = "Offline"
    case critical = "Critical"
    var id: String { rawValue }
}

struct NodesView: View {
    @EnvironmentObject private var model: DashboardModel
    @State private var search = ""
    @State private var filter: NodeFilter = .all
    @State private var showEnroll = false

    var body: some View {
        NavigationStack {
            List {
                if model.nodes.isEmpty {
                    Section {
                        AstraEmptyStateView(
                            title: model.configured ? "No nodes yet" : "Not connected",
                            systemImage: "server.rack",
                            message: model.configured
                                ? "Pull to refresh, or enroll a node with the + button."
                                : "Add your Lattice server in More → Settings."
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        Picker("Filter", selection: $filter) {
                            ForEach(NodeFilter.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowSeparator(.hidden)
                    }

                    Section {
                        ForEach(filteredNodes) { node in
                            NavigationLink(value: node) {
                                NodeRow(node: node)
                            }
                        }
                    } header: {
                        Text("\(filteredNodes.count) node\(filteredNodes.count == 1 ? "" : "s")")
                    }
                }

                if let lastError = model.lastError {
                    Section {
                        Label(lastError, systemImage: "xmark.octagon")
                            .font(.footnote)
                            .foregroundStyle(Theme.offline)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Nodes")
            .searchable(text: $search, prompt: "Search nodes, tags, IP")
            .navigationDestination(for: LatticeNode.self) { node in
                NodeDetailView(nodeID: node.id)
            }
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showEnroll = true } label: { Image(systemName: "plus") }
                        .disabled(!model.configured)
                    Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(model.isBusy || !model.configured)
                }
            }
            .sheet(isPresented: $showEnroll) {
                EnrollNodeView()
            }
        }
    }

    private var filteredNodes: [LatticeNode] {
        let timeout = model.settings.offlineTimeout
        return model.nodes.filter { node in
            let matchesSearch: Bool = {
                guard !search.isEmpty else { return true }
                let haystack = ([node.id, node.name, node.publicIP ?? "", node.wireGuardIP ?? "", node.role ?? ""] + node.tags)
                    .joined(separator: " ").lowercased()
                return haystack.contains(search.lowercased())
            }()
            guard matchesSearch else { return false }
            switch filter {
            case .all: return true
            case .online: return !node.isOffline(timeout: timeout)
            case .offline: return node.isOffline(timeout: timeout)
            case .critical: return model.criticalNodes.contains { $0.id == node.id }
            }
        }
    }
}

// MARK: - Node row (shared across Overview & Nodes)

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
                        .lineLimit(1)
                }
                Spacer()
                StatusPill(text: statusText, systemImage: statusImage, color: statusColor)
            }

            if !node.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(node.tags.prefix(4), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Theme.secondary.opacity(0.14), in: Capsule())
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }

            VStack(spacing: 7) {
                MetricBar(title: "CPU", value: node.metrics.cpuPercent / 100, text: PercentFormatter.percent(node.metrics.cpuPercent), color: Theme.usageColor(fraction: node.metrics.cpuPercent / 100))
                MetricBar(title: "Mem", value: node.memoryUsedFraction ?? 0, text: PercentFormatter.fraction(node.memoryUsedFraction), color: Theme.usageColor(fraction: node.memoryUsedFraction ?? 0))
                MetricBar(title: "Disk", value: node.diskUsedFraction ?? 0, text: PercentFormatter.fraction(node.diskUsedFraction), color: Theme.usageColor(fraction: node.diskUsedFraction ?? 0))
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

    private var isOffline: Bool { node.isOffline(timeout: model.settings.offlineTimeout) }
    private var statusText: String { node.disabled ? "Disabled" : (isOffline ? "Offline" : "Online") }
    private var statusImage: String { node.disabled ? "nosign" : (isOffline ? "xmark.circle.fill" : "checkmark.circle.fill") }
    private var statusColor: Color { node.disabled ? Theme.disabled : (isOffline ? Theme.offline : Theme.online) }
}
