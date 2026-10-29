import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Pieces every Activity screen shares: state styles, the resource and
// freshness wrappers of section 5.0, the stable-list rule, context menus and
// the export file. Module-private by name; nothing outside Activity uses them.

enum ActivityStyle {
    /// An audit decision as symbol, word and tone. Deny is the only problem word.
    static func decision(_ decision: AuditDecision) -> StatusStyle {
        switch decision {
        case .deny: StatusStyle(word: "denied", symbol: "hand.raised.slash.fill", tone: .warn)
        case .warn: StatusStyle(word: "warned", symbol: "exclamationmark.triangle", tone: .warn)
        case .observe: StatusStyle(word: "observed", symbol: "eye", tone: .quiet)
        case .dismiss: StatusStyle(word: "dismissed", symbol: "archivebox", tone: .quiet)
        case .allow: StatusStyle(word: "allowed", symbol: "checkmark.circle", tone: .quiet)
        case .other(let word): StatusStyle(word: word, symbol: "doc.text", tone: .quiet)
        }
    }

    /// The chain verification result.
    static func chain(_ status: AuditChainStatus) -> StatusStyle {
        if !status.enabled { return StatusStyle(word: "verification off", symbol: "minus.circle", tone: .quiet) }
        return status.ok
            ? StatusStyle(word: "intact", symbol: "checkmark.shield", tone: .ok)
            : StatusStyle(word: "broken", symbol: "xmark.shield", tone: .fail)
    }
}

/// The section footer every Activity list ends with.
struct ActivityFreshness<Value: Sendable>: View {
    let state: ResourceState<Value>
    var cadence: Polling = .standard

    @Environment(PowerMonitor.self) private var power

    var body: some View {
        FreshnessFooter(state: state, interval: cadence.interval(lowPower: power.isLowPower))
    }
}

/// An error row for a failed refresh with earlier data kept below it.
struct ActivityRefreshError<Value: Sendable>: View {
    let state: ResourceState<Value>
    let noun: String
    let retry: () -> Void

    var body: some View {
        if case .failed(let error, let last, _) = state, last != nil {
            ErrorRow(message: "Could not refresh \(noun): \(error.localizedDescription)", retry: retry)
        }
    }
}

/// ResourceView plus the offline state of section 6.11 for a screen with
/// nothing loaded yet: no request is made offline, so placeholders would
/// never resolve.
struct ActivityResource<Value: Sendable, Content: View>: View {
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

/// Problems the query field could not send, said in a row above the list.
struct ActivityQueryNotice: View {
    let message: String

    var body: some View {
        Label {
            Text(message).foregroundStyle(Color.statusWarnText)
        } icon: {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.statusWarnFill)
        }
        .font(.subheadline)
        .frame(minHeight: Spacing.minimumTarget)
    }

    /// One sentence for what the field left out, or nil when it sent everything.
    static func message(_ tokens: TasksParsedTokens, textAllowed: Bool, keys: String) -> String? {
        var parts: [String] = []
        for problem in tokens.problems {
            switch problem.kind {
            case .emptyValue: parts.append("\(problem.token) has no value, so it was left out.")
            case .unknownValue: parts.append("\(problem.token) names a value the server does not know, so it was left out.")
            case .unresolved: parts.append("\(problem.token) names no node in your node list; it was sent as typed.")
            }
        }
        if !textAllowed, !tokens.text.isEmpty {
            parts.append("Runs cannot be searched by text, so \"\(tokens.text)\" was left out. Use \(keys).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// The detail screen's state line: glyph, word and an optional reason. At
/// accessibility sizes the glyph sits inline so the word keeps the full width.
struct ActivityStateHeader: View {
    let style: StatusStyle
    var reason: String?

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let wordColor: Color = style.tone.isProblem ? style.tone.word : .primary
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("\(Text(Image(systemName: style.symbol)).foregroundStyle(style.tone.glyph)) \(Text(style.word.activityCapitalized).foregroundStyle(wordColor))")
                        .textRole(.detailHeader)
                    if let reason { Text(reason).textRole(.rowReason(style.tone.isProblem ? style.tone.word : .secondary)) }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                    StatusGlyph(style: style)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(style.word.activityCapitalized).textRole(.detailHeader).foregroundStyle(wordColor)
                        if let reason { Text(reason).textRole(.rowReason(style.tone.isProblem ? style.tone.word : .secondary)) }
                    }
                }
            }
        }
        .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Open, Copy link, Copy ID and Open on web, shared by every Activity row.
struct ActivityObjectMenu: View {
    var route: AppRoute?
    let link: LatticeDeepLink
    let web: LatticeConsolePath
    let objectID: String

    @Environment(Router.self) private var router

    var body: some View {
        if let route {
            Button("Open", systemImage: "arrow.right.circle") { router.push(route) }
        }
        Button("Copy link", systemImage: "link") { UIPasteboard.general.url = link.customURL }
        Button("Copy ID", systemImage: "number") { UIPasteboard.general.string = objectID }
        Button("Open on web", systemImage: "safari") { router.openOnWeb(web) }
    }
}

/// A menu item the token cannot use: disabled, with what it needs as its subtitle.
struct ActivityMenuButton: View {
    let title: String
    let symbol: String
    var role: ButtonRole?
    /// "Needs task:run", or nil when the action is available.
    var needs: String?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
            if let needs { Text(needs) }
            Image(systemName: symbol)
        }
        .disabled(needs != nil)
    }
}

/// A link row inside a detail list: label, value and a chevron.
struct ActivityLinkRow: View {
    let label: String
    let value: String
    var monospaced = false
    let route: AppRoute

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationLink(value: route) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xxs))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.m))
            layout {
                Text(label).foregroundStyle(typeSize.isAccessibilitySize ? .secondary : .primary)
                if !typeSize.isAccessibilitySize { Spacer(minLength: Spacing.s) }
                Text(monospaced ? DetailRow.breakable(value) : value)
                    .font(monospaced ? TextRole.identifierInDetail.font : .body)
                    .foregroundStyle(typeSize.isAccessibilitySize ? .primary : .secondary)
                    .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
            }
            .frame(minHeight: Spacing.minimumTarget)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Holds poll-driven reorders while the list is busy (section 5.0): a new
/// order waits until two seconds after the last scroll, and while VoiceOver
/// runs it waits behind a "Show" row. Values inside rows apply at once.
@MainActor @Observable
final class ActivityStableList<Row: Identifiable & Sendable> where Row.ID: Sendable {
    private(set) var shown: [Row] = []
    private(set) var held: [Row]?
    @ObservationIgnored private var lastActivity = Date.distantPast
    @ObservationIgnored private var hasShown = false
    @ObservationIgnored private var voiceOver = false
    @ObservationIgnored private var release: Task<Void, Never>?

    var pendingCount: Int {
        guard let held else { return 0 }
        let current = Set(shown.map(\.id)), next = Set(held.map(\.id))
        let moved = zip(shown.map(\.id), held.map(\.id)).contains { $0 != $1 }
        return max(current.symmetricDifference(next).count, moved ? 1 : 0)
    }

    func noteActivity() {
        lastActivity = Date()
        scheduleRelease()
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

    /// Applies `rows` now when only values changed or the list is idle;
    /// otherwise holds them. `force` is pull to refresh or a new question.
    func offer(_ rows: [Row], voiceOver: Bool, force: Bool = false) {
        self.voiceOver = voiceOver
        let sameOrder = rows.map(\.id) == shown.map(\.id)
        let idle = Date().timeIntervalSince(lastActivity) > 2
        if !hasShown || shown.isEmpty || force || sameOrder || (idle && !voiceOver) {
            shown = rows
            held = nil
            hasShown = true
        } else {
            let fresh = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            shown = shown.map { fresh[$0.id] ?? $0 }
            held = rows
            scheduleRelease()
        }
    }

    func showHeld() {
        if let held { shown = held }
        held = nil
    }
}

/// A file built on device and handed to the share sheet without being
/// written to disk by the app (section 6.11).
struct ActivityExportFile: Transferable {
    let name: String
    let format: AuditExportFormat
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { file in file.data }
            .suggestedFileName { $0.name }
            .exportingCondition { $0.format == .csv }
        DataRepresentation(exportedContentType: .json) { file in file.data }
            .suggestedFileName { $0.name }
            .exportingCondition { $0.format == .head }
        // NDJSON has no system type; plain text keeps every line as sent.
        DataRepresentation(exportedContentType: .plainText) { file in file.data }
            .suggestedFileName { $0.name }
    }
}

extension String {
    /// An identifier ("edge-tyo-2", "u-demo-ops") that wraps as a whole:
    /// its hyphens become non-breaking, so a line never ends in "edge-".
    var activityUnbroken: String {
        replacingOccurrences(of: "-", with: "\u{2011}")
    }

    /// "Intact" from "intact"; only the first letter changes.
    var activityCapitalized: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// The polling key for a list that refetches when its question changes:
/// the change version and the whole question hashed together, so a new
/// question restarts the poll at once instead of waiting for the next tick.
enum ActivityPollKey {
    static func of(_ version: Int, _ question: some Hashable) -> Int {
        var hasher = Hasher()
        hasher.combine(version)
        hasher.combine(question)
        return hasher.finalize()
    }
}
