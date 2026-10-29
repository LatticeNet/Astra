import SwiftUI

/// M10-01 Evidence. What is being recorded, node by node: collector
/// readiness (recording, ready, not ready, not heard from, waiting, off),
/// the captures running with their countdown, and the local budgets. A node
/// row swipes to start a capture (T2, 5, 15 or 60 minutes); a capture row
/// swipes to stop it (T2). Policies, sources and budgets are edited on the web.
struct EvidenceScreen: View {
    static let queryKey = "evidence.overview.query"

    @Environment(EvidenceStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(NetworkMonitor.self) private var network
    @Environment(SessionStore.self) private var session

    @SceneStorage(EvidenceScreen.queryKey) private var query = ""
    @State private var showQuiet = false
    @State private var showEnded = false
    @State private var idle = EvidenceListIdle()
    /// Node rows in the order last applied; a poll's reorder waits for a still list.
    @State private var heldOrder: [String] = []

    var body: some View {
        content
            .navigationTitle("Evidence")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: "Node or state")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Connections", systemImage: "arrow.left.arrow.right") { router.push(.evidence(.connections(filter: nil))) }
                        Button("Raw logs", systemImage: "doc.plaintext") { router.push(.evidence(.logs(nodeID: nil))) }
                        Divider()
                        Button("Open on web", systemImage: "safari") { router.openOnWeb(EvidenceCopy.overview) }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
            .polling(.standard, version: changes.version([.evidence])) {
                await nodes.refreshIfOlder(than: 15)
                return await store.refreshOverview()
            }
            .onChange(of: liveOrder) { _, order in if idle.isIdle || heldOrder.isEmpty { heldOrder = order } }
            .onChange(of: idle.settled) { heldOrder = liveOrder }
            .task(id: nextExpiry) {
                // A capture ends on the server at its deadline; read it then
                // rather than show "running" at 0:00 until the next poll.
                guard let nextExpiry else { return }
                try? await Task.sleep(for: .seconds(max(0, nextExpiry.timeIntervalSinceNow) + 0.5))
                guard !Task.isCancelled else { return }
                await store.refreshOverview()
            }
    }

    private var liveOrder: [String] { (store.coverage(nodes: nodes, now: Date()) ?? []).map(\.id) }

    private var nextExpiry: Date? {
        (store.sessions.value ?? []).filter { $0.isActive(now: Date()) }.compactMap(\.expiresAt).min()
    }

    private var confined: Bool { session.tokenScopes?.isConfined ?? false }

    @ViewBuilder
    private var content: some View {
        if let missing = store.readMissing {
            ScopeDeniedScreen(scope: missing)
        } else if !network.isSatisfied && store.policies.value == nil && store.sources.value == nil {
            EvidenceOfflineState(noun: "Evidence")
        } else if store.traceStoreOff {
            ResourceView(state: store.sources, noun: "evidence", retry: refresh) { _ in list }
        } else {
            ResourceView(state: store.policies, noun: "evidence", retry: refresh) { _ in list }
        }
    }

    // MARK: List

    private var list: some View {
        let now = Date()
        let rows = EvidenceListIdle.ordered(store.coverage(nodes: nodes, now: now) ?? [], by: heldOrder)
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = rows.filter { text.isEmpty || $0.name.lowercased().contains(text) || $0.state.word.contains(text) }
        let attention = matching.filter(\.needsAttention)
        let active = matching.filter { !$0.needsAttention && !$0.quiet }
        let quiet = matching.filter { !$0.needsAttention && $0.quiet }
        let sessions = store.sessions.value ?? []
        let running = sessions.filter { $0.isActive(now: now) && (text.isEmpty || $0.name.lowercased().contains(text)) }
        let ended = sessions.filter { !$0.isActive(now: now) }.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }

        return List {
            summarySection(rows)
            capturesSection(running: running, ended: ended)
            if !attention.isEmpty {
                Section {
                    ForEach(attention) { nodeRow($0) }
                } header: {
                    Text(attention.count == 1 ? "1 node asked to record is not recording" : "\(attention.count) nodes asked to record are not recording")
                        .accessibilityAddTraits(.isHeader)
                }
            }
            nodesSection(active: active, quiet: quiet, searching: !text.isEmpty, anyRows: !rows.isEmpty)
            exploreSection
            budgetSection
            Section {
                WebLinkRow(title: "Edit trace policies, log sources and budgets", path: EvidenceCopy.collection)
            } header: {
                Text("Collection").accessibilityAddTraits(.isHeader)
            } footer: {
                FreshnessFooter(state: store.traceStoreOff ? store.sources.evidenceMap(\.count) : store.policies.evidenceMap(\.count), interval: 60)
            }
        }
        .listStyle(.insetGrouped)
        .onScrollPhaseChange { _, phase in idle.note(phase) }
        .refreshable { await store.refreshOverview() }
    }

    @ViewBuilder
    private func summarySection(_ rows: [EvidenceCoverageRow]) -> some View {
        Section {
            if store.traceStoreOff {
                StatusRow(
                    style: StatusStyle(word: "off on server", symbol: "exclamationmark.triangle.fill", tone: .warn),
                    title: "Connection tracing is not enabled on this server",
                    reason: "No connection record can be kept and no capture can start. Raw log sources still ship lines."
                )
            } else if !rows.isEmpty {
                Text(headline(rows))
                    .textRole(.verdict)
                    .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            }
            if let failure = refreshFailure {
                ErrorRow(message: failure, retry: refresh)
            }
            if case .companionBehind(let surface) = store.sessions { CompanionBehindRow(surface: surface) }
            if case .companionBehind(let surface) = store.sources { CompanionBehindRow(surface: surface) }
        } footer: {
            if let proof = proofLine, !store.traceStoreOff { Text(proof) }
        }
    }

    /// One row for every list that failed to refresh, its data kept below.
    private var refreshFailure: String? {
        var names: [String] = []
        var reason: LatticeAPIError?
        if case .failed(let error, _, _) = store.sessions, !store.traceStoreOff { names.append("captures"); reason = reason ?? error }
        if case .failed(let error, _, _) = store.policies, store.policies.value != nil { names.append("trace policies"); reason = reason ?? error }
        if case .failed(let error, _, _) = store.sources, !store.logStoreOff { names.append("raw log sources"); reason = reason ?? error }
        guard let reason, !names.isEmpty else { return nil }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        var text = "Could not refresh \(list): \(reason.localizedDescription)"
        if !text.hasSuffix(".") { text += "." }
        if names.contains("raw log sources") && store.sources.value == nil { text += " Raw log counts are unknown, not zero." }
        return text
    }

    /// "2 of 35 nodes recording, 3 more ready.", in the rows' own words.
    private func headline(_ rows: [EvidenceCoverageRow]) -> String {
        let summary = EvidenceCoverage.summary(rows)
        if summary.total == 0 { return "No node to collect from." }
        let nodesWord = (confined ? "visible " : "") + (summary.total == 1 ? "node" : "nodes")
        let underCapture = rows.filter { if case .recording = $0.state { true } else { false } }.count
        let ready = summary.recording - underCapture
        var text = "\(underCapture) of \(summary.total) \(nodesWord) recording"
        text += ready > 0 ? ", \(ready) more ready." : "."
        if summary.needsAttention > 0 {
            text += summary.needsAttention == 1 ? " 1 asked to record is not." : " \(summary.needsAttention) asked to record are not."
        }
        return text
    }

    /// "Trace store 60 records, encrypted": the count only once it was read.
    private var proofLine: String? {
        guard let stats = store.traceStats.value else { return nil }
        let cipher = stats.cipherEnabled ? "encrypted" : "not encrypted"
        guard let records = stats.records else { return "Trace store \(cipher)" }
        return "Trace store \(records == 1 ? "1 record" : "\(records.formatted()) records"), \(cipher)"
    }

    @ViewBuilder
    private func capturesSection(running: [EvidenceTraceSession], ended: [EvidenceTraceSession]) -> some View {
        if !store.traceStoreOff, store.sessions.value != nil {
            Section {
                if running.isEmpty {
                    Label("No capture is running", systemImage: "record.circle")
                        .foregroundStyle(.secondary)
                        .frame(minHeight: Spacing.minimumTarget)
                }
                ForEach(running) { captureRow($0) }
                if !ended.isEmpty {
                    DisclosureGroup(isExpanded: $showEnded) {
                        ForEach(ended.prefix(Self.endedShown)) { captureRow($0) }
                    } label: {
                        Text(endedLabel(ended.count))
                            .frame(minHeight: Spacing.minimumTarget)
                    }
                }
            } header: {
                Text(running.isEmpty ? "Captures" : running.count == 1 ? "1 capture running" : "\(running.count) captures running").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("A capture raises the log level on its nodes while it runs and stops by itself. It never restarts sing-box. \(startHint)")
            }
        }
    }

    private static let endedShown = 5

    private func endedLabel(_ count: Int) -> String {
        if count == 1 { return "1 ended capture" }
        return count > Self.endedShown ? "Last \(Self.endedShown) of \(count) ended captures" : "\(count) ended captures"
    }

    /// How to start a capture, or why this token cannot.
    private var startHint: String {
        let rows = store.coverage(nodes: nodes, now: Date()) ?? []
        if rows.isEmpty { return "" }
        return rows.contains { store.canAdmin(nodeID: $0.nodeID) } ? "Swipe a node to start one." : "Starting one needs \(EvidenceCapture.adminScope)."
    }

    private func captureRow(_ session: EvidenceTraceSession) -> some View {
        let names = session.filter.nodeIDs.map { nodes.name(for: $0) }
        let active = session.isActive(now: Date())
        let blocked = blockedStop(session)
        return NavigationLink(value: AppRoute.evidence(.connections(filter: "session:\(session.id)"))) {
            EvidenceCaptureRow(session: session, nodeNames: names)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if active, blocked == nil {
                // Stopping is reversible and keeps the records, so no destructive color.
                Button("Stop", systemImage: "stop.circle") { stop(session) }
            }
        }
        .contextMenu {
            Button("Show its connections", systemImage: "arrow.left.arrow.right") { router.push(.evidence(.connections(filter: "session:\(session.id)"))) }
            Button("Copy name", systemImage: "doc.on.doc") { EvidenceCopy.copy(session.name) }
            if active {
                Divider()
                EvidenceGatedButton(title: "Stop capture", systemImage: "stop.circle", blocked: blocked) { stop(session) }
            }
        }
    }

    @ViewBuilder
    private func nodesSection(active: [EvidenceCoverageRow], quiet: [EvidenceCoverageRow], searching: Bool, anyRows: Bool) -> some View {
        Section {
            if !anyRows {
                ContentUnavailableView {
                    Label("No node to collect from", systemImage: "server.rack")
                } description: {
                    Text("This token sees no node with a trace policy or a raw log source.")
                }
            } else if active.isEmpty && quiet.isEmpty {
                if searching { ContentUnavailableView.search(text: query) }
            }
            ForEach(active) { nodeRow($0) }
            if !quiet.isEmpty {
                if showQuiet || searching {
                    ForEach(quiet) { nodeRow($0) }
                }
                if !searching {
                    Button {
                        showQuiet.toggle()
                    } label: {
                        Text(showQuiet ? "Hide the idle nodes"
                             : quiet.count == 1 ? "1 more node collects nothing. Show it"
                             : "\(quiet.count) more nodes collect nothing. Show them")
                            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
                    }
                }
            }
        } header: {
            Text("Nodes").accessibilityAddTraits(.isHeader)
        }
    }

    private func nodeRow(_ row: EvidenceCoverageRow) -> some View {
        let blocked = blockedStart(row)
        return NavigationLink(value: AppRoute.evidence(.connections(filter: "node:\(row.nodeID)"))) {
            EvidenceNodeRow(row: row)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // One button per preset, so the runner's T2 dialog is the only one.
            if blocked == nil {
                ForEach(EvidenceCapturePreset.allCases.reversed(), id: \.self) { preset in
                    Button(preset.title, systemImage: "record.circle") { start(row, preset: preset) }
                        .tint(Color.accentFill)
                        .accessibilityLabel("Capture \(preset.title)")
                }
            }
        }
        .contextMenu {
            Button("Show connections", systemImage: "arrow.left.arrow.right") { router.push(.evidence(.connections(filter: "node:\(row.nodeID)"))) }
            Button("Raw logs", systemImage: "doc.plaintext") { router.push(.evidence(.logs(nodeID: row.nodeID))) }
            Button("Open node", systemImage: "server.rack") { router.push(.fleet(.node(id: row.nodeID))) }
            Divider()
            if blocked == nil {
                Menu {
                    ForEach(EvidenceCapturePreset.allCases, id: \.self) { preset in
                        Button(preset.title) { start(row, preset: preset) }
                    }
                } label: {
                    Label("Start capture", systemImage: "record.circle")
                }
            } else {
                EvidenceGatedButton(title: "Start capture", systemImage: "record.circle", blocked: blocked) {}
            }
        }
        .accessibilityActions {
            Button("Raw logs") { router.push(.evidence(.logs(nodeID: row.nodeID))) }
        }
    }

    private var exploreSection: some View {
        Section {
            NavigationLink(value: AppRoute.evidence(.connections(filter: nil))) {
                LabeledContent {
                    if let total = store.traceStats.value?.records { Text("\(total.formatted()) held") }
                } label: {
                    Label("Connections", systemImage: "arrow.left.arrow.right")
                }
                .frame(minHeight: Spacing.minimumTarget)
            }
            .disabled(store.traceStoreOff)
            NavigationLink(value: AppRoute.evidence(.logs(nodeID: nil))) {
                LabeledContent {
                    if let count = store.sources.value?.count { Text(count == 1 ? "1 source" : "\(count) sources") }
                } label: {
                    Label("Raw logs", systemImage: "doc.plaintext")
                }
                .frame(minHeight: Spacing.minimumTarget)
            }
        } header: {
            Text("Explore").accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private var budgetSection: some View {
        let lines = EvidenceBudget.lines(settings: store.settings.value, stats: store.traceStats.value, sourceStats: store.sourceStats.value)
        if !lines.isEmpty {
            Section {
                ForEach(lines, id: \.label) { line in
                    if let fraction = line.fraction {
                        ValueBarRow(label: line.label, value: line.value, fraction: fraction)
                    } else {
                        DetailRow(label: line.label, value: line.value, copyable: false)
                    }
                }
            } header: {
                Text("Local budgets").accessibilityAddTraits(.isHeader)
            } footer: {
                if store.settings.value?.stored == false {
                    Text("The server runs on its built-in limits.")
                }
            }
        }
    }

    // MARK: Actions

    private func blockedStart(_ row: EvidenceCoverageRow) -> String? {
        if !network.isSatisfied { return "No connection" }
        return EvidenceCapture.block(canAdmin: store.canAdmin(nodeID: row.nodeID), storeReady: !store.traceStoreOff,
                                     sessions: store.sessions.value, nodeID: row.nodeID, now: Date())?.message
    }

    private func blockedStop(_ session: EvidenceTraceSession) -> String? {
        if !network.isSatisfied { return "No connection" }
        let allowed = session.filter.nodeIDs.isEmpty ? store.canAdmin(nodeID: nil) : session.filter.nodeIDs.allSatisfy { store.canAdmin(nodeID: $0) }
        return allowed ? nil : "Needs \(EvidenceCapture.adminScope)"
    }

    private func start(_ row: EvidenceCoverageRow, preset: EvidenceCapturePreset) {
        let intent = EvidenceIntents.startCapture(nodeID: row.nodeID, nodeName: row.name, preset: preset, now: Date())
        Task { await runner.run(intent) }
    }

    private func stop(_ session: EvidenceTraceSession) {
        let names = session.filter.nodeIDs.map { nodes.name(for: $0) }
        Task { await runner.run(EvidenceIntents.stopCapture(session, nodeNames: names)) }
    }

    private func refresh() {
        Task { await store.refreshOverview() }
    }
}

extension ResourceState {
    /// The same state with its value mapped, for footers that only need the timing.
    func evidenceMap<Other: Sendable>(_ transform: (Value) -> Other) -> ResourceState<Other> {
        switch self {
        case .idle: .idle
        case .loading(let previous, let at): .loading(previous: previous.map(transform), previousAt: at)
        case .loaded(let value, let at): .loaded(transform(value), at: at)
        case .failed(let error, let last, let at): .failed(error, last: last.map(transform), lastAt: at)
        case .denied(let scope): .denied(scope: scope)
        case .companionBehind(let surface): .companionBehind(surface: surface)
        }
    }
}
