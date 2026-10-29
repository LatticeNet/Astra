import SwiftUI

/// M8-05 Share: the facts of a subscription share (owner identity, expiry,
/// refresh interval, rotation, render budget) and its actions: Reveal URL
/// (S, then Share), Refresh (T2), Rotate (T3), Delete (T4); expiry and
/// interval are edited on the web. Gate an unconfined proxy:admin.
struct ShareDetailScreen: View {
    let id: String

    @Environment(PublishingStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    @State private var lastRefresh: PlatformShareRefresh?

    var body: some View {
        PlatformListState(state: store.shares, noun: "the share", retry: { Task { await store.refresh() } }) { shares in
            if let share = shares.first(where: { $0.id == id }) {
                detail(share)
            } else {
                notFound
            }
        }
        .navigationTitle(store.share(id: id)?.slug ?? "Share")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(store.share(id: id).map { PlatformShareRow.style($0, state: PlatformShareState.of($0, now: Date())).word } ?? "")
        .refreshable { await store.refresh() }
        .polling(.standard, version: changes.version(.publishing)) { await store.refresh() }
        .toolbar { toolbar }
    }

    private func date(_ value: Date) -> (String, String) {
        (TimeDisplay.dateTime(value, mode: mode, locale: locale), TimeDisplay.relative(value, now: Date(), locale: locale))
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(_ share: PlatformShare) -> some View {
        let now = Date()
        let state = PlatformShareState.of(share, now: now)
        let style = PlatformShareRow.style(share, state: state)
        let missing = store.shareMissing
        List {
            Section {
                StatusRow(style: style, title: PlatformFormat.breakable(share.slug), detail: PlatformFormat.breakable(share.maskedPath), reason: headline(share, state: state), titleIsIdentifier: true,
                          accessibilityPhrase: "Share \(share.slug), \(style.word)")
                PlatformRefreshError(state: store.shares, noun: "the share") { Task { await store.refresh() } }
                PlatformActionRow(title: "Reveal share URL", systemImage: "eye", note: revealNote, missing: store.revealMissing) {
                    Task { await runner.reveal(PlatformIntents.revealShare(id: share.id, slug: share.slug, origin: session.consoleURL)) }
                }
            } footer: {
                Text("The URL is a credential for what the share publishes. It is never sent to this iPhone until you reveal it, and it is not kept.")
            }

            Section("Share") {
                // One screen states one state: the header's word leads, and the
                // plain lifecycle follows only when a problem overrides it.
                let lifecycle = StatusStyle.platformShare(state).word
                DetailRow(label: "State", value: style.word.platformCapitalized,
                          secondary: style.word == lifecycle ? nil : "Lifecycle: \(lifecycle)", copyable: false)
                if let expiry = share.expiresAt {
                    let (absolute, relative) = date(expiry)
                    DetailRow(label: state == .expired ? "Expired" : "Expires", value: absolute, secondary: relative, copyable: false)
                } else {
                    DetailRow(label: "Expires", value: "Never", copyable: false)
                }
                DetailRow(label: "Clients refresh", value: PlatformFormat.interval(hours: share.updateIntervalHours), copyable: false)
                DetailRow(label: "Source", value: PlatformShares.sourceLabel(share), copyable: true)
                if !share.defaultFormat.isEmpty {
                    DetailRow(label: "Default format", value: share.defaultFormat, copyable: false)
                }
                if let rotated = share.rotatedAt {
                    let (absolute, relative) = date(rotated)
                    DetailRow(label: "Last rotated", value: absolute, secondary: relative, copyable: false)
                }
                if let created = share.createdAt {
                    let (absolute, relative) = date(created)
                    DetailRow(label: "Created", value: absolute, secondary: relative, copyable: false)
                }
            }

            ownerSection(share)
            budgetSection(share)
            refreshSection(share, missing: missing)

            Section {
                PlatformActionRow(title: "Rotate share \(share.slug)", systemImage: "arrow.triangle.2.circlepath", note: "The current URL stops working at once", missing: missing) {
                    Task { await runner.run(PlatformIntents.rotateShare(id: share.id, slug: share.slug, rotatedBefore: share.rotatedAt)) }
                }
                WebLinkRow(title: "Edit expiry or interval on web", path: .share(id: share.id))
                PlatformActionRow(title: "Delete share \(share.slug)", systemImage: "trash", note: "Its URL stops answering at once", missing: missing, role: .destructive) {
                    Task { await deleteShare(share) }
                }
            } header: {
                Text("Leak response")
            } footer: {
                FreshnessFooter(state: store.shares, interval: 60)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var revealNote: String {
        session.revealClient == nil ? "Needs a signed-in session and your code" : "Asks for your authenticator code, then offers Share"
    }

    private func headline(_ share: PlatformShare, state: PlatformShareState) -> String? {
        if share.fleetFeedNow == "fleet" { return "Its record now reads the identity-less export: this link hands out every user's credentials." }
        if share.fleetFeedNow == "unknown" { return "The server cannot read the Sub-Store record list to check what this link publishes." }
        if share.publishesFleetCredentials { return "Published on purpose with every user's credentials." }
        if state == .expired { return "This URL no longer answers. Extend the expiry on the web to bring it back." }
        if state == .paused { return "Turned off: the URL answers like a wrong token until it is enabled on the web." }
        return nil
    }

    @ViewBuilder
    private func ownerSection(_ share: PlatformShare) -> some View {
        Section {
            if !share.source.identityID.isEmpty {
                NavigationLink(value: AppRoute.vpn(.user(id: share.source.identityID))) {
                    DetailRow(label: "Identity", value: share.source.identityID, copyable: false)
                }
            } else if !share.source.proxyUserID.isEmpty {
                DetailRow(label: "Proxy user", value: share.source.proxyUserID, monospaced: true)
            } else {
                DetailRow(label: "Owner", value: "Names nobody: the record selects lines", copyable: false)
            }
        } header: {
            Text("Owner")
        } footer: {
            Text(share.source.identityID.isEmpty
                 ? "Whose credentials this link publishes."
                 : "The link publishes this identity's credentials into the record's lines.")
        }
    }

    @ViewBuilder
    private func budgetSection(_ share: PlatformShare) -> some View {
        let tone = PlatformRenderBudgetTone.of(share.renderBudget)
        Section {
            if let budget = share.renderBudget {
                ValueBarRow(label: "Renders left", value: "\(budget.remaining) of \(budget.burst)",
                            fraction: budget.burst > 0 ? 1 - Double(budget.remaining) / Double(budget.burst) : nil, threshold: 0.75)
                if budget.perHour > 0 {
                    DetailRow(label: "Refills", value: "\(budget.perHour) an hour", copyable: false)
                }
                if budget.refused > 0 {
                    DetailRow(label: "Refused", value: budget.refused == 1 ? "1 render" : "\(budget.refused) renders",
                              secondary: budget.lastRefusedAt.map { "Last \(TimeDisplay.relative($0, now: Date(), locale: locale))" }, copyable: false)
                }
            } else {
                DetailRow(label: "Renders left", value: "Full", secondary: "Not rendered since the server started", copyable: false)
            }
        } header: {
            Text("Render budget")
        } footer: {
            if tone == .exhausted {
                Text("Exhausted: new renders answer a decoy until the budget refills.")
                    .foregroundStyle(Color.statusWarnText)
            } else {
                Text("Caps how often clients can make the plugin render this link.")
            }
        }
    }

    @ViewBuilder
    private func refreshSection(_ share: PlatformShare, missing: String?) -> some View {
        Section {
            if PlatformShares.canRefresh(share) {
                PlatformActionRow(title: "Refresh from the provider", systemImage: "arrow.clockwise", note: "Fetches now and drops the cached body", missing: missing) {
                    Task { await refresh(share) }
                }
                if let lastRefresh {
                    if let fetched = lastRefresh.fetchedAt {
                        let (absolute, relative) = date(fetched)
                        DetailRow(label: "Last fetched", value: absolute, secondary: relative, copyable: false)
                    }
                    DetailRow(label: "Fetched", value: ByteFormatter.bytes(UInt64(max(lastRefresh.bytes, 0))), copyable: false)
                    if lastRefresh.stale {
                        Label("The provider fetch failed: \(lastRefresh.error). The last snapshot is still served.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.statusWarnText)
                            .frame(minHeight: Spacing.minimumTarget)
                    }
                }
            } else {
                DetailRow(label: "Refresh", value: "Not needed", secondary: "A proxy user's share renders from the control plane on every fetch", copyable: false)
            }
        } header: {
            Text("Provider")
        }
    }

    private func refresh(_ share: PlatformShare) async {
        let sink = PlatformRefreshSink()
        _ = await runner.run(PlatformIntents.refreshShare(id: share.id, slug: share.slug, sink: sink))
        if let result = await sink.result { lastRefresh = result }
    }

    private func deleteShare(_ share: PlatformShare) async {
        let outcome = await runner.run(PlatformIntents.deleteShare(id: share.id, slug: share.slug))
        // The screen closes only once the server confirmed the delete.
        if case .done = outcome { dismiss() }
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Share not found", systemImage: "link.badge.plus")
            } description: {
                Text("This share was deleted, or it is in the recycle bin on the web.")
            } actions: {
                Button("Open on web") { router.openOnWeb(.share(id: id)) }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let share = store.share(id: id) {
                    let missing = store.shareMissing
                    PlatformGatedButton(title: "Reveal share URL", systemImage: "eye", missing: store.revealMissing) {
                        Task { await runner.reveal(PlatformIntents.revealShare(id: share.id, slug: share.slug, origin: session.consoleURL)) }
                    }
                    if PlatformShares.canRefresh(share) {
                        PlatformGatedButton(title: "Refresh", systemImage: "arrow.clockwise", missing: missing) { Task { await refresh(share) } }
                    }
                    PlatformGatedButton(title: "Rotate", systemImage: "arrow.triangle.2.circlepath", missing: missing) {
                        Task { await runner.run(PlatformIntents.rotateShare(id: share.id, slug: share.slug, rotatedBefore: share.rotatedAt)) }
                    }
                    Section {
                        Button("Copy link", systemImage: "link") { PlatformCopy.copy(PlatformCopy.shareLink(id)) }
                        Button("Open on web", systemImage: "safari") { router.openOnWeb(.share(id: id)) }
                    }
                    Section {
                        PlatformGatedButton(title: "Delete share", systemImage: "trash", missing: missing, role: .destructive) { Task { await deleteShare(share) } }
                    }
                } else {
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.share(id: id)) }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}
