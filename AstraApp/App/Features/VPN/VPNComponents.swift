import SwiftUI
import UIKit

/// Symbol, word and tone for the VPN states (section 4.2 rules: every state
/// is symbol plus word plus color, health is quiet, problems color their
/// word). The words are the console's.
enum VPNStyle {
    static func identity(_ state: VPNIdentityState, word: String? = nil) -> StatusStyle {
        let shown = word ?? state.label
        return switch state {
        case .expired: StatusStyle(word: shown, symbol: "clock.badge.xmark", tone: .fail)
        case .overQuota: StatusStyle(word: shown, symbol: "gauge.with.dots.needle.100percent", tone: .fail)
        case .expiring: StatusStyle(word: shown, symbol: "clock.badge.exclamationmark", tone: .warn)
        case .unbound: StatusStyle(word: shown, symbol: "link.badge.plus", tone: .warn)
        case .active: StatusStyle(word: shown, symbol: "checkmark.circle.fill", tone: .ok)
        case .disabled: StatusStyle(word: shown, symbol: "minus.circle", tone: .quiet)
        }
    }

    static func identity(_ user: VPNUser, now: Date) -> StatusStyle {
        let state = VPNIdentity.state(user, now: now)
        return identity(state, word: VPNIdentity.word(user, state: state))
    }

    static func line(_ state: VPNLineState) -> StatusStyle {
        switch state {
        case .down: StatusStyle(word: "down", symbol: "xmark.octagon.fill", tone: .fail)
        case .configError: StatusStyle(word: "config error", symbol: "xmark.circle.fill", tone: .fail)
        case .restarting: StatusStyle(word: "restarting", symbol: "exclamationmark.arrow.circlepath", tone: .warn)
        case .pending: StatusStyle(word: "pending", symbol: "hourglass", tone: .warn)
        case .stale: StatusStyle(word: "stale", symbol: "clock.badge.exclamationmark", tone: .warn)
        case .running: StatusStyle(word: "running", symbol: "checkmark.circle.fill", tone: .ok)
        case .unproven: StatusStyle(word: "unproven", symbol: "questionmark.circle", tone: .quiet)
        case .configOK: StatusStyle(word: "config ok", symbol: "checkmark.circle", tone: .quiet)
        }
    }

    static func chain(_ state: MonitoringChainState) -> StatusStyle {
        switch state {
        case .converged: StatusStyle(word: "chain converged", symbol: "link", tone: .ok)
        case .pending: StatusStyle(word: "chain applying", symbol: "hourglass", tone: .quiet)
        case .drifted: StatusStyle(word: "chain drifted", symbol: "exclamationmark.triangle.fill", tone: .warn)
        case .failed: StatusStyle(word: "chain failed", symbol: "xmark.circle.fill", tone: .fail)
        }
    }

    /// The row style of a line: its own state, unless its chain is in worse
    /// shape than a working line, which then speaks for the row.
    static func lineRow(_ state: VPNLineState, chain: MonitoringChainState?) -> StatusStyle {
        if let chain, chain == .drifted || chain == .failed, !state.isProblem { return Self.chain(chain) }
        return line(state)
    }

    static func link(_ headline: VPNLinkHeadline) -> StatusStyle {
        let word = headline.title.lowercased()
        return switch headline.key {
        case .none: StatusStyle(word: word, symbol: "minus.circle", tone: .quiet)
        case .paused: StatusStyle(word: word, symbol: "pause.circle", tone: .warn)
        case .expired: StatusStyle(word: word, symbol: "clock.badge.xmark", tone: .fail)
        case .placeholder: StatusStyle(word: word, symbol: "exclamationmark.triangle.fill", tone: .warn)
        case .empty: StatusStyle(word: word, symbol: "xmark.circle.fill", tone: .fail)
        case .active:
            headline.tone == .warning
                ? StatusStyle(word: word, symbol: "exclamationmark.triangle.fill", tone: .warn)
                : StatusStyle(word: word, symbol: "checkmark.circle.fill", tone: .ok)
        }
    }

    static func linkBadge(_ badge: VPNLinkWords.Badge?) -> String? {
        switch badge {
        case .link: "link issued"
        case .paused: "link paused"
        case .expired: "link expired"
        case nil: nil
        }
    }
}

/// An action row inside a list: a full-width button with a second line
/// saying why it is off, at least 44 pt tall. Off rows are secondary, a
/// destructive row uses the fail text color, every other row the accent.
struct VPNActionRow: View {
    let title: String
    let systemImage: String
    var note: String?
    /// "proxy:admin", "No connection" or "No link issued" when the action is off.
    var unavailable: String?
    var role: ButtonRole?
    let action: () -> Void

    private var reason: String? {
        unavailable.map { $0.hasPrefix("Needs") || $0.hasPrefix("No ") ? $0 : "Needs \($0)" }
    }

    private var tint: Color {
        if unavailable != nil { return .secondary }
        return role == .destructive ? .statusFailText : .accentText
    }

    var body: some View {
        Button(role: role, action: action) {
            VPNGlyphLabel(title: title, titleColor: tint, detail: reason ?? note, detailRole: .footnote,
                          systemImage: systemImage, glyphColor: tint)
            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(unavailable != nil)
        .accessibilityHint(reason.map { "Unavailable. \($0)." } ?? "")
    }
}

/// A menu item that stays in the menu when the token cannot use it, disabled,
/// with the reason as its subtitle (section 4.5).
struct VPNGatedButton: View {
    let title: String
    let systemImage: String
    let unavailable: String?
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            if let unavailable {
                Text(title)
                Text(unavailable.hasPrefix("Needs") || unavailable.hasPrefix("No ") ? unavailable : "Needs \(unavailable)")
                Image(systemName: systemImage)
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        .disabled(unavailable != nil)
    }
}

/// A navigation row with a leading symbol, a title and a detail line.
struct VPNLinkRow: View {
    let title: String
    var detail: String?
    let systemImage: String

    var body: some View {
        VPNGlyphLabel(title: title, titleRole: .rowTitle, detail: detail, systemImage: systemImage, glyphColor: .accentText)
            .frame(minHeight: Spacing.minimumTarget)
            .accessibilityElement(children: .combine)
    }
}

/// A leading symbol beside a title and a second line, laid out the way
/// StatusRow is (section 4.5): a scaled glyph column at default sizes; at
/// accessibility sizes the glyph runs inline with the title and the second
/// line takes the full width, so it never starts indented under the glyph.
struct VPNGlyphLabel: View {
    let title: String
    /// nil keeps the body font.
    var titleRole: TextRole?
    var titleColor: Color?
    var detail: String?
    var detailRole: TextRole = .rowDetail
    let systemImage: String
    var glyphColor: Color

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var glyphWidth: CGFloat = 28

    var body: some View {
        let detail = detail?.isEmpty == false ? detail : nil
        layout(detail: detail)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ", "))
    }

    @ViewBuilder
    private func layout(detail: String?) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                styledTitle(Text("\(Text(Image(systemName: systemImage)).foregroundStyle(glyphColor)) \(Text(title))"))
                if let detail { Text(detail).textRole(detailRole) }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                Image(systemName: systemImage)
                    .foregroundStyle(glyphColor)
                    .frame(width: glyphWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    styledTitle(Text(title))
                    if let detail { Text(detail).textRole(detailRole) }
                }
            }
        }
    }

    @ViewBuilder
    private func styledTitle(_ text: Text) -> some View {
        let colored = titleColor.map { text.foregroundStyle($0) } ?? text
        if let titleRole {
            colored.textRole(titleRole)
        } else {
            colored.font(.body)
        }
    }
}

/// A section's failed refresh, kept above its data.
struct VPNRefreshError<Value: Sendable>: View {
    let state: ResourceState<Value>
    let noun: String
    let retry: () -> Void

    var body: some View {
        if case .failed(let error, let last, _) = state, last != nil {
            ErrorRow(message: "Could not refresh \(noun): \(error.localizedDescription)", retry: retry)
        }
    }
}

/// Nothing loaded and no network: says so instead of placeholders that never end.
struct VPNOfflineView: View {
    /// "The identity loads when the connection returns."
    let sentence: String
    let retry: () -> Void

    var body: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Offline", systemImage: "wifi.slash")
            } description: {
                Text("Nothing loaded yet. \(sentence)")
            } actions: {
                Button("Retry", action: retry).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum VPNCopy {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    static func userLink(_ id: String) -> String {
        LatticeDeepLink.vpnUser(id: id).customURL?.absoluteString ?? "lattice://vpn/users/\(id)"
    }
}

extension LatticeConsolePath {
    /// The vpn-core Lines page; the console reads no object parameter there.
    static let vpnLines = LatticeConsolePath(path: "/plugins/latticenet.vpn-core/lines")
}

/// Pushes a VPN screen for a demo screenshot, then gets out of the way.
struct VPNDemoPusher: View {
    let route: VPNRoute
    @Environment(Router.self) private var router

    var body: some View {
        Color.clear.task {
            // A demo scenario rebuilds the session just after launch, which
            // resets navigation; push once that has settled, on Browse.
            try? await Task.sleep(for: .seconds(1.5))
            router.dismissPresented {
                router.select(tab: .browse)
                router.push(.vpn(route))
            }
        }
    }
}

/// Holds a poll's reorder, insert or removal while the list is in use, and
/// behind a row while VoiceOver runs (section 5.0). Values inside rows that
/// stay put apply at once.
@MainActor @Observable
final class VPNStableList<Row: Identifiable & Sendable> where Row.ID: Sendable {
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

    /// `force` applies at once: pull to refresh, a query change, a confirmed write.
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

/// `-AstraVPNScroll <section>` (demo only): scrolls a VPN screen to one of
/// its sections once it has content, so screenshots can show what lies
/// below the first screen. simctl cannot scroll.
struct VPNDemoScroll: ViewModifier {
    static let argument = "AstraVPNScroll"
    let ready: Bool
    @Environment(SessionStore.self) private var session

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.task(id: ready) {
                guard ready, session.isDemo, let target = UserDefaults.standard.string(forKey: Self.argument) else { return }
                try? await Task.sleep(for: .milliseconds(700))
                proxy.scrollTo(target, anchor: .top)
            }
        }
    }
}

extension View {
    func vpnDemoScroll(ready: Bool) -> some View {
        modifier(VPNDemoScroll(ready: ready))
    }
}

enum VPNText {
    /// An email or handle with break opportunities after "@", ".", "-" and
    /// "_", so a large text size wraps it there instead of hyphenating a word.
    static func breakable(_ value: String) -> String {
        var out = ""
        for character in value {
            out.append(character)
            if "@.-_".contains(character) { out.append("\u{200B}") }
        }
        return out
    }
}
