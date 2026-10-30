import SwiftUI

/// M10-02 Connections. Connection records newest first: source to
/// destination, protocol, bytes, duration and time, with how each ended.
/// The console's filters (node, user, dst, line, session) live in the Filter
/// menu and as search tokens and go to the server under its own names; free
/// words in the search field filter the rows that came back.
struct ConnectionsScreen: View {
    var filter: String?

    static let textKey = "evidence.connections.text"
    static let rangeKey = "evidence.connections.range"

    @Environment(EvidenceStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    @SceneStorage(ConnectionsScreen.textKey) private var text = ""
    @SceneStorage(ConnectionsScreen.rangeKey) private var rangeTitle = TimeRangeSelection.lastHour.title
    @State private var query = EvidenceConnectionQuery()
    @State private var customRange: TimeRangeSelection?
    @State private var seeded = false
    @State private var shown: [EvidenceConnRecord] = []
    @State private var pending = 0
    @State private var shownQuestion: EvidenceConnectionsQuestion?
    @State private var idle = EvidenceListIdle()

    var body: some View {
        content
            .navigationTitle("Connections")
            .navigationBarTitleDisplayMode(.large)
            .navigationSubtitle(subtitle)
            .searchable(text: $text, tokens: tokensBinding, prompt: "Search, node:, user:") { token in
                Label(token.title, systemImage: token.symbol)
            }
            .onSubmit(of: .search) { absorbTokens() }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    RangeMenu(selection: rangeBinding)
                    filterMenu
                    Menu {
                        Button("Open on web", systemImage: "safari") { router.openOnWeb(EvidenceCopy.explore(nodeID: query.nodeID)) }
                        Button("Evidence", systemImage: "doc.text.magnifyingglass") { router.show(.evidence(.overview)) }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
            .onAppear(perform: seed)
            .onChange(of: store.connections.loadedAt) { offer(force: false) }
            .onChange(of: question) { offer(force: true) }
            .onChange(of: idle.settled) { if pending > 0 { offer(force: false) } }
            .polling(.standard, version: ConnectionsPollKey.of(changes.version([.evidence]), question)) {
                await nodes.refreshIfOlder(than: 15)
                await store.refreshSessionsIfNeeded()
                return await store.refreshConnections(question)
            }
    }

    // MARK: The question

    private var range: TimeRangeSelection {
        if let customRange { return customRange }
        return TimeRangeSelection.presets.first { $0.title == rangeTitle } ?? .lastHour
    }

    private var rangeBinding: Binding<TimeRangeSelection> {
        Binding(get: { range }, set: { value in
            if case .custom = value { customRange = value } else { customRange = nil; rangeTitle = value.title }
        })
    }

    private var question: EvidenceConnectionsQuestion {
        var sent = query
        sent.text = ""
        return EvidenceConnectionsQuestion(query: sent, range: range)
    }

    private func seed() {
        guard !seeded else { offer(force: true); return }
        seeded = true
        if let filter, !filter.isEmpty {
            query = EvidenceConnectionQuery.parse(filter, nodeID: resolveNode)
            query.userID = resolveUser(query.userID)
            query.text = ""
        }
        offer(force: true)
    }

    /// A typed `user:` value as a user id: an id passes, a managed user's
    /// logged name becomes its id, and anything else is kept as typed.
    private func resolveUser(_ value: String) -> String {
        value.split(separator: ",").map { part in
            let typed = String(part)
            if records.contains(where: { $0.userID == typed }) { return typed }
            return records.first { !$0.userID.isEmpty && $0.userName.caseInsensitiveCompare(typed) == .orderedSame }?.userID ?? typed
        }.joined(separator: ",")
    }

    private func resolveNode(_ value: String) -> String? {
        nodes.nodes.values.first { $0.name.caseInsensitiveCompare(value) == .orderedSame }?.id
    }

    /// Typed tokens move into the filters; the free words stay in the field.
    private func absorbTokens() {
        let parsed = EvidenceConnectionQuery.parse(text, nodeID: resolveNode)
        if !parsed.nodeID.isEmpty { query.nodeID = parsed.nodeID }
        if !parsed.userID.isEmpty { query.userID = resolveUser(parsed.userID) }
        if !parsed.dst.isEmpty { query.dst = parsed.dst }
        if !parsed.lineUUID.isEmpty { query.lineUUID = parsed.lineUUID }
        if !parsed.sessionID.isEmpty { query.sessionID = parsed.sessionID }
        if text.lowercased().contains("is:closed") { query.includeOpen = false }
        if text.lowercased().contains("is:open") { query.includeOpen = true }
        text = parsed.text
    }

    // MARK: Filter menu and tokens

    private struct Option { let value: String; let title: String }

    private var records: [EvidenceConnRecord] { answer?.records ?? [] }

    private var nodeOptions: [Option] {
        var ids = Set((store.policies.value ?? []).map(\.nodeID))
        records.forEach { ids.insert($0.nodeID) }
        if !query.nodeID.isEmpty { ids.insert(query.nodeID) }
        return ids.map { Option(value: $0, title: nodes.name(for: $0)) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The server filters on `user_id` alone, which only managed users carry
    /// (legacy, discovered and unnamed users log a name and no id), so only
    /// they can be offered.
    private var userOptions: [Option] {
        var seen: [String: String] = [:]
        for record in records where !record.userID.isEmpty { seen[record.userID] = record.userName.isEmpty ? record.userID : record.userName }
        if !query.userID.isEmpty, seen[query.userID] == nil { seen[query.userID] = query.userID }
        return seen.map { Option(value: $0.key, title: $0.value) }.sorted { $0.title < $1.title }
    }

    private var destinationOptions: [Option] {
        var hosts = Set(records.map { $0.dstHost.isEmpty ? $0.dstIP : $0.dstHost }.filter { !$0.isEmpty })
        if !query.dst.isEmpty { hosts.insert(query.dst) }
        return hosts.sorted().map { Option(value: $0, title: $0) }
    }

    private var lineOptions: [Option] {
        var lines = Set(records.map(\.lineUUID).filter { !$0.isEmpty })
        if !query.lineUUID.isEmpty { lines.insert(query.lineUUID) }
        return lines.sorted().map { Option(value: $0, title: $0) }
    }

    private var sessionOptions: [Option] {
        var options = (store.sessions.value ?? []).map { Option(value: $0.id, title: $0.name.isEmpty ? $0.id : $0.name) }
        if !query.sessionID.isEmpty, !options.contains(where: { $0.value == query.sessionID }) { options.append(Option(value: query.sessionID, title: query.sessionID)) }
        return options
    }

    private func section(_ title: String, all: String, options: [Option], value: WritableKeyPath<EvidenceConnectionQuery, String>) -> FilterMenuSection {
        FilterMenuSection(
            title: title, options: [all] + options.map(\.title), defaultOption: all,
            selection: Binding(
                get: { let current = query[keyPath: value]; return current.isEmpty ? all : (options.first { $0.value == current }?.title ?? current) },
                set: { title in query[keyPath: value] = title == all ? "" : (options.first { $0.title == title }?.value ?? "") }
            )
        )
    }

    private var filterMenu: some View {
        FilterMenu(sections: [
            section("Node", all: "All nodes", options: nodeOptions, value: \.nodeID),
            section("User", all: "All users", options: userOptions, value: \.userID),
            section("Destination", all: "All destinations", options: destinationOptions, value: \.dst),
            section("Line", all: "All lines", options: lineOptions, value: \.lineUUID),
            section("Capture", all: "All captures", options: sessionOptions, value: \.sessionID),
            FilterMenuSection(title: "Open connections", options: ["Included", "Closed only"], defaultOption: "Included",
                              selection: Binding(get: { query.includeOpen ? "Included" : "Closed only" }, set: { query.includeOpen = $0 == "Included" })),
        ])
    }

    private struct FilterToken: Identifiable, Hashable {
        enum Kind { case node, user, dst, line, session, closed }
        let kind: Kind
        let title: String
        var id: Kind { kind }
        var symbol: String {
            switch kind {
            case .node: "server.rack"
            case .user: "person"
            case .dst: "arrow.up.forward"
            case .line: "point.topleft.down.to.point.bottomright.curvepath"
            case .session: "record.circle"
            case .closed: "xmark.circle"
            }
        }
    }

    private func title(_ options: [Option], _ value: String) -> String { options.first { $0.value == value }?.title ?? value }

    private var tokens: [FilterToken] {
        var tokens: [FilterToken] = []
        if !query.nodeID.isEmpty { tokens.append(FilterToken(kind: .node, title: query.nodeID.split(separator: ",").map { nodes.name(for: String($0)) }.joined(separator: ", "))) }
        if !query.userID.isEmpty { tokens.append(FilterToken(kind: .user, title: title(userOptions, query.userID))) }
        if !query.dst.isEmpty { tokens.append(FilterToken(kind: .dst, title: query.dst)) }
        if !query.lineUUID.isEmpty { tokens.append(FilterToken(kind: .line, title: "line \(query.lineUUID.prefix(8))")) }
        if !query.sessionID.isEmpty { tokens.append(FilterToken(kind: .session, title: title(sessionOptions, query.sessionID))) }
        if !query.includeOpen { tokens.append(FilterToken(kind: .closed, title: "Closed only")) }
        return tokens
    }

    private var tokensBinding: Binding<[FilterToken]> {
        Binding(get: { tokens }, set: { kept in
            let kinds = Set(kept.map(\.kind))
            if !kinds.contains(.node) { query.nodeID = "" }
            if !kinds.contains(.user) { query.userID = "" }
            if !kinds.contains(.dst) { query.dst = "" }
            if !kinds.contains(.line) { query.lineUUID = "" }
            if !kinds.contains(.session) { query.sessionID = "" }
            if !kinds.contains(.closed) { query.includeOpen = true }
        })
    }

    private var subtitle: String {
        ([range == .all ? "All time" : "Last \(Self.rangeWords(range))"] + tokens.map(\.title)).joined(separator: ", ")
    }

    /// "hour", "24 hours", for sentences.
    static func rangeWords(_ range: TimeRangeSelection) -> String {
        switch range {
        case .lastHour: "hour"
        case .lastDay: "24 hours"
        case .lastWeek: "7 days"
        case .lastMonth: "30 days"
        case .all: "all time"
        case .custom: "custom range"
        }
    }

    // MARK: Rows

    /// The stored pages, when they answer the question on screen.
    private var answer: EvidenceConnectionsList? {
        store.connectionsQuestion == question ? store.connections.value : nil
    }

    private var filtered: [EvidenceConnRecord] {
        let words = EvidenceConnectionQuery(text: text)
        return (answer?.records ?? []).filter { words.matchesText($0, nodeName: nodes.name(for: $0.nodeID)) }
    }

    /// A poll's new rows apply only while the list is still; until then, and
    /// always while VoiceOver runs, they wait behind a row that says so (section 5.0).
    private func offer(force: Bool) {
        let next = filtered
        if force || (!voiceOver && idle.isIdle) || shownQuestion != question || shown.isEmpty {
            shown = next
            pending = 0
            shownQuestion = question
            return
        }
        let have = Set(shown.map(\.id))
        let added = next.filter { !have.contains($0.id) }.count
        if added == 0 {
            // Values inside existing rows apply at once.
            let fresh = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            shown = shown.map { fresh[$0.id] ?? $0 }
        } else {
            pending = added
        }
    }

    @ViewBuilder
    private var content: some View {
        if let missing = store.readMissing {
            ScopeDeniedScreen(scope: missing)
        } else if !network.isSatisfied && store.connections.value == nil {
            EvidenceOfflineState(noun: "Connections")
        } else if store.traceStoreOff {
            WholeScreenState {
                ContentUnavailableView("Connection tracing is not enabled on this server", systemImage: "exclamationmark.triangle",
                                       description: Text("This server runs without its trace store, so no connection record is kept."))
            }
        } else if store.connectionsQuestion == question || store.connections.value == nil {
            ResourceView(state: store.connections, noun: "connections", retry: refresh) { _ in list }
        } else {
            List { LoadingRows(label: "Loading connections") }
        }
    }

    private var list: some View {
        let rows = (shownQuestion == question ? shown : filtered).filter { record in
            EvidenceConnectionQuery(text: text).matchesText(record, nodeName: nodes.name(for: record.nodeID))
        }
        return List {
            if case .failed(let error, _, _) = store.connections {
                Section { ErrorRow(message: "Could not refresh connections: \(error.localizedDescription)", retry: refresh) }
            }
            if pending > 0 {
                Section {
                    PendingUpdatesRow(count: pending) { offer(force: true) }
                        .onAppear { AccessibilityNotification.Announcement(pending == 1 ? "1 update" : "\(pending) updates").post() }
                }
            }
            if rows.isEmpty {
                emptyState
            } else {
                Section {
                    ForEach(rows) { row($0) }
                    loadMore
                } header: {
                    Text(header(count: rows.count)).accessibilityAddTraits(.isHeader)
                }
            }
            Section {} footer: {
                FreshnessFooter(state: store.connections, interval: 60)
            }
        }
        .listStyle(.insetGrouped)
        .onScrollPhaseChange { _, phase in idle.note(phase) }
        .refreshable {
            await store.refreshConnections(question)
            offer(force: true)
        }
    }

    private func header(count: Int) -> String {
        let shownText = count == 1 ? "1 connection" : "\(count) connections"
        let more = answer?.nextCursor != nil ? " so far" : ""
        let window = range == .all ? "" : " in the last \(Self.rangeWords(range))"
        return shownText + more + window
    }

    @ViewBuilder
    private var emptyState: some View {
        if !text.trimmingCharacters(in: .whitespaces).isEmpty, !(answer?.records.isEmpty ?? true) {
            ContentUnavailableView.search(text: text)
        } else if answer?.collectedTotal == 0 {
            ContentUnavailableView {
                Label("Nothing collected yet", systemImage: "arrow.left.arrow.right")
            } description: {
                Text("Connection records exist only where collection is on. Start a capture from Evidence; it stops by itself.")
            } actions: {
                Button("Open Evidence") { router.show(.evidence(.overview)) }
            }
        } else {
            ContentUnavailableView {
                Label("No connections match", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(emptyDescription)
            } actions: {
                if question.query.isFiltered || range != .all {
                    Button("Show all time and every node") {
                        query = EvidenceConnectionQuery(includeOpen: query.includeOpen)
                        customRange = nil
                        rangeTitle = TimeRangeSelection.all.title
                    }
                }
            }
        }
    }

    private var emptyDescription: String {
        guard let answer else { return "" }
        var text = answer.collectedTotal == 1 ? "1 record is held for the nodes this token sees" : "\(answer.collectedTotal.formatted()) records are held for the nodes this token sees"
        if let newest = answer.collectedNewestAt { text += "; the newest started \(TimeDisplay.relative(newest, now: Date(), locale: locale))" }
        return text + "."
    }

    @ViewBuilder
    private var loadMore: some View {
        if let error = store.loadMoreError {
            ErrorRow(message: "Could not load more: \(error.localizedDescription)") { Task { await store.loadMoreConnections(); offer(force: true) } }
        } else if answer?.nextCursor != nil {
            Button {
                Task { await store.loadMoreConnections(); offer(force: true) }
            } label: {
                HStack {
                    Text("Load more")
                    if store.isLoadingMore { Spacer(); ProgressView() }
                }
                .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
            }
            .disabled(store.isLoadingMore)
        }
    }

    private func row(_ record: EvidenceConnRecord) -> some View {
        let name = nodes.name(for: record.nodeID)
        return NavigationLink(value: AppRoute.evidence(.connection(id: record.id))) {
            EvidenceConnectionRow(record: record, nodeName: name)
        }
        .contextMenu {
            Button("Open", systemImage: "arrow.right.circle") { router.push(.evidence(.connection(id: record.id))) }
            Button("Copy link", systemImage: "link") { EvidenceCopy.copy(EvidenceCopy.link(connection: record.id)) }
            Button("Copy ID", systemImage: "number") { EvidenceCopy.copy(record.id) }
            Button("Open on web", systemImage: "safari") { router.openOnWeb(.connection(id: record.id)) }
            Divider()
            Button("Only \(name)", systemImage: "server.rack") { query.nodeID = record.nodeID }
            if !record.destination.isEmpty {
                Button("Only this destination", systemImage: "arrow.up.forward") { query.dst = record.dstHost.isEmpty ? record.dstIP : record.dstHost }
            }
            Button("Raw logs on \(name)", systemImage: "doc.plaintext") { router.push(.evidence(.logs(nodeID: record.nodeID))) }
        } preview: {
            EvidenceConnectionRow(record: record, nodeName: name)
                .padding()
                .frame(width: 340)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
        }
        .accessibilityActions {
            Button("Copy link") { EvidenceCopy.copy(EvidenceCopy.link(connection: record.id)) }
            Button("Only \(name)") { query.nodeID = record.nodeID }
        }
    }

    private func refresh() {
        Task { await store.refreshConnections(question) }
    }
}

/// The polling key: a ChangeLog bump or a new question restarts the loop.
private struct ConnectionsPollKey {
    static func of(_ version: Int, _ question: EvidenceConnectionsQuestion) -> Int {
        var hasher = Hasher()
        hasher.combine(version)
        hasher.combine(question)
        return hasher.finalize()
    }
}
