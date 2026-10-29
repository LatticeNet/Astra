import SwiftUI
import UIKit

/// Words for the knock knowledge the server reports.
enum SSHGuardKnockWords {
    static func word(_ knowledge: String) -> String {
        switch knowledge {
        case "installed": "knock installed"
        case "installed_superseded": "knock installed, record retired"
        case "planned": "knock planned"
        case "no_knock": "no knock"
        default: "knock unknown"
        }
    }

    static func symbol(_ knowledge: String) -> String {
        switch knowledge {
        case "installed", "installed_superseded": "hand.tap"
        case "planned": "hourglass"
        case "no_knock": "minus.circle"
        default: "questionmark.circle"
        }
    }
}

/// One board row: posture (or the revert countdown) as the state, coverage
/// and knock as the detail, and a live countdown line while the timer runs.
struct SSHGuardBoardRowView: View {
    let row: SSHGuardBoardRow

    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var glyphWidth: CGFloat = 28

    var body: some View {
        let clock = row.deadline.map { TimeDisplay.clock($0, mode: mode, locale: locale) }
        let coverageStyle = StatusStyle.coverage(row.coverage, deadline: clock)
        let postureStyle = StatusStyle.posture(row.posture)
        let style = row.isReverting ? coverageStyle : postureStyle
        let knock = SSHGuardKnockWords.word(row.knock)
        let detail = row.isReverting ? "\(postureStyle.word), \(knock)" : "\(coverageStyle.word), \(knock)"
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            StatusRow(
                style: style,
                title: row.name,
                detail: detail,
                reason: reason,
                accessibilityPhrase: "\(row.name), \(postureStyle.word), \(coverageStyle.word), \(knock)"
            )
            if let deadline = row.deadline, deadline > .now {
                SSHGuardCountdown(deadline: deadline)
                    .padding(.leading, typeSize.isAccessibilitySize ? 0 : glyphWidth + Spacing.m)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The failure in the server's words, for a node whose last arm did not survive.
    private var reason: String? {
        guard row.coverage == .failed else { return nil }
        if row.stage == .reverted { return "The revert window closed without a confirm; the node undid the hardening." }
        let text = row.status.lastArm?.reason.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let last = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        return last.map { "Last arm: \($0)" } ?? "The last arm did not apply."
    }
}

/// "Reverts in 3:12", counting down to the automatic revert. Never a pulse.
struct SSHGuardCountdown: View {
    let deadline: Date
    var prominent = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.xs) { parts }
            VStack(alignment: .leading, spacing: Spacing.xxs) { parts }
        }
        .accessibilityElement(children: .combine)
        .font(prominent ? .title3.weight(.semibold) : TextRole.rowReason(Color.statusWarnText).font.weight(.semibold))
        .foregroundStyle(Color.statusWarnText)
    }

    @ViewBuilder
    private var parts: some View {
        Text("Reverts in")
        Text(timerInterval: Date.now...max(deadline, .now), countsDown: true)
            .monospacedDigit()
    }
}

/// The scope-denied state of section 5.8, worded as the spec gives it.
struct SSHGuardNeedsScopesView: View {
    let missing: String
    @Environment(Router.self) private var router

    var body: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Needs \(missing)", systemImage: "lock")
            } description: {
                Text("This token cannot read SSH Guard. The server shows a node only to a token that holds both scopes on it.")
            } actions: {
                Button("Token scopes") { router.openSettings([.page(.scopes)]) }
                    .buttonStyle(.bordered)
                Button("Manage tokens on web") { router.openOnWeb(.tokens) }
            }
        }
    }
}

/// Holds poll-driven reorders while the list is busy (section 5.0): values
/// in rows that stay apply at once; a new order waits for two idle seconds,
/// or for the Show row under VoiceOver.
@MainActor @Observable
final class SSHGuardStableList<Row: Identifiable & Sendable> where Row.ID: Sendable {
    private(set) var shown: [Row] = []
    private(set) var held: [Row]?
    @ObservationIgnored private var lastActivity = Date.distantPast
    @ObservationIgnored private var hasShown = false
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var voiceOver = false
    @ObservationIgnored private var release: Task<Void, Never>?

    var pendingCount: Int {
        guard let held else { return 0 }
        let current = Set(shown.map(\.id))
        let next = Set(held.map(\.id))
        let moved = zip(shown.map(\.id), held.map(\.id)).contains { $0 != $1 }
        return max(current.symmetricDifference(next).count, moved ? 1 : 0)
    }

    func noteActivity() {
        lastActivity = Date()
        scheduleRelease()
    }

    func setBusy(_ value: Bool) {
        busy = value
        if !value {
            lastActivity = Date()
            scheduleRelease()
        }
    }

    func offer(_ rows: [Row], voiceOver: Bool, force: Bool = false) {
        self.voiceOver = voiceOver
        let sameOrder = rows.map(\.id) == shown.map(\.id)
        let idle = Date().timeIntervalSince(lastActivity) > 2 && !busy
        if !hasShown || shown.isEmpty || force || sameOrder || (idle && !voiceOver) {
            shown = rows
            held = nil
            hasShown = true
        } else {
            let fresh = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            shown = shown.map { fresh[$0.id] ?? $0 }
            held = rows
            if voiceOver { AccessibilityNotification.Announcement(pendingCount == 1 ? "1 update" : "\(pendingCount) updates").post() }
            scheduleRelease()
        }
    }

    func showHeld() {
        if let held { shown = held }
        held = nil
    }

    private func scheduleRelease() {
        release?.cancel()
        guard held != nil, !voiceOver else { return }
        release = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.1))
            guard !Task.isCancelled, let self, !self.busy, Date().timeIntervalSince(self.lastActivity) > 2 else { return }
            self.showHeld()
        }
    }
}

/// Copies a value to the pasteboard.
enum SSHGuardCopy {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    static func nodeLink(_ nodeID: String) -> String {
        LatticeDeepLink.sshGuardNode(nodeID: nodeID).customURL?.absoluteString ?? "lattice://ssh-guard/\(nodeID)"
    }

    static func agentUpdatesLink(_ nodeID: String) -> String {
        LatticeDeepLink.agentUpdateNode(nodeID: nodeID).customURL?.absoluteString ?? "lattice://agent-updates/\(nodeID)"
    }
}

/// A sheet target: a node to arm, or to rotate.
struct SSHGuardArmTarget: Identifiable, Hashable {
    let nodeID: String
    let rotate: Bool
    var id: String { "\(nodeID):\(rotate)" }
}

/// Demo screenshots only: `-AstraDemoScroll <row id>` scrolls a list to
/// that row once it has loaded, since simctl cannot scroll.
struct SSHGuardDemoScroll: ViewModifier {
    let proxy: ScrollViewProxy
    let ready: Bool
    @Environment(SessionStore.self) private var session

    func body(content: Content) -> some View {
        content.task(id: ready) {
            guard ready, session.isDemo, let target = UserDefaults.standard.string(forKey: "AstraDemoScroll"), !target.isEmpty else { return }
            try? await Task.sleep(for: .seconds(1))
            proxy.scrollTo(target, anchor: .top)
        }
    }
}
