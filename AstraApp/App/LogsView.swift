import SwiftUI

/// Browse log sources collected across the fleet, then drill into the tailed
/// lines for any one source. Pushed inside MoreHub's NavigationStack, so neither
/// this view nor its detail wrap themselves in a NavigationStack — they rely on
/// the ambient stack for navigation and back behaviour.
struct LogsView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        List {
            sourcesSection
            statusSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Logs")
        .task {
            if model.configured {
                await model.loadLogs()
            }
        }
        .refreshable {
            await model.loadLogs()
        }
    }

    @ViewBuilder
    private var sourcesSection: some View {
        Section {
            if model.logSources.isEmpty {
                if !model.isLoading("logs") {
                    AstraEmptyStateView(
                        title: "No log sources",
                        systemImage: "doc.text.magnifyingglass",
                        message: "Configure a log source on the web dashboard to start tailing files from your fleet."
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(model.logSources) { source in
                    NavigationLink {
                        LogLinesView(source: source)
                    } label: {
                        LogSourceRow(source: source)
                    }
                }
            }
        } header: {
            SectionHeaderView(
                "Sources",
                systemImage: "doc.text.below.ecg",
                accessory: model.logSources.isEmpty ? nil : "\(model.logSources.count)"
            )
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            InlineStatusView(isLoading: model.isLoading("logs"), error: model.error(for: "logs"))
        }
        .listRowBackground(Color.clear)
    }
}

// MARK: - Log source row

struct LogSourceRow: View {
    var source: LogSource

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(source.enabled ? Theme.online : Theme.disabled.opacity(0.5))
                    .frame(width: 9, height: 9)
                    .accessibilityLabel(source.enabled ? "Enabled" : "Disabled")
                Text(source.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
            }

            Text(source.path.isEmpty ? "—" : source.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if !source.nodeID.isEmpty {
                Label(source.nodeID, systemImage: "cpu")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Log lines detail

/// Tailed lines for a single source. Lines arrive in server order (oldest →
/// newest); we present newest-first so the freshest output is at the top, the
/// way a phone-first tail reads best.
struct LogLinesView: View {
    @EnvironmentObject private var model: DashboardModel
    var source: LogSource

    private var statusKey: String { "logline.\(source.id)" }

    private var lines: [LogLine] {
        // Server order is oldest-first; reverse so newest is at the top.
        (model.logLines[source.id] ?? []).reversed()
    }

    var body: some View {
        List {
            metaSection
            linesSection
            statusSection
        }
        .listStyle(.plain)
        .navigationTitle(source.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.loadLogLines(sourceID: source.id)
        }
        .refreshable {
            await model.loadLogLines(sourceID: source.id)
        }
    }

    @ViewBuilder
    private var metaSection: some View {
        if !source.path.isEmpty || !source.nodeID.isEmpty {
            Section {
                if !source.path.isEmpty {
                    Text(source.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !source.nodeID.isEmpty {
                    Label(source.nodeID, systemImage: "cpu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var linesSection: some View {
        Section {
            if lines.isEmpty {
                if !model.isLoading(statusKey) {
                    AstraEmptyStateView(
                        title: "No lines",
                        systemImage: "text.alignleft",
                        message: "No recent output for this source. Pull to refresh once it logs."
                    )
                    .listRowSeparator(.hidden)
                }
            } else {
                ForEach(lines) { line in
                    LogLineRow(line: line)
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            InlineStatusView(isLoading: model.isLoading(statusKey), error: model.error(for: statusKey))
        }
    }
}

// MARK: - Single line row

private struct LogLineRow: View {
    var line: LogLine

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let at = line.at {
                    Text(RelativeDateFormatter.string(from: at))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if line.truncated {
                    Text("⋯")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.warning)
                        .accessibilityLabel("Truncated line")
                }
            }
            Text(line.line)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .listRowSeparator(.hidden)
    }
}
