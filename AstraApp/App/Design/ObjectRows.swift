import SwiftUI

// Object rows that more than one module shows (section 8.2). They take Shared
// models and render the vocabulary of section 4.2; modules add navigation,
// context menus and list-level dialogs around them.

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
        let now = Date()
        let state = incident.displayState(now: now)
        let style = StatusStyle.incident(state, snoozedUntil: incident.snoozedUntil.map { TimeDisplay.clock($0, mode: mode, locale: locale) })
        let actions = IncidentActions.of(incident, now: now, canAdmin: canAdmin)
        StatusRow(
            style: style,
            title: incident.displayTitle,
            detail: detail(now: now),
            trailing: style.word,
            accessibilityPhrase: "\(incident.displayTitle), \(style.word)"
        )
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
                    .tint(.indigo)
            }
        }
    }

    private func detail(now: Date) -> String? {
        guard let since = incident.since ?? incident.openedAt else { return nil }
        let clock = TimeDisplay.clock(since, mode: mode, locale: locale)
        return "since \(clock), \(RelativeDateFormatter.shortDuration(now.timeIntervalSince(since)))"
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
    nonisolated static func snoozeIntent(_ incident: Incident, minutes: Int, until: String) -> WriteIntent {
        let object = ObjectRef(kind: "incident", id: incident.id, name: incident.displayTitle)
        let previous = incident.snoozed ? incident.snoozedUntil : nil
        let ending = minutes == 0
        return WriteIntent(
            tier: .t1, verb: ending ? "End snooze for" : "Snooze", object: object, scopes: ["monitor:admin"],
            consequence: ending ? "Repeat alerts resume." : "No repeat alerts until \(until).",
            inverse: {
                let restore = previous.map { max(1, Int(($0.timeIntervalSinceNow / 60).rounded(.up))) } ?? 0
                return snoozeIntent(incident, minutes: restore, until: until)
            },
            idempotent: true, changes: [.incidents],
            perform: { client, _ in
                _ = try await client.snoozeIncident(id: incident.id, minutes: minutes)
                return .done(ending ? "Ended snooze for \(incident.displayTitle)" : "Snoozed \(incident.displayTitle) until \(until)")
            }
        )
    }
}

/// An approval row with its plan seal (section 4.7). Never offers a swipe to approve.
struct ApprovalRow: View {
    let approval: Approval
    var nodeName: String?

    @Environment(\.locale) private var locale

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
                SealLabel(sha256: planHash, state: approval.hasPlanBody ? .unverified : .noBody)
                    .padding(.leading, 40)
            }
        }
        .accessibilityElement(children: .combine)
        .modifier(OptionalSealContent(sha256: planHash))
    }

    private var title: String {
        let action = approval.action.split(separator: ":").first.map(String.init) ?? approval.action
        return "\(ApprovalVisibility.displayName(plugin: approval.plugin)): \(action)"
    }

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
            trailing: style.word,
            titleIsIdentifier: true,
            accessibilityPhrase: "Task \(task.id), \(style.word)"
        )
    }
}

/// A measured path. The arrow in the title is spoken as "to".
struct PathRow: View {
    let path: PathView
    var sourceName: String?
    var targetName: String?
    var judgesDegraded = true

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
            accessibilityPhrase: "\(source) to \(target), \(style.word)"
        )
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

    var body: some View {
        let honesty = node.honesty
        let style = StatusStyle.node(honesty)
        StatusRow(
            style: style,
            title: node.displayName,
            detail: detail,
            reason: honesty == .degraded && !node.statusReason.isEmpty ? node.statusReason : nil,
            trailing: honesty == .online ? String(format: "%.0f%%", node.metrics.cpuPercent) : nil,
            accessibilityPhrase: phrase(honesty)
        )
    }

    private var detail: String {
        var parts: [String] = []
        if let region = node.geo?.city ?? node.geo?.region, !region.isEmpty { parts.append(region) }
        if let agent = node.agentVersion, !agent.isEmpty { parts.append("agent \(agent)") }
        if let seen = node.lastSeen { parts.append("seen \(RelativeDateFormatter.shortDuration(Date().timeIntervalSince(seen)))") }
        return parts.joined(separator: ", ")
    }

    private func phrase(_ honesty: NodeHonesty) -> String {
        let age = node.lastSeen.map { RelativeDateFormatter.shortDuration(Date().timeIntervalSince($0)) }
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
