import SwiftUI

/// The Browse tab (F-22): the directory when the search field is empty, and
/// page and object results while typing.
struct BrowseRoot: View {
    @Environment(AppState.self) private var appState
    @Environment(SessionStore.self) private var session
    @Environment(NodeDirectory.self) private var nodes
    @SceneStorage("browse.root.query") private var query = ""
    @State private var results: [SearchResult] = []
    @State private var recents: [String] = BrowseRecents.load()
    @State private var unavailableExpanded = false

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                directory
            } else {
                searchResults
            }
        }
        .navigationTitle("Browse")
        .searchable(text: $query, prompt: "Pages, nodes, incidents")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .task(id: query) { await search() }
        .tabRootToolbar()
    }

    // MARK: Directory

    @ViewBuilder
    private var directory: some View {
        let scopes = session.tokenScopes
        let recentEntries = recents.compactMap(BrowseDirectory.entry(id:)).filter { isAvailable($0, scopes) }
        if !recentEntries.isEmpty {
            Section("Recent") {
                ForEach(recentEntries) { row($0) }
            }
        }
        ForEach(BrowseDirectory.sections) { section in
            let available = section.entries.filter { isAvailable($0, scopes) }
            if !available.isEmpty {
                Section(section.title) {
                    ForEach(available) { row($0) }
                }
            }
        }
        let unavailable = BrowseDirectory.allEntries.filter { !isAvailable($0, scopes) }
        if !unavailable.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $unavailableExpanded) {
                    ForEach(unavailable) { entry in
                        DirectoryRow(entry: entry, subtitle: missingText(entry, scopes), available: false) { record(entry) }
                    }
                } label: {
                    Text("Not available with this token (\(unavailable.count))")
                }
            }
        }
    }

    private func row(_ entry: DirectoryEntry) -> some View {
        DirectoryRow(entry: entry, subtitle: nil) { record(entry) }
    }

    /// Unknown scopes are not missing scopes: until `/api/me` answers, every
    /// page stays in its section.
    private func isAvailable(_ entry: DirectoryEntry, _ scopes: ScopeSet?) -> Bool {
        if entry.needsSession {
            return session.credentialKind == .session || session.revealClient != nil || session.isDemo
        }
        guard let scopes else { return true }
        return scopes.allows(entry.requirement)
    }

    private func missingText(_ entry: DirectoryEntry, _ scopes: ScopeSet?) -> String {
        if entry.needsSession { return "Needs a signed-in session" }
        let missing = scopes?.missing(entry.requirement) ?? []
        return missing.isEmpty ? "Needs \(entry.requirement.summary)" : "Needs \(missing.joined(separator: ", "))"
    }

    private func record(_ entry: DirectoryEntry) {
        BrowseRecents.record(entry.id)
        recents = BrowseRecents.load()
    }

    // MARK: Search

    @ViewBuilder
    private var searchResults: some View {
        let pages = BrowseDirectory.allEntries.filter { $0.title.localizedStandardContains(query.trimmingCharacters(in: .whitespaces)) }
        if !pages.isEmpty {
            Section("Pages") {
                ForEach(pages) { entry in
                    let available = isAvailable(entry, session.tokenScopes)
                    DirectoryRow(entry: entry, subtitle: available ? nil : missingText(entry, session.tokenScopes), available: available) { record(entry) }
                }
            }
        }
        let groups = Dictionary(grouping: results, by: \.kind)
        ForEach(groups.keys.sorted(), id: \.self) { kind in
            Section(kind) {
                ForEach((groups[kind] ?? []).prefix(5)) { result in
                    SearchResultRow(result: result)
                }
            }
        }
        if pages.isEmpty && results.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = []
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        guard case .success(let parsed) = LatticeQuery.parse(text) else {
            results = []
            return
        }
        await SearchRegistry.search(parsed, context: SearchContext(session: session, nodes: nodes)) { found in
            guard !Task.isCancelled else { return }
            results = found
        }
    }
}

/// A directory row. Push rows show a chevron; rows that switch tabs or open
/// Settings say where they open instead; web rows say they open on the web.
struct DirectoryRow: View {
    let entry: DirectoryEntry
    /// "Needs node:read" for pages this token cannot read, or a result's detail.
    let subtitle: String?
    var available = true
    /// A search result's state. It replaces the accent icon with the status
    /// glyph and leads the subtitle with the state word, because the accent
    /// never sits next to a status meaning (4.1).
    var status: StatusStyle?
    var onOpen: () -> Void = {}

    @Environment(Router.self) private var router

    var body: some View {
        switch entry.target {
        case .push(let route):
            NavigationLink(value: route) { label(trailing: nil) }
                .simultaneousGesture(TapGesture().onEnded(onOpen))
        case .tab(let tab, let scope, let query):
            Button {
                onOpen()
                router.select(tab: tab, scope: scope, query: query)
            } label: {
                label(trailing: (tab.symbol, "Opens in \(tab.title)"))
            }
            .tint(.primary)
        case .settings(let path):
            Button {
                onOpen()
                router.openSettings(path)
            } label: {
                label(trailing: ("gearshape", "Opens in Settings"))
            }
            .tint(.primary)
        case .web(let path):
            Button {
                onOpen()
                router.openOnWeb(path)
            } label: {
                label(trailing: ("safari", "Open on web"))
            }
            .tint(.primary)
            .accessibilityHint("Opens the console in your browser")
        }
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    @ViewBuilder
    private func label(trailing: (symbol: String, text: String)?) -> some View {
        if typeSize.isAccessibilitySize {
            // No icons at accessibility sizes: the title gets the full width,
            // and where the row opens is a line of its own.
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                if let status {
                    Text("\(Text(Image(systemName: status.symbol)).foregroundStyle(status.tone.glyph)) \(entry.title)")
                } else {
                    Text(entry.title)
                }
                if let subtitleLine { subtitleLine.textRole(.footnote) }
                if let trailing { Text(trailing.text).textRole(.footnote) }
            }
            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: Spacing.m) {
                Label {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(entry.title)
                        if let subtitleLine {
                            subtitleLine.textRole(.footnote)
                        }
                    }
                } icon: {
                    if let status {
                        StatusGlyph(style: status, font: .body)
                    } else {
                        Image(systemName: entry.symbol)
                            .foregroundStyle(available ? Color.accentText : .secondary)
                    }
                }
                Spacer(minLength: Spacing.s)
                if let trailing {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Spacing.xs) {
                            Text(trailing.text)
                            Image(systemName: trailing.symbol)
                        }
                        Image(systemName: trailing.symbol)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                }
            }
            .frame(minHeight: Spacing.minimumTarget)
            .accessibilityElement(children: .combine)
            .accessibilityHint(trailing.map { Text($0.text) } ?? Text(verbatim: ""))
        }
    }

    /// The state word, colored for problems, followed by the subtitle.
    private var subtitleLine: Text? {
        let word = status.flatMap { $0.word.isEmpty ? nil : Text($0.word).foregroundStyle($0.tone.word) }
        switch (word, subtitle) {
        case let (word?, subtitle?): return Text("\(word) · \(subtitle)")
        case let (word?, nil): return word
        case let (nil, subtitle?): return Text(subtitle)
        case (nil, nil): return nil
        }
    }
}

/// An object found by a module's search provider. A result with a state shows
/// its status glyph and word; one without shows a neutral object glyph.
struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        DirectoryRow(
            entry: DirectoryEntry(id: result.id, title: result.title, symbol: result.style?.symbol ?? "circle", target: result.target),
            subtitle: result.detail,
            status: result.style
        )
    }
}
