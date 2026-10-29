import SwiftUI
import UIKit

// Rows, styles and modifiers the M3 screens share.

/// The vocabulary for monitoring states the foundation does not map: a
/// check's health, a line chain's state and a strip cell.
enum MonitoringStyle {
    static func check(_ health: MonitoringHealth) -> StatusStyle {
        switch health {
        case .failing: StatusStyle(word: "failing", symbol: "xmark.circle.fill", tone: .fail)
        case .degraded: StatusStyle(word: "degraded", symbol: "exclamationmark.triangle.fill", tone: .warn)
        case .stale: StatusStyle(word: "stale", symbol: "clock.badge.exclamationmark", tone: .warn)
        case .unmeasured: StatusStyle(word: "unmeasured", symbol: "questionmark.circle", tone: .quiet)
        case .none: StatusStyle(word: "no results", symbol: "circle.dashed", tone: .quiet)
        case .unread: StatusStyle(word: "not read", symbol: "circle.dashed", tone: .quiet)
        case .up: StatusStyle(word: "up", symbol: "checkmark.circle.fill", tone: .ok)
        case .disabled: StatusStyle(word: "paused", symbol: "pause.circle", tone: .quiet)
        }
    }

    static func chain(_ state: MonitoringChainState) -> StatusStyle {
        switch state {
        case .converged: StatusStyle(word: "converged", symbol: "checkmark.circle.fill", tone: .ok)
        case .pending: StatusStyle(word: "pending", symbol: "hourglass", tone: .quiet)
        case .drifted: StatusStyle(word: "drifted", symbol: "exclamationmark.triangle.fill", tone: .warn)
        case .failed: StatusStyle(word: "failed", symbol: "xmark.circle.fill", tone: .fail)
        }
    }

    static func result(_ outcome: MonitoringResultOutcome) -> StatusStyle {
        switch outcome {
        case .passed: StatusStyle(word: "passed", symbol: "checkmark.circle.fill", tone: .ok)
        case .failed: StatusStyle(word: "failed", symbol: "xmark.circle.fill", tone: .fail)
        case .unmeasured: StatusStyle(word: "unmeasured", symbol: "questionmark.circle", tone: .quiet)
        }
    }

    static func cell(_ cell: MonitoringStripCell) -> StateStrip.Cell {
        switch cell {
        case .up: .up
        case .degraded: .degraded
        case .down: .down
        case .unknown: .unknown
        case .paused: .paused
        }
    }

    /// "238 ms · 6.2%": the row's trailing figures, nil when nothing is measured now.
    static func figures(_ item: MonitoringPathItem) -> String? {
        guard item.measuresNow else { return nil }
        let parts = [item.path.p50Ms.map(MonitoringFormat.milliseconds), item.path.loss.map(MonitoringFormat.percent)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A path in a list: state glyph, "source → target", method, trailing p50
/// and loss, and the reason in words for unknown, paused and degraded paths.
struct MonitoringPathListRow: View {
    let item: MonitoringPathItem

    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        let style = StatusStyle.path(item.display)
        StatusRow(
            style: style,
            title: "\(item.sourceName) → \(item.targetName)",
            detail: detail,
            reason: item.reason?.sentence,
            trailing: MonitoringStyle.figures(item),
            accessibilityPhrase: phrase(style)
        )
    }

    private var detail: String {
        item.display.measure == .skipped ? "\(item.path.method), unmeasured" : item.path.method
    }

    private func phrase(_ style: StatusStyle) -> String {
        let since = item.path.degraded?.since.map { TimeDisplay.clock($0, mode: mode, locale: locale) }
        switch item.display {
        case .down: return "\(item.spokenTitle), down" + (item.path.lastAt.map { " since \(TimeDisplay.clock($0, mode: mode, locale: locale))" } ?? "")
        case .degraded: return "\(item.spokenTitle), degraded" + (since.map { ", since \($0)" } ?? "")
        default: return "\(item.spokenTitle), \(style.word), \(item.path.method)"
        }
    }
}

/// A check: name, type and target, trailing last result and its age.
struct MonitoringCheckRow: View {
    let item: MonitoringCheckItem

    var body: some View {
        let style = MonitoringStyle.check(item.health)
        StatusRow(
            style: style,
            title: item.monitor.displayName,
            detail: "\(item.monitor.typeWord), \(item.monitor.target)",
            reason: reason,
            trailing: trailing,
            accessibilityPhrase: "\(item.monitor.displayName), \(style.word), \(item.monitor.typeWord) check"
        )
    }

    private var reason: String? {
        switch item.health {
        case .failing(let failing, let total, _):
            let error = item.monitor.latest.first { !$0.success && $0.reason.isEmpty }?.error ?? ""
            let count = total > 1 ? "\(failing) of \(total) sources failing" : nil
            return [count, error.isEmpty ? nil : error].compactMap { $0 }.joined(separator: ": ")
        case .unmeasured(_, let reason, _):
            return reason.isEmpty ? "Sources measure nothing" : PathReason.sentence(for: reason).capitalizedFirst
        case .stale(let at):
            return "No result since \(RelativeDateFormatter.string(from: at))"
        default:
            return nil
        }
    }

    private var trailing: String? {
        switch item.health {
        case .up(_, let latency, let at):
            return [latency.map(MonitoringFormat.milliseconds), RelativeDateFormatter.shortDuration(Date().timeIntervalSince(at))].compactMap { $0 }.joined(separator: " · ")
        case .degraded(_, _, let at), .failing(_, _, let at):
            return RelativeDateFormatter.shortDuration(Date().timeIntervalSince(at))
        default:
            return nil
        }
    }
}

extension String {
    /// "Source offline" from "source offline".
    fileprivate var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// The section footer every monitoring list ends with.
struct MonitoringFreshness<Value: Sendable>: View {
    let state: ResourceState<Value>
    let cadence: Polling

    @Environment(PowerMonitor.self) private var power

    var body: some View {
        FreshnessFooter(state: state, interval: cadence.interval(lowPower: power.isLowPower))
    }
}

/// An error row for a failed refresh with earlier data kept below it.
struct MonitoringRefreshError<Value: Sendable>: View {
    let state: ResourceState<Value>
    let noun: String
    let retry: () -> Void

    var body: some View {
        if case .failed(let error, let last, _) = state, last != nil {
            ErrorRow(message: "Could not refresh \(noun): \(error.localizedDescription)", retry: retry)
        }
    }
}

/// A query the engine could not read: shown as a row, the list unfiltered below.
struct MonitoringQueryErrorRow: View {
    let message: String

    var body: some View {
        Label {
            Text(message).foregroundStyle(Color.statusWarnText)
        } icon: {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.statusWarnFill)
        }
        .font(.subheadline)
    }
}

// MARK: Snooze

/// The one snooze dialog per list or screen (section 4.5): 1 h, 4 h, until
/// 08:00 tomorrow, and End snooze while snoozed. Its title names the incident.
struct MonitoringSnoozeDialog: ViewModifier {
    @Binding var target: Incident?

    @Environment(ActionRunner.self) private var runner
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        content.confirmationDialog(
            target.map { "Snooze \($0.displayTitle)" } ?? "Snooze",
            isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
            titleVisibility: .visible,
            presenting: target
        ) { incident in
            ForEach(options(now: Date()), id: \.minutes) { option in
                Button(option.label) {
                    Task { await runner.run(IncidentRow.snoozeIntent(incident, minutes: option.minutes, until: option.until)) }
                }
            }
            if IncidentFilter.isSnoozed(incident, now: Date()) {
                Button("End snooze") {
                    Task { await runner.run(IncidentRow.snoozeIntent(incident, minutes: 0, until: "")) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("No repeat alerts until the time you choose. Acknowledging stops them for good.")
        }
    }

    private struct Option {
        let label: String
        let minutes: Int
        let until: String
    }

    private func options(now: Date) -> [Option] {
        var calendar = Calendar.current
        calendar.timeZone = mode.timeZone
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? now
        func until(_ date: Date) -> String { TimeDisplay.clock(date, mode: mode, locale: locale) }
        let toMorning = max(1, Int((morning.timeIntervalSince(now) / 60).rounded(.up)))
        return [
            Option(label: "1 hour, until \(until(now.addingTimeInterval(3_600)))", minutes: 60, until: until(now.addingTimeInterval(3_600))),
            Option(label: "4 hours, until \(until(now.addingTimeInterval(14_400)))", minutes: 240, until: until(now.addingTimeInterval(14_400))),
            Option(label: "Until \(until(morning)) tomorrow", minutes: toMorning, until: "\(until(morning)) tomorrow"),
        ]
    }
}

extension View {
    func monitoringSnoozeDialog(_ target: Binding<Incident?>) -> some View {
        modifier(MonitoringSnoozeDialog(target: target))
    }
}

// MARK: Context menus

/// Open, Copy link, Copy ID and Open on web, shared by every M3 object row.
struct MonitoringObjectMenu: View {
    let route: AppRoute
    let link: LatticeDeepLink
    let web: LatticeConsolePath
    let objectID: String

    @Environment(Router.self) private var router

    var body: some View {
        Button("Open", systemImage: "arrow.right.circle") { router.push(route) }
        Button("Copy link", systemImage: "link") { UIPasteboard.general.url = link.customURL }
        Button("Copy ID", systemImage: "number") { UIPasteboard.general.string = objectID }
        Button("Open on web", systemImage: "safari") { router.openOnWeb(web) }
    }
}

/// An incident row's context menu items beyond the shared ones.
struct MonitoringIncidentMenu: View {
    let incident: Incident
    let path: MonitoringPathItem?
    let canAdmin: Bool
    let snooze: (Incident) -> Void

    @Environment(Router.self) private var router
    @Environment(ActionRunner.self) private var runner

    var body: some View {
        let actions = IncidentActions.of(incident, now: Date(), canAdmin: canAdmin)
        MonitoringObjectMenu(
            route: .monitoring(.incident(id: incident.id)),
            link: .incident(id: incident.id),
            web: .incident(id: incident.id, query: incident.subject.isEmpty ? incident.nodeName : incident.subject),
            objectID: incident.id
        )
        Divider()
        if actions.acknowledge {
            Button("Acknowledge", systemImage: "person.crop.circle.badge.checkmark") {
                Task { await runner.run(IncidentRow.acknowledgeIntent(incident)) }
            }
        } else if incident.state == "acknowledged" {
            Button("Unacknowledge", systemImage: "person.crop.circle.badge.xmark") {
                Task { await runner.run(IncidentRow.unacknowledgeIntent(incident)) }
            }
            .disabled(!canAdmin)
        }
        if IncidentFilter.isActive(incident), !incident.isDerivedPending {
            Button("Snooze", systemImage: "moon.zzz") { snooze(incident) }
                .disabled(!actions.snooze)
        }
        if !incident.nodeID.isEmpty {
            Button("Start maintenance", systemImage: "wrench.and.screwdriver") {
                router.present(.maintenanceStart(nodeID: incident.nodeID))
            }
            .disabled(!canAdmin)
            Button("Open node", systemImage: "server.rack") { router.push(.fleet(.node(id: incident.nodeID))) }
        }
        if let path {
            Button("Open path", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                router.push(.monitoring(.cell(path)))
            }
        }
        if !canAdmin {
            Text("Acknowledge, snooze and maintenance need monitor:admin")
        }
    }
}

/// Holds poll-driven reorders while the list is busy (section 5.0): a row
/// count change or a new order waits until two seconds after the last
/// scroll, and while VoiceOver runs it waits behind a "Show" row.
@MainActor @Observable
final class MonitoringStableList<Row: Identifiable & Sendable> where Row.ID: Sendable {
    private(set) var shown: [Row] = []
    private(set) var held: [Row]?
    @ObservationIgnored private var lastActivity = Date.distantPast
    @ObservationIgnored private var hasShown = false

    /// The number of rows that would change if the held update were shown.
    var pendingCount: Int {
        guard let held else { return 0 }
        let current = Set(shown.map(\.id))
        let next = Set(held.map(\.id))
        let moved = zip(shown.map(\.id), held.map(\.id)).filter { $0 != $1 }.count
        return max(current.symmetricDifference(next).count, moved > 0 ? 1 : 0)
    }

    func noteActivity() {
        lastActivity = Date()
    }

    /// Applies `rows` now when only values changed, or the list is idle;
    /// otherwise holds them. `force` is pull to refresh.
    func offer(_ rows: [Row], voiceOver: Bool, force: Bool = false) {
        let sameOrder = rows.map(\.id) == shown.map(\.id)
        let idle = Date().timeIntervalSince(lastActivity) > 2
        if !hasShown || shown.isEmpty || force || sameOrder || (idle && !voiceOver) {
            shown = rows
            held = nil
            hasShown = true
        } else {
            // Values inside rows that stay apply at once.
            let fresh = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            shown = shown.map { fresh[$0.id] ?? $0 }
            held = rows
        }
    }

    func showHeld() {
        if let held { shown = held }
        held = nil
    }
}

/// The state at the top of a detail screen: glyph, word and reason. At
/// accessibility sizes the glyph sits inline so the word keeps the full width.
struct MonitoringStateHeader: View {
    let style: StatusStyle
    var reason: String?

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let wordColor: Color = style.tone.isProblem ? style.tone.word : .primary
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("\(Text(Image(systemName: style.symbol)).foregroundStyle(style.tone.glyph)) \(Text(style.word.capitalized).foregroundStyle(wordColor))")
                        .textRole(.detailHeader)
                    if let reason { Text(reason).textRole(.rowReason(style.tone.isProblem ? style.tone.word : .secondary)) }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                    StatusGlyph(style: style)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(style.word.capitalized).textRole(.detailHeader).foregroundStyle(wordColor)
                        if let reason { Text(reason).textRole(.rowReason(style.tone.isProblem ? style.tone.word : .secondary)) }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// ResourceView, plus the offline state of section 6.11 for a screen that
/// has nothing loaded yet: without a network path no request is made, so
/// placeholders would never resolve.
struct MonitoringResource<Value: Sendable, Content: View>: View {
    let state: ResourceState<Value>
    let noun: String
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content

    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        if !network.isSatisfied, state.value == nil, !isTerminal {
            WholeScreenState {
                ContentUnavailableView {
                    Label("Offline", systemImage: "wifi.slash")
                } description: {
                    Text("No connection, and no \(noun) were loaded before it dropped. They load when the connection returns.")
                }
            }
        } else {
            ResourceView(state: state, noun: noun, retry: retry, content: content)
        }
    }

    private var isTerminal: Bool {
        switch state {
        case .denied, .companionBehind: true
        default: false
        }
    }
}

/// A node link row with the node's state as symbol and word (4.2), for the
/// subject and ends of incidents and paths.
struct MonitoringNodeRow: View {
    let label: String
    let id: String
    let name: String

    @Environment(NodeDirectory.self) private var nodes
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let style = nodes.nodes[id].map { StatusStyle.node($0.honesty) }
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.s))
        NavigationLink(value: AppRoute.fleet(.node(id: id))) {
            layout {
                Text(label)
                if !typeSize.isAccessibilitySize { Spacer(minLength: Spacing.s) }
                VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: Spacing.xxs) {
                    Text(name).foregroundStyle(typeSize.isAccessibilitySize ? .primary : .secondary)
                    if let style {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                            StatusGlyph(style: style, font: .footnote)
                            Text(style.word).foregroundStyle(style.tone.isProblem ? style.tone.word : .secondary)
                        }
                        .textRole(.rowDetail)
                    }
                }
            }
            .frame(minHeight: Spacing.minimumTarget)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label), \(name)" + (style.map { ", \($0.word)" } ?? ""))
        }
    }
}
