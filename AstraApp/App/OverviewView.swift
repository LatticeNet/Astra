import SwiftUI
import MapKit

struct OverviewView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !model.configured {
                        notConfiguredCard
                    }

                    FleetHealthCard()

                    statGrid

                    if model.geoNodes.contains(where: { $0.hasCoordinate }) {
                        FleetMapCard(nodes: model.geoNodes.filter { $0.hasCoordinate })
                    }

                    criticalSection

                    recentActivitySection

                    if let lastRefresh = model.lastRefresh {
                        Text("Updated \(RelativeDateFormatter.string(from: lastRefresh))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }
            .background(backgroundGradient)
            .navigationTitle("Lattice")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        model.togglePolling()
                    } label: {
                        Image(systemName: model.isPolling ? "pause.circle.fill" : "play.circle.fill")
                    }
                    .disabled(!model.configured)
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isBusy || !model.configured)
                }
            }
            .refreshable {
                await model.refresh()
                await model.loadGeo()
                await model.loadMachines()
            }
            .task {
                if model.configured {
                    if model.nodes.isEmpty { await model.refresh(sendNotifications: false) }
                    await model.loadGeo()
                    await model.loadMachines()
                }
            }
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Theme.accent.opacity(0.08), Color.clear],
            startPoint: .top,
            endPoint: .center
        )
        .ignoresSafeArea()
    }

    private var notConfiguredCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connect to Lattice", systemImage: "link.circle.fill")
                .font(.headline)
                .foregroundStyle(Theme.accent)
            Text("Add your Lattice server URL and a token (or log in) in More → Settings to start monitoring your fleet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .latticeCard()
    }

    private var statGrid: some View {
        let summary = model.fleetSummary
        let inventory = model.inventorySummary
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatTile(title: "Online", value: "\(summary.online)/\(summary.total)", systemImage: "bolt.horizontal.circle.fill", tint: Theme.online)
            StatTile(title: "Critical", value: "\(summary.critical)", systemImage: "exclamationmark.triangle.fill", tint: summary.critical > 0 ? Theme.critical : Theme.online)
            if let cost = inventory.primaryMonthlyCost {
                StatTile(title: "Monthly spend", value: CurrencyFormatter.string(amountMajorUnits: cost.amount, currency: cost.currency), systemImage: "creditcard.fill", tint: Theme.violet, caption: "\(inventory.machineCount) machines")
            } else {
                StatTile(title: "Avg CPU", value: PercentFormatter.percent(summary.averageCPU), systemImage: "cpu.fill", tint: Theme.secondary)
            }
            StatTile(title: "Renewals", value: "\(inventory.dueSoon.count + inventory.overdue.count)", systemImage: "calendar.badge.clock", tint: (inventory.overdue.isEmpty ? Theme.warning : Theme.critical), caption: inventory.overdue.isEmpty ? "due soon" : "\(inventory.overdue.count) overdue")
        }
    }

    @ViewBuilder
    private var criticalSection: some View {
        let critical = model.criticalNodes
        if !critical.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeaderView("Needs attention", systemImage: "exclamationmark.octagon.fill", accessory: "\(critical.count)")
                ForEach(critical.prefix(4)) { node in
                    NavigationLink(value: node) {
                        NodeRow(node: node)
                            .latticeCard()
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationDestination(for: LatticeNode.self) { node in
                NodeDetailView(nodeID: node.id)
            }
        }
    }

    @ViewBuilder
    private var recentActivitySection: some View {
        if !model.events.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeaderView("Recent alerts", systemImage: "bell.fill")
                ForEach(model.events.prefix(5), id: \.timelineID) { event in
                    EventRow(event: event)
                }
            }
            .latticeCard()
        }
    }
}

// MARK: - Fleet health hero

struct FleetHealthCard: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        let summary = model.fleetSummary
        HStack(spacing: 20) {
            RingGauge(
                fraction: summary.healthFraction,
                lineWidth: 14,
                gradient: summary.critical > 0 ? Theme.gradient(Theme.warning) : Theme.healthGradient,
                label: "\(Int((summary.healthFraction * 100).rounded()))%",
                caption: "healthy"
            )
            .frame(width: 118, height: 118)

            VStack(alignment: .leading, spacing: 10) {
                Text("Fleet health")
                    .font(.headline)
                healthRow(count: summary.online, label: "online", color: Theme.online)
                healthRow(count: summary.critical, label: "critical", color: summary.critical > 0 ? Theme.critical : .secondary)
                healthRow(count: summary.disabled, label: "disabled", color: .secondary)
                HStack(spacing: 6) {
                    Image(systemName: model.isPolling ? "dot.radiowaves.left.and.right" : "pause.circle")
                        .foregroundStyle(model.isPolling ? Theme.accent : .secondary)
                    Text(model.isPolling ? "Live polling" : "Paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .latticeCard(padding: 18)
    }

    private func healthRow(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(count)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Fleet map

struct FleetMapCard: View {
    var nodes: [NodeGeoView]
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 120)
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView("Fleet map", systemImage: "globe.americas.fill", accessory: "\(nodes.count) located")
            Map(coordinateRegion: $region, annotationItems: nodes) { node in
                MapAnnotation(coordinate: CLLocationCoordinate2D(latitude: node.geo?.lat ?? 0, longitude: node.geo?.lon ?? 0)) {
                    ZStack {
                        Circle()
                            .fill((node.online ? Theme.online : Theme.offline).opacity(0.25))
                            .frame(width: 26, height: 26)
                        Circle()
                            .fill(node.online ? Theme.online : Theme.offline)
                            .frame(width: 11, height: 11)
                    }
                }
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .allowsHitTesting(false)
        }
        .latticeCard()
        .onAppear { recenter() }
    }

    private func recenter() {
        let coords = nodes.compactMap { node -> CLLocationCoordinate2D? in
            guard let geo = node.geo, geo.lat != 0 || geo.lon != 0 else { return nil }
            return CLLocationCoordinate2D(latitude: geo.lat, longitude: geo.lon)
        }
        guard !coords.isEmpty else { return }
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(20, (lats.max()! - lats.min()!) * 1.6),
            longitudeDelta: max(20, (lons.max()! - lons.min()!) * 1.6)
        )
        region = MKCoordinateRegion(center: center, span: span)
    }
}

// MARK: - Event row (shared)

struct EventRow: View {
    var event: MonitorEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                Text(event.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(RelativeDateFormatter.string(from: event.date))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch event.kind {
        case .offline: "xmark.octagon.fill"
        case .recovered: "checkmark.seal.fill"
        case .cpuCritical: "cpu.fill"
        case .memoryCritical: "memorychip.fill"
        case .diskCritical: "internaldrive.fill"
        }
    }

    private var color: Color {
        switch event.kind {
        case .recovered: Theme.online
        case .offline: Theme.offline
        case .cpuCritical: Theme.warning
        case .memoryCritical: Theme.secondary
        case .diskCritical: Theme.violet
        }
    }
}
