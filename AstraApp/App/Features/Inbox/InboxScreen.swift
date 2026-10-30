import SwiftUI
import UIKit

/// The Inbox filter (M1-01). It is All on every launch.
enum InboxFilter: String, CaseIterable, Hashable {
    case all, approvals, incidents, attention

    var title: String {
        switch self {
        case .all: "All"
        case .approvals: "Approvals"
        case .incidents: "Incidents"
        case .attention: "Attention"
        }
    }

    func shows(_ section: InboxFilter) -> Bool { self == .all || self == section }
}

/// M1-01 Inbox: the verdict line, then incidents, approvals that need a
/// person, attention and renewals, in the 2am order of section 2.2.
struct InboxScreen: View {
    /// Demo only: hold reorders as if VoiceOver were running, so the
    /// pending-updates row can be captured (section 5.0).
    static let holdUpdatesArgument = "AstraInboxHoldUpdates"
    /// Demo only: start filtered, for screenshots of the lower sections.
    static let filterArgument = "AstraInboxFilter"
    @MainActor private static var appliedLaunchFilter = false

    @Environment(InboxStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(Router.self) private var router
    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(NetworkMonitor.self) private var network
    @Environment(PowerMonitor.self) private var power
    @Environment(NodeDirectory.self) private var nodeDirectory
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @Environment(\.scrollToTopSignal) private var scrollToTop
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var filter: InboxFilter = .all
    @State private var snoozing: Incident?
    @State private var announcedHold = false

    private var interval: TimeInterval { Polling.inbox.interval(lowPower: power.isLowPower) }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if filter != .all {
                    Section {
                        FilterStateRow(text: "Showing \(filter.title.lowercased()) only.") { filter = .all }
                    }
                }
                verdictSection
                    .id("inbox.top")
                if store.heldChanges > 0 {
                    Section {
                        PendingUpdatesRow(count: store.heldChanges) { store.applyHeld() }
                    }
                }
                // At accessibility sizes the first incident or approval must be
                // on screen without scrolling (4.8), so the counts and the
                // trust rows follow the two most urgent sections.
                if filter == .all, !typeSize.isAccessibilitySize { statusRows }
                if filter.shows(.incidents) { incidentsSection }
                if filter.shows(.approvals) { needsYouSection }
                if filter == .all, typeSize.isAccessibilitySize {
                    countsSection
                    statusRows
                }
                if filter.shows(.attention) {
                    InboxAttentionSection(items: store.displayed.attention, denied: store.attentionDenied)
                    dueSection
                }
                if isQuietAndEmpty {
                    Section { InboxEmptyRow() }
                }
                footerSection
            }
            .listStyle(.insetGrouped)
            .onChange(of: scrollToTop) { withAnimation { proxy.scrollTo("inbox.top", anchor: .top) } }
        }
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(typeSize.isAccessibilitySize ? .inline : .automatic)
        .navigationSubtitle(filter == .all ? "" : filter.title)
        // Inner toolbar items render after outer ones, so the Settings group
        // goes inside the filter to stay rightmost (5.2: filter, then Settings).
        .tabRootToolbar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $filter) {
                        ForEach(InboxFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityValue(filter.title)
            }
        }
        .confirmationDialog(
            snoozing.map { "Snooze \($0.displayTitle)?" } ?? "",
            isPresented: snoozeBinding,
            titleVisibility: .visible,
            presenting: snoozing
        ) { incident in
            snoozeButtons(incident)
        } message: { _ in
            Text("No repeat alerts until the time you choose. Uses monitor:admin.")
        }
        .polling(.inbox, version: changes.version([.approvals, .incidents, .nodes, .tasks, .sshguard, .ddns, .upcoming, .machines, .audit])) {
            await store.refresh()
        }
        .refreshable { await store.refresh(force: true) }
        .onScrollPhaseChange { _, phase in
            if phase != .idle { store.lastInteraction = .now }
        }
        .onChange(of: store.heldChanges) { _, count in
            // Announced once per hold; focus stays where it is.
            if count > 0, !announcedHold {
                announcedHold = true
                AccessibilityNotification.Announcement(count == 1 ? "1 update. Show it from the top of the list." : "\(count) updates. Show them from the top of the list.").post()
            } else if count == 0 {
                announcedHold = false
            }
        }
        .task { await nodeDirectory.refreshIfOlder(than: 15) }
        .onChange(of: mode, initial: true) {
            store.timeZoneMode = mode
            store.locale = locale
            store.rebuild(force: true)
        }
        .onAppear {
            guard session.isDemo, !Self.appliedLaunchFilter else { return }
            Self.appliedLaunchFilter = true
            if let raw = UserDefaults.standard.string(forKey: Self.filterArgument), let launch = InboxFilter(rawValue: raw) { filter = launch }
            // `-AstraInboxOpen attention` opens M1-05, which has no deep link.
            if UserDefaults.standard.string(forKey: "AstraInboxOpen") == "attention" { router.push(.inbox(.allAttention)) }
        }
    }

    // MARK: Verdict

    private var verdictSection: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let verdict = verdict(now: context.date)
                VerdictView(verdict: typeSize.isAccessibilitySize ? Verdict(sentence: verdict.sentence, segments: []) : verdict) { segment in
                    open(segment)
                }
                // A sentence, not a hero: it stops growing at the first
                // accessibility size so the rows below stay in view.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
        }
    }

    /// The count buttons as full-width rows, at accessibility sizes.
    private var countsSection: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let segments = verdict(now: context.date).segments
            if !segments.isEmpty {
                Section {
                    ForEach(segments) { segment in
                        Button { open(segment) } label: {
                            HStack(spacing: Spacing.s) {
                                Text(segment.text).textRole(.count).foregroundStyle(.primary)
                                Spacer(minLength: Spacing.s)
                                Image(systemName: segment.target == .approvals || segment.target == .failedTasks ? AppTab.activity.symbol : AppTab.fleet.symbol)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: Spacing.minimumTarget)
                        }
                        .accessibilityHint(segment.target == .approvals || segment.target == .failedTasks ? "Opens in Activity" : "Opens in Fleet")
                    }
                } header: {
                    header("Counts")
                }
            }
        }
    }

    private func verdict(now: Date) -> Verdict {
        let snapshot = store.snapshot(now: now, interval: interval, offline: !network.isSatisfied, mode: mode, locale: locale)
        return VerdictBuilder.verdict(for: snapshot, now: now, mode: mode, locale: locale)
    }

    private func open(_ segment: VerdictSegment) {
        switch segment.target {
        case .nodes:
            router.select(tab: .fleet, scope: FleetScope.nodes.rawValue, query: segment.query)
        case .approvals:
            appState.approvalsView = .needs
            router.select(tab: .activity, scope: ActivityScope.approvals.rawValue)
        case .failedTasks:
            router.select(tab: .activity, scope: ActivityScope.tasks.rawValue, query: segment.query)
        case .upcoming:
            router.select(tab: .fleet, scope: FleetScope.machines.rawValue)
            router.push(.inventory(.upcoming))
        }
    }

    // MARK: Trust and control plane

    @ViewBuilder
    private var statusRows: some View {
        let trustWarns = store.trust?.warns == true
        let healthBad = store.healthError != nil || store.health.map { !$0.isOK } == true
        if trustWarns || healthBad {
            Section {
                if trustWarns, let trust = store.trust {
                    NavigationLink(value: AppRoute.inbox(.trust)) {
                        StatusRow(
                            style: StatusStyle(word: trust.allowUnsignedHostRisk ? "unsigned plugins allowed" : "unofficial plugins", symbol: "puzzlepiece.extension", tone: trust.allowUnsignedHostRisk ? .fail : .warn),
                            title: "Plugin trust",
                            detail: trust.publishers.isEmpty ? nil : trust.publishers.joined(separator: ", "),
                            accessibilityPhrase: "Plugin trust, \(trust.allowUnsignedHostRisk ? "unsigned plugins allowed" : "unofficial plugins installed")"
                        )
                    }
                }
                if healthBad {
                    InboxControlPlaneRow(health: store.health, error: store.healthError, canOpenSystem: store.scopes?.allows("*") == true)
                }
            }
        }
    }

    // MARK: Incidents

    @ViewBuilder
    private var incidentsSection: some View {
        let rows = store.displayed.incidents
        switch store.incidents {
        case .denied(let scope):
            Section { ScopeDeniedRow(scope: scope) } header: { header("Incidents") }
        case .companionBehind(let surface):
            Section { CompanionBehindRow(surface: surface) } header: { header("Incidents") }
        case .idle, .loading(nil, _):
            Section { placeholder("incidents") } header: { header("Incidents") }
        default:
            if !rows.isEmpty || failure(store.incidents) != nil {
                Section {
                    if let failure = InboxSectionStatus(store.incidents, noun: "incidents").failureSentence {
                        ErrorRow(message: failure) { Task { await store.refresh(force: true) } }
                    }
                    ForEach(rows) { incident in
                        incidentRow(incident)
                    }
                } header: {
                    header("Incidents", count: rows.count)
                }
            }
        }
    }

    private func incidentRow(_ incident: Incident) -> some View {
        let canAdmin = store.missing(ScopeRequirement("monitor:admin")) == nil
        return NavigationLink(value: AppRoute.monitoring(.incident(id: incident.id))) {
            IncidentRow(incident: incident, canAdmin: canAdmin) { snoozing = $0 }
        }
        .contextMenu {
            InboxIncidentMenu(incident: incident, canAdmin: canAdmin, snooze: { snoozing = incident })
        } preview: {
            InboxIncidentPreview(incident: incident)
                .environment(\.timeZoneMode, mode)
        }
    }

    private var snoozeBinding: Binding<Bool> {
        Binding(
            get: { snoozing != nil },
            set: { shown in
                store.interactionInProgress = shown
                if !shown {
                    snoozing = nil
                    store.lastInteraction = .now
                }
            }
        )
    }

    @ViewBuilder
    private func snoozeButtons(_ incident: Incident) -> some View {
        let now = Date()
        ForEach(IncidentSnoozeChoice.choices(now: now, mode: mode, locale: locale)) { choice in
            Button(choice.label) {
                Task { await runner.run(IncidentRow.snoozeIntent(incident, minutes: choice.minutes, until: choice.until)) }
            }
        }
        if IncidentFilter.isSnoozed(incident, now: now) {
            Button("End snooze") {
                Task { await runner.run(IncidentRow.snoozeIntent(incident, minutes: 0, until: "")) }
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    @Environment(ActionRunner.self) private var runner

    // MARK: Needs you

    @ViewBuilder
    private var needsYouSection: some View {
        let events = store.displayed.events
        switch store.approvals {
        case .denied(let scope):
            Section { ScopeDeniedRow(scope: scope) } header: { header("Needs you") }
        case .companionBehind(let surface):
            Section { CompanionBehindRow(surface: surface) } header: { header("Needs you") }
        case .idle, .loading(nil, _):
            Section { placeholder("approvals") } header: { header("Needs you") }
        default:
            if !events.isEmpty || failure(store.approvals) != nil || !store.hiddenPlugins.isEmpty {
                Section {
                    if let failure = InboxSectionStatus(store.approvals, noun: "approvals").failureSentence {
                        ErrorRow(message: failure) { Task { await store.refresh(force: true) } }
                    }
                    ForEach(events) { event in
                        InboxEventRow(event: event, nodeName: { nodeDirectory.name(for: $0) })
                    }
                } header: {
                    header("Needs you", count: events.reduce(0) { $0 + $1.approvals.count })
                } footer: {
                    needsYouFooter
                }
            }
        }
    }

    @ViewBuilder
    private var needsYouFooter: some View {
        let hidden = store.hiddenPlugins
        let page = store.approvals.value
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if !hidden.isEmpty {
                Label {
                    Text(AccessState.partial(plugins: hidden.joined(separator: ", ")).text)
                } icon: {
                    Image(systemName: "eye.slash")
                }
            }
            if let page, page.total > page.approvals.count, page.approvals.count >= page.limit {
                Text("Showing \(page.approvals.count) of \(page.total)")
            }
        }
        .textRole(.footnote)
    }

    // MARK: Attention and due soon

    @ViewBuilder
    private var dueSection: some View {
        switch store.expiring {
        case .loaded, .loading(.some, _), .failed(_, .some, _):
            let due = store.displayed.due
            if !due.isEmpty {
                Section {
                    ForEach(due) { item in
                        InboxDueRow(item: item)
                    }
                    Button {
                        router.select(tab: .fleet, scope: FleetScope.machines.rawValue)
                        router.push(.inventory(.upcoming))
                    } label: {
                        HStack {
                            Text("All upcoming").foregroundStyle(Color.accentText)
                            Spacer()
                            Image(systemName: AppTab.fleet.symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                        .frame(minHeight: Spacing.minimumTarget)
                    }
                    .accessibilityHint("Opens in Fleet")
                } header: {
                    header("Due soon")
                }
            }
        default:
            EmptyView()
        }
    }

    // MARK: Footer

    private var footerSection: some View {
        Section {
            EmptyView()
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                // Before anything has loaded the footer says "Updating", not
                // "Stale. As of never".
                FreshnessFooter(loadedAt: store.oldestLoadedAt, isUpdating: store.isRefreshing || (store.oldestLoadedAt == nil && !store.anyFailed), lastAttemptFailed: store.anyFailed, interval: interval)
                if let source = store.badgeSourceAt ?? appState.badgeSourceAt, let badge = store.badge {
                    Text("Badge \(badge) from \(TimeDisplay.clock(source, mode: mode, locale: locale))")
                        .textRole(.stamp)
                }
                if let delivery = store.newestDelivery, let line = deliveryLine(delivery) {
                    line
                }
            }
        }
    }

    private func deliveryLine(_ delivery: NotifyDelivery) -> Text? {
        guard let at = delivery.settledAt ?? delivery.createdAt else { return nil }
        let channel = delivery.channelName.isEmpty ? delivery.channelKind : delivery.channelName
        let time = TimeDisplay.clock(at, mode: mode, locale: locale)
        if delivery.outcome == "sent" || delivery.outcome == "delivered" {
            return Text("Notified via \(channel) at \(time)").font(TextRole.stamp.font).foregroundStyle(.secondary)
        }
        if delivery.outcome == "failed" || delivery.outcome == "dead" {
            return Text("Notification failed via \(channel) at \(time)").font(TextRole.stamp.font).foregroundStyle(Color.statusFailText)
        }
        return nil
    }

    // MARK: Helpers

    /// Placeholders while a first load runs; offline, a plain statement
    /// that nothing has loaded, never an endless placeholder.
    @ViewBuilder
    private func placeholder(_ noun: String) -> some View {
        if network.isSatisfied {
            LoadingRows(label: "Loading \(noun)", count: 2)
        } else {
            Label {
                Text("No connection. No \(noun) have loaded yet.")
                    .foregroundStyle(Color.statusWarnText)
            } icon: {
                Image(systemName: "wifi.slash").foregroundStyle(Color.statusWarnFill)
            }
            .frame(minHeight: Spacing.minimumTarget)
        }
    }

    private var isQuietAndEmpty: Bool {
        filter == .all && store.displayed.isEmpty && store.approvals.value != nil && store.incidents.value != nil && !store.anyFailed
    }

    private func failure<Value>(_ state: ResourceState<Value>) -> String? {
        if case .failed(let error, _, _) = state { return error.localizedDescription }
        return nil
    }

    private func header(_ title: String, count: Int? = nil) -> some View {
        HStack {
            Text(title)
            if let count, count > 0 {
                Spacer()
                Text("\(count)").monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension InboxStore {
    /// "sshguard:read and network:plan": every scope a requirement lacks.
    func missingSentence(_ requirement: ScopeRequirement) -> String {
        let missing = scopes?.missing(requirement) ?? []
        return missing.isEmpty ? requirement.summary : VerdictBuilder.listed(missing)
    }
}

// MARK: Rows

/// A group of one renders the shared approval row; a group of several
/// renders one row that opens BatchReview. There is no swipe to approve.
struct InboxEventRow: View {
    let event: ApprovalEvents.Event
    let nodeName: (String) -> String
    @Environment(Router.self) private var router

    var body: some View {
        if event.approvals.count == 1, let approval = event.approvals.first {
            Button { router.present(.review(.single(approval.id))) } label: {
                ApprovalRow(approval: approval, nodeName: approval.nodeID.isEmpty ? nil : nodeName(approval.nodeID))
            }
            .tint(.primary)
            .accessibilityHint("Opens the review")
            .contextMenu { InboxApprovalMenu(approval: approval) }
        } else {
            Button {
                router.present(.review(.batch(groupKey: event.key, ids: event.approvals.map(\.id))))
            } label: {
                InboxGroupRow(event: event, nodeName: nodeName)
            }
            .tint(.primary)
            .accessibilityHint("Opens one review for every plan in this group")
        }
    }
}

/// "Agent update to 0.3.10 on 3 nodes", with the nodes it covers.
struct InboxGroupRow: View {
    let event: ApprovalEvents.Event
    var nodeName: (String) -> String = { $0 }
    @Environment(\.locale) private var locale

    var body: some View {
        let names = InboxGroupRow.names(event, nodeName: nodeName)
        let nodes = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " +\(names.count - 3) more" : "")
        let age = event.newestCreatedAt.map { RelativeDateFormatter.string(from: $0) }
        let style = StatusStyle.approval(.needsYou)
        StatusRow(
            style: style,
            title: ApprovalEvents.summary(event),
            detail: [nodes, age].compactMap { $0 }.joined(separator: ", "),
            reason: nil,
            accessibilityPhrase: "Needs you, \(ApprovalEvents.summary(event)), \(nodes)" + (event.newestCreatedAt.map { ", filed \(TimeDisplay.duration(Date().timeIntervalSince($0), locale: locale)) ago" } ?? "")
        )
    }
}

extension InboxGroupRow {
    /// Distinct node names of a group, in its order: the plan's node name
    /// for agent updates, the directory's name otherwise.
    static func names(_ event: ApprovalEvents.Event, nodeName: (String) -> String) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for approval in event.approvals {
            let key = approval.nodeID.isEmpty ? "global" : approval.nodeID
            guard seen.insert(key).inserted else { continue }
            if approval.plugin == "agentupdate", let name = ApprovalEvents.parseAgentUpdatePlan(approval.plan).nodeName {
                names.append(name)
            } else {
                names.append(approval.nodeID.isEmpty ? "global" : nodeName(approval.nodeID))
            }
        }
        return names
    }
}

/// The empty Inbox under a quiet verdict.
struct InboxEmptyRow: View {
    var body: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.statusOKFill)
                .accessibilityHidden(true)
            Text("Nothing needs you").font(.headline)
            Text("No open incidents, approvals or attention items.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
        .accessibilityElement(children: .combine)
    }
}

/// A renewal or expiry in the next week.
struct InboxDueRow: View {
    let item: ExpiringItem
    @Environment(Router.self) private var router

    var body: some View {
        let style = item.days < 0
            ? StatusStyle(word: "overdue", symbol: "calendar.badge.exclamationmark", tone: .fail)
            : StatusStyle(word: InboxAttentionItem.kindWord(item.kind), symbol: "calendar", tone: .quiet)
        let when = item.dueAt.map { RelativeDateFormatter.string(from: $0) }
        let row = StatusRow(
            style: style,
            title: item.title,
            detail: item.subtitle.inboxNonEmpty,
            trailing: when,
            accessibilityPhrase: "\(item.title), \(style.word)" + (when.map { ", \($0)" } ?? "")
        )
        switch InboxAttentionItem.target(for: item) {
        case .route(let route):
            NavigationLink(value: route) { row }
        default:
            Button {
                router.select(tab: .fleet, scope: FleetScope.machines.rawValue)
                router.push(.inventory(.upcoming))
            } label: { row }
            .tint(.primary)
            .accessibilityHint("Opens in Fleet")
        }
    }
}

/// The control-plane row: shown only when `/api/health` is not ok, and it
/// expands inline to what the health endpoint said.
struct InboxControlPlaneRow: View {
    let health: ServerHealth?
    let error: LatticeAPIError?
    let canOpenSystem: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            DetailRow(label: "Health", value: health?.status ?? "no answer", copyable: false)
            if let error {
                Text(error.localizedDescription).textRole(.rowReason(Color.statusFailText))
            }
            if canOpenSystem {
                NavigationLink("Open System", value: AppRoute.platform(.system))
            }
        } label: {
            StatusRow(
                style: StatusStyle(word: health?.status ?? "not answering", symbol: "server.rack", tone: error == nil ? .warn : .fail),
                title: "Control plane",
                accessibilityPhrase: "Control plane, \(health?.status ?? "not answering")"
            )
        }
    }
}

/// Context menu items for an incident row (section 4.5).
struct InboxIncidentMenu: View {
    let incident: Incident
    let canAdmin: Bool
    let snooze: () -> Void
    @Environment(Router.self) private var router
    @Environment(ActionRunner.self) private var runner

    var body: some View {
        let actions = IncidentActions.of(incident, now: .now, canAdmin: canAdmin)
        Button("Open", systemImage: "arrow.right.circle") { router.push(.monitoring(.incident(id: incident.id))) }
        Section {
            if incident.state == "acknowledged" {
                Button("Unacknowledge", systemImage: "person.crop.circle.badge.xmark") {
                    Task { await runner.run(IncidentRow.unacknowledgeIntent(incident)) }
                }
                .disabled(!canAdmin)
            } else {
                Button { Task { await runner.run(IncidentRow.acknowledgeIntent(incident)) } } label: {
                    Label("Acknowledge", systemImage: "person.crop.circle.badge.checkmark")
                    if !canAdmin { Text("Needs monitor:admin") }
                }
                .disabled(!actions.acknowledge)
            }
            Button(action: snooze) {
                Label("Snooze", systemImage: "moon.zzz")
                if !canAdmin { Text("Needs monitor:admin") }
            }
            .disabled(!actions.snooze)
            Button("Start maintenance", systemImage: "wrench.and.screwdriver") {
                router.present(.maintenanceStart(nodeID: incident.nodeID.inboxNonEmpty))
            }
        }
        Section {
            if !incident.nodeID.isEmpty {
                Button("Open node", systemImage: AppTab.fleet.symbol) {
                    router.select(tab: .fleet)
                    router.push(.fleet(.node(id: incident.nodeID)))
                }
            }
            if incident.kind.hasPrefix("path."), !incident.monitorID.isEmpty {
                Button("Open path", systemImage: "point.3.connected.trianglepath.dotted") {
                    let key = encodePathKey(.check(source: incident.nodeID, monitorID: incident.monitorID))
                    router.select(tab: .monitor)
                    router.push(.monitoring(.path(key: key)))
                }
            } else if !incident.monitorID.isEmpty {
                Button("Open check", systemImage: AppTab.monitor.symbol) {
                    router.select(tab: .monitor)
                    router.push(.monitoring(.check(id: incident.monitorID)))
                }
            }
        }
        Section {
            Button("Copy link", systemImage: "link") {
                UIPasteboard.general.string = LatticeDeepLink.incident(id: incident.id).customURL?.absoluteString
            }
            Button("Copy ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = incident.id }
            Button("Open on web", systemImage: "safari") {
                router.openOnWeb(.incident(id: incident.id, query: incident.subject.isEmpty ? incident.nodeName : incident.subject))
            }
        }
    }
}

/// The glance preview above an incident's context menu.
struct InboxIncidentPreview: View {
    let incident: Incident
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        let style = StatusStyle.incident(incident.displayState(now: .now))
        VStack(alignment: .leading, spacing: Spacing.s) {
            StatusRow(style: style, title: incident.displayTitle, detail: incident.nodeName.inboxNonEmpty)
            if !incident.detail.isEmpty {
                Text(incident.detail).font(.subheadline).foregroundStyle(.secondary)
            }
            if let since = incident.since ?? incident.openedAt {
                Text("Since \(TimeDisplay.dateTime(since, mode: mode, locale: locale))").textRole(.stamp)
            }
        }
        .padding(Spacing.l)
        .frame(width: 320, alignment: .leading)
    }
}

/// Context menu items for an approval row (section 4.5).
struct InboxApprovalMenu: View {
    let approval: Approval
    @Environment(Router.self) private var router

    var body: some View {
        Button("Review", systemImage: "checkmark.seal") { router.present(.review(.single(approval.id))) }
        Section {
            Button("Copy link", systemImage: "link") {
                UIPasteboard.general.string = LatticeDeepLink.approval(id: approval.id).customURL?.absoluteString
            }
            Button("Copy ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = approval.id }
            Button("Copy plan hash", systemImage: "seal") { UIPasteboard.general.string = approval.planSHA256 }
            Button("Open on web", systemImage: "safari") { router.openOnWeb(.approval(id: approval.id)) }
        }
    }
}
