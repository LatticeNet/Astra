import SwiftUI

/// M9-02 Sent. A scope root, frozen as `init()`, and the Sent view of
/// Notifications. Deliveries newest first, grouped by day: title, channel,
/// outcome word, time, repeats. The Filter menu's outcome, channel and event
/// type go to the server as `outcome`, `channel_id` and `event_type`; the
/// search field runs the console's grammar over the rows that came back.
struct SentLogScreen: View {
    static let queryKey = "activity.sent.query"
    static let outcomeKey = "activity.sent.outcome"
    static let channelKey = "activity.sent.channel"
    static let eventKey = "activity.sent.event"

    /// Leading on the Activity tab root, where trailing belongs to Settings
    /// alone; trailing when pushed inside Notifications.
    private let filterPlacement: ToolbarItemPlacement

    @Environment(NotifyStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    @SceneStorage(SentLogScreen.queryKey) private var query = ""
    @SceneStorage(SentLogScreen.outcomeKey) private var outcomeRaw = NotifySentOutcomeFilter.all.rawValue
    @SceneStorage(SentLogScreen.channelKey) private var channelID = ""
    @SceneStorage(SentLogScreen.eventKey) private var eventType = ""
    @State private var stable = NotifyStableList<NotifyDelivery>()
    /// The filters the shown rows answer; a different question applies at once.
    @State private var shownQuestion: NotifySentFilters?

    init() { filterPlacement = .topBarTrailing }

    init(filterPlacement: ToolbarItemPlacement) { self.filterPlacement = filterPlacement }

    var body: some View {
        NotifyResourceScreen(state: store.sent, noun: "the Sent log", retry: refresh) { response in
            list(response)
        }
        .searchable(text: $query, tokens: tokensBinding, prompt: "Search, state:, channel:") { token in
            Label(token.title, systemImage: token.symbol)
        }
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: filterPlacement) { filterMenu }
        }
        .onAppear {
            consumeQuery()
            // The store may already hold the log (another Sent view, or offline).
            offer(force: true)
        }
        .onChange(of: appState.pendingQuery) { consumeQuery() }
        .onChange(of: store.sent.loadedAt) { offer(force: false) }
        .onChange(of: query) { offer(force: true) }
        .onChange(of: filters) { offer(force: true) }
        .polling(.standard, version: NotifyPollKey.of(changes.version([.notify, .webhooks]), filters)) {
            await store.refreshSent(filters: filters)
        }
    }

    // MARK: Filters

    private var filters: NotifySentFilters {
        NotifySentFilters(outcome: NotifySentOutcomeFilter(rawValue: outcomeRaw) ?? .all, channelID: channelID, eventType: eventType)
    }

    private var channelOptions: [(id: String, name: String)] {
        var seen: [(String, String)] = (store.channels.value ?? []).map { ($0.id, $0.displayName) }
        for delivery in store.sent.value?.deliveries ?? [] where !delivery.channelID.isEmpty && !seen.contains(where: { $0.0 == delivery.channelID }) {
            seen.append((delivery.channelID, delivery.channelName.isEmpty ? delivery.channelID : "\(delivery.channelName), since deleted"))
        }
        if !channelID.isEmpty && !seen.contains(where: { $0.0 == channelID }) { seen.append((channelID, channelID)) }
        return seen.sorted { $0.1.localizedCompare($1.1) == .orderedAscending }.map { (id: $0.0, name: $0.1) }
    }

    private var eventOptions: [String] {
        var types = Set((store.sent.value?.deliveries ?? []).map(\.eventType).filter { !$0.isEmpty })
        for entry in store.catalogue.value?.types ?? [] { types.insert(entry.type) }
        for entry in store.catalogue.value?.webhookTypes ?? [] { types.insert(entry.type) }
        if !eventType.isEmpty { types.insert(eventType) }
        return types.sorted { store.eventLabel($0).localizedCompare(store.eventLabel($1)) == .orderedAscending }
    }

    private func channelName(_ id: String) -> String {
        channelOptions.first { $0.id == id }?.name ?? id
    }

    private var filterMenu: some View {
        let channelTitles = ["All channels"] + channelOptions.map(\.name)
        let eventTitles = ["All event types"] + eventOptions.map { store.eventLabel($0) }
        return FilterMenu(sections: [
            FilterMenuSection(title: "Outcome", options: NotifySentOutcomeFilter.allCases.map(\.title), defaultOption: NotifySentOutcomeFilter.all.title,
                              selection: Binding(get: { filters.outcome.title }, set: { outcomeRaw = NotifySentOutcomeFilter.titled($0).rawValue })),
            FilterMenuSection(title: "Channel", options: channelTitles, defaultOption: "All channels",
                              selection: Binding(get: { channelID.isEmpty ? "All channels" : channelName(channelID) },
                                                 set: { title in channelID = channelOptions.first { $0.name == title }?.id ?? "" })),
            FilterMenuSection(title: "Event type", options: eventTitles, defaultOption: "All event types",
                              selection: Binding(get: { eventType.isEmpty ? "All event types" : store.eventLabel(eventType) },
                                                 set: { title in eventType = eventOptions.first { store.eventLabel($0) == title } ?? "" })),
        ])
    }

    private struct FilterToken: Identifiable, Hashable {
        enum Kind { case outcome, channel, event }
        let kind: Kind
        let title: String
        var id: Kind { kind }
        var symbol: String {
            switch kind {
            case .outcome: "line.3.horizontal.decrease.circle"
            case .channel: "bell"
            case .event: "tag"
            }
        }
    }

    private var tokensBinding: Binding<[FilterToken]> {
        Binding(
            get: {
                var tokens: [FilterToken] = []
                if filters.outcome != .all { tokens.append(FilterToken(kind: .outcome, title: filters.outcome.title)) }
                if !channelID.isEmpty { tokens.append(FilterToken(kind: .channel, title: channelName(channelID))) }
                if !eventType.isEmpty { tokens.append(FilterToken(kind: .event, title: store.eventLabel(eventType))) }
                return tokens
            },
            set: { tokens in
                if !tokens.contains(where: { $0.kind == .outcome }) { outcomeRaw = NotifySentOutcomeFilter.all.rawValue }
                if !tokens.contains(where: { $0.kind == .channel }) { channelID = "" }
                if !tokens.contains(where: { $0.kind == .event }) { eventType = "" }
            }
        )
    }

    private var appliedParts: [String] {
        var parts: [String] = []
        if filters.outcome != .all { parts.append(filters.outcome.title) }
        if !channelID.isEmpty { parts.append(channelName(channelID)) }
        if !eventType.isEmpty { parts.append(store.eventLabel(eventType)) }
        return parts
    }

    private var subtitle: String {
        appliedParts.joined(separator: ", ")
    }

    // MARK: Rows

    private var compiled: Result<LatticeCompiledQuery<NotifyDelivery>, LatticeQueryError> {
        LatticeQueryEngine.compile(query, provider: NotifySentQueryFields.self)
    }

    /// The stored log, when it answers the filters on screen.
    private var answer: NotifyDeliveriesResponse? {
        store.sentFilters == filters ? store.sent.value : nil
    }

    private func offer(force: Bool) {
        let rows = answer?.deliveries ?? []
        let filtered: [NotifyDelivery] = switch compiled {
        case .success(let q): LatticeQueryEngine.apply(q, to: rows, now: Date())
        case .failure: rows
        }
        // Only polls of the same question are held (section 5.0).
        stable.offer(filtered, voiceOver: voiceOver, force: force || shownQuestion != filters)
        if answer != nil { shownQuestion = filters }
    }

    private func list(_ response: NotifyDeliveriesResponse) -> some View {
        let rows = stable.shown
        let answering = answer != nil && shownQuestion == filters
        let calendar = displayCalendar
        let days = Dictionary(grouping: rows) { delivery in
            delivery.createdAt.map { calendar.startOfDay(for: $0) } ?? .distantPast
        }
        let order = days.keys.sorted(by: >)
        return List {
            NotifyRefreshError(state: store.sent, noun: "the Sent log", retry: refresh)
            if !appliedParts.isEmpty {
                FilterStateRow(text: "Showing \(appliedParts.joined(separator: ", ")) only") {
                    outcomeRaw = NotifySentOutcomeFilter.all.rawValue
                    channelID = ""
                    eventType = ""
                }
            }
            if case .failure(let error) = compiled, !query.isEmpty {
                Section {
                    Label {
                        Text(queryProblem(error)).foregroundStyle(Color.statusWarnText)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.statusWarnFill)
                    }
                    .frame(minHeight: Spacing.minimumTarget)
                }
            }
            if stable.held != nil, voiceOver {
                Section { PendingUpdatesRow(count: stable.pendingCount) { stable.showHeld() } }
            }
            if rows.isEmpty {
                if answering {
                    emptyState(serverEmpty: response.deliveries.isEmpty)
                } else {
                    LoadingRows(label: "Loading the Sent log", count: 3)
                }
            }
            ForEach(order, id: \.self) { day in
                Section {
                    ForEach(days[day] ?? []) { delivery in
                        NavigationLink(value: AppRoute.notify(.delivery(id: delivery.id))) {
                            NotifyDeliveryRow(delivery: delivery, eventLabel: store.eventLabel(delivery.eventType))
                        }
                        .contextMenu {
                            NotifyObjectMenu(route: .notify(.delivery(id: delivery.id)), link: .notifyDelivery(id: delivery.id), web: .notifyDelivery(id: delivery.id), objectID: delivery.id)
                            if !delivery.channelID.isEmpty {
                                Button("Show this channel only", systemImage: "line.3.horizontal.decrease.circle") { channelID = delivery.channelID }
                            }
                        }
                    }
                } header: {
                    Text(dayTitle(day, calendar: calendar)).accessibilityAddTraits(.isHeader)
                }
            }
            Section {} footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    if answering {
                        Text(storageLine(response)).textRole(.footnote)
                    }
                    NotifyFreshness(state: store.sent)
                }
            }
        }
        .listStyle(.insetGrouped)
        .onScrollPhaseChange { _, phase in
            if phase != .idle { stable.noteActivity() }
        }
        .refreshable {
            await store.refreshSent(filters: filters)
            offer(force: true)
        }
    }

    @ViewBuilder
    private func emptyState(serverEmpty: Bool) -> some View {
        if serverEmpty && appliedParts.isEmpty {
            ContentUnavailableView {
                Label("Nothing sent yet", systemImage: "paperplane")
            } description: {
                Text("Deliveries appear here as events reach channels. Send a test from a channel to see one.")
            }
        } else {
            ContentUnavailableView {
                Label("No deliveries match", systemImage: "magnifyingglass")
            } description: {
                Text(appliedParts.isEmpty ? "Nothing matched the search." : "Nothing matched \(appliedParts.joined(separator: ", ")). Clear a filter to widen the log.")
            }
        }
    }

    private func storageLine(_ response: NotifyDeliveriesResponse) -> String {
        let shown = response.deliveries.count
        let stored = "\(response.stored) stored"
        let kept = response.durable
            ? "kept on disk, the last \(response.max)"
            : "History is lost on restart: the outbox is kept in memory only"
        // The server stops at the page limit; below it every match is shown.
        let page = shown >= NotifySentFilters.limit ? "Showing the newest \(shown) that match. " : ""
        return response.durable ? "\(page)\(stored), \(kept)." : "\(page)\(stored). \(kept)."
    }

    /// Days in the zone the row times use, so UTC mode groups by UTC days.
    private var displayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = mode.timeZone
        calendar.locale = locale
        return calendar
    }

    private func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if day == .distantPast { return "Undated" }
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.abbreviated).day().locale(locale)
        style.timeZone = mode.timeZone
        return day.formatted(style)
    }

    private func queryProblem(_ error: LatticeQueryError) -> String {
        if let field = error.params["field"] {
            let suggestion = error.params["suggestion"].flatMap { $0.isEmpty ? nil : " Did you mean \($0):?" } ?? ""
            return "\(field): is not a Sent field, so the search shows every row.\(suggestion) Fields: state, channel, event, rule, severity, source, role, incident, is:recovery."
        }
        return "The search could not be read, so it shows every row."
    }

    /// A link's `outcome:`, `channel_id:` and `event_type:` words are the
    /// server's own filter names, so they become the Filter menu's choices;
    /// the rest is search text.
    private func consumeQuery() {
        guard let pending = appState.consumeQuery(ActivityScope.sent.rawValue) else { return }
        // A link states the whole question, so filters left from earlier do not narrow it.
        outcomeRaw = NotifySentOutcomeFilter.all.rawValue
        channelID = ""
        eventType = ""
        var text: [String] = []
        for word in pending.split(whereSeparator: \.isWhitespace).map(String.init) {
            let parts = word.split(separator: ":", maxSplits: 1).map(String.init)
            switch (parts.first, parts.count) {
            case ("outcome", 2) where NotifySentOutcomeFilter(rawValue: parts[1]) != nil: outcomeRaw = parts[1]
            case ("channel_id", 2): channelID = parts[1]
            case ("event_type", 2): eventType = parts[1]
            default: text.append(word)
            }
        }
        query = text.joined(separator: " ")
    }

    private func refresh() {
        Task { await store.refreshSent(filters: filters) }
    }
}
