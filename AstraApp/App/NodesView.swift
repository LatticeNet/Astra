import SwiftUI

enum NodeFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case needsYou = "Needs you"
    case online = "Online"
    var id: String { rawValue }
}

struct NodesView: View {
    @EnvironmentObject private var model: DashboardModel
    @State private var search = ""
    @State private var filter: NodeFilter = .all

    var body: some View {
        NavigationStack(path: $model.fleetPath) {
            List {
                if model.geoNodes.contains(where: { $0.hasCoordinate }) {
                    Section {
                        FleetMapCard(nodes: model.geoNodes.filter { $0.hasCoordinate })
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }

                if model.nodes.isEmpty {
                    Section {
                        AstraEmptyStateView(
                            title: model.configured ? "No nodes yet" : "Not connected",
                            systemImage: "server.rack",
                            message: model.configured
                                ? "Pull to refresh. Enroll stays on the web console."
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
                            NavigationLink(value: node.id) {
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
            .navigationTitle("Fleet")
            .searchable(text: $search, prompt: "Search nodes, tags, IP")
            .navigationDestination(for: String.self) { nodeID in
                NodeDetailView(nodeID: nodeID)
            }
            .refreshable {
                await model.refresh()
                await model.loadGeo()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.refresh(); await model.loadGeo() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isBusy || !model.configured)
                }
            }
            .task {
                if model.configured {
                    if model.nodes.isEmpty { await model.refresh() }
                    if model.geoNodes.isEmpty { await model.loadGeo() }
                }
            }
        }
    }

    private var filteredNodes: [LatticeNode] {
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
            case .needsYou: return node.needsAttention
            case .online: return node.honestyWord == "online"
            }
        }
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
                        .lineLimit(1)
                }
                Spacer()
                StatusPill(text: node.honestyWord, systemImage: model.honestyImage(node.honestyWord), color: Theme.honestyColor(node.honestyWord))
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
}
