import SwiftUI
import UIKit

// Views and styles the notify screens share. Status words follow section
// 4.2: every state is a symbol and a word, colored only for problems.

extension StatusStyle {
    static func notifySent(_ state: NotifySentState) -> StatusStyle {
        switch state {
        case .sent: StatusStyle(word: "sent", symbol: "checkmark.circle.fill", tone: .ok)
        case .failed: StatusStyle(word: "failed", symbol: "xmark.circle.fill", tone: .fail)
        case .retrying: StatusStyle(word: "retrying", symbol: "arrow.clockwise.circle", tone: .warn)
        case .queued: StatusStyle(word: "queued", symbol: "clock", tone: .warn)
        case .notRouted: StatusStyle(word: "not routed", symbol: "bell.slash", tone: .quiet)
        case .held: StatusStyle(word: "held", symbol: "pause.circle", tone: .quiet)
        }
    }

    static func notifyChannel(_ channel: NotifyChannel) -> StatusStyle {
        guard channel.enabled else { return StatusStyle(word: "off", symbol: "minus.circle", tone: .quiet) }
        switch NotifyChannelHealthLine.of(channel.health).state {
        case .unreported: return StatusStyle(word: "health not reported", symbol: "questionmark.circle", tone: .quiet)
        case .unknown: return StatusStyle(word: "no sends yet", symbol: "circle.dashed", tone: .quiet)
        case .ok: return StatusStyle(word: "delivering", symbol: "checkmark.circle.fill", tone: .ok)
        case .degraded: return StatusStyle(word: "last send failed", symbol: "exclamationmark.triangle.fill", tone: .warn)
        case .failing: return StatusStyle(word: "failing", symbol: "xmark.octagon.fill", tone: .fail)
        }
    }

    static func notifyRule(_ rule: NotifyRule, channels: [NotifyChannel]?) -> StatusStyle {
        guard rule.enabled else { return StatusStyle(word: "off", symbol: "minus.circle", tone: .quiet) }
        if let channels, NotifyRules.reachesNoChannel(rule, channels: channels) {
            return StatusStyle(word: "reaches no channel", symbol: "exclamationmark.triangle.fill", tone: .warn)
        }
        return StatusStyle(word: "on", symbol: "checkmark.circle.fill", tone: .ok)
    }

    static func notifyWebhook(_ hook: NotifyWebhook, reachesNobody: Bool) -> StatusStyle {
        if !hook.enabled { return StatusStyle(word: "off", symbol: "minus.circle", tone: .quiet) }
        if reachesNobody { return StatusStyle(word: "reaches nobody", symbol: "exclamationmark.triangle.fill", tone: .warn) }
        if hook.lastUsedAt == nil { return StatusStyle(word: "never called", symbol: "circle.dashed", tone: .quiet) }
        return StatusStyle(word: "enabled", symbol: "checkmark.circle.fill", tone: .ok)
    }

    static func notifyAttempt(_ outcome: String) -> StatusStyle {
        let word = NotifyWebhookAttempt.word(outcome)
        return switch outcome {
        case "accepted": StatusStyle(word: word, symbol: "checkmark.circle.fill", tone: .ok)
        case "no_route", "partial": StatusStyle(word: word, symbol: "exclamationmark.triangle.fill", tone: .warn)
        case "rejected": StatusStyle(word: word, symbol: "hand.raised.slash", tone: .fail)
        default: StatusStyle(word: word, symbol: "xmark.circle.fill", tone: .fail)
        }
    }

    static func notifyWitness(_ line: NotifyWitnessLine) -> StatusStyle {
        let tone: StatusTone = switch line.tone {
        case .quiet: line.key == .watching ? .ok : .quiet
        case .warn: .warn
        case .fail: .fail
        }
        let symbol = switch line.key {
        case .watching: "checkmark.circle.fill"
        case .starting, .planned: "hourglass"
        case .notConfigured: "circle"
        case .neverReported: "circle.dashed"
        case .notReporting: "clock.badge.exclamationmark"
        case .stopped, .failing: "exclamationmark.triangle.fill"
        case .down: "xmark.octagon.fill"
        case .networkDown: "wifi.slash"
        case .unknown: "questionmark.circle"
        }
        return StatusStyle(word: line.word, symbol: symbol, tone: tone)
    }
}

enum NotifyTime {
    /// A clock time for today's events, a date and time for older ones.
    static func when(_ date: Date, mode: TimeZoneMode, locale: Locale, now: Date = Date()) -> String {
        abs(now.timeIntervalSince(date)) < 20 * 3_600 ? TimeDisplay.clock(date, mode: mode, locale: locale) : TimeDisplay.dateTime(date, mode: mode, locale: locale)
    }
}

/// A polling version that also changes with the question, so a new filter refetches at once.
enum NotifyPollKey {
    static func of(_ version: Int, _ question: some Hashable) -> Int {
        var hasher = Hasher()
        hasher.combine(version)
        hasher.combine(question)
        return hasher.finalize()
    }
}

enum NotifyCopy {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    static func link(_ link: LatticeDeepLink) -> String {
        link.customURL?.absoluteString ?? ""
    }
}

extension LatticeConsolePath {
    /// The console's Notifications page at one of its views.
    static func notifyNotifications(view: String) -> LatticeConsolePath {
        LatticeConsolePath(path: "/platform/notifications", query: [URLQueryItem(name: "view", value: view)])
    }

    static let notifyWebhooks = LatticeConsolePath(path: "/platform/webhooks")
}

/// The whole-screen state of a confined token: the server refuses the
/// notify surface to it, so nothing here would ever load.
struct NotifyConfinedView: View {
    let nodes: Int
    @Environment(Router.self) private var router

    var body: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Hidden from a confined token", systemImage: "lock")
            } description: {
                Text("Notifications are fleet-wide, so the server refuses them to a token confined to \(nodes == 1 ? "1 node" : "\(nodes) nodes"). Use a token without a node allowlist.")
            } actions: {
                Button("Token scopes") { router.openSettings([.page(.scopes)]) }
                    .buttonStyle(.bordered)
                Button("Manage tokens on web") { router.openOnWeb(.tokens) }
            }
        }
    }
}

/// A whole screen from one notify resource, with the confined state first.
struct NotifyResourceScreen<Value: Sendable, Content: View>: View {
    let state: ResourceState<Value>
    let noun: String
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content

    @Environment(NotifyStore.self) private var store
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        if store.isConfined {
            NotifyConfinedView(nodes: store.confinedCount)
        } else if !network.isSatisfied, state.value == nil, !state.isLoading {
            // Polling stops offline, so placeholders would read as a load that never ends.
            WholeScreenState {
                ContentUnavailableView {
                    Label("Offline", systemImage: "wifi.slash")
                } description: {
                    Text("Nothing loaded yet. \(noun.prefix(1).uppercased() + noun.dropFirst()) load when the connection returns.")
                } actions: {
                    Button("Retry", action: retry).buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
        } else {
            ResourceView(state: state, noun: noun, retry: retry, content: content)
        }
    }
}

/// A failed refresh above data that is still shown (section 5.0).
struct NotifyRefreshError<Value: Sendable>: View {
    let state: ResourceState<Value>
    let noun: String
    let retry: () -> Void

    var body: some View {
        if case .failed(let error, let last, _) = state, last != nil {
            ErrorRow(message: "Could not refresh \(noun): \(error.localizedDescription)", retry: retry)
        }
    }
}

/// A menu or list action the token may lack: disabled, with "Needs ..." under it.
struct NotifyGatedButton: View {
    let title: String
    let systemImage: String
    var missing: String?
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            if let missing {
                Label {
                    Text(title)
                    Text("Needs \(missing)")
                } icon: {
                    Image(systemName: systemImage)
                }
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        .disabled(missing != nil)
    }
}

/// Open, Copy link, Copy ID and Open on web for an object row's context menu.
struct NotifyObjectMenu: View {
    let route: AppRoute
    let link: LatticeDeepLink?
    let web: LatticeConsolePath
    let objectID: String
    @Environment(Router.self) private var router

    var body: some View {
        Button("Open", systemImage: "arrow.up.right.square") { router.push(route) }
        if let link {
            Button("Copy link", systemImage: "link") { NotifyCopy.copy(NotifyCopy.link(link)) }
        }
        Button("Copy ID", systemImage: "number") { NotifyCopy.copy(objectID) }
        Button("Open on web", systemImage: "safari") { router.openOnWeb(web) }
    }
}

/// The freshness footer of a notify list, with the offline and stale states.
struct NotifyFreshness<Value: Sendable>: View {
    let state: ResourceState<Value>
    var interval: TimeInterval = 60

    var body: some View {
        FreshnessFooter(state: state, interval: interval)
    }
}

/// Holds poll reorders and inserts while the list is touched or VoiceOver
/// runs (section 5.0). Value changes inside rows that keep their order apply at once.
@MainActor @Observable
final class NotifyStableList<Item: Identifiable & Equatable> where Item.ID: Hashable {
    private(set) var shown: [Item] = []
    private(set) var held: [Item]?
    @ObservationIgnored private var lastActivity = Date.distantPast

    var pendingCount: Int {
        guard let held else { return 0 }
        let current = Set(shown.map(\.id))
        let inserted = held.filter { !current.contains($0.id) }.count
        return max(inserted, held.map(\.id) == shown.map(\.id) ? 0 : 1)
    }

    func noteActivity() { lastActivity = Date() }

    func offer(_ rows: [Item], voiceOver: Bool, force: Bool) {
        let sameOrder = rows.map(\.id) == shown.map(\.id)
        if force || shown.isEmpty || sameOrder {
            shown = rows
            held = nil
            return
        }
        if voiceOver || Date().timeIntervalSince(lastActivity) < 2 {
            held = rows
            if !voiceOver { scheduleRelease() }
        } else {
            shown = rows
            held = nil
        }
    }

    func showHeld() {
        if let held { shown = held }
        held = nil
    }

    private func scheduleRelease() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard let self, let held = self.held, Date().timeIntervalSince(self.lastActivity) >= 2 else { return }
            self.shown = held
            self.held = nil
        }
    }
}

/// One outbox row: state, title, channel, event and time; the reason or note
/// for a problem or a hold, and how many times a folded row happened.
struct NotifyDeliveryRow: View {
    let delivery: NotifyDelivery
    let eventLabel: String

    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        let state = NotifySentState.of(delivery, now: Date())
        let style = StatusStyle.notifySent(state)
        let title = delivery.title.isEmpty ? eventLabel : delivery.title
        StatusRow(
            style: style,
            title: title,
            detail: detail,
            reason: reason(state),
            trailing: delivery.createdAt.map { NotifyTime.when($0, mode: mode, locale: locale) },
            accessibilityPhrase: ([NotifySent.severityWord(delivery), title, style.word] + spokenParts).joined(separator: ", ")
        )
    }

    private var channel: String {
        delivery.channelName.isEmpty ? (delivery.channelID.isEmpty ? "no channel" : delivery.channelID) : delivery.channelName
    }

    private var detail: String {
        var parts: [String] = []
        parts.append(delivery.role == "fallback" || delivery.role == "test" ? "\(channel), \(delivery.role)" : channel)
        if !delivery.title.isEmpty { parts.append(eventLabel) }
        if let count = NotifySent.occurrences(delivery) { parts.append("\(count) times") }
        return parts.joined(separator: " · ")
    }

    private var spokenParts: [String] {
        var parts = [delivery.role == "fallback" ? "via \(channel) as fallback" : (delivery.role == "test" ? "test via \(channel)" : "via \(channel)")]
        if !delivery.title.isEmpty { parts.append(eventLabel) }
        if let count = NotifySent.occurrences(delivery) { parts.append("\(count) times") }
        return parts
    }

    private func reason(_ state: NotifySentState) -> String? {
        switch state {
        case .failed, .retrying:
            return NotifySent.cause(delivery).map { $0.sentence.prefix(1).uppercased() + $0.sentence.dropFirst() }
        case .held, .notRouted:
            return NotifySentNote.of(delivery)?.sentence(mode: mode, locale: locale)
        case .sent, .queued:
            return nil
        }
    }
}

/// A StatusRow whose detail is a statement that must be read whole: the
/// witness attention rows and the webhook's "Who receives it" notice.
/// StatusRow caps its detail at two lines (section 4.5), which cut these
/// sentences off before their consequence, so this row wraps every line.
struct NotifyStatementRow: View {
    let style: StatusStyle
    let title: String
    var detail: String?
    var reason: String?

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var glyphWidth: CGFloat = 28

    var body: some View {
        let accessible = typeSize.isAccessibilitySize
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            if !accessible {
                StatusGlyph(style: style).frame(width: glyphWidth)
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Group {
                    if accessible {
                        Text("\(Text(Image(systemName: style.symbol)).foregroundStyle(style.tone.glyph)) \(title)")
                    } else {
                        Text(title)
                    }
                }
                .textRole(.rowTitle)
                if let line = statusLine {
                    line.textRole(.rowDetail)
                }
                if let reason {
                    Text(reason).textRole(.rowReason(style.tone.word))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: Spacing.minimumTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, style.word.isEmpty ? nil : style.word, detail, reason].compactMap { $0 }.joined(separator: ", "))
    }

    private var statusLine: Text? {
        let word = style.word.isEmpty ? nil : Text(style.word).foregroundStyle(style.tone.word)
        let detail = detail?.isEmpty == false ? detail : nil
        switch (word, detail) {
        case let (word?, detail?): return Text("\(word) · \(detail)")
        case let (word?, nil): return word
        case let (nil, detail?): return Text(detail)
        case (nil, nil): return nil
        }
    }
}

/// The first row of a detail screen whose subject is a sentence (section
/// 5.0): the full sentence in the detail header style, never truncated,
/// then the state as symbol and word, and the reason for a problem.
struct NotifyDetailHeader: View {
    let style: StatusStyle
    let title: String
    var detail: String?
    var reason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .textRole(.detailHeader)
                .fixedSize(horizontal: false, vertical: true)
            // One Text, so the state line wraps as a sentence at accessibility sizes.
            Text("\(Text(Image(systemName: style.symbol)).foregroundStyle(style.tone.glyph)) \(Text(style.word).foregroundStyle(style.tone.word))\(Text(detail.map { " · \($0)" } ?? "").foregroundStyle(.secondary))")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if let reason {
                Text(reason)
                    .textRole(.rowReason(style.tone.word))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, style.word, detail, reason].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isHeader)
    }
}
