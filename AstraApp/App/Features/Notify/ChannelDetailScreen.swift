import SwiftUI

/// The newest deliveries through one channel, by the server's own
/// `channel_id` filter.
@MainActor @Observable
final class NotifyChannelDeliveries {
    static let limit = 5
    private(set) var state: ResourceState<[NotifyDelivery]> = .idle

    func load(channelID: String, store: NotifyStore, session: SessionStore) async {
        guard !store.isConfined, store.adminMissing == nil, let client = session.client else { return }
        state = state.reloading
        do {
            state = .loaded(try await client.fetchDeliveries(query: DeliveryQuery(channelID: channelID, limit: Self.limit)).deliveries, at: Date())
        } catch {
            if NotifyStore.isCancellation(error) { return }
            state = state.failing(LatticeAPIError(error), surface: "Deliveries", missingScope: NotifyIntents.adminScope)
        }
    }
}

/// M9-04 Channel. Kind, health, the last deliveries, the fallback and what
/// routes to it. Send test (T2), Delete (T4), Edit on web, and the
/// notify:send test as a web-only row.
struct ChannelDetailScreen: View {
    let id: String

    @Environment(NotifyStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    @State private var recent = NotifyChannelDeliveries()

    var body: some View {
        NotifyResourceScreen(state: store.channels, noun: "the channel", retry: refresh) { channels in
            if let channel = channels.first(where: { $0.id == id }) {
                detail(channel, channels: channels)
            } else {
                notFound
            }
        }
        .navigationTitle(store.channel(id: id)?.displayName ?? "Channel")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(store.channel(id: id).map { StatusStyle.notifyChannel($0).word } ?? "")
        .toolbar { toolbar }
        .polling(.standard, version: changes.version([.notify])) {
            let ok = await store.refreshRouting()
            await recent.load(channelID: id, store: store, session: session)
            return ok
        }
    }

    // MARK: Detail

    private func detail(_ channel: NotifyChannel, channels: [NotifyChannel]) -> some View {
        let line = NotifyChannelHealthLine.of(channel.health)
        let missing = store.adminMissing
        return List {
            Section {
                NotifyRefreshError(state: store.channels, noun: "the channel", retry: refresh)
                NotifyChannelRow(channel: channel, fallback: store.channel(id: channel.fallbackChannelID))
            }

            healthSection(channel, line: line)

            Section {
                DetailRow(label: "Kind", value: NotifyKind.label(channel.kind), copyable: false)
                DetailRow(label: "Enabled", value: channel.enabled ? "On" : "Off: sends nothing", copyable: false)
                DetailRow(label: "Configured keys", value: channel.configKeys.isEmpty ? "None" : channel.configKeys.joined(separator: ", "), monospaced: true, copyable: false)
                if !channel.fallbackChannelID.isEmpty {
                    if let fallback = store.channel(id: channel.fallbackChannelID) {
                        NavigationLink(value: AppRoute.notify(.channel(id: fallback.id))) {
                            DetailRow(label: "Fallback", value: fallback.displayName, copyable: false)
                        }
                    } else {
                        DetailRow(label: "Fallback", value: channel.fallbackChannelID, monospaced: true, copyable: false)
                    }
                } else {
                    DetailRow(label: "Fallback", value: "None", copyable: false)
                }
            } header: {
                Text("Channel").accessibilityAddTraits(.isHeader)
            } footer: {
                Text(channel.fallbackChannelID.isEmpty
                     ? "Values are write-only; the server lists only which keys are set."
                     : "Critical messages it fails go to the fallback: \(channel.criticalEventTypes.joined(separator: ", ")). Values are write-only; the server lists only which keys are set.")
            }

            routedBySection(channel, channels: channels)
            recentSection

            Section {
                Button {
                    Task { await runner.run(NotifyIntents.testChannel(channel)) }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("Send test")
                            Text(missing.map { "Needs \($0)" } ?? "Sends Lattice's fixed test message through \(channel.displayName).")
                                .textRole(.footnote)
                        }
                    } icon: {
                        Image(systemName: "paperplane")
                    }
                    .frame(minHeight: Spacing.minimumTarget)
                }
                .disabled(missing != nil)
                WebLinkRow(title: "Test send on web (needs notify:send)", path: .notifyChannel(id: channel.id))
                WebLinkRow(title: "Edit on web", path: .notifyChannel(id: channel.id))
            } header: {
                Text("Actions").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("A test send with your own text needs notify:send, which this app never holds, so it stays on the web.")
            }

            Section {
                Button(role: .destructive) {
                    Task { await delete(channel, channels: channels) }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("Delete channel")
                            if let missing { Text("Needs \(missing)").textRole(.footnote) }
                        }
                    } icon: {
                        Image(systemName: "trash")
                    }
                    .frame(minHeight: Spacing.minimumTarget)
                }
                .disabled(missing != nil)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await store.refreshRouting()
            await recent.load(channelID: id, store: store, session: session)
        }
    }

    @ViewBuilder
    private func healthSection(_ channel: NotifyChannel, line: NotifyChannelHealthLine) -> some View {
        Section {
            if let health = channel.health {
                DetailRow(label: "State", value: healthSentence(line), copyable: false)
                if let attempt = health.lastAttemptAt { timeRow("Last attempt", attempt) }
                if let ok = health.lastOKAt { timeRow("Last delivered", ok) }
                if let failure = health.lastFailureAt { timeRow("Last failure", failure) }
                if let cause = line.cause {
                    DetailRow(label: "Cause", value: cause.sentence.sentenceCased, copyable: false)
                }
                if health.consecutiveFailures > 0 {
                    DetailRow(label: "Failures in a row", value: "\(health.consecutiveFailures)", copyable: false)
                }
                if let since = health.failingSince { timeRow("Failing since", since) }
                if health.fallbacks > 0 {
                    let to = store.channel(id: health.lastFallbackChannelID)?.displayName ?? health.lastFallbackChannelID
                    DetailRow(label: "Handed to fallback", value: health.fallbacks == 1 ? "Once, to \(to)" : "\(health.fallbacks) times, last to \(to)", copyable: false)
                }
            } else {
                DetailRow(label: "State", value: "Not reported by this server", copyable: false)
            }
        } header: {
            Text("Health").accessibilityAddTraits(.isHeader)
        }
    }

    private func healthSentence(_ line: NotifyChannelHealthLine) -> String {
        let when = line.at.map { NotifyTime.when($0, mode: mode, locale: locale) } ?? ""
        switch line.state {
        case .unreported: return "Not reported by this server"
        case .unknown: return "No sends yet"
        case .ok: return "Delivered \(when)"
        case .degraded: return "Last send failed \(when)"
        case .failing: return "Failing since \(when), \(line.failures) in a row"
        }
    }

    private func timeRow(_ label: String, _ date: Date) -> some View {
        DetailRow(label: label, value: TimeDisplay.dateTime(date, mode: mode, locale: locale), secondary: TimeDisplay.otherZone(date, mode: mode, locale: locale), copyable: false)
    }

    @ViewBuilder
    private func routedBySection(_ channel: NotifyChannel, channels: [NotifyChannel]) -> some View {
        let rules = store.rules.value ?? []
        let routing = NotifyChannels.rules(routingTo: channel.id, in: rules)
        let fallbackUsers = NotifyChannels.fallbackUsers(of: channel.id, channels: channels, rules: rules)
        Section {
            if store.rules.value == nil {
                LoadingRows(label: "Loading rules", count: 1)
            } else if routing.isEmpty && fallbackUsers.channels.isEmpty && fallbackUsers.rules.isEmpty {
                Text(rules.contains(where: \.enabled) ? "No rule sends to this channel, so it receives nothing." : "No rule is enabled, so this channel receives every event.")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
            }
            ForEach(routing) { rule in
                NavigationLink(value: AppRoute.notify(.rule(id: rule.id))) {
                    NotifyRuleRow(rule: rule, channels: channels)
                }
            }
            ForEach(fallbackUsers.rules) { rule in
                NavigationLink(value: AppRoute.notify(.rule(id: rule.id))) {
                    DetailRow(label: "Fallback for rule", value: rule.displayName, copyable: false)
                }
            }
            ForEach(fallbackUsers.channels) { other in
                NavigationLink(value: AppRoute.notify(.channel(id: other.id))) {
                    DetailRow(label: "Fallback for channel", value: other.displayName, copyable: false)
                }
            }
        } header: {
            Text("Routed by").accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        Section {
            switch recent.state {
            case .idle:
                LoadingRows(label: "Loading deliveries", count: 2)
            case .failed(let error, nil, _):
                ErrorRow(message: "Could not load deliveries: \(error.localizedDescription)") {
                    Task { await recent.load(channelID: id, store: store, session: session) }
                }
            case .denied(let scope):
                ScopeDeniedRow(scope: scope)
            default:
                if let rows = recent.state.value {
                    if rows.isEmpty {
                        Text("Nothing has gone through this channel yet.").foregroundStyle(.secondary)
                            .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                    }
                    ForEach(rows) { delivery in
                        NavigationLink(value: AppRoute.notify(.delivery(id: delivery.id))) {
                            NotifyDeliveryRow(delivery: delivery, eventLabel: store.eventLabel(delivery.eventType))
                        }
                    }
                    Button {
                        router.select(tab: .activity, scope: ActivityScope.sent.rawValue, query: "channel_id:\(id)")
                    } label: {
                        HStack {
                            Text("All deliveries through this channel")
                            Spacer(minLength: Spacing.s)
                            Text("Opens in Activity").textRole(.footnote)
                            Image(systemName: AppTab.activity.symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                        .frame(minHeight: Spacing.minimumTarget)
                    }
                } else {
                    LoadingRows(label: "Loading deliveries", count: 2)
                }
            }
        } header: {
            Text("Last deliveries").accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: Actions

    private func delete(_ channel: NotifyChannel, channels: [NotifyChannel]) async {
        let outcome = await runner.run(NotifyIntents.deleteChannel(channel, rules: store.rules.value, channels: channels))
        // The screen closes only once the server confirmed the delete.
        if case .done = outcome { dismiss() }
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Channel not found", systemImage: "bell.slash")
            } description: {
                Text("It was deleted, or this link names a channel this server does not hold.")
            } actions: {
                Button("Open on web") { router.openOnWeb(.notifyChannel(id: id)) }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let channel = store.channel(id: id) {
                    NotifyGatedButton(title: "Send test", systemImage: "paperplane", missing: store.adminMissing) {
                        Task { await runner.run(NotifyIntents.testChannel(channel)) }
                    }
                    Section {
                        Button("Copy link", systemImage: "link") { NotifyCopy.copy(NotifyCopy.link(.notifyChannel(id: id))) }
                        Button("Copy ID", systemImage: "number") { NotifyCopy.copy(id) }
                        Button("Open on web", systemImage: "safari") { router.openOnWeb(.notifyChannel(id: id)) }
                        Button("Edit on web", systemImage: "square.and.pencil") { router.openOnWeb(.notifyChannel(id: id)) }
                    }
                    Section {
                        NotifyGatedButton(title: "Delete channel", systemImage: "trash", missing: store.adminMissing, role: .destructive) {
                            Task { await delete(channel, channels: store.channels.value ?? []) }
                        }
                    }
                } else {
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.notifyChannel(id: id)) }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    private func refresh() {
        Task { await store.refreshRouting() }
    }
}
