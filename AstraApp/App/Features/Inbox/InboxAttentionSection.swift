import SwiftUI

/// One row of the Attention section (M1-01, item 5): something that needs a
/// look and is not already an incident or an approval to decide.
struct InboxAttentionItem: Identifiable, Hashable {
    enum Target: Hashable {
        case route(AppRoute)
        /// A scoped tab root. A layer forces the Audit view and a query
        /// replaces whatever search was left there.
        case select(AppTab, scope: String?, query: String?, auditLayer: AuditLayer? = nil)
        case review(String)
        /// Fleet > Machines > Upcoming.
        case upcoming
    }

    let id: String
    let style: StatusStyle
    let title: String
    var detail: String?
    var reason: String?
    /// A running revert timer shows a countdown to this time.
    var deadline: Date?
    var trailing: String?
    let target: Target
    let phrase: String

    /// Builds the rows from the loaded sections, most urgent first: SSH
    /// Guard reverts, nodes down without an incident, failed and stalled
    /// tasks, blocked applies, DDNS, renewals in three days, recent changes.
    @MainActor
    static func items(store: InboxStore, now: Date, mode: TimeZoneMode = .local, locale: Locale = .current) -> [InboxAttentionItem] {
        var items: [InboxAttentionItem] = []
        let names = Dictionary((store.nodes.value ?? []).map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })

        for status in SSHGuardBoard.revertingNodes(store.sshGuard.value ?? [], now: now) {
            let name = status.nodeName.isEmpty ? status.nodeID : status.nodeName
            let deadline = SSHGuardBoard.revertDeadline(status)
            let clock = deadline.map { TimeDisplay.clock($0, mode: mode, locale: locale) }
            let style = StatusStyle.coverage(.reverting(deadline: deadline), deadline: clock)
            let target: Target = status.actionableApprovalID.isEmpty ? .route(.sshGuard(.node(id: status.nodeID))) : .review(status.actionableApprovalID)
            items.append(InboxAttentionItem(
                id: "sshguard:\(status.nodeID)", style: style, title: "SSH Guard on \(name)",
                detail: deadline == nil ? "reverts unless confirmed" : nil, deadline: deadline, target: target,
                phrase: "SSH Guard on \(name), \(style.word), reverts unless confirmed"
            ))
        }

        let covered = Set((store.incidents.value?.incidents ?? []).filter(IncidentFilter.isActive).map(\.nodeID))
        for node in store.nodes.value ?? [] where !covered.contains(node.id) {
            let honesty = node.honesty
            guard honesty == .offline || honesty == .degraded else { continue }
            let style = StatusStyle.node(honesty)
            let since = node.statusSince ?? node.lastSeen
            let age = since.map { RelativeDateFormatter.shortDuration(now.timeIntervalSince($0)) }
            let reasonText = TimeDisplay.localizingStamps(in: node.statusReason, mode: mode, locale: locale)
            let detail = honesty == .offline ? age.map { "last reported \($0) ago" } : reasonText.inboxNonEmpty
            items.append(InboxAttentionItem(
                id: "node:\(node.id)", style: style, title: node.displayName, detail: detail,
                reason: honesty == .degraded ? nil : reasonText.inboxNonEmpty,
                target: .route(.fleet(.node(id: node.id))),
                phrase: honesty == .offline ? "\(node.displayName), offline" + (age.map { " for \($0)" } ?? "") : "\(node.displayName), degraded, \(reasonText)"
            ))
        }

        for task in store.tasks.value ?? [] {
            let state = task.runState(now: now)
            guard state == .failed || state == .stalled else { continue }
            let style = StatusStyle.task(state)
            let when = (task.finishedAt ?? task.startedAt ?? task.createdAt).map { RelativeDateFormatter.string(from: $0, now: now) }
            let reason = state == .stalled ? task.stalledReason.inboxNonEmpty : nil
            items.append(InboxAttentionItem(
                id: "task:\(task.id)", style: style, title: "Task \(task.id)",
                detail: [task.targets.count == 1 ? "1 node" : "\(task.targets.count) nodes", when].compactMap { $0 }.joined(separator: ", "),
                reason: reason, target: .route(.activity(.task(id: task.id))),
                phrase: "Task \(task.id), \(style.word)"
            ))
        }

        for approval in store.stuck.value ?? [] {
            let style = StatusStyle.approval(.waiting)
            let title = ApprovalEvents.title(for: approval)
            let node = approval.waiting?.nodeName.inboxNonEmpty ?? names[approval.nodeID] ?? ApprovalEvents.nodeLabel(approval)
            items.append(InboxAttentionItem(
                id: "stuck:\(approval.id)", style: style, title: title, detail: "approved, on \(node)",
                reason: approval.waiting?.reason.inboxNonEmpty, target: .review(approval.id),
                phrase: "Approved, waiting: \(approval.waiting?.reason ?? title)"
            ))
        }

        for profile in store.ddns.value ?? [] {
            let health = profile.health(now: now)
            guard health != .current else { continue }
            let style = health == .failing
                ? StatusStyle(word: "failing", symbol: "xmark.circle.fill", tone: .fail)
                : StatusStyle(word: "stale", symbol: "clock.badge.exclamationmark", tone: .warn)
            let lastRun = profile.lastRunAt.map { "last run \(RelativeDateFormatter.string(from: $0, now: now))" }
            items.append(InboxAttentionItem(
                id: "ddns:\(profile.id)", style: style, title: "DDNS \(profile.name)",
                detail: lastRun ?? profile.domains.first, reason: health == .failing ? profile.lastError.inboxNonEmpty : nil,
                target: .route(.networking(.ddnsProfile(id: profile.id))),
                phrase: "DDNS \(profile.name), \(style.word)"
            ))
        }

        for item in store.dueSoon where item.days <= 3 {
            let overdue = item.days < 0
            let style = overdue
                ? StatusStyle(word: "overdue", symbol: "calendar.badge.exclamationmark", tone: .fail)
                : StatusStyle(word: "due", symbol: "calendar.badge.clock", tone: .warn)
            let when = item.dueAt.map { RelativeDateFormatter.string(from: $0, now: now) }
            items.append(InboxAttentionItem(
                id: "due:\(item.id)", style: style, title: item.title,
                detail: [InboxAttentionItem.kindWord(item.kind), when].compactMap { $0 }.joined(separator: ", "),
                target: InboxAttentionItem.target(for: item),
                phrase: "\(item.title), \(InboxAttentionItem.kindWord(item.kind)), \(style.word)" + (when.map { ", \($0)" } ?? "")
            ))
        }

        if case .loaded(let count, _) = store.recentChanges, count > 0 {
            items.append(InboxAttentionItem(
                id: "audit:recent", style: StatusStyle(word: "", symbol: "list.bullet.rectangle", tone: .quiet),
                title: "Recent changes", detail: count == 1 ? "1 change in the last hour" : "\(count) changes in the last hour",
                target: .select(.activity, scope: ActivityScope.audit.rawValue, query: "", auditLayer: .changes),
                phrase: "Recent changes, \(count) in the last hour"
            ))
        }
        return items
    }

    static func kindWord(_ kind: String) -> String {
        switch kind {
        case "machine_renewal": "renewal"
        case "vpn_user": "VPN user expires"
        case "tls_certificate": "certificate expires"
        case "share": "share expires"
        default: kind.replacingOccurrences(of: "_", with: " ")
        }
    }

    static func target(for item: ExpiringItem) -> Target {
        item.kind == "machine_renewal" ? .route(.inventory(.machine(id: item.objectID))) : .upcoming
    }
}

extension String {
    /// Nil for an empty string, so optional chains skip it.
    var inboxNonEmpty: String? { isEmpty ? nil : self }
}

/// The Attention section of Inbox (M1-01, item 5). More than six rows show
/// "Show all", which pushes the full list.
struct InboxAttentionSection: View {
    let items: [InboxAttentionItem]
    /// Rows the token cannot read, named so the section never looks healthy by omission.
    var denied: [String] = []
    var limit = 6

    var body: some View {
        if !items.isEmpty || !denied.isEmpty {
            Section {
                ForEach(items.prefix(limit)) { item in
                    InboxAttentionRow(item: item)
                }
                if items.count > limit {
                    NavigationLink(value: AppRoute.inbox(.allAttention)) {
                        Text("Show all \(items.count)")
                            .foregroundStyle(Color.accentText)
                            .frame(minHeight: Spacing.minimumTarget)
                    }
                }
                ForEach(denied, id: \.self) { scope in
                    ScopeDeniedRow(scope: scope)
                }
            } header: {
                Text("Attention").accessibilityAddTraits(.isHeader)
            }
        }
    }
}

/// One attention row: pushes, selects a tab or opens Review.
struct InboxAttentionRow: View {
    let item: InboxAttentionItem
    @Environment(Router.self) private var router

    var body: some View {
        switch item.target {
        case .route(let route):
            NavigationLink(value: route) { content }
        case .select(let tab, let scope, let query, let auditLayer):
            Button { router.select(tab: tab, scope: scope, query: query, auditLayer: auditLayer) } label: {
                HStack(spacing: Spacing.s) {
                    content
                    Image(systemName: tab.symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            .tint(.primary)
            .accessibilityHint("Opens in \(tab.title)")
        case .review(let id):
            Button { router.present(.review(.single(id))) } label: { content }
                .tint(.primary)
                .accessibilityHint("Opens the review")
        case .upcoming:
            Button {
                router.select(tab: .fleet, scope: FleetScope.machines.rawValue)
                router.push(.inventory(.upcoming))
            } label: {
                HStack(spacing: Spacing.s) {
                    content
                    Image(systemName: AppTab.fleet.symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            .tint(.primary)
            .accessibilityHint("Opens in Fleet")
        }
    }

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var glyphWidth: CGFloat = 28

    private var content: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            StatusRow(
                style: item.style,
                title: item.title,
                detail: item.detail,
                reason: item.reason,
                trailing: item.trailing,
                accessibilityPhrase: item.phrase
            )
            if let deadline = item.deadline, deadline > .now {
                // A live countdown to the automatic revert, never a pulse.
                HStack(spacing: Spacing.xs) {
                    Text("Reverts in")
                    Text(timerInterval: Date.now...deadline, countsDown: true)
                        .monospacedDigit()
                }
                .font(TextRole.rowReason(Color.statusWarnText).font.weight(.semibold))
                .foregroundStyle(Color.statusWarnText)
                .padding(.leading, typeSize.isAccessibilitySize ? 0 : glyphWidth + Spacing.m)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
