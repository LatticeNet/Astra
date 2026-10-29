import SwiftUI

/// M9-06 Webhooks. Inbound webhooks with their last call, and the ones that
/// answer 202 but reach nobody, named with the fix. Creating, editing and
/// rotating a secret are on the web, where the secret is shown once.
struct WebhooksScreen: View {
    static let queryKey = "notify.webhooks.query"

    @Environment(NotifyStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    @SceneStorage(WebhooksScreen.queryKey) private var query = ""

    var body: some View {
        NotifyResourceScreen(state: store.webhooks, noun: "webhooks", retry: refresh) { hooks in
            list(hooks)
        }
        .navigationTitle("Webhooks")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, prompt: "Name or event type")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New webhook on web", systemImage: "plus.circle") { router.openOnWeb(.notifyWebhooks) }
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.notifyWebhooks) }
                    Button("Notifications", systemImage: "bell") { router.push(.notify(.notifications(view: nil))) }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .polling(.standard, version: changes.version([.webhooks, .notify])) {
            await store.refreshWebhooks()
        }
    }

    private var channels: [NotifyChannel]? { store.channels.value }
    private var rules: [NotifyRule]? { store.rules.value }

    private func list(_ hooks: [NotifyWebhook]) -> some View {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = hooks
            .filter { text.isEmpty || $0.displayName.lowercased().contains(text) || $0.eventType.lowercased().contains(text) }
            .sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
        let noChannel = !hooks.isEmpty && channels.map { !$0.contains(where: \.enabled) } == true
        return List {
            NotifyRefreshError(state: store.webhooks, noun: "webhooks", retry: refresh)
            if noChannel {
                Section {
                    StatusRow(
                        style: StatusStyle(word: "reaches nobody", symbol: "exclamationmark.triangle.fill", tone: .warn),
                        title: "No notification channel is enabled",
                        reason: "A webhook will authenticate and render its message, then reach nobody. Add a channel before handing the URL out."
                    )
                    NavigationLink("Open Notifications", value: AppRoute.notify(.notifications(view: nil)))
                        .frame(minHeight: Spacing.minimumTarget)
                }
            }
            if case .failed(let error, _, _) = store.channels {
                Section { ErrorRow(message: "Channels not read: \(error.localizedDescription). Reach is not judged.", retry: refresh) }
            } else if case .failed(let error, _, _) = store.rules {
                Section { ErrorRow(message: "Routing rules not read: \(error.localizedDescription). Reach is not judged.", retry: refresh) }
            }
            if shown.isEmpty {
                if hooks.isEmpty {
                    ContentUnavailableView {
                        Label("No webhooks yet", systemImage: "arrow.down.forward.and.arrow.up.backward")
                    } description: {
                        Text("A webhook turns an HTTP request from a script, an appliance or another system into a notification event. Create one on the web; its secret is shown once there.")
                    } actions: {
                        Button("New webhook on web") { router.openOnWeb(.notifyWebhooks) }
                    }
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
            if !shown.isEmpty {
                Section {
                    ForEach(shown) { hook in
                        row(hook)
                    }
                } header: {
                    Text(summary(hooks)).accessibilityAddTraits(.isHeader)
                }
            }
            Section {} footer: {
                NotifyFreshness(state: store.webhooks)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refreshWebhooks() }
    }

    /// Reaches nobody first, then enabled, then off.
    private func rank(_ hook: NotifyWebhook) -> Int {
        if NotifyWebhookRouting.reachesNobody(hook, channels: channels, rules: rules) { return 0 }
        return hook.enabled ? 1 : 2
    }

    private func summary(_ hooks: [NotifyWebhook]) -> String {
        let enabled = hooks.filter(\.enabled).count
        let total = hooks.count == 1 ? "1 webhook" : "\(hooks.count) webhooks"
        return "\(total), \(enabled) enabled"
    }

    private func row(_ hook: NotifyWebhook) -> some View {
        NavigationLink(value: AppRoute.notify(.webhook(id: hook.id))) {
            NotifyWebhookRow(hook: hook, channels: channels, rules: rules)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if store.adminMissing == nil, hook.enabled {
                Button("Send test", systemImage: "paperplane") {
                    Task { await runner.run(NotifyIntents.testWebhook(hook)) }
                }
                .tint(Color.accentFill)
            }
        }
        .contextMenu {
            NotifyObjectMenu(route: .notify(.webhook(id: hook.id)), link: .webhook(id: hook.id), web: .webhook(id: hook.id), objectID: hook.id)
            Divider()
            if hook.enabled {
                NotifyGatedButton(title: "Send test", systemImage: "paperplane", missing: store.adminMissing) {
                    Task { await runner.run(NotifyIntents.testWebhook(hook)) }
                }
            }
            NotifyGatedButton(title: "Delete webhook", systemImage: "trash", missing: store.adminMissing, role: .destructive) {
                Task { await runner.run(NotifyIntents.deleteWebhook(hook)) }
            }
        }
        .accessibilityActions {
            Button("Copy link") { NotifyCopy.copy(NotifyCopy.link(.webhook(id: hook.id))) }
            if store.adminMissing == nil {
                Button("Delete webhook") { Task { await runner.run(NotifyIntents.deleteWebhook(hook)) } }
            }
        }
    }

    private func refresh() {
        Task { await store.refreshWebhooks() }
    }
}

/// A webhook: its state word, event type and last call; why it reaches nobody.
struct NotifyWebhookRow: View {
    let hook: NotifyWebhook
    let channels: [NotifyChannel]?
    let rules: [NotifyRule]?

    var body: some View {
        let routing = NotifyWebhookRouting.of(hook, channels: channels, rules: rules)
        let nobody = NotifyWebhookRouting.reachesNobody(hook, channels: channels, rules: rules)
        let style = StatusStyle.notifyWebhook(hook, reachesNobody: nobody)
        let called = hook.lastUsedAt.map { "called \(RelativeDateFormatter.string(from: $0))" } ?? "never called"
        let reason: String? = nobody ? (routing == .noChannel ? "No notification channel is enabled." : "No enabled rule routes \(hook.eventType). Add a rule for it on the web.") : nil
        return StatusRow(
            style: style,
            title: hook.displayName,
            detail: style.word == "never called" ? hook.eventType : "\(hook.eventType), \(called)",
            reason: reason,
            accessibilityPhrase: "Webhook \(hook.displayName), \(style.word)"
        )
    }
}
