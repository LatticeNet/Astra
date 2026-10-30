import SwiftUI

/// One webhook's retained attempts (`/api/notify/webhooks/deliveries`).
@MainActor @Observable
final class NotifyWebhookAttempts {
    private(set) var state: ResourceState<[NotifyWebhookDelivery]> = .idle

    func load(id: String, store: NotifyStore, session: SessionStore) async {
        guard !store.isConfined else { return }
        if let missing = store.adminMissing {
            state = .denied(scope: missing)
            return
        }
        guard let client = session.client else { return }
        state = state.reloading
        do {
            state = .loaded(try await client.notifyWebhookDeliveries(id: id), at: Date())
        } catch {
            if NotifyStore.isCancellation(error) { return }
            let apiError = LatticeAPIError(error)
            if case .invalidResponse = apiError { session.markCompanionBehind("Webhook attempts") }
            state = state.failing(apiError, surface: "Webhook attempts", missingScope: NotifyIntents.adminScope)
        }
    }
}

/// M9-07 Webhook. Its fields (never the secret), whether anything receives
/// its event, and its recent attempts. Test (T2) and Delete (T4); create,
/// edit and rotate the secret on the web.
struct WebhookDetailScreen: View {
    let id: String

    @Environment(NotifyStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    @State private var attempts = NotifyWebhookAttempts()

    var body: some View {
        NotifyResourceScreen(state: store.webhooks, noun: "the webhook", retry: refresh) { hooks in
            if let hook = hooks.first(where: { $0.id == id }) {
                detail(hook)
            } else {
                notFound
            }
        }
        .navigationTitle(store.webhook(id: id)?.displayName ?? "Webhook")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .polling(.standard, version: changes.version([.webhooks, .notify])) {
            let ok = await store.refreshWebhooks()
            await attempts.load(id: id, store: store, session: session)
            return ok
        }
    }

    private var subtitle: String {
        guard let hook = store.webhook(id: id) else { return "" }
        let nobody = NotifyWebhookRouting.reachesNobody(hook, channels: store.channels.value, rules: store.rules.value)
        return StatusStyle.notifyWebhook(hook, reachesNobody: nobody).word
    }

    private func detail(_ hook: NotifyWebhook) -> some View {
        let missing = store.adminMissing
        return List {
            Section {
                NotifyRefreshError(state: store.webhooks, noun: "the webhook", retry: refresh)
                NotifyWebhookRow(hook: hook, channels: store.channels.value, rules: store.rules.value)
            }

            routingSection(hook)

            Section {
                DetailRow(label: "Event type", value: hook.eventType, monospaced: true)
                DetailRow(label: "Enabled", value: hook.enabled ? "On" : "Off: refuses outside calls, keeps its secret and history", copyable: false)
                DetailRow(label: "Endpoint", value: hook.path, monospaced: true)
                if !hook.titleTemplate.isEmpty {
                    DetailRow(label: "Title template", value: hook.titleTemplate, monospaced: true)
                }
                DetailRow(label: "Body template", value: hook.bodyTemplate.isEmpty ? "None" : hook.bodyTemplate, monospaced: !hook.bodyTemplate.isEmpty, copyable: !hook.bodyTemplate.isEmpty)
                DetailRow(label: "Secret", value: "Shown once at creation; rotate on the web", copyable: false)
            } header: {
                Text("Webhook").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("The endpoint path is not a credential. A caller without the secret gets a refusal, a rate limit and an audit record.")
            }

            Section {
                if let last = hook.lastUsedAt { timeRow("Last called", last) } else {
                    DetailRow(label: "Last called", value: "Never", copyable: false)
                }
                if let created = hook.createdAt { timeRow("Created", created) }
                if let updated = hook.updatedAt { timeRow("Updated", updated) }
            }

            attemptsSection

            Section {
                Button {
                    Task { await runner.run(NotifyIntents.testWebhook(hook)) }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("Send test")
                            Text(missing.map { "Needs \($0)" } ?? (hook.enabled ? "Raises \(hook.eventType) through the same path a caller uses." : "The webhook is off: outside callers are refused, but a test still raises \(hook.eventType) through the rules."))
                                .textRole(.footnote)
                        }
                    } icon: {
                        Image(systemName: "paperplane")
                    }
                    .frame(minHeight: Spacing.minimumTarget)
                }
                .disabled(missing != nil)
                WebLinkRow(title: "Edit on web", path: .webhook(id: hook.id))
                WebLinkRow(title: "Rotate secret on web", path: .webhook(id: hook.id))
            } header: {
                Text("Actions").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("A new secret is shown once and belongs at a desk, so rotation stays on the web.")
            }

            Section {
                Button(role: .destructive) {
                    Task { await delete(hook) }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("Delete webhook")
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
            await store.refreshWebhooks()
            await attempts.load(id: id, store: store, session: session)
        }
    }

    @ViewBuilder
    private func routingSection(_ hook: NotifyWebhook) -> some View {
        let routing = NotifyWebhookRouting.of(hook, channels: store.channels.value, rules: store.rules.value)
        Section {
            switch routing {
            case .noChannel:
                notice("No notification channel is enabled", "A call authenticates and renders its message, then reaches nobody. Add a channel before handing the URL out.", tone: .warn)
                NavigationLink("Open Notifications", value: AppRoute.notify(.notifications(view: nil)))
                    .frame(minHeight: Spacing.minimumTarget)
            case .noRule:
                notice("Reaches nobody", "Channels exist, but no enabled rule routes \(hook.eventType), so this webhook delivers nothing. Add a rule for it on the web.", tone: .warn)
                // The console's own fix-it link: it opens the rule form with this event filled in.
                WebLinkRow(title: "Add a rule on web", path: LatticeConsolePath(path: "/platform/notifications", query: [URLQueryItem(name: "newRule", value: hook.eventType)]))
            case .ok:
                let receivers = receivingRules(hook)
                notice("Routed", receivers.isEmpty ? "No rule is enabled, so every enabled channel receives it." : "Rules that send it: \(receivers.joined(separator: ", ")).", tone: .ok)
            case .unknown:
                notice("Reach not judged", "The channels or rules could not be read.", tone: .quiet)
            }
        } header: {
            Text("Who receives it").accessibilityAddTraits(.isHeader)
        }
    }

    private func receivingRules(_ hook: NotifyWebhook) -> [String] {
        (store.rules.value ?? []).filter { $0.enabled && (NotifyRules.matchesEverything($0) || $0.eventTypes.contains(hook.eventType)) }.map(\.displayName)
    }

    private func notice(_ title: String, _ text: String, tone: StatusTone) -> some View {
        let symbol = switch tone {
        case .warn: "exclamationmark.triangle.fill"
        case .ok: "checkmark.circle.fill"
        default: "questionmark.circle"
        }
        return NotifyStatementRow(style: StatusStyle(word: "", symbol: symbol, tone: tone), title: title, detail: text)
    }

    @ViewBuilder
    private var attemptsSection: some View {
        Section {
            switch attempts.state {
            case .idle:
                LoadingRows(label: "Loading attempts", count: 2)
            case .denied(let scope):
                ScopeDeniedRow(scope: scope)
            case .companionBehind(let surface):
                CompanionBehindRow(surface: surface)
            case .failed(let error, nil, _):
                ErrorRow(message: "Could not load attempts: \(error.localizedDescription)") {
                    Task { await attempts.load(id: id, store: store, session: session) }
                }
            default:
                if let rows = attempts.state.value {
                    NotifyRefreshError(state: attempts.state, noun: "attempts") {
                        Task { await attempts.load(id: id, store: store, session: session) }
                    }
                    if rows.isEmpty {
                        Text("Nothing has called this webhook yet.").foregroundStyle(.secondary)
                            .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                    }
                    ForEach(rows) { attempt in
                        attemptRow(attempt)
                    }
                } else {
                    LoadingRows(label: "Loading attempts", count: 2)
                }
            }
        } header: {
            Text("Recent attempts").accessibilityAddTraits(.isHeader)
        } footer: {
            if let rows = attempts.state.value {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Health: \(NotifyWebhookHealth.of(rows).title). The server keeps the last 50 attempts; the audit log keeps every call.")
                    NotifyFreshness(state: attempts.state)
                }
            }
        }
    }

    private func attemptRow(_ attempt: NotifyWebhookDelivery) -> some View {
        let style = StatusStyle.notifyAttempt(attempt.outcome)
        let detail = (attempt.test ? "Test, " : "") + NotifyWebhookAttempt.detail(attempt)
        let problem = attempt.outcome != "accepted"
        return StatusRow(
            style: style,
            title: attempt.title.isEmpty ? NotifyWebhookAttempt.word(attempt.outcome).sentenceCased : attempt.title,
            detail: detail,
            reason: problem && !attempt.reason.isEmpty ? attempt.reason.sentenceCased : nil,
            trailing: attempt.createdAt.map { NotifyTime.when($0, mode: mode, locale: locale) },
            accessibilityPhrase: "\(attempt.test ? "Test attempt" : "Attempt"), \(style.word), \(NotifyWebhookAttempt.detail(attempt))"
        )
    }

    private func timeRow(_ label: String, _ date: Date) -> some View {
        DetailRow(label: label, value: TimeDisplay.dateTime(date, mode: mode, locale: locale), secondary: TimeDisplay.otherZone(date, mode: mode, locale: locale), copyable: false)
    }

    private func delete(_ hook: NotifyWebhook) async {
        let outcome = await runner.run(NotifyIntents.deleteWebhook(hook))
        // The screen closes only once the server confirmed the delete.
        if case .done = outcome { dismiss() }
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Webhook not found", systemImage: "arrow.down.forward.and.arrow.up.backward")
            } description: {
                Text("It was deleted, or this link names a webhook this server does not hold.")
            } actions: {
                Button("Open on web") { router.openOnWeb(.webhook(id: id)) }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let hook = store.webhook(id: id) {
                    NotifyGatedButton(title: "Send test", systemImage: "paperplane", missing: store.adminMissing) {
                        Task { await runner.run(NotifyIntents.testWebhook(hook)) }
                    }
                    Section {
                        Button("Copy link", systemImage: "link") { NotifyCopy.copy(NotifyCopy.link(.webhook(id: id))) }
                        Button("Copy ID", systemImage: "number") { NotifyCopy.copy(id) }
                        Button("Open on web", systemImage: "safari") { router.openOnWeb(.webhook(id: id)) }
                        Button("Edit on web", systemImage: "square.and.pencil") { router.openOnWeb(.webhook(id: id)) }
                        Button("Rotate secret on web", systemImage: "key") { router.openOnWeb(.webhook(id: id)) }
                    }
                    Section {
                        NotifyGatedButton(title: "Delete webhook", systemImage: "trash", missing: store.adminMissing, role: .destructive) {
                            Task { await delete(hook) }
                        }
                    }
                } else {
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.webhook(id: id)) }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    private func refresh() {
        Task { await store.refreshWebhooks() }
    }
}
