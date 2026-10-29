import Foundation
import UIKit
import UserNotifications

/// The pending approvals Inbox reads: one page of human-pending rows (with
/// agent-update plan text only, for grouping) and the server's total.
struct InboxApprovalsPage: Sendable {
    var approvals: [Approval]
    var total: Int
    var limit: Int
}

/// What the Inbox shows, in display order. The stable-list rule (section
/// 5.0) compares two of these and holds reorders while the list is busy.
struct InboxContent: Equatable {
    var incidents: [Incident] = []
    var events: [ApprovalEvents.Event] = []
    var attention: [InboxAttentionItem] = []
    var due: [ExpiringItem] = []

    var isEmpty: Bool { incidents.isEmpty && events.isEmpty && attention.isEmpty && due.isEmpty }

    /// The row identities, in order, per section.
    var shape: [[String]] {
        [incidents.map(\.id), events.map(\.key), attention.map(\.id), due.map(\.id)]
    }

    /// How many rows were inserted, removed or moved between two contents.
    static func changes(from old: InboxContent, to new: InboxContent) -> Int {
        zip(old.shape, new.shape).reduce(0) { total, pair in
            let (before, after) = pair
            let removed = Set(before).subtracting(after).count
            let inserted = Set(after).subtracting(before).count
            let kept = before.filter(Set(after).contains)
            let keptAfter = after.filter(Set(before).contains)
            let moved = zip(kept, keptAfter).filter { $0 != $1 }.count
            return total + removed + inserted + moved
        }
    }

    /// The old order with each row's newest values: values inside existing
    /// rows apply at once, structure waits.
    static func refreshingValues(of old: InboxContent, from new: InboxContent) -> InboxContent {
        func merge<T>(_ before: [T], _ after: [T], id: (T) -> String) -> [T] {
            let latest = Dictionary(after.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
            return before.map { latest[id($0)] ?? $0 }
        }
        return InboxContent(
            incidents: merge(old.incidents, new.incidents, id: \.id),
            events: merge(old.events, new.events, id: \.key),
            attention: merge(old.attention, new.attention, id: \.id),
            due: merge(old.due, new.due, id: \.id)
        )
    }
}

/// Inbox data (M1-01): every section's resource, the verdict snapshot, the
/// badge and the stable-list hold. Each section loads on its own, so one
/// failure leaves the others on screen.
@MainActor @Observable
final class InboxStore {
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog

    private(set) var approvals: ResourceState<InboxApprovalsPage> = .idle
    private(set) var incidents: ResourceState<IncidentListResponse> = .idle
    private(set) var newestResolvedAt: Date?
    private(set) var nodes: ResourceState<[LatticeNode]> = .idle
    private(set) var tasks: ResourceState<[LatticeTask]> = .idle
    private(set) var taskCounts: TaskCounts?
    private(set) var expiring: ResourceState<ExpiringResponse> = .idle
    private(set) var sshGuard: ResourceState<[SSHGuardNodeStatus]> = .idle
    private(set) var ddns: ResourceState<[DDNSProfile]> = .idle
    /// Approved plans whose apply is blocked (the console's Stuck).
    private(set) var stuck: ResourceState<[Approval]> = .idle
    /// Audit changes in the last hour.
    private(set) var recentChanges: ResourceState<Int> = .idle
    private(set) var newestDelivery: NotifyDelivery?
    private(set) var trust: PluginTrust?
    private(set) var health: ServerHealth?
    private(set) var healthError: LatticeAPIError?

    /// What is on screen, and what a held poll would put there.
    private(set) var displayed = InboxContent()
    private(set) var held: InboxContent?
    private(set) var heldChanges = 0
    /// The last time the list was touched, scrolled or showed a dialog.
    @ObservationIgnored var lastInteraction: Date = .distantPast
    /// A dialog, swipe or menu is up.
    @ObservationIgnored var interactionInProgress = false
    @ObservationIgnored private var generation = -1
    /// Until the first refresh of a session finishes, each section shows as
    /// soon as it lands; the stable-list hold applies to later polls only.
    @ObservationIgnored private var firstRefreshDone = false
    @ObservationIgnored private var planCache = ApprovalsPlanCache()
    @ObservationIgnored private var applyLater: Task<Void, Never>?
    /// The screen's time zone mode and locale, for times inside rows.
    @ObservationIgnored var timeZoneMode: TimeZoneMode = .local
    @ObservationIgnored var locale: Locale = .current

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    // MARK: Requirements (section 8.9)

    static let incidentsRequirement = ScopeRequirement("monitor:read")
    static let nodesRequirement = ScopeRequirement("node:read")
    static let tasksRequirement = ScopeRequirement("task:read")
    static let upcomingRequirement = ScopeRequirement.anyOf("inventory:read", "proxy:read", "proxy:admin", "monitor:read")
    static let sshGuardRequirement = ScopeRequirement("sshguard:read", "network:plan")
    static let ddnsRequirement = ScopeRequirement("ddns:admin")
    static let auditRequirement = ScopeRequirement("audit:read")
    static let notifyRequirement = ScopeRequirement("notify:admin")

    var scopes: ScopeSet? { session.tokenScopes }

    /// The first scope `requirement` lacks, or nil when it is met or unknown.
    func missing(_ requirement: ScopeRequirement) -> String? {
        session.missing(requirement)?.first
    }

    /// Approvals are hidden only when the token cannot list any plugin.
    var approvalsDenied: Bool {
        guard let scopes else { return false }
        return !scopes.allows("network:plan") && ApprovalVisibility.hiddenPlugins(scopes: scopes).count == ApprovalVisibility.knownPlugins.count
    }

    /// Plugins whose approvals the server hides from this token.
    var hiddenPlugins: [String] {
        guard let scopes, !approvalsDenied else { return [] }
        return ApprovalVisibility.hiddenPlugins(scopes: scopes)
    }

    var confined: Bool { scopes?.isConfined ?? false }

    // MARK: Refresh

    /// Reloads every section at once. Returns false when any section failed,
    /// which backs the polling interval off.
    @discardableResult
    func refresh(force: Bool = false) async -> Bool {
        guard let client = session.client else { return false }
        if generation != session.generation {
            generation = session.generation
            reset()
        }
        let now = Date()
        async let approvalsOK = loadApprovals(client)
        async let incidentsOK = loadIncidents(client)
        async let nodesOK = loadNodes(client)
        async let tasksOK = loadTasks(client, now: now)
        async let expiringOK = loadExpiring(client)
        async let sshGuardOK = loadSSHGuard(client)
        async let ddnsOK = loadDDNS(client)
        async let stuckOK = loadStuck(client)
        async let changesOK = loadRecentChanges(client, now: now)
        async let extrasOK = loadExtras(client)
        let results = await [approvalsOK, incidentsOK, nodesOK, tasksOK, expiringOK, sshGuardOK, ddnsOK, stuckOK, changesOK, extrasOK]
        updateBadge()
        rebuild(force: force || !firstRefreshDone)
        firstRefreshDone = true
        return !results.contains(false)
    }

    private func reset() {
        approvals = .idle
        incidents = .idle
        newestResolvedAt = nil
        nodes = .idle
        tasks = .idle
        taskCounts = nil
        expiring = .idle
        sshGuard = .idle
        ddns = .idle
        stuck = .idle
        recentChanges = .idle
        newestDelivery = nil
        trust = nil
        health = nil
        healthError = nil
        displayed = InboxContent()
        held = nil
        heldChanges = 0
        firstRefreshDone = false
        planCache = ApprovalsPlanCache()
    }

    /// Loads one section into its state, keeping earlier data on failure.
    /// A 403 after `/api/me` said the scope was held names the section's own
    /// requirement (`deniedScope` when it has none) and re-reads `/api/me`
    /// (section 6.7), so the row never says "lacks" with no scope.
    private func load<Value: Sendable>(
        _ keyPath: ReferenceWritableKeyPath<InboxStore, ResourceState<Value>>,
        surface: String,
        requirement: ScopeRequirement?,
        deniedScope: String? = nil,
        fetch: () async throws -> Value
    ) async -> Bool {
        defer { sectionLanded() }
        if let requirement, let scope = missing(requirement) {
            self[keyPath: keyPath] = .denied(scope: scope)
            return true
        }
        self[keyPath: keyPath] = self[keyPath: keyPath].reloading
        do {
            self[keyPath: keyPath] = .loaded(try await fetch(), at: Date())
            return true
        } catch {
            let apiError = LatticeAPIError(error)
            if case .forbidden = apiError { session.noteForbidden() }
            if apiError == .invalidResponse { session.markCompanionBehind(surface) }
            let scope = requirement.flatMap(missing) ?? requirement?.summary ?? deniedScope
            self[keyPath: keyPath] = self[keyPath: keyPath].failing(apiError, surface: surface, missingScope: scope)
            return false
        }
    }

    /// During a session's first refresh, puts each section on screen as it lands.
    private func sectionLanded() {
        guard !firstRefreshDone else { return }
        rebuild(force: true)
    }

    private func loadApprovals(_ client: LatticeClient) async -> Bool {
        if approvalsDenied {
            approvals = .denied(scope: "network:plan")
            sectionLanded()
            return true
        }
        return await load(\.approvals, surface: "Approvals", requirement: nil, deniedScope: "network:plan") {
            let (page, cache) = try await client.approvalsPendingPage(cache: planCache)
            planCache = cache
            return InboxApprovalsPage(approvals: page.approvals.filter(\.isHumanPending), total: page.total, limit: page.limit)
        }
    }

    private func loadIncidents(_ client: LatticeClient) async -> Bool {
        let ok = await load(\.incidents, surface: "Incidents", requirement: Self.incidentsRequirement) {
            try await client.listIncidents(states: [.open, .acknowledged])
        }
        if case .loaded = incidents {
            newestResolvedAt = (try? await client.listIncidents(states: [.resolved], limit: 1))?.incidents.first?.resolvedAt ?? newestResolvedAt
        }
        return ok
    }

    private func loadNodes(_ client: LatticeClient) async -> Bool {
        await load(\.nodes, surface: "Nodes", requirement: Self.nodesRequirement) {
            try await client.fetchNodes()
        }
    }

    private func loadTasks(_ client: LatticeClient, now: Date) async -> Bool {
        let ok = await load(\.tasks, surface: "Tasks", requirement: Self.tasksRequirement) {
            let query = TaskQuery(statuses: ["failed", "stalled"], since: now.addingTimeInterval(-86_400), limit: 20)
            return try await client.listTasks(query: query).tasks
        }
        if case .loaded = tasks { taskCounts = (try? await client.fetchTaskCounts()) ?? taskCounts }
        return ok
    }

    private func loadExpiring(_ client: LatticeClient) async -> Bool {
        await load(\.expiring, surface: "Upcoming", requirement: Self.upcomingRequirement) {
            try await client.fetchExpiring(within: 7)
        }
    }

    private func loadSSHGuard(_ client: LatticeClient) async -> Bool {
        await load(\.sshGuard, surface: "SSH Guard", requirement: Self.sshGuardRequirement) {
            try await client.fetchSSHGuardStatus()
        }
    }

    private func loadDDNS(_ client: LatticeClient) async -> Bool {
        await load(\.ddns, surface: "DDNS", requirement: Self.ddnsRequirement) {
            try await client.listDDNS()
        }
    }

    private func loadStuck(_ client: LatticeClient) async -> Bool {
        if approvalsDenied {
            stuck = .denied(scope: "network:plan")
            sectionLanded()
            return true
        }
        return await load(\.stuck, surface: "Approvals", requirement: nil, deniedScope: "network:plan") {
            let page = try await client.listApprovals(query: ApprovalQuery(status: "approved", limit: 100))
            return page.approvals.filter { $0.waiting?.blocked == true }
        }
    }

    /// Changes in the last hour, with the console's Changes-view exclusions
    /// (`changesExclusions` in auditModel.ts: node flips and observe events).
    private func loadRecentChanges(_ client: LatticeClient, now: Date) async -> Bool {
        await load(\.recentChanges, surface: "Audit", requirement: Self.auditRequirement) {
            let query = AuditQuery(atFrom: now.addingTimeInterval(-3600), excludeAction: "node.online,node.offline", excludeDecision: "observe", limit: 100, offset: 0)
            return try await client.fetchAudit(query: query).events.count
        }
    }

    /// Trust, health and the newest delivery: optional rows with no section of their own.
    private func loadExtras(_ client: LatticeClient) async -> Bool {
        async let trustResult = try? client.fetchPluginTrust()
        async let healthResult: Result<ServerHealth, LatticeAPIError> = {
            do { return .success(try await client.fetchHealth()) } catch { return .failure(LatticeAPIError(error)) }
        }()
        async let deliveryResult: NotifyDelivery?? = missing(Self.notifyRequirement) == nil
            ? (try? await client.fetchDeliveries(query: DeliveryQuery(limit: 1)))?.deliveries.first
            : .some(nil)
        trust = await trustResult ?? trust
        switch await healthResult {
        case .success(let value):
            health = value
            healthError = nil
        case .failure(let error):
            healthError = error
        }
        if let delivery = await deliveryResult { newestDelivery = delivery }
        return true
    }

    // MARK: Badge

    /// Human-pending approvals plus urgent incidents (section 6.9). Demo
    /// mode never touches the app icon or stored preferences.
    private func updateBadge() {
        guard approvals.value != nil || incidents.value != nil else { return }
        let count = BadgeCount.compute(approvals: approvals.value?.approvals ?? [], incidents: incidents.value?.incidents ?? [])
        badge = count
        badgeSourceAt = Date()
        guard !session.isDemo else { return }
        BackgroundRefresh.noteForegroundBadge()
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.badgeSetting == .enabled { try? await UNUserNotificationCenter.current().setBadgeCount(count) }
        }
    }

    private(set) var badge: Int?
    private(set) var badgeSourceAt: Date?

    // MARK: Content and the stable-list rule

    /// Whether reorders and inserts wait: while VoiceOver runs (they wait
    /// behind a "Show" row) or while the list was touched in the last 2 s.
    var holdsForAssistiveTechnology: Bool {
        UIAccessibility.isVoiceOverRunning || (session.isDemo && UserDefaults.standard.bool(forKey: InboxScreen.holdUpdatesArgument))
    }

    private var isBusy: Bool {
        interactionInProgress || Date().timeIntervalSince(lastInteraction) < 2
    }

    func rebuild(force: Bool = false) {
        let next = content(now: Date())
        let first = displayed.isEmpty && held == nil
        let structural = InboxContent.changes(from: displayed, to: next)
        if force || first || structural == 0 {
            displayed = next
            held = nil
            heldChanges = 0
            return
        }
        if holdsForAssistiveTechnology {
            displayed = InboxContent.refreshingValues(of: displayed, from: next)
            held = next
            heldChanges = structural
        } else if isBusy {
            displayed = InboxContent.refreshingValues(of: displayed, from: next)
            held = next
            heldChanges = 0
            scheduleApplyWhenIdle()
        } else {
            displayed = next
            held = nil
            heldChanges = 0
        }
    }

    /// "Show" on the pending-updates row, or the list going idle.
    func applyHeld() {
        guard let held else { return }
        displayed = held
        self.held = nil
        heldChanges = 0
    }

    private func scheduleApplyWhenIdle() {
        applyLater?.cancel()
        applyLater = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if !self.isBusy, !self.holdsForAssistiveTechnology {
                    self.applyHeld()
                    return
                }
            }
        }
    }

    /// Builds the content from the loaded sections.
    func content(now: Date) -> InboxContent {
        InboxContent(
            incidents: sortedIncidents(now: now),
            events: ApprovalEvents.group(approvals.value?.approvals ?? []),
            attention: InboxAttentionItem.items(store: self, now: now, mode: timeZoneMode, locale: locale),
            due: Array(dueSoon.prefix(3))
        )
    }

    /// Open incidents, critical first, then warning, then by age; then
    /// acknowledged, snoozed and held in quiet style.
    func sortedIncidents(now: Date) -> [Incident] {
        let active = (incidents.value?.incidents ?? []).filter { IncidentFilter.isActive($0) || $0.isDerivedPending }
        func rank(_ incident: Incident) -> Int {
            switch incident.displayState(now: now) {
            case .openCritical: 0
            case .openWarning: 1
            case .openInfo: 2
            case .pending: 3
            case .acknowledged: 4
            case .snoozed: 5
            case .held: 6
            case .resolved: 7
            }
        }
        return active.sorted { lhs, rhs in
            let left = rank(lhs), right = rank(rhs)
            if left != right { return left < right }
            return (lhs.since ?? lhs.openedAt ?? .distantFuture) < (rhs.since ?? rhs.openedAt ?? .distantFuture)
        }
    }

    /// Upcoming items, soonest first.
    var dueSoon: [ExpiringItem] {
        (expiring.value?.items ?? []).sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
    }

    // MARK: Verdict

    func coverage<Value>(_ state: ResourceState<Value>, interval: TimeInterval, offline: Bool, now: Date) -> SectionCoverage {
        if case .denied(let scope) = state { return .denied(scope: scope) }
        // Offline is known even before anything loaded: never "Checking".
        if offline { return .offline(lastGoodAt: state.loadedAt) }
        switch state {
        case .idle: return .notLoaded
        case .companionBehind: return .failed(lastGoodAt: nil)
        default: break
        }
        if case .failed = state { return .failed(lastGoodAt: state.loadedAt) }
        guard let at = state.loadedAt else { return .notLoaded }
        if now.timeIntervalSince(at) > 3 * interval { return .stale(lastGoodAt: at) }
        return .fresh(at: at)
    }

    func snapshot(now: Date, interval: TimeInterval, offline: Bool, mode: TimeZoneMode, locale: Locale) -> InboxSnapshot {
        var coverage: [InboxSection: SectionCoverage] = [
            .approvals: self.coverage(approvals, interval: interval, offline: offline, now: now),
            .incidents: self.coverage(incidents, interval: interval, offline: offline, now: now),
            .nodes: self.coverage(nodes, interval: interval, offline: offline, now: now),
            .tasks: self.coverage(tasks, interval: interval, offline: offline, now: now),
            .upcoming: self.coverage(expiring, interval: interval, offline: offline, now: now),
            .sshGuard: self.coverage(sshGuard, interval: interval, offline: offline, now: now),
            .ddns: self.coverage(ddns, interval: interval, offline: offline, now: now),
        ]
        if case .fresh(let at) = coverage[.approvals], !hiddenPlugins.isEmpty {
            coverage[.approvals] = .partial(hiddenPlugins: hiddenPlugins, at: at)
        }
        let pending = approvals.value?.approvals ?? []
        // Listing rows carry bodies only for agent updates; Review checks
        // every other body against its hash when it opens.
        let decidable = pending.filter { !$0.isStale && (!$0.hasPlanBody || $0.planHashMatchesServer) && ApprovalsDecisionGate.missingScopes($0, scopes: scopes).isEmpty }
        let nodeList = nodes.value ?? []
        return InboxSnapshot(
            coverage: coverage,
            approvalsNeedingYou: decidable.count,
            approvalsWaiting: max(pending.count, approvals.value?.total ?? 0),
            problems: problems(now: now, mode: mode, locale: locale),
            nodeCount: nodeList.count,
            onlineCount: nodeList.filter { $0.honesty == .online }.count,
            confinedTo: confined ? nodeList.count : nil,
            failedTasks: taskCounts?.failed24h ?? (tasks.value ?? []).filter { $0.runState(now: now) == .failed }.count,
            dueCount: expiring.value?.items.count ?? 0,
            newestResolvedAt: newestResolvedAt
        )
    }

    func problems(now: Date, mode: TimeZoneMode, locale: Locale) -> [VerdictProblem] {
        var problems: [VerdictProblem] = []
        for incident in incidents.value?.incidents ?? [] where incident.state == "open" && !IncidentFilter.isSnoozed(incident, now: now) && incident.maintenance.isEmpty {
            let since = incident.since ?? incident.openedAt
            if incident.severity == "critical" {
                problems.append(VerdictProblem(kind: .criticalIncident, summary: incident.displayTitle, since: since))
            } else if incident.severity == "warning" {
                let kind: VerdictProblemKind = incident.kind.hasPrefix("path.") ? .degradedPath : .warningIncident
                problems.append(VerdictProblem(kind: kind, summary: incident.displayTitle, since: since))
            }
        }
        for status in SSHGuardBoard.revertingNodes(sshGuard.value ?? [], now: now) {
            let name = status.nodeName.isEmpty ? status.nodeID : status.nodeName
            let deadline = SSHGuardBoard.revertDeadline(status).map { " by \(TimeDisplay.clock($0, mode: mode, locale: locale))" } ?? ""
            problems.append(VerdictProblem(kind: .sshGuardReverting, summary: "Confirm SSH Guard on \(name)\(deadline)", since: nil))
        }
        for node in nodes.value ?? [] where node.honesty == .offline {
            problems.append(VerdictProblem(kind: .offlineNode, summary: "\(node.displayName) offline", since: node.statusSince ?? node.lastSeen))
        }
        for task in tasks.value ?? [] where task.runState(now: now) == .failed {
            problems.append(VerdictProblem(kind: .failedTask, summary: "Task \(task.id) failed", since: task.finishedAt))
        }
        return problems
    }

    /// The oldest successful refresh among the sections that loaded.
    var oldestLoadedAt: Date? {
        [approvals.loadedAt, incidents.loadedAt, nodes.loadedAt, tasks.loadedAt, expiring.loadedAt, sshGuard.loadedAt, ddns.loadedAt].compactMap { $0 }.min()
    }

    var isRefreshing: Bool {
        approvals.isLoading || incidents.isLoading || nodes.isLoading
    }

    var anyFailed: Bool {
        func failed<Value>(_ state: ResourceState<Value>) -> Bool {
            if case .failed = state { return true }
            return false
        }
        return failed(approvals) || failed(incidents) || failed(nodes) || failed(tasks) || failed(expiring) || failed(sshGuard) || failed(ddns)
    }
}

/// One section's load state, reduced to what a screen says about it.
struct InboxSectionStatus: Identifiable {
    let noun: String
    /// Idle, or loading with nothing loaded before.
    let waiting: Bool
    /// Why the last load failed, when it did.
    let failure: String?
    /// Something has loaded at least once.
    let everLoaded: Bool

    var id: String { noun }

    init<Value>(_ state: ResourceState<Value>, noun: String) {
        self.noun = noun
        switch state {
        case .idle, .loading(nil, _):
            waiting = true
            failure = nil
        case .failed(let error, _, _):
            waiting = false
            failure = error.localizedDescription
        case .companionBehind:
            waiting = false
            failure = "This app is behind the server"
        default:
            waiting = false
            failure = nil
        }
        everLoaded = state.value != nil
    }

    /// "Could not load nodes: ..." or "Could not refresh nodes: ...".
    var failureSentence: String? {
        failure.map { "Could not \(everLoaded ? "refresh" : "load") \(noun): \($0)" }
    }
}

extension InboxStore {
    /// The sections the Attention rows are built from.
    var attentionStatuses: [InboxSectionStatus] {
        [
            InboxSectionStatus(sshGuard, noun: "SSH Guard"),
            InboxSectionStatus(nodes, noun: "nodes"),
            InboxSectionStatus(tasks, noun: "tasks"),
            InboxSectionStatus(stuck, noun: "stuck approvals"),
            InboxSectionStatus(ddns, noun: "DDNS"),
            InboxSectionStatus(expiring, noun: "renewals"),
            InboxSectionStatus(recentChanges, noun: "recent changes"),
        ]
    }

    /// Attention rows the token cannot read, named so a short list never
    /// reads as healthy by omission.
    var attentionDenied: [String] {
        if case .denied = sshGuard { return [missingSentence(Self.sshGuardRequirement)] }
        return []
    }
}
