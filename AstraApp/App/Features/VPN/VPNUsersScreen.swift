import SwiftUI

/// M13-01 VPN users: every vpn-core identity, worst state first (expired,
/// over quota, expiring, no line, active, disabled), with its lines, link,
/// usage this period and expiry. Gate vpncore:read or proxy:read on a token
/// without a node allowlist. Create, bind and cutover stay on the web.
struct VPNUsersScreen: View {
    static let queryKey = "vpn.users.query"

    @Environment(VPNStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(SessionStore.self) private var session
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @SceneStorage(Self.queryKey) private var query = ""
    @State private var stable = VPNStableList<VPNUser> { old, new in
        VPNIdentity.state(old, now: Date()) == VPNIdentity.state(new, now: Date())
    }

    var body: some View {
        content
            .navigationTitle("VPN users")
            .navigationBarTitleDisplayMode(.large)
            .navigationSubtitle(subtitle)
            .searchable(text: $query, prompt: "Email, group or status:expiring")
            .toolbar { toolbar }
            .onChange(of: store.users.loadedAt, initial: true) { offer(force: false) }
            .onChange(of: query) { offer(force: true) }
            .polling(.standard, version: changes.version(.vpn)) { await store.refreshUsers() }
    }

    private var subtitle: String {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "" : "Filtered: \(text)"
    }

    @ViewBuilder
    private var content: some View {
        if !network.isSatisfied, store.users.value == nil, !store.users.isLoading, store.readMissing == nil {
            VPNOfflineView(noun: "VPN users", retry: refresh)
        } else {
            ResourceView(state: store.users, noun: "VPN users", retry: refresh) { listing in
                list(listing)
            }
        }
    }

    private func filtered(_ users: [VPNUser]) -> (rows: [VPNUser], error: String?) {
        let ordered = VPNIdentity.ordered(users, now: Date())
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return (ordered, nil) }
        switch LatticeQueryEngine.compile(text, provider: VPNUserQueryFields.self) {
        case .success(let compiled): return (LatticeQueryEngine.apply(compiled, to: ordered, now: Date()), nil)
        case .failure(let error): return (ordered, error.localizedDescription)
        }
    }

    private func offer(force: Bool) {
        stable.offer(filtered(store.users.value?.users ?? []).rows, voiceOver: voiceOver, force: force)
    }

    private func list(_ listing: VPNUserListing) -> some View {
        let now = Date()
        let queryError = filtered(listing.users).error
        let shown = stable.shown
        let groups = VPNIdentityState.order.compactMap { state -> (VPNIdentityState, [VPNUser])? in
            let rows = shown.filter { VPNIdentity.state($0, now: now) == state }
            return rows.isEmpty ? nil : (state, rows)
        }
        return List {
            VPNRefreshError(state: store.users, noun: "VPN users", retry: refresh)
            if stable.held != nil, voiceOver {
                Section { PendingUpdatesRow(count: stable.pendingCount) { stable.showHeld() } }
            }
            if let queryError {
                Section {
                    Label(queryError, systemImage: "exclamationmark.magnifyingglass")
                        .foregroundStyle(Color.statusWarnText)
                        .frame(minHeight: Spacing.minimumTarget)
                }
            }
            if !listing.users.isEmpty, query.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    Text(VPNUsersSummary.of(listing.users, now: now).sentence)
                        .textRole(.rowTitle)
                        .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    if listing.source == .legacyProxyUser {
                        Label("Read from the legacy proxy users: vpn-core is not active on this server, so lines and links are not shown.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.statusWarnText)
                            .frame(minHeight: Spacing.minimumTarget)
                    }
                }
            }
            if shown.isEmpty {
                Section { emptyState(all: listing.users) }
            }
            ForEach(groups, id: \.0) { state, rows in
                Section {
                    ForEach(rows) { row($0, now: now) }
                } header: {
                    Text("\(state.label.prefix(1).uppercased())\(state.label.dropFirst()) (\(rows.count))")
                        .accessibilityAddTraits(.isHeader)
                        .id(state.rawValue)
                }
            }
            Section {
                NavigationLink(value: AppRoute.vpn(.lines)) {
                    VPNLinkRow(title: "Lines", detail: "The lines these identities are bound to", systemImage: "point.3.connected.trianglepath.dotted")
                }
                WebLinkRow(title: "Create, bind and cut over on web", path: .vpnUsers)
            } footer: {
                FreshnessFooter(state: store.users, interval: Polling.standard.interval(lowPower: false))
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await store.refreshUsers()
            offer(force: true)
        }
        .onScrollPhaseChange { _, phase in if phase != .idle { stable.noteActivity() } }
        .vpnDemoScroll(ready: !stable.shown.isEmpty)
    }

    @ViewBuilder
    private func emptyState(all: [VPNUser]) -> some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView {
                Label("No VPN identities", systemImage: "person.2")
            } description: {
                Text("Identities are created on the web, in the vpn-core Users page.")
            } actions: {
                Button("Open Users on web") { router.openOnWeb(.vpnUsers) }
            }
        }
    }

    private func detail(_ user: VPNUser, now: Date) -> String {
        var parts: [String] = []
        if !user.group.isEmpty { parts.append(user.group) }
        if user.source == .vpnCore {
            let lines = user.bindings.filter(\.enabled).count
            parts.append(lines == 1 ? "1 line" : "\(lines) lines")
        }
        if let badge = VPNStyle.linkBadge(VPNLinkWords.badge(user.link, now: now)) { parts.append(badge) }
        if case .later(let at) = VPNExpiry.of(user.expiresAt, now: now) {
            parts.append("expires \(TimeDisplay.relative(at, now: now, locale: .current))")
        }
        return parts.joined(separator: " · ")
    }

    private func usage(_ user: VPNUser) -> String? {
        guard let usage = user.usage else { return nil }
        return VPNBytes.text(usage.usedPeriodBytes)
    }

    private func row(_ user: VPNUser, now: Date) -> some View {
        let state = VPNIdentity.state(user, now: now)
        let style = VPNStyle.identity(user, now: now)
        let detail = detail(user, now: now)
        return NavigationLink(value: AppRoute.vpn(.user(id: user.id))) {
            StatusRow(style: style, title: VPNText.breakable(user.displayName), detail: detail,
                      reason: VPNIdentity.reason(user, state: state, now: now),
                      trailing: usage(user),
                      accessibilityPhrase: "\(user.displayName), \(style.word), \(detail)\(usage(user).map { ", \($0) this period" } ?? "")")
        }
        .contextMenu {
            Button("Open", systemImage: "person.text.rectangle") { router.push(.vpn(.user(id: user.id))) }
            Button("Copy link", systemImage: "link") { VPNCopy.copy(VPNCopy.userLink(user.id)) }
            Button("Copy ID", systemImage: "number") { VPNCopy.copy(user.id) }
            Button("Open on web", systemImage: "safari") { router.openOnWeb(.vpnUsers) }
            if user.link != nil {
                Divider()
                VPNGatedButton(title: "Reveal subscription link", systemImage: "eye", unavailable: network.isSatisfied ? store.revealLinkMissing : "No connection") {
                    Task { await runner.reveal(VPNIntents.revealLink(userID: user.id, email: user.displayName, origin: session.consoleURL)) }
                }
                VPNGatedButton(title: "Rotate link", systemImage: "arrow.triangle.2.circlepath",
                               unavailable: network.isSatisfied ? store.linkMissing : "No connection") {
                    Task { await runner.run(VPNIntents.rotateLink(userID: user.id, email: user.displayName, rotatedBefore: user.link?.rotatedAt,
                                                                   caveat: VPNLinkWords.rotateCaveat(user.link, now: Date()))) }
                }
            }
        } preview: {
            VPNUserGlance(user: user, now: now)
        }
        .accessibilityActions {
            Button("Copy link") { VPNCopy.copy(VPNCopy.userLink(user.id)) }
            Button("Copy ID") { VPNCopy.copy(user.id) }
            Button("Open on web") { router.openOnWeb(.vpnUsers) }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Lines", systemImage: "point.3.connected.trianglepath.dotted") { router.push(.vpn(.lines)) }
                Button("Users on web", systemImage: "safari") { router.openOnWeb(.vpnUsers) }
                    .accessibilityHint("Creating, binding and cutting over identities happen on the web")
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    private func refresh() {
        Task { await store.refreshUsers() }
    }
}

/// The context-menu glance of an identity: its row and a few facts.
private struct VPNUserGlance: View {
    let user: VPNUser
    let now: Date

    var body: some View {
        let state = VPNIdentity.state(user, now: now)
        VStack(alignment: .leading, spacing: Spacing.s) {
            StatusRow(style: VPNStyle.identity(user, now: now), title: user.displayName, reason: VPNIdentity.reason(user, state: state, now: now))
            if let usage = user.usage {
                Text("\(VPNBytes.text(usage.usedPeriodBytes)) this period").textRole(.rowDetail)
            }
            if user.quotaBytes > 0 {
                Text("Quota \(VPNBytes.text(user.quotaBytes))\(user.quotaPeriod == "monthly" ? " a month" : "")").textRole(.rowDetail)
            }
            Text(user.credentials.map(\.protocol).joined(separator: ", ")).textRole(.rowDetail)
        }
        .padding()
        .frame(width: 320, alignment: .leading)
    }
}
