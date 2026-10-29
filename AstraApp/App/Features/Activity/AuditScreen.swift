import SwiftUI

/// M4-04 Audit. A scope root, frozen as `init()`. Changes (the default)
/// hides node reachability flips and observe events inside the server's
/// scan; All hides nothing; Integrity shows the last chain verification.
/// The query field's keys are the audit endpoint's own parameters.
struct AuditScreen: View {
    static let queryKey = "activity.audit.query"
    static let layerKey = "activity.audit.layer"
    static let rangeKey = "activity.audit.range"
    /// Demo only: start on a layer (`-AstraAuditLayer integrity`), for screenshots.
    static let layerArgument = "AstraAuditLayer"
    @MainActor private static var appliedLaunchLayer = false

    @Environment(AuditStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(AppState.self) private var appState
    @Environment(ChangeLog.self) private var changes
    @Environment(NodeDirectory.self) private var nodes
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    @SceneStorage(AuditScreen.queryKey) private var query = ""
    @SceneStorage(AuditScreen.layerKey) private var layer: AuditLayer = .changes
    @SceneStorage(AuditScreen.rangeKey) private var rangeTitle = TimeRangeSelection.lastDay.title
    @State private var customRange: TimeRangeSelection?
    @State private var windowAnchor = Date()
    @State private var verifying = false

    var body: some View {
        Group {
            if layer == .integrity {
                integrity
            } else {
                ActivityResource(state: store.page, noun: "audit events", retry: refresh) { page in
                    list(page)
                }
            }
        }
        .searchable(text: $query, prompt: "action:, actor:, node:, trace:")
        .searchScopes($layer, activation: .automatic) {
            ForEach(AuditLayer.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { RangeMenu(selection: rangeBinding) }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
        .sheet(isPresented: $verifying) { AuditVerifySheet() }
        .onAppear(perform: consumeQuery)
        .onAppear(perform: applyLaunchLayer)
        .onChange(of: appState.pendingQuery) { consumeQuery() }
        .polling(.standard, version: ActivityPollKey.of(changes.version([.audit, .tasks, .approvals]), request)) {
            await nodes.refreshIfOlder(than: 60)
            guard layer != .integrity else { return true }
            // Past the first page a poll would re-page under the reader; it holds still.
            if (store.page.value?.events.count ?? 0) > AuditModel.pageSize, store.query == request { return true }
            return await store.refresh(request)
        }
    }

    // MARK: Question

    private var range: TimeRangeSelection {
        customRange ?? TimeRangeSelection.presets.first { $0.title == rangeTitle } ?? .lastDay
    }

    private var rangeBinding: Binding<TimeRangeSelection> {
        Binding(get: { range }, set: { value in
            windowAnchor = Date()
            if case .custom = value { customRange = value } else { customRange = nil; rangeTitle = value.title }
        })
    }

    private var tokens: TasksParsedTokens {
        let directory = nodes.nodes
        let byName = Dictionary(directory.values.map { ($0.displayName.lowercased(), $0.id) }, uniquingKeysWith: { a, _ in a })
        let resolve: @Sendable (String) -> String? = { value in directory[value] != nil ? value : byName[value.lowercased()] }
        return TasksTokens.parse(query, grammar: AuditModel.grammar, resolvers: directory.isEmpty ? [:] : ["node": resolve])
    }

    private var request: AuditQuery {
        AuditModel.request(layer: layer == .integrity ? .all : layer, tokens: tokens, from: range.since(now: windowAnchor), to: range.until, offset: 0)
    }

    /// Empty for the default view (Changes, last 24 h), so the tab's title keeps its place.
    private var subtitle: String {
        if layer == .changes, !isFiltered { return "" }
        var parts = [layer == .changes ? "Changes" : (layer == .all ? "All events" : "Integrity")]
        if layer != .integrity {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(query) }
            parts.append(range == .all ? "any time" : "last \(range.title)")
        }
        return parts.joined(separator: ", ")
    }

    private var isFiltered: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || range != .lastDay
    }

    // MARK: Events

    private func list(_ page: AuditPage) -> some View {
        let days = groupedByDay(page.events)
        return List {
            ActivityRefreshError(state: store.page, noun: "audit events", retry: refresh)
            if isFiltered {
                FilterStateRow(text: "Showing \(subtitle)") {
                    query = ""
                    customRange = nil
                    rangeTitle = TimeRangeSelection.lastDay.title
                    windowAnchor = Date()
                }
            }
            if let notice = ActivityQueryNotice.message(tokens, textAllowed: true, keys: "") {
                Section { ActivityQueryNotice(message: notice) }
            }
            exportSection
            if page.events.isEmpty {
                ContentUnavailableView {
                    Label(isFiltered ? "No events match" : "No changes in the last day", systemImage: "list.bullet.rectangle")
                } description: {
                    Text(isFiltered ? "Nothing matched in this range. Widen the range, or drop a token." : "Nothing was changed in the last 24 hours. All shows every event, including node flips.")
                }
            }
            ForEach(days, id: \.day) { group in
                Section {
                    ForEach(group.events) { event in
                        NavigationLink(value: AppRoute.activity(.auditEvent(id: event.id))) {
                            ActivityAuditRow(event: event, nodeName: nodes.name(for:))
                        }
                        .contextMenu {
                            ActivityObjectMenu(route: .activity(.auditEvent(id: event.id)), link: .auditEvent(id: event.id), web: .auditEvent(id: event.id), objectID: event.id)
                            if !event.correlationID.isEmpty {
                                Button("Open trace", systemImage: "point.3.connected.trianglepath.dotted") {
                                    router.push(.activity(.trace(correlationID: event.correlationID)))
                                }
                            }
                        } preview: {
                            ActivityAuditRow(event: event, nodeName: nodes.name(for:)).padding().frame(width: 340)
                        }
                    }
                } header: {
                    Text(group.title).accessibilityAddTraits(.isHeader)
                }
            }
            if store.hasMore {
                Section { loadMore }
            }
            Section {} footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(AuditModel.scanLine(page, locale: locale))
                        .textRole(.footnote)
                        .foregroundStyle(page.isPartial ? Color.statusWarnText : .secondary)
                    ActivityFreshness(state: store.page)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            windowAnchor = Date()
            await store.refresh(request)
        }
    }

    private struct DayGroup {
        let day: Date
        let title: String
        let events: [AuditEvent]
    }

    private func groupedByDay(_ events: [AuditEvent]) -> [DayGroup] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = mode.timeZone
        var order: [Date] = []
        var byDay: [Date: [AuditEvent]] = [:]
        for event in events {
            let day = calendar.startOfDay(for: event.at ?? .distantPast)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(event)
        }
        return order.map { day in
            let title: String
            if calendar.isDateInToday(day) { title = "Today" }
            else if calendar.isDateInYesterday(day) { title = "Yesterday" }
            else if day == calendar.startOfDay(for: .distantPast) { title = "Undated" }
            else {
                var style = Date.FormatStyle.dateTime.locale(locale).weekday(.wide).month(.abbreviated).day()
                style.timeZone = mode.timeZone
                title = day.formatted(style)
            }
            let count = byDay[day]?.count ?? 0
            return DayGroup(day: day, title: "\(title) (\(count))", events: byDay[day] ?? [])
        }
    }

    private var loadMore: some View {
        Group {
            if let error = store.loadMoreError {
                ErrorRow(message: "Could not load older events: \(error.localizedDescription)") { Task { await store.loadMore() } }
            } else {
                Button(store.isLoadingMore ? "Loading older events" : "Load older events") { Task { await store.loadMore() } }
                    .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget)
                    .disabled(store.isLoadingMore)
            }
        }
    }

    // MARK: Export

    /// Export and Verify chain share one menu, so the tab's title keeps its place.
    private var moreMenu: some View {
        Menu {
            Section("Export what this question matches") {
                Button("Export CSV", systemImage: "tablecells") { export(.csv) }
                    .disabled(store.export.isRunning || store.page.value == nil)
                Button("Export NDJSON", systemImage: "curlybraces") { export(.ndjson) }
                    .disabled(store.export.isRunning || store.page.value == nil)
            }
            Section {
                Button("Export audit head", systemImage: "seal") { export(.head) }
                    .disabled(store.export.isRunning)
                Button("Verify chain", systemImage: "checkmark.shield") { verifying = true }
            }
            Section {
                Button("Open on web", systemImage: "safari") { router.openOnWeb(.audit(view: layer.rawValue)) }
            }
        } label: {
            Label("Export and verify", systemImage: "ellipsis.circle")
        }
    }

    private func export(_ format: AuditExportFormat) {
        let query = request
        Task { await store.startExport(format, query: query) }
    }

    @ViewBuilder
    private var exportSection: some View {
        switch store.export {
        case .idle:
            EmptyView()
        case .running(let count):
            Section {
                Text(count == 0 ? "Exporting: reading the first page" : "Exporting: \(count.formatted(.number.locale(locale))) events read")
                    .contentTransition(.numericText())
                    .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
            } header: {
                Text("Export").accessibilityAddTraits(.isHeader)
            }
        case .ready(let file, let title, let summary):
            Section {
                ShareLink(item: file, preview: SharePreview(title)) {
                    Label {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("Share \(file.name)")
                            Text(summary).textRole(.rowDetail)
                        }
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .frame(minHeight: Spacing.minimumTarget)
                }
                Button("Done", role: .cancel) { store.clearExport() }
            } header: {
                Text("Export").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Built on this iPhone from the server's own records. It is not kept here once you leave.")
            }
        case .failed(let message):
            Section {
                Label {
                    Text(message).foregroundStyle(Color.statusFailText)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusFailFill)
                }
                .frame(minHeight: Spacing.minimumTarget)
                Button("Dismiss") { store.clearExport() }
            } header: {
                Text("Export").accessibilityAddTraits(.isHeader)
            }
        }
    }

    // MARK: Integrity

    private var integrity: some View {
        List {
            exportSection
            Section {
                if let last = store.lastVerify {
                    let style = ActivityStyle.chain(last.status)
                    ActivityStateHeader(style: style, reason: integrityReason(last.status))
                    DetailRow(label: "Verified", value: TimeDisplay.dateTime(last.at, mode: mode, locale: locale),
                              secondary: TimeDisplay.otherZone(last.at, mode: mode, locale: locale), copyable: false)
                    if last.status.enabled {
                        DetailRow(label: "Events checked", value: last.status.count.formatted(.number.locale(locale)), copyable: false)
                        if !last.status.head.isEmpty { DetailRow(label: "Head", value: last.status.head, monospaced: true) }
                    }
                } else {
                    ActivityStateHeader(style: StatusStyle(word: "not verified on this iPhone", symbol: "shield", tone: .quiet),
                                        reason: "Verification walks the server's audit log and checks every link of its hash chain.")
                }
                Button("Verify now", systemImage: "checkmark.shield") { verifying = true }
                    .frame(minHeight: Spacing.minimumTarget)
            } header: {
                Text("Chain").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("A broken chain names the first record that does not match. The result is kept on this iPhone only until the app closes.")
            }
            Section {
                Button("Export audit head", systemImage: "seal") { export(.head) }
                    .frame(minHeight: Spacing.minimumTarget)
                    .disabled(store.export.isRunning)
            } header: {
                Text("Off-box anchor").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("The head record is the verified count and hash. Keep it somewhere the server cannot reach; a later head that does not extend it shows the log was cut.")
            }
            Section {
                WebLinkRow(path: .audit(view: "integrity"))
            }
        }
        .listStyle(.insetGrouped)
    }

    private func integrityReason(_ status: AuditChainStatus) -> String? {
        if !status.enabled { return "This server keeps no audit WAL, so there is no chain to check." }
        if !status.ok { return status.error.map { "First broken link: \($0)" } ?? "The chain does not verify." }
        return status.anchored ? "Every link matches, and the anchor guards the end of the log." : "Every link matches. No anchor guards the end of the log against truncation."
    }

    private func consumeQuery() {
        if let pending = appState.consumeQuery(ActivityScope.audit.rawValue) { query = pending }
    }

    private func applyLaunchLayer() {
        guard session.isDemo, !Self.appliedLaunchLayer else { return }
        Self.appliedLaunchLayer = true
        if let raw = UserDefaults.standard.string(forKey: Self.layerArgument), let value = AuditLayer(rawValue: raw) { layer = value }
    }

    private func refresh() {
        let request = request
        Task { await store.refresh(request) }
    }
}

/// An audit event: what it did in words, who, on which node and object,
/// the decision as symbol and word, and when.
struct ActivityAuditRow: View {
    let event: AuditEvent
    let nodeName: (String) -> String

    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        let style = ActivityStyle.decision(AuditModel.decision(of: event))
        let words = AuditActionWords.words(for: event.action)
        StatusRow(
            style: style,
            title: words,
            detail: detail(labelled: words != event.action),
            reason: style.tone.isProblem && !event.reason.isEmpty ? event.reason : nil,
            trailing: event.at.map { TimeDisplay.clock($0, mode: mode, locale: locale) },
            accessibilityPhrase: "\(words), \(style.word)" + (event.actorID.isEmpty ? "" : ", by \(event.actorID)")
        )
    }

    private func detail(labelled: Bool) -> String {
        var parts: [String] = []
        if labelled { parts.append(event.action) }
        if !event.actorID.isEmpty { parts.append(event.actorID) }
        if !event.nodeID.isEmpty { parts.append(nodeName(event.nodeID)) }
        if let object = AuditModel.object(of: event) { parts.append(object) }
        return parts.map(\.activityUnbroken).joined(separator: ", ")
    }
}
