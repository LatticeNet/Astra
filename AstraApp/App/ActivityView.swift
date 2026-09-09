import SwiftUI

/// Server authorization audit trail. Local MonitorEngine alerts are retired;
/// always-on alerting is the Lattice notify channel.
struct ActivityView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        List {
            if model.isLoading("audit") || model.error(for: "audit") != nil {
                Section {
                    InlineStatusView(isLoading: model.isLoading("audit"), error: model.error(for: "audit"))
                }
            }

            if model.auditEvents.isEmpty {
                if !model.isLoading("audit") {
                    Section {
                        AstraEmptyStateView(
                            title: "No audit events",
                            systemImage: "checklist",
                            message: model.configured
                                ? "Authorization decisions made against your Lattice control plane will appear here."
                                : "Connect to Lattice in More → Settings to load the audit trail."
                        )
                    }
                }
            } else {
                Section {
                    ForEach(model.auditEvents) { event in
                        AuditEventRow(event: event)
                    }
                } header: {
                    Text("\(model.auditEvents.count) decisions")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Audit")
        .task { if model.configured { await model.loadAudit() } }
        .refreshable { await model.loadAudit() }
    }
}

struct AuditEventRow: View {
    var event: AuditEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(actionTitle)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                decisionPill
            }

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !event.reason.isEmpty {
                Text(event.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                if !event.scope.isEmpty {
                    Text(event.scope)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let at = event.at {
                    Text(RelativeDateFormatter.string(from: at))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var actionTitle: String {
        event.action.isEmpty ? "Authorization check" : event.action
    }

    private var decisionPill: some View {
        Group {
            if event.isDeny {
                StatusPill(text: "deny", systemImage: "xmark.shield", color: Theme.critical)
            } else {
                StatusPill(text: "allow", systemImage: "checkmark.shield", color: Theme.online)
            }
        }
    }

    private var subtitle: String {
        [event.actorID, event.nodeID]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
