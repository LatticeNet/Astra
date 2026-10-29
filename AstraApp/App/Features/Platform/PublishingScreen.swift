import SwiftUI

/// The four views of Publishing.
enum PlatformPublishingView: String, CaseIterable, Hashable {
    case overview, routes, tokens, buckets

    var title: String { rawValue.platformCapitalized }
}

/// M8-04 Publishing: what this server publishes, where, and with which
/// credential. Gate any of kv:read, static:read or proxy:admin. Routes are
/// filtered per origin by the server; share routes need an unconfined
/// proxy:admin and storage tokens need kv:admin or static:admin. Delete
/// binding and Revoke token are T4 swipes; everything that creates is web.
struct PublishingScreen: View {
    var view: String?

    static let queryKey = "platform.publishing.query"

    @Environment(PublishingStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(ActionRunner.self) private var runner
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @Environment(\.timeZoneMode) private var mode
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var stable = PlatformStableList<String, PlatformPublishingRecord>()

    @State private var selected = PlatformPublishingView.overview
    @State private var lens = PlatformPublishingLens.all
    @State private var tokens: [PlatformPublishingLens] = []
    @State private var width: CGFloat?
    @State private var applied = false
    @SceneStorage(PublishingScreen.queryKey) private var query = ""

    var body: some View {
        content
            .navigationTitle("Publishing")
            // Inline: a large title would sit under the picker bar's scroll edge effect.
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(subtitle)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .safeAreaBar(edge: .top) {
                if verticalSizeClass != .compact, store.screenMissing == nil {
                    picker(containerWidth: width).padding(.horizontal, Spacing.l).padding(.bottom, Spacing.s)
                }
            }
            .toolbar { toolbar }
            .onAppear {
                applyLink()
                offerRoutes(force: true)
            }
            .onChange(of: lens) { _, new in
                tokens = new == .all ? [] : [new]
                offerRoutes(force: true)
            }
            .onChange(of: tokens) { _, new in if new.isEmpty, lens != .all { lens = .all } }
            .onChange(of: query) { offerRoutes(force: true) }
            // Each view reads the search with its own grammar, so a query
            // typed for one never silently filters another.
            .onChange(of: selected) { query = "" }
            .onChange(of: store.records.value) { offerRoutes(force: false) }
            .refreshable {
                await store.refresh()
                offerRoutes(force: true)
            }
            .polling(.standard, version: changes.version([.publishing, .store])) { await store.refresh() }
    }

    private var subtitle: String {
        var parts: [String] = []
        if lens != .all { parts.append("\(lens.title) only") }
        if !query.isEmpty { parts.append(query) }
        return parts.joined(separator: " · ")
    }

    private func applyLink() {
        guard !applied else { return }
        applied = true
        if let view, let initial = PlatformPublishingView(rawValue: view) { selected = initial }
    }

    private func picker(containerWidth: CGFloat?) -> some View {
        AdaptiveSegmentedPicker(
            title: "Publishing view",
            options: PlatformPublishingView.allCases.map { ($0, $0.title) },
            selection: $selected,
            containerWidth: containerWidth
        )
    }

    @ViewBuilder
    private var content: some View {
        if let missing = store.screenMissing {
            ScopeDeniedScreen(scope: missing)
        } else if store.records.value == nil {
            PlatformListState(state: store.records, noun: "publishing", retry: { Task { await store.refresh() } }) { _ in EmptyView() }
        } else {
            switch selected {
            case .overview: overview
            case .routes: routes
            case .tokens: tokensView
            case .buckets: bucketsView
            }
        }
    }

    // MARK: Overview

    private var overview: some View {
        let now = Date()
        let records = store.records.value?.records ?? []
        let shares = store.shares.value ?? []
        let visible = Set(store.records.value?.origins ?? [])
        return List {
            PlatformRefreshError(state: store.records, noun: "routes") { Task { await store.refresh() } }
            Section {
                ForEach(["kv", "static", "plugin"], id: \.self) { origin in
                    originRow(origin, records: records.filter { $0.origin == origin }, visible: visible.contains(origin), now: now)
                }
            } header: {
                Text("Routes by origin")
            } footer: {
                Text("A route decides the URL; its origin decides where the bytes come from.")
            }
            attentionSection(records: records, shares: shares, now: now)
            Section {
                ForEach([PlatformAccessMode.storageToken, .anonymous, .shareToken], id: \.self) { mode in
                    DetailRow(label: accessTitle(mode), value: mode.sentence, copyable: false)
                }
            } header: {
                Text("Who can read a route")
            } footer: {
                FreshnessFooter(loadedAt: store.loadedAt, isUpdating: store.anyLoading && store.loadedAt != nil, lastAttemptFailed: store.anyFailed)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func accessTitle(_ mode: PlatformAccessMode) -> String {
        switch mode {
        case .storageToken: "KV"
        case .anonymous: "Static"
        case .shareToken: "Shares"
        case .unknown: "Other"
        }
    }

    @ViewBuilder
    private func originRow(_ origin: String, records: [PlatformPublishingRecord], visible: Bool, now: Date) -> some View {
        let title = origin == "plugin" ? "Shares and identity links" : (origin == "kv" ? "KV" : "Static")
        let lensValue: PlatformPublishingLens = origin == "plugin" ? .share : (origin == "kv" ? .kv : .static)
        if visible || store.records.value == nil {
            let states = records.map { PlatformRouteState.of($0, now: now) }
            let serving = states.filter { $0 == .serving }.count
            let expired = states.filter { $0 == .expired }.count
            let disabled = states.filter { $0 == .disabled }.count
            Button {
                lens = lensValue
                selected = .routes
            } label: {
                let doubt = recordsDoubt(now: now)
                // Only an expired route warns, and Needs attention lists it; a
                // route switched off on purpose is reported in the quiet style.
                let style: StatusStyle = if records.isEmpty {
                    StatusStyle(word: "no routes", symbol: originSymbol(origin), tone: .quiet)
                } else if expired > 0 {
                    StatusStyle(word: "\(expired) expired", symbol: "clock.badge.xmark", tone: .warn)
                } else if doubt != nil {
                    PlatformConfidence.style
                } else if disabled > 0 {
                    StatusStyle(word: "\(disabled) off", symbol: "minus.circle", tone: .quiet)
                } else {
                    StatusStyle(word: "all serving", symbol: "checkmark.circle.fill", tone: .ok)
                }
                StatusRow(style: style, title: title,
                          detail: records.isEmpty ? nil : (records.count == 1 ? "1 route" : "\(records.count) routes"),
                          reason: expired == 0 && !records.isEmpty ? doubt : nil,
                          accessibilityPhrase: "\(title), \(style.word), \(serving) of \(records.count) serving")
            }
            .tint(.primary)
            .accessibilityHint("Shows these routes")
        } else {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title).textRole(.rowTitle)
                ScopeDeniedRow(scope: origin == "plugin" ? "proxy:admin" : "\(origin):read")
            }
        }
    }

    private func recordsDoubt(now: Date) -> String? {
        PlatformConfidence.doubt(store.records, offline: !network.isSatisfied, now: now, mode: mode, locale: locale)
    }

    private func originSymbol(_ origin: String) -> String {
        switch origin {
        case "kv": "tablecells"
        case "static": "doc.on.doc"
        default: "link"
        }
    }

    @ViewBuilder
    private func attentionSection(records: [PlatformPublishingRecord], shares: [PlatformShare], now: Date) -> some View {
        let expiredRoutes = records.filter { $0.origin != "plugin" && PlatformRouteState.of($0, now: now) == .expired }
        let attentionShares = shares.filter { share in
            let state = PlatformShareState.of(share, now: now)
            return state == .expiring || state == .expired || PlatformRenderBudgetTone.of(share.renderBudget) == .exhausted || !share.fleetFeedNow.isEmpty
        }
        // The all-clear needs both reads fresh; a blank or stale section must
        // never read as healthy.
        let doubt = recordsDoubt(now: now)
            ?? PlatformConfidence.doubt(store.shares, offline: !network.isSatisfied, now: now, mode: mode, locale: locale)
        Section {
            if case .denied = store.shares {
                ScopeDeniedRow(scope: store.shareMissing ?? "proxy:admin")
            } else if store.shares.value == nil {
                PlatformSectionState(state: store.shares, noun: "shares") { Task { await store.refresh() } }
            } else {
                PlatformRefreshError(state: store.shares, noun: "shares") { Task { await store.refresh() } }
            }
            if expiredRoutes.isEmpty, attentionShares.isEmpty, store.shares.value != nil {
                if let doubt {
                    Label(doubt, systemImage: PlatformConfidence.style.symbol)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: Spacing.minimumTarget)
                } else {
                    Label("Nothing needs attention", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .frame(minHeight: Spacing.minimumTarget)
                }
            }
            ForEach(attentionShares) { share in
                NavigationLink(value: AppRoute.platform(.share(id: share.id))) {
                    PlatformShareRow(share: share, now: now, emphasizeBudget: true)
                }
            }
            ForEach(expiredRoutes) { record in
                PlatformRouteRow(record: record, shareSlugs: store.shareSlugs, now: now)
            }
        } header: {
            Text("Needs attention")
        }
    }

    // MARK: Routes

    private func filteredRecords() -> (records: [PlatformPublishingRecord], error: String?) {
        let all = PlatformPublishing.sorted(lens.filter(store.records.value?.records ?? []))
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return (all, nil) }
        switch LatticeQueryEngine.compile(text, provider: PlatformRecordQueryFields.self) {
        case .success(let compiled): return (LatticeQueryEngine.apply(compiled, to: all, now: Date()), nil)
        case .failure(let error): return (all, error.localizedDescription)
        }
    }

    /// The filtered routes, offered to the stable list grouped by origin.
    private func offerRoutes(force: Bool) {
        let slots = filteredRecords().records.map { PlatformStableList<String, PlatformPublishingRecord>.Slot(group: $0.origin, row: $0) }
        stable.offer(slots, voiceOver: voiceOver, force: force)
    }

    private var routes: some View {
        let now = Date()
        let error = filteredRecords().error
        let visible = Set(store.records.value?.origins ?? [])
        let origins = (lens.origin.map { [$0] } ?? ["kv", "static", "plugin"])
        return List {
            if stable.held != nil, voiceOver {
                Section { PendingUpdatesRow(count: stable.pendingCount) { stable.showHeld() } }
            }
            if let error { queryErrorRow(error) }
            if lens != .all {
                FilterStateRow(text: "Showing \(lens.title) routes only.") { lens = .all }
            }
            PlatformRefreshError(state: store.records, noun: "routes") { Task { await store.refresh() } }
            ForEach(origins, id: \.self) { origin in
                routeSection(origin, rows: stable.rows(in: origin), visible: visible.contains(origin), now: now)
            }
            Section {
                WebLinkRow(title: "Create a binding or share on web", path: .platformPublishing(view: "routes"))
            } footer: {
                FreshnessFooter(state: store.records, interval: 60)
            }
        }
        .listStyle(.insetGrouped)
        .onScrollPhaseChange { _, phase in
            if phase != .idle { stable.noteActivity() }
        }
        .searchable(text: $query, tokens: $tokens, prompt: Text("Search routes")) { token in
            Text(token.title)
        }
    }

    @ViewBuilder
    private func routeSection(_ origin: String, rows: [PlatformPublishingRecord], visible: Bool, now: Date) -> some View {
        let heading = origin == "plugin" ? "Shares" : (origin == "kv" ? "KV" : "Static")
        Section {
            routeSectionState(origin, empty: rows.isEmpty, visible: visible)
            ForEach(rows) { record in
                routeLink(record, now: now)
            }
        } header: {
            Text(heading).accessibilityAddTraits(.isHeader)
        } footer: {
            Text(PlatformAccessMode.of(origin: origin).sentence + ".")
        }
    }

    @ViewBuilder
    private func routeSectionState(_ origin: String, empty: Bool, visible: Bool) -> some View {
        if store.records.value == nil {
            PlatformSectionState(state: store.records, noun: "routes") { Task { await store.refresh() } }
        } else if !visible {
            ScopeDeniedRow(scope: origin == "plugin" ? (store.shareMissing ?? "proxy:admin") : "\(origin):read")
        } else if empty {
            let noun = origin == "plugin" ? "share" : (origin == "kv" ? "KV" : origin)
            Text(query.isEmpty ? "No \(noun) routes" : "No matching routes")
                .foregroundStyle(.secondary)
                .frame(minHeight: Spacing.minimumTarget)
        }
    }

    @ViewBuilder
    private func routeLink(_ record: PlatformPublishingRecord, now: Date) -> some View {
        let row = PlatformRouteRow(record: record, shareSlugs: store.shareSlugs, now: now)
        if record.origin == "plugin", !record.shareID.isEmpty {
            NavigationLink(value: AppRoute.platform(.share(id: record.shareID))) { row }
                .contextMenu {
                    Button("Open", systemImage: "arrow.right.circle") { router.push(.platform(.share(id: record.shareID))) }
                    Button("Copy link", systemImage: "link") { PlatformCopy.copy(PlatformCopy.shareLink(record.shareID)) }
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.share(id: record.shareID)) }
                }
        } else if record.origin == "plugin", !record.identityID.isEmpty {
            NavigationLink(value: AppRoute.vpn(.user(id: record.identityID))) { row }
        } else if let kind = PlatformPublishing.storageKind(record) {
            let missing = store.adminMissing(kind)
            NavigationLink(value: AppRoute.platform(.binding(id: record.id))) { row }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if missing == nil {
                        Button("Delete", systemImage: "trash", role: .destructive) { deleteBinding(record, kind: kind) }
                    }
                }
                .contextMenu {
                    Button("Open", systemImage: "arrow.right.circle") { router.push(.platform(.binding(id: record.id))) }
                    Button("Copy ID", systemImage: "doc.on.doc") { PlatformCopy.copy(record.id) }
                    PlatformGatedButton(title: "Delete binding", systemImage: "trash", missing: missing, role: .destructive) { deleteBinding(record, kind: kind) }
                }
        } else {
            row
        }
    }

    private func deleteBinding(_ record: PlatformPublishingRecord, kind: PlatformStorageKind) {
        let intent = PlatformIntents.deleteBinding(kind: kind, id: record.id, route: PlatformPublishing.routeLabel(record), bucket: record.bucket)
        Task { await runner.run(intent) }
    }

    // MARK: Tokens

    private var tokensView: some View {
        List {
            if let error = tokenQueryError { queryErrorRow(error) }
            ForEach(PlatformStorageKind.allCases, id: \.self) { kind in
                if lens == .all || lens.origin == kind.rawValue {
                    tokenSection(kind)
                }
            }
            if lens == .share {
                Section {
                    Text("Shares carry their own token in the URL; storage tokens are for KV and static buckets.")
                        .foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
                }
            }
            Section {
                WebLinkRow(title: "Create a storage token on web", path: .platformPublishing(view: "tokens"))
            } footer: {
                Text("A new token is shown once, so it is created on the web where you will use it.")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, tokens: $tokens, prompt: Text("Search tokens")) { token in
            Text(token.title)
        }
    }

    @ViewBuilder
    private func tokenSection(_ kind: PlatformStorageKind) -> some View {
        let state = store.tokens[kind] ?? .idle
        let missing = store.adminMissing(kind)
        Section {
            if let list = state.value {
                PlatformRefreshError(state: state, noun: "\(kind.title) tokens") { Task { await store.refresh() } }
                let rows = filterTokens(list)
                if rows.isEmpty {
                    Text(list.isEmpty ? "No \(kind.platformNoun) storage tokens" : "No matching tokens")
                        .foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
                }
                ForEach(rows.sorted { ($0.isRevoked ? 1 : 0, $0.name) < ($1.isRevoked ? 1 : 0, $1.name) }) { token in
                    NavigationLink(value: AppRoute.platform(.storageToken(id: token.id))) {
                        PlatformTokenRow(token: token)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if missing == nil, !token.isRevoked {
                            Button("Revoke", systemImage: "xmark.circle", role: .destructive) { revoke(token, kind: kind) }
                        }
                    }
                    .contextMenu {
                        Button("Open", systemImage: "arrow.right.circle") { router.push(.platform(.storageToken(id: token.id))) }
                        Button("Copy ID", systemImage: "doc.on.doc") { PlatformCopy.copy(token.id) }
                        if !token.isRevoked {
                            PlatformGatedButton(title: "Revoke token", systemImage: "xmark.circle", missing: missing, role: .destructive) { revoke(token, kind: kind) }
                        }
                    }
                }
            } else {
                PlatformSectionState(state: state, noun: "\(kind.title) tokens") { Task { await store.refresh() } }
            }
        } header: {
            Text("\(kind.title) tokens").accessibilityAddTraits(.isHeader)
        } footer: {
            if state.value != nil { FreshnessFooter(state: state, interval: 60) }
        }
    }

    private var tokenQueryError: String? {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, case .failure(let error) = LatticeQueryEngine.compile(text, provider: PlatformTokenQueryFields.self) else { return nil }
        return error.localizedDescription
    }

    private func filterTokens(_ list: [PlatformStorageToken]) -> [PlatformStorageToken] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, case .success(let compiled) = LatticeQueryEngine.compile(text, provider: PlatformTokenQueryFields.self) else { return list }
        return LatticeQueryEngine.apply(compiled, to: list, now: Date())
    }

    private func revoke(_ token: PlatformStorageToken, kind: PlatformStorageKind) {
        Task { await runner.run(PlatformIntents.revokeToken(kind: kind, id: token.id, name: token.name, buckets: PlatformStorageTokens.bucketsLabel(token))) }
    }

    // MARK: Buckets

    private var bucketsView: some View {
        List {
            ForEach(PlatformStorageKind.allCases, id: \.self) { kind in
                if lens == .all || lens.origin == kind.rawValue {
                    PlatformBucketSection(kind: kind, query: query)
                }
            }
            if lens == .share {
                Section {
                    Text("Shares are rendered by their plugin and keep no bucket.")
                        .foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
                }
            }
            Section {
                WebLinkRow(title: "Create a bucket on web", path: .platformPublishing(view: "buckets"))
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, tokens: $tokens, prompt: Text("Search buckets")) { token in
            Text(token.title)
        }
    }

    private func queryErrorRow(_ error: String) -> some View {
        Section {
            Label(error, systemImage: "exclamationmark.magnifyingglass")
                .foregroundStyle(Color.statusWarnText)
                .frame(minHeight: Spacing.minimumTarget)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if verticalSizeClass == .compact, store.screenMissing == nil {
            ToolbarItem(placement: .topBarTrailing) {
                picker(containerWidth: typeSize.isAccessibilitySize ? 0 : width).frame(maxWidth: 320)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            FilterMenu(sections: [
                FilterMenuSection(title: "Origin", options: PlatformPublishingLens.allCases.map(\.title), defaultOption: PlatformPublishingLens.all.title,
                                  selection: Binding(get: { lens.title }, set: { title in lens = PlatformPublishingLens.allCases.first { $0.title == title } ?? .all })),
            ])
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Store", systemImage: "cylinder.split.1x2") { router.push(.platform(.store)) }
                Button("Open on web", systemImage: "safari") { router.openOnWeb(.platformPublishing(view: selected.rawValue)) }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}

/// One published route: its state, host and path, and what it serves.
struct PlatformRouteRow: View {
    let record: PlatformPublishingRecord
    let shareSlugs: [String: String]
    let now: Date

    var body: some View {
        let state = PlatformRouteState.of(record, now: now)
        let style = StatusStyle.platformRoute(state)
        let label = PlatformPublishing.routeLabel(record)
        let target = PlatformPublishing.originTargetLabel(record, shareSlugs: shareSlugs)
        let detail = detailLine(target: target)
        StatusRow(style: style, title: PlatformFormat.breakable(label), detail: detail, titleIsIdentifier: true,
                  accessibilityPhrase: "\(label.replacingOccurrences(of: "*", with: "any host")), \(style.word), \(detail)")
    }

    private func detailLine(target: String) -> String {
        if !record.identityID.isEmpty { return "identity link · edited with the identity" }
        switch record.origin {
        case "plugin": return "share \(target)\(record.reserved ? " · reserved" : "")"
        case "kv": return "KV bucket \(target)"
        case "static": return "static bucket \(target)"
        default: return "\(record.origin) \(target)"
        }
    }
}

/// One share: its state, slug and source, with the render budget when it matters.
struct PlatformShareRow: View {
    let share: PlatformShare
    let now: Date
    var emphasizeBudget = false

    @Environment(\.locale) private var locale

    var body: some View {
        let state = PlatformShareState.of(share, now: now)
        let style = PlatformShareRow.style(share, state: state)
        StatusRow(style: style, title: share.slug, detail: PlatformShares.sourceLabel(share), reason: reason(state),
                  accessibilityPhrase: "Share \(share.slug), \(style.word)")
    }

    /// The share's state, unless a serving share has a problem worse than
    /// its expiry: a link publishing every credential, or an exhausted budget.
    static func style(_ share: PlatformShare, state: PlatformShareState) -> StatusStyle {
        guard state.isServing else { return .platformShare(state) }
        if share.fleetFeedNow == "fleet" {
            return StatusStyle(word: "publishes every credential", symbol: "person.2.badge.key.fill", tone: .fail)
        }
        if PlatformRenderBudgetTone.of(share.renderBudget) == .exhausted {
            return StatusStyle(word: "budget exhausted", symbol: "gauge.with.dots.needle.100percent", tone: .warn)
        }
        return .platformShare(state)
    }

    private func reason(_ state: PlatformShareState) -> String? {
        if PlatformRenderBudgetTone.of(share.renderBudget) == .exhausted {
            return "Render budget exhausted: new renders answer a decoy until it refills."
        }
        if share.fleetFeedNow == "fleet" { return "Now publishes every user's credentials (fleet feed)." }
        if share.fleetFeedNow == "unknown" { return "Fleet feed could not be checked." }
        if let expiry = share.expiresAt, state == .expiring || state == .expired {
            let when = TimeDisplay.relative(expiry, now: now, locale: locale)
            return state == .expired ? "Expired \(when)" : "Expires \(when)"
        }
        return nil
    }
}

/// One storage token: active or revoked, its access and buckets, and when it was last used.
struct PlatformTokenRow: View {
    let token: PlatformStorageToken

    @Environment(\.locale) private var locale

    var body: some View {
        let style = StatusStyle.platformToken(token)
        let used = token.lastUsedAt.map { TimeDisplay.relative($0, now: Date(), locale: locale) } ?? "never used"
        let detail = "\(token.access) · \(PlatformStorageTokens.bucketsLabel(token))"
        StatusRow(style: style, title: token.name.isEmpty ? token.id : token.name, detail: detail, trailing: token.isRevoked ? nil : used,
                  accessibilityPhrase: "\(token.name), \(style.word), \(detail), \(token.isRevoked ? "" : "last used \(used)")")
    }
}

/// The buckets of one kind, for Publishing's Buckets view and for Store.
struct PlatformBucketSection: View {
    let kind: PlatformStorageKind
    var query = ""

    @Environment(PublishingStore.self) private var store

    var body: some View {
        let state = store.buckets[kind] ?? .idle
        Section {
            if let list = state.value {
                PlatformRefreshError(state: state, noun: "\(kind.title) buckets") { Task { await store.refreshBuckets() } }
                let text = query.trimmingCharacters(in: .whitespaces).lowercased()
                let entries = list.allBuckets
                    .filter { text.isEmpty || $0.name.lowercased().contains(text) }
                    .sorted { $0.name < $1.name }
                if entries.isEmpty {
                    Text(list.allBuckets.isEmpty ? "No \(kind.platformNoun) buckets" : "No matching buckets")
                        .foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
                }
                ForEach(entries) { entry in
                    if entry.reserved {
                        PlatformBucketRow(entry: entry, displayName: nil)
                    } else {
                        NavigationLink(value: AppRoute.platform(.bucket(kind: kind.rawValue, name: entry.name))) {
                            PlatformBucketRow(entry: entry, displayName: store.registeredBucket(kind: kind, name: entry.name)?.displayName)
                        }
                    }
                }
            } else {
                PlatformSectionState(state: state, noun: "\(kind.title) buckets") { Task { await store.refreshBuckets() } }
            }
        } header: {
            Text("\(kind.title) buckets").accessibilityAddTraits(.isHeader)
        } footer: {
            if state.value != nil { FreshnessFooter(state: state, interval: 60) }
        }
    }
}

/// One bucket: its name, who writes it and how much it holds.
struct PlatformBucketRow: View {
    let entry: PlatformBucketInventoryEntry
    let displayName: String?

    var body: some View {
        let owner = PlatformBucketOwner.of(entry)
        let count = entry.entries == 1 ? "1 entry" : "\(entry.entries) entries"
        let detail = entry.reserved
            ? "Server-owned; no scope can read it"
            : [displayName?.isEmpty == false ? displayName : nil, owner.sentence, count, entry.registered ? nil : "not registered"].compactMap { $0 }.joined(separator: " · ")
        StatusRow(style: .platformBucket(entry), title: PlatformFormat.breakable(entry.name), detail: detail, titleIsIdentifier: true,
                  accessibilityPhrase: "\(entry.name), \(detail)")
    }
}
