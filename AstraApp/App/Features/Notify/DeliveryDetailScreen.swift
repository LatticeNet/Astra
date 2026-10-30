import SwiftUI

/// What one delivery screen reads: the delivery (from the loaded Sent log,
/// or the newest 200 of the outbox when opened by link, since the listing
/// takes no id) and the incidents it reports.
@MainActor @Observable
final class NotifyDeliveryModel {
    static let lookupLimit = 200

    private(set) var delivery: ResourceState<NotifyDelivery?> = .idle
    private(set) var incidents: ResourceState<[Incident]> = .idle

    @discardableResult
    func load(id: String, store: NotifyStore, session: SessionStore) async -> Bool {
        if let known = store.sent.value?.deliveries.first(where: { $0.id == id }), delivery.value == nil {
            delivery = .loaded(known, at: store.sent.loadedAt ?? Date())
        }
        if store.isConfined { return true }
        if let missing = store.adminMissing {
            delivery = .denied(scope: missing)
            return true
        }
        guard let client = session.client else { return false }
        let before = delivery
        delivery = before.reloading
        do {
            let rows = try await client.fetchDeliveries(query: DeliveryQuery(limit: Self.lookupLimit)).deliveries
            let found = rows.first { $0.id == id }
            // A row that aged out of the newest 200 keeps what the Sent log showed.
            delivery = .loaded(found ?? before.value ?? nil, at: Date())
        } catch {
            if NotifyStore.isCancellation(error) {
                delivery = before
                return true
            }
            let apiError = LatticeAPIError(error)
            if case .invalidResponse = apiError { session.markCompanionBehind("The delivery") }
            delivery = delivery.failing(apiError, surface: "The delivery", missingScope: NotifyIntents.adminScope)
            return false
        }
        await loadIncidents(session: session)
        return true
    }

    private func loadIncidents(session: SessionStore) async {
        guard let ids = delivery.value??.incidentIDs, !ids.isEmpty else { return }
        if let missing = session.missing(ScopeRequirement("monitor:read")), !missing.isEmpty {
            incidents = .denied(scope: missing.joined(separator: " and "))
            return
        }
        guard let client = session.client else { return }
        do {
            let all = try await client.listIncidents().incidents
            incidents = .loaded(all.filter { ids.contains($0.id) }, at: Date())
        } catch {
            if NotifyStore.isCancellation(error) { return }
            incidents = incidents.failing(LatticeAPIError(error), surface: "Incidents", missingScope: "monitor:read")
        }
    }
}

/// M9-03 Delivery. The title and body as sent, the channel, rule, role and
/// fallback, every attempt with its outcome and time, a hold, and the
/// incidents it reports, each one tap from IncidentDetail.
struct DeliveryDetailScreen: View {
    let id: String

    @Environment(NotifyStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    @State private var model = NotifyDeliveryModel()

    var body: some View {
        NotifyResourceScreen(state: model.delivery, noun: "the delivery", retry: refresh) { delivery in
            if let delivery {
                detail(delivery)
            } else {
                notFound
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .polling(.standard, version: changes.version([.notify])) {
            await model.load(id: id, store: store, session: session)
        }
        .task {
            await store.refreshRoutingIfNeeded()
        }
    }

    private var current: NotifyDelivery? { model.delivery.value ?? nil }

    private var title: String {
        guard let delivery = current else { return "Delivery" }
        return store.eventLabel(delivery.eventType)
    }

    private var subtitle: String {
        guard let delivery = current else { return "" }
        return StatusStyle.notifySent(delivery, now: Date()).word
    }

    // MARK: Detail

    private func detail(_ delivery: NotifyDelivery) -> some View {
        let state = NotifySentState.of(delivery, now: Date())
        return List {
            Section {
                NotifyRefreshError(state: model.delivery, noun: "the delivery", retry: refresh)
                EventHeader(
                    style: .notifySent(delivery, now: Date()),
                    title: delivery.title.isEmpty ? store.eventLabel(delivery.eventType) : delivery.title,
                    detail: [NotifySent.severityWord(delivery).lowercased(), delivery.createdAt.map { NotifyTime.when($0, mode: mode, locale: locale) }].compactMap { $0 }.joined(separator: " · "),
                    reason: headline(delivery, state: state)
                )
            }

            messageSection(delivery)
            deliverySection(delivery)
            attemptsSection(delivery, state: state)
            incidentsSection(delivery)
            detailsSection(delivery)
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.load(id: id, store: store, session: session) }
    }

    /// The one sentence a problem or a hold needs, first.
    private func headline(_ delivery: NotifyDelivery, state: NotifySentState) -> String? {
        switch state {
        case .failed, .retrying:
            let cause = NotifySent.cause(delivery).map { $0.sentence } ?? "the send failed"
            let tries = delivery.attempts.count == 1 ? "1 attempt" : "\(delivery.attempts.count) attempts"
            return "Not delivered after \(tries): \(cause)."
        case .held, .notRouted:
            return NotifySentNote.of(delivery)?.sentence(mode: mode, locale: locale)
        case .queued:
            return NotifySent.isOverdue(delivery, now: Date())
                ? "Due for its first attempt but not sent yet. The server's outbox may be stuck; check System in Browse."
                : "Planned and waiting for its first attempt."
        case .sent:
            return nil
        }
    }

    private func messageSection(_ delivery: NotifyDelivery) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(delivery.title.isEmpty ? "No title" : delivery.title)
                    .font(.headline)
                if delivery.body.isEmpty {
                    Text("No body: the title was the whole message.").foregroundStyle(.secondary)
                } else {
                    Text(delivery.body)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
            .accessibilityElement(children: .combine)
        } header: {
            Text("Message as sent").accessibilityAddTraits(.isHeader)
        } footer: {
            Text(delivery.truncated
                 ? "The server cut this message to its title and body limits. This is the shortened text the channel received."
                 : "This is the text the channel received, after the rule's templates.")
        }
    }

    @ViewBuilder
    private func deliverySection(_ delivery: NotifyDelivery) -> some View {
        Section {
            if delivery.channelID.isEmpty {
                DetailRow(label: "Channel", value: "No channel", copyable: false)
            } else if let channel = store.channel(id: delivery.channelID) {
                NavigationLink(value: AppRoute.notify(.channel(id: channel.id))) {
                    NotifyChannelRow(channel: channel, fallback: store.channel(id: channel.fallbackChannelID))
                }
            } else {
                // Channel fields are a snapshot, so a deleted channel still reads.
                DetailRow(label: "Channel", value: "\(delivery.channelName.isEmpty ? delivery.channelID : delivery.channelName), \(NotifyKind.label(delivery.channelKind))", copyable: false)
            }
            if delivery.ruleID.isEmpty {
                DetailRow(label: "Rule", value: delivery.role == "test" ? "None: a test" : "Routed without a rule", copyable: false)
            } else if store.rule(id: delivery.ruleID) != nil {
                NavigationLink(value: AppRoute.notify(.rule(id: delivery.ruleID))) {
                    DetailRow(label: "Rule", value: delivery.ruleName.isEmpty ? delivery.ruleID : delivery.ruleName, copyable: false)
                }
            } else {
                // Rule fields are a snapshot too; "since deleted" only once the rules have loaded.
                let name = delivery.ruleName.isEmpty ? delivery.ruleID : delivery.ruleName
                DetailRow(label: "Rule", value: store.rules.value == nil ? name : "\(name), since deleted", copyable: false)
            }
            DetailRow(label: "Role", value: roleText(delivery), copyable: false)
            if delivery.source == "webhook", let hook = store.webhook(id: delivery.sourceID) {
                NavigationLink(value: AppRoute.notify(.webhook(id: hook.id))) {
                    DetailRow(label: "From", value: "Inbound webhook \(hook.displayName)", copyable: false)
                }
            } else {
                DetailRow(label: "From", value: NotifySent.origin(delivery), copyable: false)
            }
            if let held = delivery.heldUntil {
                DetailRow(label: "Held until", value: TimeDisplay.dateTime(held, mode: mode, locale: locale), secondary: TimeDisplay.otherZone(held, mode: mode, locale: locale), copyable: false)
            }
            if let next = delivery.nextAttemptAt {
                DetailRow(label: "Next try", value: TimeDisplay.dateTime(next, mode: mode, locale: locale), secondary: TimeDisplay.otherZone(next, mode: mode, locale: locale), copyable: false)
            }
            if let count = NotifySent.occurrences(delivery) {
                DetailRow(label: "Happened", value: "\(count) times; repeats within an hour share this row", copyable: false)
            }
        } header: {
            Text("Delivery").accessibilityAddTraits(.isHeader)
        } footer: {
            if !delivery.fallbackFor.isEmpty {
                let name = store.channel(id: delivery.fallbackFor)?.displayName ?? delivery.fallbackFor
                Text("Sent through the fallback because \(name) did not deliver it.")
            }
        }
    }

    private func roleText(_ delivery: NotifyDelivery) -> String {
        switch delivery.role {
        case "fallback": "Fallback"
        case "test": "Test from the console"
        case "primary", "": "Primary"
        default: delivery.role
        }
    }

    @ViewBuilder
    private func attemptsSection(_ delivery: NotifyDelivery, state: NotifySentState) -> some View {
        Section {
            if delivery.attempts.isEmpty {
                Text(state == .held ? "No attempt: the message was held." : (state == .notRouted ? "No attempt: no channel was chosen." : "No attempt yet."))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
            }
            ForEach(Array(delivery.attempts.enumerated()), id: \.offset) { index, attempt in
                attemptRow(attempt, number: index + 1)
            }
        } header: {
            Text(delivery.attempts.count == 1 ? "1 attempt" : "\(delivery.attempts.count) attempts").accessibilityAddTraits(.isHeader)
        }
    }

    private func attemptRow(_ attempt: NotifyAttempt, number: Int) -> some View {
        let style = attempt.ok
            ? StatusStyle(word: "delivered", symbol: "checkmark.circle.fill", tone: .ok)
            : StatusStyle(word: "failed", symbol: "xmark.circle.fill", tone: .fail)
        let status = attempt.status.map { "HTTP \($0)" }
        let detail = [status, "\(attempt.durationMs) ms"].compactMap { $0 }.joined(separator: ", ")
        let reason = attempt.ok ? nil : NotifyFailureCause.of(kind: attempt.kind, status: attempt.status).sentence
        return StatusRow(
            style: style,
            title: "Attempt \(number)",
            detail: detail,
            reason: reason.map { $0.prefix(1).uppercased() + $0.dropFirst() },
            trailing: attempt.at.map { TimeDisplay.clock($0, mode: mode, locale: locale) },
            accessibilityPhrase: "Attempt \(number), \(style.word), \(detail)"
        )
    }

    @ViewBuilder
    private func incidentsSection(_ delivery: NotifyDelivery) -> some View {
        if !delivery.incidentIDs.isEmpty {
            Section {
                switch model.incidents {
                case .denied(let scope):
                    ScopeDeniedRow(scope: scope)
                    ForEach(delivery.incidentIDs, id: \.self) { incidentLink($0) }
                default:
                    let loaded = model.incidents.value ?? []
                    ForEach(delivery.incidentIDs, id: \.self) { incidentID in
                        if let incident = loaded.first(where: { $0.id == incidentID }) {
                            NavigationLink(value: AppRoute.monitoring(.incident(id: incident.id))) {
                                IncidentRow(incident: incident)
                            }
                        } else {
                            incidentLink(incidentID)
                        }
                    }
                }
            } header: {
                Text(delivery.incidentIDs.count == 1 ? "Reports 1 incident" : "Reports \(delivery.incidentIDs.count) incidents").accessibilityAddTraits(.isHeader)
            }
        }
    }

    private func incidentLink(_ incidentID: String) -> some View {
        NavigationLink(value: AppRoute.monitoring(.incident(id: incidentID))) {
            DetailRow(label: "Incident", value: incidentID, monospaced: true, copyable: false)
        }
    }

    private func detailsSection(_ delivery: NotifyDelivery) -> some View {
        Section {
            if let created = delivery.createdAt {
                DetailRow(label: "Planned", value: TimeDisplay.dateTime(created, mode: mode, locale: locale), secondary: TimeDisplay.otherZone(created, mode: mode, locale: locale), copyable: false)
            }
            if let settled = delivery.settledAt {
                DetailRow(label: "Settled", value: TimeDisplay.dateTime(settled, mode: mode, locale: locale), secondary: TimeDisplay.otherZone(settled, mode: mode, locale: locale), copyable: false)
            }
            DetailRow(label: "Event type", value: delivery.eventType, monospaced: true)
            if !delivery.eventID.isEmpty {
                DetailRow(label: "Event ID", value: delivery.eventID, monospaced: true)
            }
            DetailRow(label: "Delivery ID", value: delivery.id, monospaced: true)
        } header: {
            Text("Details").accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: States

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Not found in the last \(NotifyDeliveryModel.lookupLimit)", systemImage: "questionmark.square.dashed")
            } description: {
                Text("The outbox evicted this delivery, or it is older than the newest \(NotifyDeliveryModel.lookupLimit) the phone reads.")
            } actions: {
                Button("Open on web") { router.openOnWeb(.notifyDelivery(id: id)) }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Copy link", systemImage: "link") { NotifyCopy.copy(NotifyCopy.link(.notifyDelivery(id: id))) }
                Button("Copy ID", systemImage: "number") { NotifyCopy.copy(id) }
                Button("Open on web", systemImage: "safari") { router.openOnWeb(.notifyDelivery(id: id)) }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    private func refresh() {
        Task { await model.load(id: id, store: store, session: session) }
    }
}
