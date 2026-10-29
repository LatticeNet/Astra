import SwiftUI

/// One session's transcript, read from `/events` with a cursor so each poll
/// feeds only new output to the cleaner. The events read is the only read of
/// a session by id, so a deep link needs no list.
@MainActor @Observable
final class TerminalTranscriptModel {
    /// Why the server will not answer for this session any more.
    enum Gone: Equatable {
        /// 404: forgotten after it ended, or never held.
        case notFound
        /// 403 by ownership: another operator opened it.
        case otherOperator
    }

    private(set) var state: ResourceState<TerminalSession> = .idle
    private(set) var cleaner = TranscriptCleaner()
    private(set) var gone: Gone?
    /// The server dropped output before the first event this phone read, or between reads.
    private(set) var truncated = false
    /// Bumps whenever lines change, so the screen can follow the tail.
    private(set) var revision = 0
    @ObservationIgnored private var cursor: Int64 = 0
    @ObservationIgnored private var generation = -1
    @ObservationIgnored private var loadedID: String?

    static let surface = "The transcript"

    var hasLines: Bool { !cleaner.lines.isEmpty }

    @discardableResult
    func load(id: String, session: SessionStore) async -> Bool {
        if loadedID != id || session.generation != generation {
            loadedID = id
            generation = session.generation
            state = .idle
            cleaner = TranscriptCleaner()
            gone = nil
            truncated = false
            cursor = 0
            revision += 1
        }
        if let missing = session.missing(TerminalStore.requirement)?.first {
            state = .denied(scope: missing)
            return true
        }
        guard let client = session.client else { return false }
        let before = state
        state = before.reloading
        do {
            let response = try await client.terminalEvents(sessionID: id, cursor: cursor)
            apply(response.events)
            gone = nil
            state = .loaded(response.session, at: Date())
            return true
        } catch {
            if TerminalStore.isCancellation(error) {
                state = before
                return true
            }
            let apiError = LatticeAPIError(error)
            switch apiError {
            case .notFound:
                gone = .notFound
                // An ended session the server forgot keeps the copy already read.
                if let value = before.value, let at = before.loadedAt {
                    state = .loaded(value, at: at)
                } else {
                    state = .failed(apiError, last: nil, lastAt: nil)
                }
                return true
            case .forbidden(_, let message) where message.localizedCaseInsensitiveContains(TerminalServerMessages.otherOperator):
                gone = .otherOperator
                cleaner = TranscriptCleaner()
                state = .failed(apiError, last: nil, lastAt: nil)
                return true
            default:
                if case .invalidResponse = apiError { session.markCompanionBehind(Self.surface) }
                if case .forbidden = apiError { session.noteForbidden() }
                state = state.failing(apiError, surface: Self.surface, missingScope: TerminalLimits.scope)
                return false
            }
        }
    }

    private func apply(_ events: [TerminalEvent]) {
        let fresh = events.filter { $0.seq > cursor }.sorted { $0.seq < $1.seq }
        guard let first = fresh.first, let last = fresh.last else { return }
        if first.seq > cursor + 1 { truncated = true }
        for event in fresh where event.kind == "output" {
            cleaner.feed(event.data)
        }
        cursor = last.seq
        revision += 1
    }
}

/// M12-02 Transcript. A read-only transcript of one session, cleaned of
/// escape sequences and polled every 3 s while the session is live and on
/// screen. Find, copy, Close session (T2) and Open on web. There is no
/// input path: typing stays on the web.
struct TerminalTranscriptScreen: View {
    let sessionID: String

    @Environment(SessionStore.self) private var session
    @Environment(TerminalStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(NetworkMonitor.self) private var network
    @Environment(PowerMonitor.self) private var power
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    @State private var model = TerminalTranscriptModel()
    @State private var find = ""
    @State private var finding = false
    @State private var followTail = true
    @State private var scrolledOnce = false
    @State private var highlighted: Int?
    @AccessibilityFocusState private var focusedLine: Int?

    private static let bottomID = "terminal.transcript.bottom"

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .polling(cadence, version: changes.version(.terminal)) {
                // A refused or forgotten session answers the same way every
                // time, and the server audits each refusal as a deny, so the
                // screen stops asking. Retry and pull to refresh still ask.
                guard model.gone == nil else { return true }
                await nodes.refreshIfOlder(than: 60)
                return await model.load(id: sessionID, session: session)
            }
    }

    private var record: TerminalSession? { model.state.value }

    private var isLive: Bool { (record?.isLive ?? true) && model.gone == nil }

    /// 3 s while the shell can still print; the standard minute once it ended.
    private var cadence: Polling { isLive ? .live : .standard }

    private var nodeName: String {
        record.map { nodes.name(for: $0.nodeID) } ?? store.session(id: sessionID).map { nodes.name(for: $0.nodeID) } ?? "Session"
    }

    private var title: String { nodeName }

    /// The state as last read, and the transport while the view is current.
    /// A stale or offline view says so here, where it stays in sight while
    /// the list follows the tail.
    private var subtitle: String {
        guard let record else { return "" }
        let state = TerminalSessionState.of(record).word.capitalizedFirst
        let asOf = model.state.loadedAt.map { TimeDisplay.clock($0, mode: mode, locale: locale) }
        if case .failed(_, let last, _) = model.state, last != nil {
            return asOf.map { "\(state), stale since \($0)" } ?? "\(state), stale"
        }
        if !network.isSatisfied {
            return asOf.map { "\(state), offline since \($0)" } ?? "\(state), offline"
        }
        let transport = TerminalTransport.of(record, runtime: nil, now: Date())
        return transport == .unknown ? state : "\(state), \(transport.word)"
    }

    private var isStale: Bool {
        if case .failed(_, let last, _) = model.state, last != nil { return true }
        return false
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        if model.gone == .otherOperator {
            WholeScreenState {
                ContentUnavailableView {
                    Label("Another operator's session", systemImage: "person.crop.circle.badge.xmark")
                } description: {
                    Text("Only the operator who opened a session can read its transcript or close it. The server refused this one.")
                } actions: {
                    Button("Your sessions") { router.replaceTop(.terminal(.sessions(nodeID: nil))) }
                        .buttonStyle(.bordered)
                }
            }
        } else if model.gone == .notFound, record == nil {
            WholeScreenState {
                ContentUnavailableView {
                    Label("Session not found", systemImage: "apple.terminal")
                } description: {
                    Text("The server forgets an ended session after \(TerminalLimits.closedRetentionMinutes) minutes, and this link may name one it never held.")
                } actions: {
                    Button("Your sessions") { router.replaceTop(.terminal(.sessions(nodeID: nil))) }
                        .buttonStyle(.bordered)
                    Button("Open on web") { router.openOnWeb(.terminalSession(id: sessionID)) }
                }
            }
        } else if !network.isSatisfied, record == nil, !model.state.isLoading, session.missing(TerminalStore.requirement)?.isEmpty ?? true {
            TerminalOfflineView(noun: "Transcripts", retry: refresh)
        } else {
            ResourceView(state: model.state, noun: "the transcript", retry: refresh) { record in
                transcript(record)
            }
        }
    }

    // MARK: Transcript

    private func transcript(_ record: TerminalSession) -> some View {
        ScrollViewReader { proxy in
            List {
                // With lines, the failure shows under the newest line instead.
                if case .failed(let error, let last, _) = model.state, last != nil, !model.hasLines {
                    ErrorRow(message: "Could not refresh the transcript: \(error.localizedDescription)", retry: refresh)
                }
                if find.trimmingCharacters(in: .whitespaces).isEmpty {
                    sessionSection(record)
                    nowSection(record)
                    linesSection
                } else {
                    matchesSection(proxy: proxy)
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 1)
            .searchable(text: $find, isPresented: $finding, prompt: "Find in transcript")
            .refreshable { await model.load(id: sessionID, session: session) }
            .onScrollPhaseChange { _, phase, context in
                guard phase == .idle else { return }
                let geometry = context.geometry
                followTail = geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 120
            }
            .onChange(of: model.revision, initial: true) {
                guard model.hasLines, find.isEmpty else { return }
                // An ended session opens at the top, where its status and end
                // reason are; Latest output jumps to the end.
                guard record.isLive else {
                    if !scrolledOnce { followTail = false }
                    return
                }
                guard !scrolledOnce || followTail else { return }
                scrolledOnce = true
                Task {
                    // Let the new rows lay out before scrolling to them.
                    await Task.yield()
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .onChange(of: isStale) { _, stale in
                // A failed poll bumps no revision, and the stale row is taller
                // than the stamp it replaces, so bring it into view.
                guard stale, followTail, record.isLive, model.hasLines, find.isEmpty else { return }
                Task {
                    await Task.yield()
                    withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
            .onChange(of: highlighted) { _, line in
                guard let line else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    proxy.scrollTo(line, anchor: .center)
                    focusedLine = line
                    try? await Task.sleep(for: .seconds(2))
                    if highlighted == line { highlighted = nil }
                }
            }
            .toolbar {
                if !followTail, model.hasLines, find.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Latest output", systemImage: "arrow.down.to.line") {
                            followTail = true
                            withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                        }
                    }
                }
                if model.hasLines {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Find", systemImage: "magnifyingglass") { finding = true }
                    }
                }
            }
        }
    }

    private func sessionSection(_ record: TerminalSession) -> some View {
        let now = Date()
        let state = TerminalSessionState.of(record)
        let style = StatusStyle.terminal(state)
        let transport = TerminalTransport.of(record, runtime: nil, now: now)
        let timeline = TerminalWords.timeline(record, now: now, mode: mode, locale: locale)
        return Section {
            StatusRow(
                style: style,
                title: nodeName,
                detail: timeline.isEmpty ? nil : timeline,
                reason: state == .pending ? "Waiting for the node agent to pick it up." : TerminalCloseReason.of(record)?.sentence,
                accessibilityPhrase: "Terminal session on \(nodeName), \(style.word)"
            )
            if nodes.nodes[record.nodeID] != nil {
                NavigationLink(value: AppRoute.fleet(.node(id: record.nodeID))) {
                    LabeledContent("Node", value: nodeName)
                        .frame(minHeight: Spacing.minimumTarget)
                }
            } else {
                DetailRow(label: "Node", value: record.nodeID, monospaced: true)
            }
            DetailRow(label: "Shell", value: record.shellPath, monospaced: true)
            DetailRow(label: "Transport", value: transportSentence(transport, live: record.isLive), copyable: false)
            let opener = TerminalOpener.of(record, currentTokenID: store.currentTokenID)
            DetailRow(label: "Opened", value: opener.phrase.capitalizedFirst, copyable: false)
            if case .otherToken(let tokenID) = opener {
                DetailRow(label: "Token", value: tokenID, monospaced: true)
            }
            if let created = record.createdAt { timeRow(record.status == "pending" ? "Requested" : "Started", created) }
            if let seen = record.lastSeen, record.isLive, record.status != "pending", transport != .stream {
                DetailRow(label: "Last activity", value: TimeDisplay.relative(seen, now: now, locale: locale).capitalizedFirst,
                          secondary: TimeDisplay.dateTime(seen, mode: mode, locale: locale), copyable: false)
            }
            if let closed = record.closedAt { timeRow("Ended", closed) }
            if transport == .poll {
                DetailRow(label: "Output", value: "\(TerminalWords.bytes(record.bytesOut)) through the server", copyable: false)
                DetailRow(label: "Input", value: "\(TerminalWords.bytes(record.bytesIn)) typed on the web", copyable: false)
            }
            if record.cols > 0, record.rows > 0 {
                DetailRow(label: "Size", value: "\(record.cols) columns by \(record.rows) rows", copyable: false)
            }
            DetailRow(label: "Session ID", value: record.id, monospaced: true)
        } header: {
            Text("Session").accessibilityAddTraits(.isHeader)
        }
    }

    private func transportSentence(_ transport: TerminalTransport, live: Bool) -> String {
        switch transport {
        case .poll: "Poll: output passes through the server, which keeps the recent part"
        case .stream: "Stream: relayed live through the server, which keeps no copy"
        case .unknown: live ? "Not known yet" : "Not reported"
        }
    }

    @ViewBuilder
    private var linesSection: some View {
        let lines = model.cleaner.lines
        if !lines.isEmpty {
            let gutter = String(repeating: "0", count: String(lines.last?.id ?? 1).count)
            Section {
                ForEach(lines) { line in
                    lineRow(line, gutter: gutter)
                }
                tailRow
            } header: {
                HStack {
                    Text("Transcript").accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text(lines.count == 1 ? "1 line" : "\(lines.count) lines").monospacedDigit()
                }
            } footer: {
                Text("Read only. Typing stays on the web. Find from the toolbar; copy from the More menu or by touching and holding a line.")
            }
        }
    }

    /// The newest line's freshness, or why the view stopped updating. It is
    /// the scroll anchor, so following the tail always keeps it in view.
    @ViewBuilder
    private var tailRow: some View {
        Group {
            if case .failed(let error, _, let lastAt) = model.state, isStale {
                let since = lastAt.map { " since \(TimeDisplay.clock($0, mode: mode, locale: locale))" } ?? ""
                ErrorRow(message: "Stale\(since). Could not refresh the transcript: \(error.localizedDescription)", retry: refresh)
            } else {
                FreshnessFooter(state: model.state, interval: cadence.interval(lowPower: power.isLowPower))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Spacing.xs)
            }
        }
        .id(Self.bottomID)
        .listRowSeparator(.hidden)
    }

    /// A line-number gutter marks where each logical line starts, so a line
    /// wrapped across rows reads as one line and table columns stay legible.
    private func lineRow(_ line: TranscriptCleaner.Line, gutter: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            ZStack(alignment: .trailing) {
                Text(verbatim: gutter).hidden()
                Text(verbatim: String(line.id))
            }
            .font(.caption2.monospacedDigit())
            // A found line is marked by weight as well as by tint.
            .fontWeight(highlighted == line.id ? .bold : .regular)
            .foregroundStyle(highlighted == line.id ? AnyShapeStyle(Color.accentText) : AnyShapeStyle(.tertiary))
            .lineLimit(1)
            // Capped so the gutter never crowds out the text it numbers.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityHidden(true)
            switch line.kind {
            case .text:
                Text(line.text.isEmpty ? " " : line.text)
                    .textRole(.code)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityHidden(line.text.isEmpty)
            case .fullScreen:
                Label("Full-screen program output not shown", systemImage: "macwindow")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Spacing.xs)
            }
        }
        .id(line.id)
        .accessibilityFocused($focusedLine, equals: line.id)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 2, leading: Spacing.m, bottom: 2, trailing: Spacing.l))
        .listRowBackground(highlighted == line.id ? Color.accentText.opacity(0.18) : nil)
    }

    @ViewBuilder
    private func nowSection(_ record: TerminalSession) -> some View {
        let transport = TerminalTransport.of(record, runtime: nil, now: Date())
        let notices = TerminalTranscriptNotice.of(record, transport: transport, cleaner: model.cleaner, firstSeq: model.truncated ? 2 : 1)
        Section {
            if model.gone == .notFound {
                TerminalNoticeRow(symbol: "tray", tone: .quiet, title: "No longer on the server",
                                  text: "The server forgot this ended session. This is the copy read \(model.state.loadedAt.map { TimeDisplay.relative($0, now: Date(), locale: locale) } ?? "earlier").")
            }
            ForEach(notices, id: \.self) { notice in
                noticeRow(notice, record: record)
            }
            if record.isLive, model.gone == nil {
                Button(role: .destructive) {
                    close(record)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("Close session")
                            Text(network.isSatisfied ? "Ends the shell on \(nodeName) and everything running in it." : "No connection")
                                .textRole(.footnote)
                        }
                    } icon: {
                        Image(systemName: "xmark.square").foregroundStyle(Color.destructiveFill)
                    }
                    .frame(minHeight: Spacing.minimumTarget)
                }
                .disabled(!network.isSatisfied)
            }
            TerminalOpensInRow(title: "Audit trail", symbol: "list.bullet.rectangle", tab: .activity,
                               hint: "Shows terminal opens, attaches and closes on \(nodeName)") {
                router.select(tab: .activity, scope: "audit", query: auditQuery(record))
            }
            WebLinkRow(path: .terminalSession(id: record.id))
        } header: {
            Text(record.isLive ? "Now" : "After it ended").accessibilityAddTraits(.isHeader)
        } footer: {
            // With lines, freshness sits under the newest line instead.
            if !model.hasLines {
                FreshnessFooter(state: model.state, interval: cadence.interval(lowPower: power.isLowPower))
            }
        }
    }

    @ViewBuilder
    private func noticeRow(_ notice: TerminalTranscriptNotice, record: TerminalSession) -> some View {
        switch notice {
        case .waitingForAgent:
            TerminalNoticeRow(symbol: "hourglass", tone: .quiet, title: "Waiting for the node agent",
                              text: "The session opens once the agent on \(nodeName) picks it up. If it does not within \(TerminalLimits.pendingMinutes) minutes, the server ends it.")
        case .fullScreenRunning:
            TerminalNoticeRow(symbol: "macwindow", tone: .warn, title: "A full-screen program is running",
                              text: "Open on web to see it. Its screens are drawn, not written as lines, so the transcript leaves them out.")
        case .streamed:
            TerminalNoticeRow(symbol: "dot.radiowaves.left.and.right", tone: .quiet, title: "No transcript on the server",
                              text: record.isLive
                                ? "The server relays this session live and keeps no copy of its output. Open on web to watch it."
                                : "The server relayed this session live and kept no copy of its output.")
        case .noOutputYet:
            TerminalNoticeRow(symbol: "text.alignleft", tone: .quiet, title: "No output",
                              text: record.isLive ? "The shell has not printed anything yet." : "The server holds no output for this session.")
        case .trimmedOnPhone:
            TerminalNoticeRow(symbol: "scissors", tone: .quiet, title: "Earlier lines not kept here",
                              text: "This iPhone keeps the last \(model.cleaner.maxLines.formatted()) lines, so Find and Copy cover only those. Open on web for the rest.")
        case .truncated:
            TerminalNoticeRow(symbol: "scissors", tone: .quiet, title: "Earlier output dropped",
                              text: "The server keeps the last \(TerminalLimits.maxEvents) output events (\(TerminalLimits.maxSessionKiB) KB) of a session; what came before is gone.")
        }
    }

    // MARK: Find

    @ViewBuilder
    private func matchesSection(proxy: ScrollViewProxy) -> some View {
        let term = find.trimmingCharacters(in: .whitespaces)
        let matches = model.cleaner.lines.filter { $0.kind == .text && $0.text.localizedCaseInsensitiveContains(term) }
        Section {
            if matches.isEmpty {
                ContentUnavailableView.search(text: term)
            }
            ForEach(matches) { line in
                Button {
                    jump(to: line.id)
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(highlightedText(line.text, term: term))
                            .textRole(.code)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Line \(line.id)").textRole(.stamp)
                    }
                    .frame(minHeight: Spacing.minimumTarget)
                }
                .tint(.primary)
                .accessibilityLabel("Line \(line.id): \(line.text)")
                .accessibilityHint("Shows this line in the transcript")
            }
        } header: {
            Text(matches.count == 1 ? "1 matching line" : "\(matches.count) matching lines").accessibilityAddTraits(.isHeader)
        }
    }

    private func highlightedText(_ text: String, term: String) -> AttributedString {
        var attributed = AttributedString(text)
        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let range = attributed[searchStart..<attributed.endIndex].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[range].foregroundColor = Color.accentText
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
            searchStart = range.upperBound
        }
        return attributed
    }

    private func jump(to line: Int) {
        find = ""
        finding = false
        followTail = false
        highlighted = line
    }

    // MARK: Actions

    private func auditQuery(_ record: TerminalSession) -> String {
        let name = nodes.nodes[record.nodeID]?.displayName ?? record.nodeID
        return "action:terminal.* node:\(name)"
    }

    private func close(_ record: TerminalSession) {
        Task { await runner.run(TerminalIntents.close(record, nodeName: nodeName)) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let record, record.isLive, model.gone == nil {
                    TerminalGatedButton(title: "Close session", systemImage: "xmark.square",
                                        unavailable: network.isSatisfied ? nil : "No connection", role: .destructive) { close(record) }
                }
                Section {
                    if model.hasLines {
                        Button("Copy transcript", systemImage: "doc.on.doc") { TerminalCopy.copyOutput(model.cleaner.text) }
                    }
                    Button("Copy link", systemImage: "link") { TerminalCopy.copy(TerminalCopy.link(sessionID: sessionID)) }
                    Button("Copy ID", systemImage: "number") { TerminalCopy.copy(sessionID) }
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.terminalSession(id: sessionID)) }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    private func timeRow(_ label: String, _ date: Date) -> some View {
        DetailRow(label: label, value: TimeDisplay.dateTime(date, mode: mode, locale: locale), secondary: TimeDisplay.otherZone(date, mode: mode, locale: locale), copyable: false)
    }

    private func refresh() {
        Task { await model.load(id: sessionID, session: session) }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
