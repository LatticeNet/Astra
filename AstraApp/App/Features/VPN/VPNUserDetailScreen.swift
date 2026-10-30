import SwiftUI

/// M13-02 VPN user: the identity's state, its subscription link (what a
/// fetch gets now, the lines it serves and leaves out, the last client that
/// fetched it), its bound lines, usage and fields. Actions: Reveal
/// subscription link (S, with Share), Reveal credentials (S), Rotate link
/// (T3), Revoke link (T4). Create, bind and cutover stay on the web.
/// Gate vpncore:read or proxy:read, unconfined; the link section needs
/// vpncore:admin or proxy:admin.
struct VPNUserDetailScreen: View {
    let id: String

    @Environment(VPNStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    @State private var model = VPNUserDetailModel()

    var body: some View {
        content
            .navigationTitle(model.user.value?.displayName ?? store.user(id: id)?.displayName ?? "VPN user")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(model.user.value.map { VPNStyle.identity($0, now: Date()).word } ?? "")
            .toolbar { toolbar }
            .polling(.standard, version: changes.version(.vpn)) {
                await model.refresh(id: id, session: session, store: store)
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.notFound {
            notFound
        } else if !network.isSatisfied, model.user.value == nil, !model.user.isLoading, store.readMissing == nil {
            VPNOfflineView(noun: "The identity", retry: refresh)
        } else {
            ResourceView(state: model.user, noun: "the identity", retry: refresh) { user in
                detail(user)
            }
        }
    }

    private func date(_ value: Date) -> (String, String) {
        (TimeDisplay.dateTime(value, mode: mode, locale: locale), TimeDisplay.relative(value, now: Date(), locale: locale))
    }

    private var offline: String? { network.isSatisfied ? nil : "No connection" }

    // MARK: Detail

    private func detail(_ user: VPNUser) -> some View {
        let now = Date()
        let state = VPNIdentity.state(user, now: now)
        let style = VPNStyle.identity(user, now: now)
        let others = VPNIdentity.conditions(user, now: now).dropFirst()
        return List {
            VPNRefreshError(state: model.user, noun: "the identity", retry: refresh)
            Section {
                StatusRow(style: style, title: VPNText.breakable(user.displayName), detail: [user.name, user.group].filter { !$0.isEmpty && $0 != user.displayName }.joined(separator: " · "),
                          reason: VPNIdentity.reason(user, state: state, now: now), reasonLineLimit: nil,
                          accessibilityPhrase: "\(user.displayName), \(style.word)")
                ForEach(Array(others), id: \.self) { condition in
                    let other = VPNStyle.identity(condition)
                    StatusRow(style: other, title: "Also \(other.word)", reason: VPNIdentity.reason(user, state: condition, now: now), reasonLineLimit: nil)
                }
                if user.source == .legacyProxyUser {
                    Label("A legacy proxy user: vpn-core is not active, so this identity has no lines or link here.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.statusWarnText)
                        .frame(minHeight: Spacing.minimumTarget)
                }
            }
            if user.source == .vpnCore {
                linkSections(user)
                boundLinesSection(user)
            }
            usageSection(user, now: now)
            identitySection(user)
            Section {
                VPNActionRow(title: "Reveal credentials", systemImage: "key",
                             note: store.hasRevealSession ? "Asks for your authenticator code, then shows them once" : "Needs a signed-in session and your code",
                             unavailable: offline ?? (user.source == .legacyProxyUser ? "No identity record to read" : store.credentialsMissing)) {
                    Task { await runner.reveal(VPNIntents.revealCredentials(userID: user.id, email: user.displayName)) }
                }
                WebLinkRow(title: "Edit, bind lines and cut over on web", path: .vpnUsers)
            } header: {
                Text("Credentials and changes").accessibilityAddTraits(.isHeader).id("actions")
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Credentials and the link are never sent to this iPhone until you reveal them, and they are not kept.")
                    FreshnessFooter(state: model.user, interval: Polling.standard.interval(lowPower: false))
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.refresh(id: id, session: session, store: store) }
        .vpnDemoScroll(ready: model.user.value != nil && !model.link.isLoading)
    }

    // MARK: Link

    @ViewBuilder
    private func linkSections(_ user: VPNUser) -> some View {
        switch model.link {
        case .denied(let scope):
            Section {
                ScopeDeniedRow(scope: scope)
            } header: {
                Text("Subscription link").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("What the link serves and its actions need vpncore:admin or proxy:admin on a token without a node allowlist.")
            }
        case .companionBehind(let surface):
            Section {
                CompanionBehindRow(surface: surface)
            } header: {
                Text("Subscription link").accessibilityAddTraits(.isHeader)
            }
        case .failed(let error, nil, _):
            Section {
                ErrorRow(message: "Could not load the subscription link: \(error.localizedDescription)", retry: refresh)
            } header: {
                Text("Subscription link").accessibilityAddTraits(.isHeader)
            }
        default:
            if let status = model.link.value {
                linkStatus(status, user: user)
            } else {
                Section {
                    LoadingRows(label: "Loading the subscription link", count: 2)
                } header: {
                    Text("Subscription link").accessibilityAddTraits(.isHeader)
                }
            }
        }
    }

    @ViewBuilder
    private func linkStatus(_ status: VPNLinkStatus, user: VPNUser) -> some View {
        let now = Date()
        let headline = VPNLinkHeadline.of(status) { TimeDisplay.dateTime($0, mode: mode, locale: locale) }
        let style = VPNStyle.link(headline)
        let noLink = status.issued ? nil : "No link issued"
        Section {
            VPNRefreshError(state: model.link, noun: "the subscription link", retry: refresh)
            StatusRow(style: style, title: "Subscription link", detail: status.link.map { VPNLinkWords.pathHint($0.slug) },
                      reason: headline.detail, reasonLineLimit: nil,
                      accessibilityPhrase: "Subscription link, \(style.word)")
                .id("link")
            if status.issued {
                let fetch = VPNLinkWords.fetch(status, now: now) { TimeDisplay.duration($0, locale: locale) }
                let late = !(fetch.healthy || fetch.freshness == .never)
                VPNGlyphLabel(title: fetch.text, titleColor: late ? Color.statusWarnText : Color.secondary,
                              systemImage: switch fetch.freshness {
                              case .never: "iphone.slash"
                              case .stale: "clock.badge.exclamationmark"
                              case .fresh: "iphone"
                              }, glyphColor: late ? Color.statusWarnFill : Color.statusQuiet)
                .frame(minHeight: Spacing.minimumTarget)
                let userinfo = VPNLinkWords.userinfo(status.subscriptionUserinfo, answer: status.answer) {
                    $0.formatted(Date.FormatStyle.dateTime.locale(locale).month(.abbreviated).day())
                }
                if !userinfo.isEmpty {
                    DetailRow(label: "Clients see", value: userinfo, copyable: false)
                }
                if let link = status.link {
                    DetailRow(label: "Clients refresh", value: link.updateIntervalHours == 1 ? "Every hour" : "Every \(link.updateIntervalHours) hours", copyable: false)
                    if let issued = link.issuedAt {
                        let (absolute, relative) = date(issued)
                        DetailRow(label: "Issued", value: absolute, secondary: relative, copyable: false)
                    }
                    if let rotated = link.rotatedAt {
                        let (absolute, relative) = date(rotated)
                        DetailRow(label: "Last rotated", value: absolute, secondary: relative, copyable: false)
                    }
                    if let expires = link.expiresAt {
                        let (absolute, relative) = date(expires)
                        DetailRow(label: expires <= now ? "Link expired" : "Link expires", value: absolute, secondary: relative, copyable: false)
                    }
                }
            }
            VPNActionRow(title: "Reveal subscription link", systemImage: "eye",
                         note: store.hasRevealSession ? "Asks for your authenticator code, then offers Share" : "Needs a signed-in session and your code",
                         unavailable: offline ?? noLink ?? store.revealLinkMissing) {
                Task { await runner.reveal(VPNIntents.revealLink(userID: user.id, email: user.displayName, origin: session.consoleURL)) }
            }
        } header: {
            Text("Subscription link").accessibilityAddTraits(.isHeader)
        } footer: {
            Text(status.issued
                 ? "The link is a credential for this identity's lines. Rotate it when it may have leaked."
                 : "Issue a link on the web; the phone can reveal, rotate and revoke it afterwards.")
        }
        if !status.included.isEmpty {
            Section {
                ForEach(status.included) { line in
                    linkLineRow(line, left: false)
                }
                .id("served")
            } header: {
                Text(VPNLinkWords.servedHeading(status)).accessibilityAddTraits(.isHeader)
            }
        }
        if !status.excluded.isEmpty {
            Section {
                ForEach(status.excluded) { line in
                    linkLineRow(line, left: true)
                }
                .id("leftout")
            } header: {
                Text(VPNLinkWords.leftOutHeading(status)).accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Plans that bring a line back are filed on the web and approved like any other.")
            }
        }
        Section {
            let caveat = VPNLinkWords.rotateCaveat(status.link, now: now)
            VPNActionRow(title: "Rotate subscription link", systemImage: "arrow.triangle.2.circlepath",
                         note: caveat.map { "The old link stops working at once. \($0)" } ?? "The old link stops working at once",
                         unavailable: offline ?? noLink ?? store.linkMissing) {
                Task { await runner.run(VPNIntents.rotateLink(userID: user.id, email: user.displayName, rotatedBefore: status.link?.rotatedAt, caveat: caveat)) }
            }
            .id("leak")
            VPNActionRow(title: "Revoke subscription link", systemImage: "trash", note: "The link stops answering and cannot be restored",
                         unavailable: offline ?? noLink ?? store.linkMissing, role: .destructive) {
                Task { await runner.run(VPNIntents.revokeLink(userID: user.id, email: user.displayName)) }
            }
        } header: {
            Text("Leak response").accessibilityAddTraits(.isHeader)
        }
    }

    private func linkLineRow(_ line: VPNLinkLine, left: Bool) -> some View {
        let title = VPNLinkWords.lineTitle(line)
        let style = left
            ? StatusStyle(word: "left out", symbol: "minus.circle", tone: .warn)
            : StatusStyle(word: "served", symbol: "checkmark.circle", tone: .ok)
        let reason = left ? ([VPNLinkWords.excludedReason(line)] + [VPNLinkWords.fix(line)].compactMap { $0 }).joined(separator: "; ") : nil
        return NavigationLink(value: AppRoute.vpn(.line(id: line.lineHashID))) {
            StatusRow(style: style, title: title, detail: line.protocol.isEmpty ? nil : line.protocol,
                      reason: reason.map { "\($0.prefix(1).uppercased())\($0.dropFirst())." }, reasonLineLimit: nil,
                      accessibilityPhrase: "\(title), \(style.word)")
        }
    }

    // MARK: Bound lines

    @ViewBuilder
    private func boundLinesSection(_ user: VPNUser) -> some View {
        Section {
            if user.bindings.isEmpty {
                Text("Bound to no line. Bind one on the web; until then this identity signs in nowhere Lattice manages.")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
            }
            ForEach(user.bindings, id: \.lineHashID) { binding in
                let entry = store.line(id: binding.lineHashID)
                let title = entry.map { "\($0.nodeName) / \($0.line.displayName)" } ?? binding.lineHashID
                let style = binding.enabled
                    ? entry.map { VPNStyle.line(VPNLineState.of($0.line)) } ?? StatusStyle(word: "on", symbol: "circle", tone: .quiet)
                    : StatusStyle(word: "binding off", symbol: "minus.circle", tone: .quiet)
                let credential = VPNBindingCredential.words(binding.credential)
                NavigationLink(value: AppRoute.vpn(.line(id: binding.lineHashID))) {
                    StatusRow(style: style, title: title,
                              detail: [entry.map { VPNLineFormat.shape($0.line) }, binding.flowOverride.isEmpty ? nil : "flow \(binding.flowOverride)"]
                                  .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                              reason: binding.credential == "stale" ? credential.map { "\($0.prefix(1).uppercased())\($0.dropFirst())." } : nil,
                              titleIsIdentifier: entry == nil,
                              accessibilityPhrase: "\(title), \(style.word)\(credential.map { ", \($0)" } ?? "")")
                }
            }
        } header: {
            Text(user.bindings.count == 1 ? "1 bound line" : "\(user.bindings.count) bound lines").accessibilityAddTraits(.isHeader).id("bound")
        }
    }

    // MARK: Usage

    @ViewBuilder
    private func usageSection(_ user: VPNUser, now: Date) -> some View {
        Section {
            if let usage = user.usage {
                let quota = VPNIdentity.quota(user)
                if quota.hasQuota {
                    ValueBarRow(label: user.quotaPeriod == "monthly" ? "This month" : "Used of quota",
                                value: "\(VPNBytes.text(quota.usedBytes)) of \(VPNBytes.text(quota.quotaBytes))",
                                fraction: quota.fraction, threshold: 0.8)
                } else {
                    DetailRow(label: "Used", value: VPNBytes.text(usage.usedPeriodBytes), secondary: "No quota", copyable: false)
                }
                if let start = usage.periodStart, let end = usage.periodEnd {
                    DetailRow(label: "Period", value: "\(TimeDisplay.dateTime(start, mode: mode, locale: locale)) to \(TimeDisplay.dateTime(end, mode: mode, locale: locale))",
                              secondary: "Resets \(TimeDisplay.relative(end, now: now, locale: locale))", copyable: false)
                }
                if !usage.last7d.isEmpty {
                    let total = usage.last7d.reduce(0, +)
                    DetailRow(label: "Last 7 days", value: VPNBytes.text(total),
                              secondary: total > 0 ? "Busiest day \(VPNBytes.text(usage.last7d.max() ?? 0))" : "No traffic counted", copyable: false)
                }
                if usage.usedTotalBytes > 0 || usage.usedTotalTruncated {
                    DetailRow(label: "Total kept", value: VPNBytes.text(usage.usedTotalBytes),
                              secondary: usage.usedTotalTruncated ? "Older traffic is no longer kept, so this is a floor" : usage.usedTotalFrom.map { "Since \(TimeDisplay.dateTime($0, mode: mode, locale: locale))" },
                              copyable: false)
                }
                if let seen = usage.lastSeenAt {
                    let (absolute, relative) = date(seen)
                    DetailRow(label: "Last seen", value: relative, secondary: absolute, copyable: false)
                } else {
                    DetailRow(label: "Last seen", value: "Never", copyable: false)
                }
                ForEach(usage.allocatedNodes, id: \.nodeID) { node in
                    allocationRow(node)
                }
            } else {
                Text("This server does not report usage per identity.")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
            }
        } header: {
            Text("Usage").accessibilityAddTraits(.isHeader).id("usage")
        } footer: {
            if let policy = user.policy, policy.quota?.evidence == "inferred" {
                Text("The quota is reached by inferred traffic, not proven counters; nothing acts on it without a person.")
            }
        }
    }

    private func allocationRow(_ node: VPNAllocatedNode) -> some View {
        let bytes = node.lines.reduce(Int64(0)) { $0 + $1.periodBytes }
        let lines = node.lines.map { line in
            line.tag.isEmpty ? line.allocation : "\(line.tag) (\(line.viaRelay ? "via relay" : line.allocation))"
        }.joined(separator: ", ")
        let collector = switch node.collectorState {
        case "ok", "": nil as String?
        case "stats_off": "counters are off on this node"
        case "no_collector": "no usage collector on this node"
        default: "the usage collector reports an error"
        }
        return StatusRow(style: StatusStyle(word: "", symbol: collector == nil ? "server.rack" : "exclamationmark.triangle", tone: collector == nil ? .quiet : .warn),
                         title: node.nodeName.isEmpty ? node.nodeID : node.nodeName, detail: lines,
                         reason: collector.map { "Usage may be missing: \($0)." }, trailing: VPNBytes.text(bytes),
                         accessibilityPhrase: "\(node.nodeName), \(lines)")
    }

    // MARK: Identity

    @ViewBuilder
    private func identitySection(_ user: VPNUser) -> some View {
        Section {
            DetailRow(label: "Email", value: user.email.isEmpty ? "None" : user.email)
                .id("identity")
            if !user.name.isEmpty { DetailRow(label: "Name", value: user.name) }
            if !user.group.isEmpty { DetailRow(label: "Group", value: user.group) }
            if !user.comment.isEmpty { DetailRow(label: "Comment", value: user.comment, copyable: false) }
            DetailRow(label: "Enabled", value: user.enabled ? "Yes" : "No", copyable: false)
            if let policy = user.policy {
                DetailRow(label: "Server policy", value: policy.status.replacingOccurrences(of: "_", with: " "),
                          secondary: policyNote(policy), copyable: false)
            }
            if let expires = user.expiresAt {
                let (absolute, relative) = date(expires)
                DetailRow(label: expires <= Date() ? "Expired" : "Expires", value: absolute, secondary: relative, copyable: false)
            } else {
                DetailRow(label: "Expires", value: "Never", copyable: false)
            }
            DetailRow(label: "Quota", value: quotaText(user), copyable: false)
            DetailRow(label: "Credentials", value: user.credentials.isEmpty ? "None" : user.credentials.map(credentialText).joined(separator: ", "), copyable: false)
            if let created = user.createdAt {
                let (absolute, relative) = date(created)
                DetailRow(label: "Created", value: absolute, secondary: relative, copyable: false)
            }
            if user.migrated { DetailRow(label: "Origin", value: "Migrated from a legacy proxy user", copyable: false) }
            DetailRow(label: "ID", value: user.id, monospaced: true)
        } header: {
            Text("Identity").accessibilityAddTraits(.isHeader)
        }
    }

    private func policyNote(_ policy: VPNPolicy) -> String? {
        guard !policy.reason.isEmpty else { return nil }
        var note = "Reason: \(policy.reason)"
        if !policy.suspendedBy.isEmpty { note += ", by \(policy.suspendedBy == "policy" ? "Lattice" : policy.suspendedBy)" }
        if let since = policy.suspendedSince { note += ", since \(TimeDisplay.dateTime(since, mode: mode, locale: locale))" }
        return note
    }

    private func quotaText(_ user: VPNUser) -> String {
        guard user.quotaBytes > 0 else { return "None" }
        if user.quotaPeriod == "monthly" {
            return "\(VPNBytes.text(user.quotaBytes)) a month\(user.quotaResetDay > 0 ? ", resets on day \(user.quotaResetDay)" : "")"
        }
        return "\(VPNBytes.text(user.quotaBytes)) in total"
    }

    private func credentialText(_ credential: VPNCredentialView) -> String {
        credential.hasSecret ? credential.protocol : "\(credential.protocol) (no secret yet)"
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Identity not found", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("vpn-core holds no identity \(id). It may have been deleted on the web.")
            } actions: {
                Button("All VPN users") { router.replaceTop(.vpn(.users)) }
                    .buttonStyle(.bordered)
                Button("Open on web") { router.openOnWeb(.vpnUsers) }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let user = model.user.value {
                    let noLink = (model.link.value?.issued ?? (user.link != nil)) ? nil : "No link issued"
                    if user.source == .vpnCore {
                        VPNGatedButton(title: "Reveal subscription link", systemImage: "eye", unavailable: offline ?? noLink ?? store.revealLinkMissing) {
                            Task { await runner.reveal(VPNIntents.revealLink(userID: user.id, email: user.displayName, origin: session.consoleURL)) }
                        }
                    }
                    VPNGatedButton(title: "Reveal credentials", systemImage: "key",
                                   unavailable: offline ?? (user.source == .legacyProxyUser ? "No identity record to read" : store.credentialsMissing)) {
                        Task { await runner.reveal(VPNIntents.revealCredentials(userID: user.id, email: user.displayName)) }
                    }
                    if user.source == .vpnCore {
                        VPNGatedButton(title: "Rotate link", systemImage: "arrow.triangle.2.circlepath", unavailable: offline ?? noLink ?? store.linkMissing) {
                            let link = model.link.value?.link ?? user.link
                            Task { await runner.run(VPNIntents.rotateLink(userID: user.id, email: user.displayName, rotatedBefore: link?.rotatedAt,
                                                                          caveat: VPNLinkWords.rotateCaveat(link, now: Date()))) }
                        }
                    }
                }
                Section {
                    Button("Copy link", systemImage: "link") { VPNCopy.copy(VPNCopy.userLink(id)) }
                    Button("Copy ID", systemImage: "number") { VPNCopy.copy(id) }
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.vpnUsers) }
                }
                if let user = model.user.value, user.source == .vpnCore {
                    let noLink = (model.link.value?.issued ?? (user.link != nil)) ? nil : "No link issued"
                    Section {
                        VPNGatedButton(title: "Revoke link", systemImage: "trash", unavailable: offline ?? noLink ?? store.linkMissing, role: .destructive) {
                            Task { await runner.run(VPNIntents.revokeLink(userID: user.id, email: user.displayName)) }
                        }
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    private func refresh() {
        Task { await model.refresh(id: id, session: session, store: store) }
    }
}

/// The identity and its link status, owned by the detail screen. The link
/// status is read only for a vpn-core identity and only with the scope its
/// endpoint needs, so a token without it sees the denied row, not an error.
@MainActor @Observable
final class VPNUserDetailModel {
    private(set) var user: ResourceState<VPNUser> = .idle
    private(set) var link: ResourceState<VPNLinkStatus> = .idle
    private(set) var notFound = false

    @discardableResult
    func refresh(id: String, session: SessionStore, store: VPNStore) async -> Bool {
        if let missing = store.readMissing {
            user = .denied(scope: missing)
            link = .idle
            return true
        }
        guard let client = session.client else { return false }
        if store.lines.value == nil { await store.refreshLines() }
        let before = user
        user = before.reloading
        let loaded: VPNUser
        do {
            if store.users.value?.source == .legacyProxyUser {
                loaded = try await legacyUser(id: id, store: store)
            } else {
                do {
                    loaded = try await client.vpnGetUser(id: id)
                } catch let error as LatticeAPIError where LatticeClient.vpnPluginUnavailable(error) {
                    loaded = try await legacyUser(id: id, store: store)
                }
            }
            notFound = false
            user = .loaded(loaded, at: Date())
        } catch {
            if VPNStore.isCancellation(error) {
                user = before
                return true
            }
            let apiError = LatticeAPIError(error)
            if LatticeClient.vpnUserGetAmbiguous(apiError) {
                // A fresh list read decides whether the id is gone; it also
                // drops a deleted identity from the users list.
                let listed = await store.refreshUsers()
                let listing: VPNUserListing? = if listed, case .loaded(let value, _) = store.users { value } else { nil }
                if LatticeClient.vpnUserMissing(apiError, listing: listing, id: id) {
                    notFound = true
                    user = .idle
                    link = .idle
                    return true
                }
            }
            if case .invalidResponse = apiError { session.markCompanionBehind(VPNStore.usersSurface) }
            if case .forbidden = apiError { session.noteForbidden() }
            user = user.failing(apiError, surface: "This identity", missingScope: store.readMissing ?? "proxy:read")
            return false
        }
        guard loaded.source == .vpnCore else {
            link = .idle
            return true
        }
        if let missing = store.linkMissing {
            link = .denied(scope: missing)
            return true
        }
        let beforeLink = link
        link = beforeLink.reloading
        do {
            link = .loaded(try await client.vpnLinkStatus(userID: id), at: Date())
            return true
        } catch {
            if VPNStore.isCancellation(error) {
                link = beforeLink
                return true
            }
            let apiError = LatticeAPIError(error)
            if case .invalidResponse = apiError { session.markCompanionBehind("Subscription link") }
            link = link.failing(apiError, surface: "The subscription link", missingScope: store.linkMissing ?? "vpncore:admin or proxy:admin")
            return false
        }
    }

    private func legacyUser(id: String, store: VPNStore) async throws -> VPNUser {
        await store.refreshUsers()
        if let user = store.user(id: id) { return user }
        if case .failed(let error, _, _) = store.users { throw error }
        throw LatticeAPIError.notFound
    }
}
