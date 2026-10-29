import SwiftUI
import UIKit

/// One source's lines as the log explorer shows them: oldest at the top,
/// newest at the bottom, older pages loaded above with `before_seq`.
@MainActor @Observable
final class EvidenceLogModel {
    private(set) var lines: [LogLine] = []
    private(set) var nextBeforeSeq: UInt64?
    private(set) var state: ResourceState<Bool> = .idle
    private(set) var loadingOlder = false
    private(set) var olderError: LatticeAPIError?
    /// A stored chunk failed to decode and was skipped.
    private(set) var skippedChunks = false
    /// The source and server search the lines answer.
    private(set) var question: (sourceID: String, search: String)?
    /// Bumped when the newest page replaced the lines, so the view scrolls to the bottom.
    private(set) var newestRevision = 0

    @discardableResult
    func refresh(session: SessionStore, sourceID: String, search: String) async -> Bool {
        guard let client = session.client else { return false }
        let changed = question?.sourceID != sourceID || question?.search != search
        if changed {
            lines = []
            nextBeforeSeq = nil
            olderError = nil
            state = .loading(previous: nil, previousAt: nil)
        } else {
            state = state.reloading
        }
        question = (sourceID, search)
        do {
            let page = try await client.queryLogs(sourceID: sourceID, search: search, limit: EvidenceLogs.pageSize)
            guard question?.sourceID == sourceID, question?.search == search else { return true }
            let newest = EvidenceLogs.chronological(page)
            if changed || lines.isEmpty {
                lines = newest
                nextBeforeSeq = page.nextBeforeSeq
                newestRevision += 1
            } else {
                // Keep the older pages already read; replace the newest one.
                let fresh = Set(newest.map(\.id))
                let floor = newest.first?.seq ?? .max
                let grew = newest.last?.id != lines.last?.id
                lines = lines.filter { !fresh.contains($0.id) && $0.seq < floor } + newest
                if grew { newestRevision += 1 }
            }
            skippedChunks = page.truncated
            state = .loaded(true, at: Date())
            return true
        } catch {
            if EvidenceStore.isCancellation(error) { return true }
            let apiError = LatticeAPIError(error)
            if case .invalidResponse = apiError { session.markCompanionBehind("Raw log lines") }
            state = state.failing(apiError, surface: "Raw log lines", missingScope: EvidenceCapture.readScope)
            return false
        }
    }

    func loadOlder(session: SessionStore) async {
        guard let question, let cursor = nextBeforeSeq, !loadingOlder, let client = session.client else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let page = try await client.queryLogs(sourceID: question.sourceID, search: question.search, limit: EvidenceLogs.pageSize, beforeSeq: cursor)
            guard self.question?.sourceID == question.sourceID, self.question?.search == question.search else { return }
            lines = EvidenceLogs.prependingOlder(lines, page: page)
            nextBeforeSeq = page.nextBeforeSeq
            skippedChunks = skippedChunks || page.truncated
            olderError = nil
        } catch {
            if !EvidenceStore.isCancellation(error) { olderError = LatticeAPIError(error) }
        }
    }
}

/// M10-04 Logs. A source picker, a server search over the source, the lines
/// in code style with the newest at the bottom, "Load older" by
/// `before_seq`, a find bar over the loaded lines, and copy per line.
struct LogExplorerScreen: View {
    var nodeID: String?

    static let searchKey = "evidence.logs.search"

    @Environment(EvidenceStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize

    @SceneStorage(LogExplorerScreen.searchKey) private var searchText = ""
    @State private var submittedSearch = ""
    @State private var model = EvidenceLogModel()
    @State private var chosenSourceID: String?
    @State private var finding = false
    @State private var findText = ""
    @State private var currentMatch: String?
    @FocusState private var findFocused: Bool

    var body: some View {
        content
            .navigationTitle("Raw logs")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(source.map { nodes.name(for: $0.nodeID) } ?? "")
            .searchable(text: $searchText, prompt: "Search lines on the server")
            .onSubmit(of: .search) { submittedSearch = searchText.trimmingCharacters(in: .whitespaces) }
            .onChange(of: searchText) { _, value in if value.isEmpty { submittedSearch = "" } }
            .onAppear {
                submittedSearch = searchText.trimmingCharacters(in: .whitespaces)
                if session.isDemo, let find = EvidenceDemoFind.take() {
                    finding = true
                    findText = find
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        finding.toggle()
                        findFocused = finding
                        if !finding { findText = ""; currentMatch = nil }
                    } label: {
                        Label(finding ? "Done finding" : "Find", systemImage: finding ? "xmark.circle" : "text.magnifyingglass")
                    }
                    .disabled(model.lines.isEmpty && !finding)
                    Menu {
                        Button("Open on web", systemImage: "safari") { router.openOnWeb(EvidenceCopy.rawLog(sourceID: source?.id)) }
                        Button("Evidence", systemImage: "doc.text.magnifyingglass") { router.push(.evidence(.overview)) }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
            .safeAreaBar(edge: .top) {
                if finding {
                    findBar
                        .padding(.horizontal, Spacing.l)
                        .padding(.bottom, Spacing.s)
                }
            }
            .polling(.standard, version: LogPollKey.of(changes.version([.evidence]), source?.id, submittedSearch)) {
                await nodes.refreshIfOlder(than: 15)
                // A restart because the source list just arrived need not read it again.
                var ok = true
                if store.sources.value == nil || Date().timeIntervalSince(store.sources.loadedAt ?? .distantPast) > 30 {
                    ok = await store.refreshSources()
                }
                guard let source else { return ok }
                return await model.refresh(session: session, sourceID: source.id, search: submittedSearch)
            }
    }

    // MARK: Source

    private var sources: [LogSource] { store.sources.value ?? [] }

    /// The chosen source, else the freshest on the node asked about, else the freshest.
    private var source: LogSource? {
        EvidenceLogs.pickSource(sources, sourceID: chosenSourceID, nodeID: chosenSourceID == nil ? nodeID : nil, stats: store.sourceStats.value ?? [])
    }

    private func sourceTitle(_ source: LogSource) -> String {
        let node = nodes.name(for: source.nodeID)
        let name = source.displayName.replacingOccurrences(of: "sing-box - \(node)", with: "sing-box")
        return source.enabled ? "\(name), \(node)" : "\(name), \(node), disabled"
    }

    private var sourcePicker: some View {
        Picker(selection: Binding(get: { source?.id ?? "" }, set: { chosenSourceID = $0 })) {
            ForEach(sources.sorted { sourceTitle($0).localizedStandardCompare(sourceTitle($1)) == .orderedAscending }) { source in
                Text(sourceTitle(source)).tag(source.id)
            }
        } label: {
            Label("Source", systemImage: "doc.plaintext")
        }
        .pickerStyle(.menu)
        .frame(minHeight: Spacing.minimumTarget)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let missing = store.readMissing {
            ScopeDeniedScreen(scope: missing)
        } else if store.logStoreOff {
            WholeScreenState {
                ContentUnavailableView("Raw logs are not enabled on this server", systemImage: "exclamationmark.triangle",
                                       description: Text("This server runs without its log store, so no line is kept."))
            }
        } else {
            ResourceView(state: store.sources, noun: "log sources", retry: refreshSources) { sources in
                if sources.isEmpty {
                    WholeScreenState {
                        ContentUnavailableView {
                            Label("No raw log source", systemImage: "doc.plaintext")
                        } description: {
                            Text("Sources are added on the web. A node with connection tracing on ships its sing-box lines here too.")
                        } actions: {
                            Button("Add a source on web") { router.openOnWeb(EvidenceCopy.collection) }
                        }
                    }
                } else {
                    list
                }
            }
        }
    }

    private var matches: [String] { EvidenceLogs.matches(model.lines, find: findText) }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    sourcePicker
                    if let source { sourceFacts(source) }
                } footer: {
                    if let nodeID, chosenSourceID == nil, source == nil {
                        Text("\(nodes.name(for: nodeID)) has no raw log source. Choose another source above.")
                    }
                }
                if source != nil {
                    linesSection
                }
            }
            .listStyle(.insetGrouped)
            .refreshable {
                if let source { await model.refresh(session: session, sourceID: source.id, search: submittedSearch) }
            }
            .task(id: model.newestRevision) {
                // Rows must be laid out before the list can scroll to them.
                try? await Task.sleep(for: .milliseconds(150))
                if finding, !findText.isEmpty {
                    if currentMatch == nil { currentMatch = EvidenceLogs.step(matches, from: nil, forward: false) }
                    if let currentMatch { proxy.scrollTo(currentMatch, anchor: .center) }
                } else if let last = model.lines.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
            .onChange(of: currentMatch) { _, id in
                guard let id else { return }
                withAnimation(nil) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: findText) { currentMatch = EvidenceLogs.step(matches, from: nil, forward: false) }
        }
    }

    @ViewBuilder
    private func sourceFacts(_ source: LogSource) -> some View {
        let stat = store.sourceStats.value?.first { $0.sourceID == source.id }
        if !source.path.hasPrefix("singbox://") {
            DetailRow(label: "Path", value: source.path, monospaced: true)
        }
        if let stat {
            let last = stat.lastIngestAt.map { "last line \(TimeDisplay.relative($0, now: Date(), locale: locale))" } ?? "never shipped a line"
            DetailRow(label: "Held", value: "\(stat.lines.formatted()) lines, \(ByteFormatter.bytes(stat.bytes))", secondary: last, copyable: false)
        }
    }

    @ViewBuilder
    private var linesSection: some View {
        Section {
            if case .failed(let error, _, _) = model.state {
                ErrorRow(message: "Could not read lines: \(error.localizedDescription)") { refreshLines() }
            }
            if case .companionBehind(let surface) = model.state {
                CompanionBehindRow(surface: surface)
            }
            if case .denied(let scope) = model.state {
                ScopeDeniedRow(scope: scope)
            }
            if model.lines.isEmpty {
                if model.state.isLoading || model.state.value == nil, model.state.evidenceError == nil {
                    LoadingRows(label: "Loading lines")
                } else if model.state.value != nil {
                    Text(submittedSearch.isEmpty ? "No line has been shipped from this source." : "No line contains \u{201C}\(submittedSearch)\u{201D}.")
                        .foregroundStyle(.secondary)
                        .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                }
            } else {
                olderRow
                let matched = Set(matches)
                ForEach(model.lines) { line in
                    lineRow(line, isMatch: matched.contains(line.id))
                        .id(line.id)
                }
            }
        } header: {
            Text(linesHeader).accessibilityAddTraits(.isHeader)
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if model.skippedChunks {
                    Text("A stored chunk could not be decoded and was skipped.").foregroundStyle(Color.statusWarnText)
                }
                FreshnessFooter(state: model.state, interval: 60)
            }
        }
    }

    private var linesHeader: String {
        let count = model.lines.count
        let base = count == 1 ? "1 line, newest last" : "\(count.formatted()) lines, newest last"
        return submittedSearch.isEmpty ? base : "\(base), containing \u{201C}\(submittedSearch)\u{201D}"
    }

    @ViewBuilder
    private var olderRow: some View {
        if let error = model.olderError {
            ErrorRow(message: "Could not load older lines: \(error.localizedDescription)") { Task { await model.loadOlder(session: session) } }
        } else if model.nextBeforeSeq != nil {
            Button {
                Task { await model.loadOlder(session: session) }
            } label: {
                HStack {
                    Label("Load older", systemImage: "arrow.up.to.line")
                    if model.loadingOlder { Spacer(); ProgressView() }
                }
                .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
            }
            .disabled(model.loadingOlder)
        } else {
            Text("Start of what this source holds").textRole(.footnote)
                .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
        }
    }

    private func lineRow(_ line: LogLine, isMatch: Bool) -> some View {
        let isCurrent = currentMatch == line.id
        let time = line.at.map { TimeDisplay.clock($0, mode: mode, locale: locale) }
        return VStack(alignment: .leading, spacing: Spacing.xxs) {
            if let time {
                Text(time + (line.truncated ? ", truncated" : "")).textRole(.stamp)
            }
            Text(highlighted(line.line, isMatch: isMatch))
                .textRole(.code)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
        .listRowBackground(isCurrent ? Color.accentText.opacity(0.12) : nil)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([time, line.line, line.truncated ? "truncated" : nil, isCurrent ? "current match" : nil].compactMap { $0 }.joined(separator: ", "))
        .contextMenu {
            Button("Copy line", systemImage: "doc.on.doc") { EvidenceCopy.copy(line.line) }
            if let time { Button("Copy with time", systemImage: "clock") { EvidenceCopy.copy("\(time) \(line.line)") } }
        }
        .accessibilityActions {
            Button("Copy line") { EvidenceCopy.copy(line.line) }
        }
    }

    /// The find text highlighted wherever it occurs in a matching line.
    private func highlighted(_ text: String, isMatch: Bool) -> AttributedString {
        var attributed = AttributedString(text)
        guard isMatch else { return attributed }
        var searchRange = attributed.startIndex..<attributed.endIndex
        while let range = attributed[searchRange].range(of: findText, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[range].backgroundColor = Color.accentText.opacity(0.28)
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
            searchRange = range.upperBound..<attributed.endIndex
        }
        return attributed
    }

    /// Find over the loaded lines: the field, "2 of 14", previous and next.
    private var findBar: some View {
        let accessible = typeSize.isAccessibilitySize
        let layout = accessible
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.s))
            : AnyLayout(HStackLayout(spacing: Spacing.s))
        return layout {
            HStack(spacing: Spacing.s) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Find in loaded lines", text: $findText)
                    .textFieldStyle(.plain)
                    .focused($findFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { step(forward: false) }
            }
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: Spacing.minimumTarget)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            HStack(spacing: Spacing.xs) {
                Text(matchCount)
                    .textRole(.stamp)
                    .lineLimit(1)
                    .fixedSize()
                Button { step(forward: false) } label: {
                    Image(systemName: "chevron.up").frame(width: Spacing.minimumTarget, height: Spacing.minimumTarget)
                }
                .accessibilityLabel("Previous match")
                .disabled(matches.isEmpty)
                Button { step(forward: true) } label: {
                    Image(systemName: "chevron.down").frame(width: Spacing.minimumTarget, height: Spacing.minimumTarget)
                }
                .accessibilityLabel("Next match")
                .disabled(matches.isEmpty)
            }
        }
    }

    private var matchCount: String {
        guard !findText.isEmpty else { return "" }
        guard !matches.isEmpty else { return "No match" }
        let index = currentMatch.flatMap { matches.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        return "\(index) of \(matches.count)"
    }

    private func step(forward: Bool) {
        currentMatch = EvidenceLogs.step(matches, from: currentMatch, forward: forward)
        if !matchCount.isEmpty { AccessibilityNotification.Announcement(matchCount).post() }
    }

    private func refreshSources() {
        Task { await store.refreshSources() }
    }

    private func refreshLines() {
        guard let source else { return }
        Task { await model.refresh(session: session, sourceID: source.id, search: submittedSearch) }
    }
}

/// The polling key: a ChangeLog bump, another source or another search restarts the loop.
private struct LogPollKey {
    static func of(_ version: Int, _ sourceID: String?, _ search: String) -> Int {
        var hasher = Hasher()
        hasher.combine(version)
        hasher.combine(sourceID)
        hasher.combine(search)
        return hasher.finalize()
    }
}
