import SwiftUI

struct InboxView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        NavigationStack {
            List {
                if !model.configured {
                    Section {
                        Text("Connect to Lattice in More → Settings. Use a PAT with network:apply, node:read, audit:read, and task:read.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if model.companionBehindServer {
                    Section {
                        Label("Companion is behind this server. Approve is disabled until this app can decode the approval view.", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Theme.warning)
                    }
                }

                plansSection
                attentionSection
                quietSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Inbox")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.refreshInbox() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isBusy || !model.configured)
                }
            }
            .refreshable { await model.refreshInbox() }
            .task {
                if model.configured {
                    await model.refreshInbox()
                }
            }
            .sheet(item: $model.reviewRoute) { route in
                NavigationStack {
                    ApprovalReviewView(approvalID: route.id)
                        .environmentObject(model)
                }
            }
        }
    }

    @ViewBuilder
    private var plansSection: some View {
        let plans = model.humanPendingApprovals
        Section {
            if model.isLoading("inbox") && plans.isEmpty {
                InlineStatusView(isLoading: true, error: nil)
            } else if let error = model.error(for: "inbox"), plans.isEmpty {
                InlineStatusView(isLoading: false, error: error)
            } else if plans.isEmpty {
                Text("No plans waiting on you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(plans) { approval in
                    Button {
                        model.openReview(id: approval.id)
                    } label: {
                        ApprovalRow(approval: approval)
                    }
                }
            }
        } header: {
            Text("Plans")
        } footer: {
            if !plans.isEmpty {
                Text("\(plans.count) need a decision")
            }
        }
    }

    @ViewBuilder
    private var attentionSection: some View {
        let items = model.attentionItems
        Section {
            if items.isEmpty {
                Text("Fleet is quiet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    Button {
                        model.openAttention(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Spacer()
                                StatusPill(text: item.badge, systemImage: item.systemImage, color: toneColor(item.tone))
                            }
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        } header: {
            Text("Attention")
        }
    }

    @ViewBuilder
    private var quietSection: some View {
        Section {
            if let last = model.lastRefresh {
                DetailRow(label: "Last refresh", value: RelativeDateFormatter.string(from: last))
            }
            if let last = model.lastInboxNotifyAt {
                DetailRow(label: "Last notify", value: RelativeDateFormatter.string(from: last))
            } else {
                DetailRow(label: "Last notify", value: "none on this device")
            }
            DetailRow(label: "Quiet since", value: model.quietSinceText)
        } header: {
            Text("Unattended")
        } footer: {
            Text("Always-on alerting is the Lattice server notify channel. Background refresh only updates this badge, and the system decides if it runs.")
        }
    }

    private func toneColor(_ tone: AttentionItem.Tone) -> Color {
        switch tone {
        case .warning: Theme.warning
        case .critical: Theme.critical
        case .accent: Theme.accent
        case .offline: Theme.offline
        }
    }
}
