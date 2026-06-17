import SwiftUI
import Charts

// MARK: - Monitors list

/// Reachability/latency probes the operator has configured on the fleet. The list
/// is the entry point into per-monitor detail and the create sheet.
struct MonitorsView: View {
    @EnvironmentObject private var model: DashboardModel
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !model.configured {
                        notConfiguredCard
                    }

                    InlineStatusView(
                        isLoading: model.isLoading("monitors"),
                        error: model.error(for: "monitors")
                    )

                    if model.monitors.isEmpty {
                        AstraEmptyStateView(
                            title: "No monitors",
                            systemImage: "dot.radiowaves.up.forward",
                            message: model.configured
                                ? "Add a TCP, HTTP, or ICMP probe to watch reachability and latency across your fleet."
                                : "Connect to Lattice in More → Settings to configure monitors."
                        )
                        .latticeCard()
                    } else {
                        VStack(spacing: 12) {
                            ForEach(model.monitors) { monitor in
                                NavigationLink {
                                    MonitorDetailView(monitorID: monitor.id)
                                } label: {
                                    MonitorRow(monitor: monitor)
                                        .latticeCard()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(backgroundGradient)
            .navigationTitle("Monitors")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!model.configured)
                }
            }
            .refreshable {
                if model.configured { await model.loadMonitors() }
            }
            .task {
                if model.configured { await model.loadMonitors() }
            }
            .sheet(isPresented: $showCreate) {
                MonitorEditView()
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
            Text("Add your Lattice server URL and a token (or log in) in More → Settings to manage monitors.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .latticeCard()
    }
}

// MARK: - Monitor row

struct MonitorRow: View {
    var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(monitor.enabled ? Theme.online : Theme.disabled)
                    .frame(width: 8, height: 8)
                Text(monitor.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                typeBadge
            }

            Text(monitor.target.isEmpty ? "—" : monitor.target)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 14) {
                Label("every \(monitor.intervalSec)s", systemImage: "timer")
                Label(assignmentText, systemImage: "server.rack")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .labelStyle(.titleAndIcon)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var typeBadge: some View {
        let type = monitor.type
        return Text(type?.displayName ?? monitor.typeRaw.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(typeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(typeColor.opacity(0.14), in: Capsule())
    }

    private var typeColor: Color {
        switch monitor.type {
        case .tcp: return Theme.secondary
        case .http: return Theme.accent
        case .icmp: return Theme.violet
        case .none: return Theme.disabled
        }
    }

    private var assignmentText: String {
        monitor.assignAll ? "all nodes" : "\(monitor.nodeIDs.count) node\(monitor.nodeIDs.count == 1 ? "" : "s")"
    }
}

// MARK: - Monitor detail

/// Per-monitor health, configuration, latency trend and the most recent checks.
/// Bound to the id so it always reflects the latest results in the model.
struct MonitorDetailView: View {
    @EnvironmentObject private var model: DashboardModel
    @Environment(\.dismiss) private var dismiss
    var monitorID: String

    @State private var showDeleteConfirm = false
    @State private var deleting = false

    private var monitor: Monitor? { model.monitors.first { $0.id == monitorID } }
    private var loadKey: String { "monitor.\(monitorID)" }

    var body: some View {
        ScrollView {
            if let monitor {
                let results = model.monitorResults[monitorID] ?? []
                let stats = MonitorStats(results: results)
                VStack(spacing: 16) {
                    InlineStatusView(
                        isLoading: model.isLoading(loadKey),
                        error: model.error(for: loadKey)
                    )
                    headerCard(monitor, stats: stats)
                    configCard(monitor)
                    latencyCard(results)
                    recentChecksCard(results)
                }
                .padding(16)
            } else {
                AstraEmptyStateView(
                    title: "Monitor unavailable",
                    systemImage: "questionmark.folder",
                    message: "This monitor is no longer in the latest list."
                )
                .padding(.top, 60)
            }
        }
        .navigationTitle(monitor?.displayName ?? "Monitor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(monitor == nil || deleting)
            }
        }
        .refreshable { await model.loadMonitorResults(monitorID: monitorID) }
        .task { await model.loadMonitorResults(monitorID: monitorID) }
        .confirmationDialog("Delete this monitor?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete monitor", role: .destructive) {
                Task {
                    deleting = true
                    let ok = await model.deleteMonitor(id: monitorID)
                    deleting = false
                    if ok { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The monitor and its probe schedule are removed from Lattice. Collected results are discarded.")
        }
    }

    // MARK: - Sections

    private func headerCard(_ monitor: Monitor, stats: MonitorStats) -> some View {
        let uptime = stats.uptimeFraction ?? 0
        return HStack(spacing: 20) {
            RingGauge(
                fraction: uptime,
                lineWidth: 14,
                gradient: uptime >= 0.99 ? Theme.healthGradient : Theme.gradient(uptime >= 0.9 ? Theme.warning : Theme.critical),
                label: PercentFormatter.percent(uptime * 100),
                caption: "uptime"
            )
            .frame(width: 118, height: 118)

            VStack(alignment: .leading, spacing: 10) {
                StatusPill(
                    text: monitor.enabled ? "Enabled" : "Disabled",
                    systemImage: monitor.enabled ? "checkmark.circle.fill" : "nosign",
                    color: monitor.enabled ? Theme.online : Theme.disabled
                )
                detailMini("Avg latency", latencyText(stats.averageLatencyMs), Theme.accent)
                detailMini("Last check", lastCheckText(stats.lastResult?.at), .secondary)
                detailMini("Samples", "\(stats.successCount)/\(stats.sampleCount)", .secondary)
            }
            Spacer(minLength: 0)
        }
        .latticeCard(padding: 18)
    }

    private func detailMini(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func configCard(_ monitor: Monitor) -> some View {
        VStack(spacing: 0) {
            SectionHeaderView("Configuration", systemImage: "slider.horizontal.3").padding(.bottom, 4)
            DetailRow(label: "Type", value: monitor.type?.displayName ?? monitor.typeRaw.uppercased())
            Divider()
            DetailRow(label: "Target", value: monitor.target.isEmpty ? "—" : monitor.target, monospaced: true, copyable: true)
            Divider()
            DetailRow(label: "Interval", value: "\(monitor.intervalSec)s")
            Divider()
            DetailRow(label: "Timeout", value: "\(monitor.timeoutSec)s")
            Divider()
            DetailRow(label: "Assignment", value: monitor.assignAll ? "All nodes" : "\(monitor.nodeIDs.count) node\(monitor.nodeIDs.count == 1 ? "" : "s")")
        }
        .latticeCard()
    }

    @ViewBuilder
    private func latencyCard(_ results: [MonitorResult]) -> some View {
        let successful = results.filter(\.success)
        if successful.count >= 2 {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeaderView("Latency", systemImage: "chart.xyaxis.line", accessory: "\(successful.count) pts")
                Chart(successful) { result in
                    LineMark(
                        x: .value("Time", result.at ?? Date()),
                        y: .value("ms", result.latencyMs)
                    )
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.catmullRom)
                }
                .chartYAxis(.automatic)
                .frame(height: 160)
            }
            .latticeCard()
        }
    }

    @ViewBuilder
    private func recentChecksCard(_ results: [MonitorResult]) -> some View {
        let recent = results
            .sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
            .prefix(12)
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeaderView("Recent checks", systemImage: "checklist")
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, result in
                        if index > 0 { Divider() }
                        recentRow(result)
                    }
                }
            }
            .latticeCard()
        }
    }

    private func recentRow(_ result: MonitorResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.success ? Theme.online : Theme.offline)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(result.success ? latencyText(result.latencyMs) : "Failed")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Spacer(minLength: 8)
                    if let at = result.at {
                        Text(RelativeDateFormatter.string(from: at))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let error = result.error, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private func latencyText(_ ms: Double?) -> String {
        guard let ms else { return "—" }
        if ms >= 1000 {
            return String(format: "%.2f s", ms / 1000)
        }
        return String(format: "%.0f ms", ms)
    }

    private func lastCheckText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return RelativeDateFormatter.string(from: date)
    }
}

// MARK: - Monitor create sheet

/// Create-only form for a new probe. Submits via the model and dismisses on
/// success. The node multi-select is only shown when the monitor is not assigned
/// to the whole fleet.
struct MonitorEditView: View {
    @EnvironmentObject private var model: DashboardModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type: MonitorType = .http
    @State private var target = ""
    @State private var intervalSec = 60
    @State private var timeoutSec = 10
    @State private var assignAll = true
    @State private var selectedNodeIDs: Set<String> = []
    @State private var saving = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedTarget: String { target.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && !trimmedTarget.isEmpty && !saving }

    var body: some View {
        NavigationStack {
            Form {
                Section("Probe") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    Picker("Type", selection: $type) {
                        ForEach(MonitorType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    TextField("host:port or https://…", text: $target)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section("Schedule") {
                    Stepper(value: $intervalSec, in: 10...3600, step: 10) {
                        LabeledContent("Interval", value: "\(intervalSec)s")
                    }
                    Stepper(value: $timeoutSec, in: 1...120) {
                        LabeledContent("Timeout", value: "\(timeoutSec)s")
                    }
                }

                Section {
                    Toggle("Assign to all nodes", isOn: $assignAll)
                        .tint(Theme.accent)
                } footer: {
                    Text("When off, the probe runs only on the nodes you select below.")
                }

                if !assignAll {
                    Section("Nodes") {
                        if model.nodes.isEmpty {
                            Text("No nodes available. Refresh the Servers tab first.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.nodes) { node in
                                Button {
                                    toggle(node.id)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(node.displayName)
                                                .font(.subheadline)
                                                .foregroundStyle(.primary)
                                            Text(node.id)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        if selectedNodeIDs.contains(node.id) {
                                            Image(systemName: "checkmark")
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(Theme.accent)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Monitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(!canSave)
                    }
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if selectedNodeIDs.contains(id) {
            selectedNodeIDs.remove(id)
        } else {
            selectedNodeIDs.insert(id)
        }
    }

    private func save() {
        Task {
            saving = true
            let ok = await model.createMonitor(
                name: trimmedName,
                type: type,
                target: trimmedTarget,
                intervalSec: intervalSec,
                timeoutSec: timeoutSec,
                assignAll: assignAll,
                nodeIDs: assignAll ? [] : Array(selectedNodeIDs)
            )
            saving = false
            if ok { dismiss() }
        }
    }
}
