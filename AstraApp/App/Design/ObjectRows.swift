import SwiftUI

// Object rows that more than one module shows (section 8.2). They take Shared
// models and render the vocabulary of section 4.2; modules add navigation,
// context menus and list-level dialogs around them.

/// The trailing accessory of a row that switches tab, segment or sheet
/// instead of pushing (section 2.4): the words, then the target's symbol, in
/// place of a chevron. At accessibility sizes the symbol goes and the words
/// take a line of their own (see `OpensInRow`).
struct OpensInAccessory: View {
    let text: String
    let symbol: String

    @Environment(\.dynamicTypeSize) private var typeSize

    init(text: String, symbol: String) {
        self.text = text
        self.symbol = symbol
    }

    init(tab: AppTab) {
        self.init(text: "Opens in \(tab.title)", symbol: tab.symbol)
    }

    /// A Monitor segment: the segment's name, with the Monitor tab's symbol.
    init(segment: MonitorSegment) {
        self.init(text: "Opens in \(segment.title)", symbol: AppTab.monitor.symbol)
    }

    /// The Settings sheet, marked with the symbol of the button that opens it.
    static let settings = OpensInAccessory(text: "Opens in Settings", symbol: "person.crop.circle")

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                Text(text).font(TextRole.footnote.font)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.xs) {
                        Text(text)
                        Image(systemName: symbol)
                    }
                    Image(systemName: symbol)
                }
                .font(.subheadline)
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// A row that switches tab or segment: the content, then the accessory, and
/// at accessibility sizes the accessory's words under the content. The words
/// become the hint, since the accessory itself is hidden.
struct OpensInRow<Content: View>: View {
    let accessory: OpensInAccessory
    @ViewBuilder let content: Content

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xxs))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.s))
        layout {
            // The content keeps its width first; the accessory drops its words
            // and keeps the symbol when the row is tight.
            content.layoutPriority(1)
            if !typeSize.isAccessibilitySize { Spacer(minLength: Spacing.s) }
            accessory
        }
        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityHint(accessory.text)
    }
}

/// An incident with its T1 swipes. Acknowledge runs at once (the label states
/// the consequence); Snooze needs a choice, so it calls `onSnooze` and the
/// list shows its one confirmation dialog (section 4.5).
struct IncidentRow: View {
    let incident: Incident
    var canAdmin = false
    var onSnooze: ((Incident) -> Void)?

    @Environment(ActionRunner.self) private var runner
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        let actions = IncidentActions.of(incident, now: Date(), canAdmin: canAdmin)
        // The age keeps moving between polls (section 4.2).
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let state = incident.displayState(now: context.date)
            let style = StatusStyle.incident(state, snoozedUntil: incident.snoozedUntil.map { TimeDisplay.clock($0, mode: mode, locale: locale) })
            StatusRow(
                style: style,
                title: incident.displayTitle,
                detail: detail(now: context.date),
                accessibilityPhrase: phrase(state, now: context.date)
            )
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if actions.acknowledge {
                Button("Acknowledge: stops repeat alerts", systemImage: "person.crop.circle.badge.checkmark") {
                    Task { await runner.run(IncidentRow.acknowledgeIntent(incident)) }
                }
                .tint(.secondary)
            } else if incident.state == "acknowledged", canAdmin {
                Button("Unacknowledge", systemImage: "person.crop.circle.badge.xmark") {
                    Task { await runner.run(IncidentRow.unacknowledgeIntent(incident)) }
                }
                .tint(.secondary)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if actions.snooze, let onSnooze {
                Button("Snooze", systemImage: "moon.zzz") { onSnooze(incident) }
                    .tint(.statusQuiet)
            }
        }
    }

    private func detail(now: Date) -> String? {
        guard let since = incident.since ?? incident.openedAt else { return nil }
        return "since \(when(since, now: now)), \(RelativeDateFormatter.shortDuration(now.timeIntervalSince(since)))"
    }

    /// A clock time alone reads as today; older times carry their date.
    private func when(_ date: Date, now: Date) -> String {
        abs(now.timeIntervalSince(date)) < 20 * 3_600 ? TimeDisplay.clock(date, mode: mode, locale: locale) : TimeDisplay.dateTime(date, mode: mode, locale: locale)
    }

    /// The VoiceOver sentence of section 4.2: severity leads an open
    /// incident, so a critical and a warning never sound alike.
    private func phrase(_ state: IncidentDisplayState, now: Date) -> String {
        let title = incident.displayTitle
        let openSince = (incident.since ?? incident.openedAt).map { ", open since \(when($0, now: now))" } ?? ", open"
        let base: String
        switch state {
        case .openCritical: base = "Critical, \(title)\(openSince)"
        case .openWarning: base = "Warning, \(title)\(openSince)"
        case .openInfo: base = "\(title)\(openSince)"
        case .acknowledged: base = incident.ackedBy.isEmpty ? "\(title), acknowledged" : "\(title), acknowledged by \(incident.ackedBy)"
        case .snoozed(let until): base = until.map { "\(title), snoozed until \(when($0, now: now))" } ?? "\(title), snoozed"
        case .held(let window): base = "\(title), held by maintenance window \(window)"
        case .pending(let opensAt): base = opensAt.map { "\(title), pending, opens at \(when($0, now: now)) if still failing" } ?? "\(title), pending"
        case .resolved: base = incident.resolvedAt.map { "\(title), resolved at \(when($0, now: now))" } ?? "\(title), resolved"
        }
        return incident.flapping ? base + ", flapping" : base
    }

    nonisolated static func acknowledgeIntent(_ incident: Incident) -> WriteIntent {
        let object = ObjectRef(kind: "incident", id: incident.id, name: incident.displayTitle)
        return WriteIntent(
            tier: .t1, verb: "Acknowledge", object: object, scopes: ["monitor:admin"],
            consequence: "Stops repeat alerts for \(incident.displayTitle).",
            inverse: { unacknowledgeIntent(incident) },
            idempotent: true, changes: [.incidents],
            perform: { client, _ in
                _ = try await client.acknowledgeIncident(id: incident.id)
                return .done("Acknowledged \(incident.displayTitle)")
            }
        )
    }

    nonisolated static func unacknowledgeIntent(_ incident: Incident) -> WriteIntent {
        let object = ObjectRef(kind: "incident", id: incident.id, name: incident.displayTitle)
        return WriteIntent(
            tier: .t1, verb: "Unacknowledge", object: object, scopes: ["monitor:admin"],
            consequence: "Repeat alerts for \(incident.displayTitle) resume.",
            inverse: { acknowledgeIntent(incident) },
            idempotent: true, changes: [.incidents],
            perform: { client, _ in
                do {
                    _ = try await client.unacknowledgeIncident(id: incident.id)
                } catch LatticeAPIError.conflict {
                    return .refused(.validation("Already resolved"), "Already resolved")
                }
                return .done("Unacknowledged \(incident.displayTitle)")
            }
        )
    }

    /// Snooze for `minutes`; `0` ends a snooze. The inverse restores the
    /// previous snooze, or ends it when there was none (section 6.6).
    nonisolated static func snoozeIntent(_ incident: Incident, minutes: Int, until: String, mode: TimeZoneMode, locale: Locale) -> WriteIntent {
        let object = ObjectRef(kind: "incident", id: incident.id, name: incident.displayTitle)
        let previous = incident.snoozed ? incident.snoozedUntil : nil
        let ending = minutes == 0
        return WriteIntent(
            tier: .t1, verb: ending ? "End snooze for" : "Snooze", object: object, scopes: ["monitor:admin"],
            consequence: ending ? "Repeat alerts resume." : "No repeat alerts until \(until).",
            // Undo restores the snooze that was there before, judged at undo
            // time: one that has since run out ends instead of becoming a
            // fresh one-minute snooze.
            inverse: {
                guard let previous, previous > Date() else {
                    return snoozeIntent(incident, minutes: 0, until: "", mode: mode, locale: locale)
                }
                let restore = max(1, Int((previous.timeIntervalSinceNow / 60).rounded(.up)))
                return snoozeIntent(incident, minutes: restore, until: TimeDisplay.clock(previous, mode: mode, locale: locale), mode: mode, locale: locale)
            },
            idempotent: true, changes: [.incidents],
            perform: { client, _ in
                _ = try await client.snoozeIncident(id: incident.id, minutes: minutes)
                return .done(ending ? "Ended snooze for \(incident.displayTitle)" : "Snoozed \(incident.displayTitle) until \(until)")
            }
        )
    }
}

/// The snooze choices of every snooze dialog (section 4.5): 1 h, 4 h, and
/// until the next 08:00. Before
/// 08:00 that is this morning, so a 3am snooze does not silence repeat
/// alerts through the whole next working day; the label names the day.
struct IncidentSnoozeChoice: Identifiable {
    let id: String
    let label: String
    let minutes: Int
    let until: String

    static func choices(now: Date, mode: TimeZoneMode, locale: Locale) -> [IncidentSnoozeChoice] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = mode.timeZone
        let todayMorning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: now) ?? now
        let isToday = todayMorning > now
        let morning = isToday ? todayMorning : (calendar.date(byAdding: .day, value: 1, to: todayMorning) ?? todayMorning)
        let clock = { (date: Date) in TimeDisplay.clock(date, mode: mode, locale: locale) }
        let hour = now.addingTimeInterval(3600), four = now.addingTimeInterval(4 * 3600)
        let minutes = max(1, Int(morning.timeIntervalSince(now) / 60))
        let rounded = Int((morning.timeIntervalSince(now) / 3600).rounded())
        let hours = rounded < 1 ? "under an hour" : (rounded == 1 ? "1 hour" : "\(rounded) hours")
        let until = isToday ? "\(clock(morning)) this morning" : "\(clock(morning)) tomorrow"
        return [
            IncidentSnoozeChoice(id: "1h", label: "1 hour, until \(clock(hour))", minutes: 60, until: clock(hour)),
            IncidentSnoozeChoice(id: "4h", label: "4 hours, until \(clock(four))", minutes: 240, until: clock(four)),
            IncidentSnoozeChoice(id: "morning", label: "Until \(until), \(hours)", minutes: minutes, until: until),
        ]
    }
}

/// The one snooze dialog for every list and screen that offers Snooze
/// (section 4.5): the shared choices, End snooze while a snooze is still in
/// force, and one title and message naming the consequence and the scope.
/// `presented` reports when it opens and closes, for a list that holds
/// updates while a dialog is up.
struct IncidentSnoozeDialog: ViewModifier {
    @Binding var target: Incident?
    var presented: ((Bool) -> Void)?

    @Environment(ActionRunner.self) private var runner
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        content.confirmationDialog(
            target.map { "Snooze \($0.displayTitle)" } ?? "Snooze",
            isPresented: Binding(
                get: { target != nil },
                set: { shown in
                    if !shown { target = nil }
                    presented?(shown)
                }
            ),
            titleVisibility: .visible,
            presenting: target
        ) { incident in
            let now = Date()
            ForEach(IncidentSnoozeChoice.choices(now: now, mode: mode, locale: locale)) { choice in
                Button(choice.label) {
                    Task { await runner.run(IncidentRow.snoozeIntent(incident, minutes: choice.minutes, until: choice.until, mode: mode, locale: locale)) }
                }
            }
            if IncidentFilter.isSnoozed(incident, now: now) {
                Button("End snooze") {
                    Task { await runner.run(IncidentRow.snoozeIntent(incident, minutes: 0, until: "", mode: mode, locale: locale)) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("No repeat alerts until the time you choose. Acknowledging stops them for good. Uses monitor:admin.")
        }
    }
}

extension View {
    func incidentSnoozeDialog(_ target: Binding<Incident?>, presented: ((Bool) -> Void)? = nil) -> some View {
        modifier(IncidentSnoozeDialog(target: target, presented: presented))
    }
}

/// An approval row with its plan seal (section 4.7). Never offers a swipe to approve.
struct ApprovalRow: View {
    let approval: Approval
    var nodeName: String?

    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    /// StatusRow's glyph column, so the seal lines up with the title at every size.
    @ScaledMetric(relativeTo: .title3) private var glyphWidth: CGFloat = 28

    var body: some View {
        let style = StatusStyle.approval(approval.displayState)
        VStack(alignment: .leading, spacing: Spacing.xs) {
            StatusRow(
                style: style,
                title: title,
                detail: detail,
                reason: approval.waiting?.blocked == true ? approval.waiting?.reason : nil,
                accessibilityPhrase: phrase(style)
            )
            if !approval.id.isEmpty, !planHash.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                    // The plugin glyph (section 4.12) sits in StatusRow's glyph
                    // column, under the status symbol; inline at accessibility sizes.
                    Image(systemName: ApprovalEvents.pluginSymbol(approval.plugin))
                        .textRole(.sealInRow)
                        .frame(width: typeSize.isAccessibilitySize ? nil : glyphWidth)
                        .accessibilityHidden(true)
                    SealLabel(sha256: planHash, state: approval.hasPlanBody ? .unverified : .noBody)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .modifier(OptionalSealContent(sha256: planHash))
    }

    /// The console's kind title ("Confirm the SSH Guard arm"), with its fallback.
    private var title: String { ApprovalEvents.title(for: approval) }

    private var detail: String {
        var parts: [String] = []
        parts.append(nodeName ?? (approval.nodeID.isEmpty ? "\(approval.targets.count) targets" : approval.nodeID))
        parts.append(approval.actorID.isEmpty ? "filed by agent" : approval.actorID)
        if let created = approval.createdAt {
            parts.append(RelativeDateFormatter.string(from: created))
        }
        return parts.joined(separator: ", ")
    }

    /// The server's hash; listing rows may omit the body, so it is never recomputed here.
    private var planHash: String { approval.planSHA256 }

    private func phrase(_ style: StatusStyle) -> String {
        let age = approval.createdAt.map { TimeDisplay.duration(Date().timeIntervalSince($0), locale: locale) }
        switch approval.displayState {
        case .needsYou: return "Needs you, \(title) on \(nodeName ?? approval.nodeID)" + (age.map { ", filed \($0) ago" } ?? "")
        case .stale: return "Stale, inspect only, \(title)"
        default: return "\(title), \(style.word)"
        }
    }
}

private struct OptionalSealContent: ViewModifier {
    let sha256: String

    func body(content: Content) -> some View {
        if sha256.isEmpty { content } else { content.sealCustomContent(sha256) }
    }
}

/// A task run with a determinate progress count, never a spinner (section 4.2).
struct TaskRow: View {
    let task: LatticeTask
    var progress: String?

    var body: some View {
        let state = task.runState(now: Date())
        let style = StatusStyle.task(state)
        StatusRow(
            style: style,
            title: task.id,
            detail: [progress, task.createdAt.map { RelativeDateFormatter.string(from: $0) }].compactMap { $0 }.joined(separator: ", "),
            titleIsIdentifier: true,
            accessibilityPhrase: phrase(state)
        )
    }

    /// Section 4.2's spoken state, then the progress and age the row shows.
    private func phrase(_ state: TaskRunState) -> String {
        let spoken: String = switch state {
        case .pending: "pending, not yet sent to nodes"
        case .leased: "running"
        case .expired: "expired, the node never picked it up"
        default: StatusStyle.task(state).word
        }
        let age = task.createdAt.map { "created \(RelativeDateFormatter.string(from: $0))" }
        return ["Task \(task.id)", spoken, progress?.isEmpty == false ? progress : nil, age].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A measured path. The arrow in the title is spoken as "to".
struct PathRow: View {
    let path: PathView
    var sourceName: String?
    var targetName: String?
    var judgesDegraded = true

    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        let state = path.displayState(judgesDegraded: judgesDegraded)
        let style = StatusStyle.path(state)
        let source = sourceName ?? path.source
        let target = targetName ?? (path.targetNode.isEmpty ? path.target : path.targetNode)
        StatusRow(
            style: style,
            title: "\(source) → \(target)",
            detail: path.method,
            reason: reason(state),
            trailing: path.loss.map { String(format: "%.1f%% loss", $0 * 100) },
            accessibilityPhrase: phrase(state, source: source, target: target)
        )
    }

    /// Section 4.2's path sentence, with the method the row shows. The
    /// reason sentence follows from StatusRow, which speaks `reason` itself.
    private func phrase(_ state: PathDisplayState, source: String, target: String) -> String {
        var parts = ["\(source) to \(target)"]
        switch state {
        case .up:
            parts.append("up")
            if let p50 = path.p50Ms { parts.append("\(Int(p50.rounded())) milliseconds") }
        case .degraded:
            parts.append("degraded")
            if let since = path.degraded?.since { parts.append("since \(TimeDisplay.clock(since, mode: mode, locale: locale))") }
        case .down: parts.append("down")
        case .paused: parts.append("paused")
        case .unknown: parts.append("unknown")
        }
        if !path.method.isEmpty { parts.append(path.method) }
        return parts.joined(separator: ", ")
    }

    private func reason(_ state: PathDisplayState) -> String? {
        switch state {
        case .degraded(let reason), .unknown(let reason): reason?.sentence
        case .paused(let reason): reason.sentence
        case .up, .down: nil
        }
    }
}

/// A node with its honesty state. An offline node hides live metrics instead
/// of showing zeros (section 4.2).
struct NodeRow: View {
    let node: LatticeNode
    /// The provider, shown after the place when the list is not already grouped by it.
    var provider: String?

    var body: some View {
        let honesty = node.honesty
        let style = StatusStyle.node(honesty)
        // "seen 25m" keeps moving between polls.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            StatusRow(
                style: style,
                title: node.displayName,
                detail: detail(now: context.date),
                reason: honesty == .degraded && !node.statusReason.isEmpty ? node.statusReason : nil,
                trailing: honesty == .online ? String(format: "%.0f%%", node.metrics.cpuPercent) : nil,
                accessibilityPhrase: phrase(honesty, now: context.date)
            )
        }
    }

    private func detail(now: Date) -> String {
        var parts: [String] = []
        if let region = node.geo?.city ?? node.geo?.region, !region.isEmpty { parts.append(region) }
        if let provider, !provider.isEmpty { parts.append(provider) }
        if let agent = node.agentVersion, !agent.isEmpty { parts.append("agent \(agent)") }
        if let seen = node.lastSeen { parts.append("seen \(RelativeDateFormatter.shortDuration(now.timeIntervalSince(seen)))") }
        return parts.joined(separator: ", ")
    }

    private func phrase(_ honesty: NodeHonesty, now: Date) -> String {
        let age = node.lastSeen.map { RelativeDateFormatter.shortDuration(now.timeIntervalSince($0)) }
        switch honesty {
        case .online: return "\(node.displayName), online" + (age.map { ", seen \($0) ago" } ?? "")
        case .degraded: return "\(node.displayName), degraded"
        case .offline: return "\(node.displayName), offline" + (age.map { " for \($0)" } ?? "")
        case .neverReported: return "\(node.displayName), never reported"
        case .disabled: return "\(node.displayName), disabled, cannot authenticate"
        }
    }
}

/// An audit event: action, actor, decision and time.
struct AuditRow: View {
    let event: AuditEvent

    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        let style = event.isDeny
            ? StatusStyle(word: "denied", symbol: "hand.raised.slash", tone: .warn)
            : StatusStyle(word: event.decision.isEmpty ? "recorded" : event.decision, symbol: "doc.text", tone: .quiet)
        StatusRow(
            style: style,
            title: event.action,
            detail: [event.actorID, event.nodeID].filter { !$0.isEmpty }.joined(separator: ", "),
            trailing: event.at.map { TimeDisplay.clock($0, mode: mode, locale: locale) },
            accessibilityPhrase: "\(event.action), \(style.word)"
        )
    }
}
