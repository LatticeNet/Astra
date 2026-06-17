import SwiftUI

/// Server-side notification configuration: delivery channels and the rules that
/// fan events out to them. This screen is read-only on iOS — channels and rules
/// are authored on the web dashboard — but it surfaces their state and lets the
/// operator fire a quick test through any channel.
///
/// Pushed inside MoreHub's NavigationStack, so it intentionally does not wrap
/// itself in a NavigationStack.
struct NotificationsView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        List {
            channelsSection
            rulesSection
            footerSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Notifications")
        .task {
            if model.configured {
                await model.loadNotify()
            }
        }
        .refreshable {
            await model.loadNotify()
        }
    }

    // MARK: - Channels

    @ViewBuilder
    private var channelsSection: some View {
        Section {
            if model.notifyChannels.isEmpty {
                if !model.isLoading("notify") {
                    AstraEmptyStateView(
                        title: "No channels",
                        systemImage: "bell.slash",
                        message: "Add a delivery channel on the web dashboard to start routing alerts."
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(model.notifyChannels) { channel in
                    ChannelRow(channel: channel)
                }
            }
        } header: {
            SectionHeaderView(
                "Channels",
                systemImage: "bell.badge.fill",
                accessory: model.notifyChannels.isEmpty ? nil : "\(model.notifyChannels.count)"
            )
        }
    }

    // MARK: - Rules

    @ViewBuilder
    private var rulesSection: some View {
        Section {
            if model.notifyRules.isEmpty {
                if !model.isLoading("notify") {
                    Text("No rules configured yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.notifyRules) { rule in
                    RuleRow(rule: rule)
                }
            }
        } header: {
            SectionHeaderView(
                "Rules",
                systemImage: "arrow.triangle.branch",
                accessory: model.notifyRules.isEmpty ? nil : "\(model.notifyRules.count)"
            )
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerSection: some View {
        Section {
            InlineStatusView(isLoading: model.isLoading("notify"), error: model.error(for: "notify"))
            Label("Create/edit channels & rules on the web dashboard.", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .listRowBackground(Color.clear)
    }
}

// MARK: - Channel row

struct ChannelRow: View {
    @EnvironmentObject private var model: DashboardModel
    var channel: NotifyChannel

    @State private var isTesting = false
    @State private var testResult: TestResult?

    private enum TestResult {
        case success
        case failure
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                EnabledDot(enabled: channel.enabled)
                Text(channel.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                kindBadge
                Spacer(minLength: 8)
                testButton
            }

            if !channel.configKeys.isEmpty {
                Label(channel.configKeys.joined(separator: " · "), systemImage: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var kindBadge: some View {
        Text(channel.kind.isEmpty ? "channel" : channel.kind.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.secondary.opacity(0.14), in: Capsule())
    }

    @ViewBuilder
    private var testButton: some View {
        if isTesting {
            ProgressView()
        } else {
            Button {
                runTest()
            } label: {
                Label("Test", systemImage: testIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(testTint)
            }
            .buttonStyle(.borderless)
            .disabled(!model.configured)
        }
    }

    private var testIcon: String {
        switch testResult {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        case nil: "paperplane"
        }
    }

    private var testTint: Color {
        switch testResult {
        case .success: Theme.online
        case .failure: Theme.critical
        case nil: Theme.accent
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            let ok = await model.testNotifyChannel(id: channel.id)
            isTesting = false
            testResult = ok ? .success : .failure
        }
    }
}

// MARK: - Rule row

struct RuleRow: View {
    var rule: NotifyRule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                EnabledDot(enabled: rule.enabled)
                Text(rule.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(rule.channelIDs.count) channel\(rule.channelIDs.count == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !rule.eventTypes.isEmpty {
                Label(rule.eventTypes.joined(separator: " · "), systemImage: "bolt.horizontal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Shared local helper

/// A small filled/hollow dot communicating an enabled/disabled toggle state.
/// Local to the notifications screen to avoid colliding with shared types.
private struct EnabledDot: View {
    var enabled: Bool

    var body: some View {
        Circle()
            .fill(enabled ? Theme.online : Theme.disabled.opacity(0.5))
            .frame(width: 9, height: 9)
            .accessibilityLabel(enabled ? "Enabled" : "Disabled")
    }
}
