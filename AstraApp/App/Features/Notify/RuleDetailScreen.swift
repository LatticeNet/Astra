import SwiftUI

/// A rule's recent matches. The outbox listing has no rule filter, so the
/// newest 200 deliveries are read and kept by `rule_id` on the phone.
@MainActor @Observable
final class NotifyRuleMatches {
    static let scanned = 200
    static let shown = 8
    private(set) var state: ResourceState<[NotifyDelivery]> = .idle

    func load(ruleID: String, store: NotifyStore, session: SessionStore) async {
        guard !store.isConfined, store.adminMissing == nil, let client = session.client else { return }
        state = state.reloading
        do {
            let rows = try await client.fetchDeliveries(query: DeliveryQuery(limit: Self.scanned)).deliveries
            state = .loaded(Array(rows.filter { $0.ruleID == ruleID }.prefix(Self.shown)), at: Date())
        } catch {
            if NotifyStore.isCancellation(error) { return }
            state = state.failing(LatticeAPIError(error), surface: "Deliveries", missingScope: NotifyIntents.adminScope)
        }
    }
}

/// M9-05 Rule. What it matches, where it sends, its fallback, quiet hours
/// and escalation, its templates and recent matches. Editing and deleting a
/// rule are on the web.
struct RuleDetailScreen: View {
    let id: String

    @Environment(NotifyStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router

    @State private var matches = NotifyRuleMatches()

    var body: some View {
        NotifyResourceScreen(state: store.rules, noun: "the rule", retry: refresh) { rules in
            if let rule = rules.first(where: { $0.id == id }) {
                detail(rule)
            } else {
                notFound
            }
        }
        .navigationTitle(store.rule(id: id)?.displayName ?? "Rule")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(store.rule(id: id).map { StatusStyle.notifyRule($0, channels: store.channels.value).word } ?? "")
        .toolbar { toolbar }
        .polling(.standard, version: changes.version([.notify])) {
            let ok = await store.refreshRouting()
            await matches.load(ruleID: id, store: store, session: session)
            return ok
        }
    }

    private func detail(_ rule: NotifyRule) -> some View {
        return List {
            Section {
                NotifyRefreshError(state: store.rules, noun: "the rule", retry: refresh)
                NotifyRuleRow(rule: rule, channels: store.channels.value)
            }

            Section {
                if NotifyRules.matchesEverything(rule) {
                    Text("Every event type").frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                } else {
                    ForEach(rule.eventTypes, id: \.self) { type in
                        DetailRow(label: store.eventLabel(type), value: type, monospaced: true)
                    }
                }
            } header: {
                Text("Matches").accessibilityAddTraits(.isHeader)
            }

            Section {
                if rule.channelIDs.isEmpty {
                    Text("No channel").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                }
                ForEach(rule.channelIDs, id: \.self) { channelID in
                    if let channel = store.channel(id: channelID) {
                        NavigationLink(value: AppRoute.notify(.channel(id: channel.id))) {
                            NotifyChannelRow(channel: channel, fallback: store.channel(id: channel.fallbackChannelID))
                        }
                    } else {
                        DetailRow(label: "Missing channel", value: channelID, monospaced: true)
                    }
                }
                if !rule.fallbackChannelID.isEmpty {
                    if let fallback = store.channel(id: rule.fallbackChannelID) {
                        NavigationLink(value: AppRoute.notify(.channel(id: fallback.id))) {
                            DetailRow(label: "Fallback", value: fallback.displayName, copyable: false)
                        }
                    } else {
                        DetailRow(label: "Fallback", value: rule.fallbackChannelID, monospaced: true)
                    }
                }
            } header: {
                Text("Sends to").accessibilityAddTraits(.isHeader)
            } footer: {
                if !rule.fallbackChannelID.isEmpty {
                    Text("The fallback takes every message this rule's channels fail to deliver.")
                }
            }

            Section {
                DetailRow(label: "Quiet hours", value: NotifyRules.quietHoursText(rule) ?? "Off", copyable: false)
                DetailRow(label: "Escalation", value: NotifyRules.escalationText(rule), copyable: false)
            } header: {
                Text("Incidents").accessibilityAddTraits(.isHeader)
            } footer: {
                if rule.quietHours != nil {
                    Text("During quiet hours the rule holds its messages until they end; the server withdraws a held message whose incident was resolved, acknowledged or snoozed meanwhile.")
                }
            }

            if !rule.titleTemplate.isEmpty || !rule.bodyTemplate.isEmpty {
                Section {
                    if !rule.titleTemplate.isEmpty {
                        DetailRow(label: "Title", value: rule.titleTemplate, monospaced: true)
                    }
                    if !rule.bodyTemplate.isEmpty {
                        DetailRow(label: "Body", value: rule.bodyTemplate, monospaced: true)
                    }
                } header: {
                    Text("Templates").accessibilityAddTraits(.isHeader)
                }
            }

            matchesSection

            Section {
                WebLinkRow(title: "Edit on web", path: .notifyNotifications(view: "routing"))
                WebLinkRow(title: "Delete on web", path: .notifyNotifications(view: "routing"))
            } footer: {
                Text("Routing authoring stays on the web.")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await store.refreshRouting()
            await matches.load(ruleID: id, store: store, session: session)
        }
    }

    @ViewBuilder
    private var matchesSection: some View {
        Section {
            switch matches.state {
            case .idle:
                LoadingRows(label: "Loading recent matches", count: 2)
            case .failed(let error, nil, _):
                ErrorRow(message: "Could not load recent matches: \(error.localizedDescription)") {
                    Task { await matches.load(ruleID: id, store: store, session: session) }
                }
            case .denied(let scope):
                ScopeDeniedRow(scope: scope)
            default:
                if let rows = matches.state.value {
                    if rows.isEmpty {
                        Text("No match in the newest \(NotifyRuleMatches.scanned) deliveries.").foregroundStyle(.secondary)
                            .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                    }
                    ForEach(rows) { delivery in
                        NavigationLink(value: AppRoute.notify(.delivery(id: delivery.id))) {
                            NotifyDeliveryRow(delivery: delivery, eventLabel: store.eventLabel(delivery.eventType))
                        }
                    }
                } else {
                    LoadingRows(label: "Loading recent matches", count: 2)
                }
            }
        } header: {
            Text("Recent matches").accessibilityAddTraits(.isHeader)
        }
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Rule not found", systemImage: "arrow.triangle.branch")
            } description: {
                Text("It was deleted, or this server does not hold it.")
            } actions: {
                Button("Open on web") { router.openOnWeb(.notifyNotifications(view: "routing")) }
                    .buttonStyle(.bordered)
            }
        }
    }

    /// Rules have no app link of their own (section 2.5), so there is no Copy link.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Copy ID", systemImage: "number") { NotifyCopy.copy(id) }
                Button("Open on web", systemImage: "safari") { router.openOnWeb(.notifyNotifications(view: "routing")) }
                Button("Edit on web", systemImage: "square.and.pencil") { router.openOnWeb(.notifyNotifications(view: "routing")) }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    private func refresh() {
        Task { await store.refreshRouting() }
    }
}
