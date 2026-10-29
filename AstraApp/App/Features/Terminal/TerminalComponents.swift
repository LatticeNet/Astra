import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Views and styles the terminal screens share. Every state is a symbol and
// a word (section 4.2), colored only for a fault.

extension StatusStyle {
    static func terminal(_ state: TerminalSessionState) -> StatusStyle {
        switch state {
        case .pending: StatusStyle(word: state.word, symbol: "hourglass", tone: .quiet)
        case .open: StatusStyle(word: state.word, symbol: "apple.terminal.fill", tone: .ok)
        case .closed: StatusStyle(word: state.word, symbol: "stop.circle", tone: .quiet)
        case .expired: StatusStyle(word: state.word, symbol: "clock.badge.xmark", tone: .quiet)
        case .failed: StatusStyle(word: state.word, symbol: "xmark.circle.fill", tone: .fail)
        }
    }
}

extension LatticeConsolePath {
    /// The console's Terminal page with a node chosen, where a session is opened.
    static func terminalNewSession(nodeID: String?) -> LatticeConsolePath {
        guard let nodeID, !nodeID.isEmpty else { return LatticeConsolePath(path: "/terminal") }
        return LatticeConsolePath(path: "/terminal", query: [URLQueryItem(name: "node_id", value: nodeID)])
    }
}

enum TerminalCopy {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    /// Root-shell output often holds config and environment values, so it
    /// stays on this device and leaves the pasteboard after two minutes.
    static func copyOutput(_ text: String) {
        UIPasteboard.general.setItems([[UTType.plainText.identifier: text]],
                                      options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(120)])
    }

    static func link(sessionID: String) -> String {
        LatticeDeepLink.terminalSession(id: sessionID).customURL?.absoluteString ?? ""
    }
}

/// Words a session row and its detail share.
enum TerminalWords {
    static func shellName(_ session: TerminalSession) -> String {
        session.shellPath.split(separator: "/").last.map(String.init) ?? session.shellPath
    }

    /// "started 14:02, active 40 s ago" or "ended 12 min ago". A streamed
    /// session never touches the server while it runs, so its last-seen time
    /// says nothing about activity and is left out.
    static func timeline(_ session: TerminalSession, now: Date, mode: TimeZoneMode, locale: Locale) -> String {
        var parts: [String] = []
        if session.isLive {
            if let created = session.createdAt {
                parts.append("\(session.status == "pending" ? "requested" : "started") \(TimeDisplay.clock(created, mode: mode, locale: locale))")
            }
            if session.status != "pending", TerminalTransport.of(session, runtime: nil, now: now) != .stream, let seen = session.lastSeen {
                parts.append("active \(TimeDisplay.relative(seen, now: now, locale: locale))")
            }
        } else if let ended = session.closedAt ?? session.lastSeen {
            parts.append("ended \(TimeDisplay.relative(ended, now: now, locale: locale))")
        }
        return parts.joined(separator: ", ")
    }

    static func bytes(_ count: Int64) -> String {
        ByteFormatter.bytes(UInt64(max(0, count)))
    }
}

/// One session: node, state word, shell, transport, who opened it and when.
struct TerminalSessionRow: View {
    let session: TerminalSession
    let nodeName: String
    let currentTokenID: String?

    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            row(now: context.date)
        }
    }

    private func row(now: Date) -> some View {
        let state = TerminalSessionState.of(session)
        let style = StatusStyle.terminal(state)
        let transport = TerminalTransport.of(session, runtime: nil, now: now)
        var facts = [TerminalWords.shellName(session)]
        if transport != .unknown { facts.append(transport.word) }
        facts.append(TerminalOpener.of(session, currentTokenID: currentTokenID).phrase)
        let timeline = TerminalWords.timeline(session, now: now, mode: mode, locale: locale)
        let detail = ([facts.joined(separator: " · ")] + (timeline.isEmpty ? [] : [timeline])).joined(separator: ", ")
        let reason: String? = state == .pending
            ? "Waiting for the node agent to pick it up."
            : TerminalCloseReason.of(session)?.sentence
        return StatusRow(
            style: style,
            title: nodeName,
            detail: detail,
            reason: reason,
            accessibilityPhrase: "Terminal session on \(nodeName), \(style.word), \(detail)"
        )
    }
}

/// A notice inside a list: symbol, a title and a sentence, as one element.
struct TerminalNoticeRow: View {
    let symbol: String
    let tone: StatusTone
    let title: String
    let text: String

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tone.glyph)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                if typeSize.isAccessibilitySize {
                    Text("\(Text(Image(systemName: symbol)).foregroundStyle(tone.glyph)) \(title)")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(tone.isProblem ? tone.word : .primary)
                } else {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(tone.isProblem ? tone.word : .primary)
                }
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: Spacing.minimumTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(text)")
    }
}

/// A menu action that cannot run now: disabled, with why under it.
struct TerminalGatedButton: View {
    let title: String
    let systemImage: String
    /// Why it cannot run, such as "No connection".
    var unavailable: String?
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            if let unavailable {
                Label {
                    Text(title)
                    Text(unavailable)
                } icon: {
                    Image(systemName: systemImage)
                }
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        .disabled(unavailable != nil)
    }
}

/// The whole-screen offline state when nothing has loaded: polling stops
/// offline, so placeholders would read as a load that never ends.
struct TerminalOfflineView: View {
    let noun: String
    let retry: () -> Void

    var body: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Offline", systemImage: "wifi.slash")
            } description: {
                Text("Nothing loaded yet. \(noun) load when the connection returns.")
            } actions: {
                Button("Retry", action: retry).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

/// Holds a poll's reorder, insert or removal while the list is in use, and
/// behind a row while VoiceOver runs (section 5.0). Values inside rows that
/// stay put apply at once.
@MainActor @Observable
final class TerminalStableList<Row: Identifiable & Sendable> where Row.ID: Sendable {
    /// False when a new value would move the row to another section, which
    /// is a move like any reorder and is held the same way.
    private let keepsPlace: (Row, Row) -> Bool
    private(set) var shown: [Row] = []
    private(set) var held: [Row]?
    @ObservationIgnored private var lastActivity = Date.distantPast
    @ObservationIgnored private var hasShown = false
    @ObservationIgnored private var voiceOver = false
    @ObservationIgnored private var release: Task<Void, Never>?

    init(keepsPlace: @escaping (Row, Row) -> Bool = { _, _ in true }) {
        self.keepsPlace = keepsPlace
    }

    var pendingCount: Int {
        guard let held else { return 0 }
        let moved = zip(shown.map(\.id), held.map(\.id)).contains { $0 != $1 }
        let current = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let replaced = held.filter { row in current[row.id].map { !keepsPlace($0, row) } ?? false }.count
        return max(Set(shown.map(\.id)).symmetricDifference(Set(held.map(\.id))).count + replaced, moved ? 1 : 0)
    }

    func noteActivity() {
        lastActivity = Date()
        scheduleRelease()
    }

    /// `force` applies at once: pull to refresh, a filter or query change, a confirmed write.
    func offer(_ rows: [Row], voiceOver: Bool, force: Bool = false) {
        self.voiceOver = voiceOver
        let current = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sameOrder = rows.map(\.id) == shown.map(\.id)
            && rows.allSatisfy { row in current[row.id].map { keepsPlace($0, row) } ?? true }
        let idle = Date().timeIntervalSince(lastActivity) > 2
        if !hasShown || shown.isEmpty || force || sameOrder || (idle && !voiceOver) {
            shown = rows
            held = nil
            hasShown = true
        } else {
            let fresh = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            shown = shown.map { old in fresh[old.id].map { keepsPlace(old, $0) ? $0 : old } ?? old }
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
            guard !Task.isCancelled, let self, Date().timeIntervalSince(self.lastActivity) > 2 else { return }
            self.showHeld()
        }
    }
}

/// A row that switches tabs (section 2.4): the target tab's symbol and
/// "Opens in {tab}" in place of a chevron, stacked at accessibility sizes.
struct TerminalOpensInRow: View {
    let title: String
    let symbol: String
    let tab: AppTab
    var hint: String?
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let accessible = typeSize.isAccessibilitySize
        let layout = accessible
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.m))
        Button(action: action) {
            layout {
                Label(title, systemImage: symbol)
                if !accessible { Spacer(minLength: Spacing.s) }
                HStack(spacing: Spacing.xs) {
                    Image(systemName: tab.symbol).accessibilityHidden(true)
                    Text("Opens in \(tab.title)")
                }
                .textRole(.footnote)
            }
            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
        }
        .accessibilityHint(hint ?? "Opens in \(tab.title)")
    }
}
