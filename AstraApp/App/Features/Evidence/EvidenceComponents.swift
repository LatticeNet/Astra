import SwiftUI
import UIKit

extension StatusTone {
    static func evidence(_ severity: EvidenceSeverity) -> StatusTone {
        switch severity {
        case .ok: .ok
        case .warn: .warn
        case .fail: .fail
        case .quiet: .quiet
        }
    }
}

extension StatusStyle {
    static func evidenceNode(_ state: EvidenceNodeState) -> StatusStyle {
        StatusStyle(word: state.word, symbol: state.symbol, tone: .evidence(state.severity))
    }

    static func evidenceClose(_ state: EvidenceCloseState) -> StatusStyle {
        StatusStyle(word: state.word, symbol: state.symbol, tone: .evidence(state.severity))
    }

    static func evidenceHop(_ confidence: EvidenceHopConfidence) -> StatusStyle {
        StatusStyle(word: confidence.word, symbol: confidence.symbol, tone: .evidence(confidence.severity))
    }

    /// A running capture is activity, not health: quiet, with its own symbol.
    static func evidenceSession(_ session: EvidenceTraceSession, now: Date) -> StatusStyle {
        if session.isActive(now: now) { return StatusStyle(word: "running", symbol: "record.circle", tone: .quiet) }
        if session.state == EvidenceTraceSession.stopped { return StatusStyle(word: "stopped", symbol: "stop.circle", tone: .quiet) }
        return StatusStyle(word: "ended", symbol: "clock", tone: .quiet)
    }

    static func evidenceSource(_ source: EvidenceCoverageSource) -> StatusStyle {
        if !source.enabled { return StatusStyle(word: "disabled", symbol: "minus.circle", tone: .quiet) }
        if source.lastIngestAt == nil { return StatusStyle(word: "never shipped a line", symbol: "circle.dashed", tone: .quiet) }
        if source.stale { return StatusStyle(word: "stale", symbol: "clock.badge.exclamationmark", tone: .warn) }
        return StatusStyle(word: "shipping", symbol: "checkmark.circle.fill", tone: .ok)
    }
}

/// Section 5.0 stable lists: a poll may reorder, insert or remove rows only
/// once the list has been still, with no touch or scroll, for 2 s.
@MainActor @Observable
final class EvidenceListIdle {
    /// Bumped each time the list has been still for 2 s, so held updates can apply.
    private(set) var settled = 0
    @ObservationIgnored private var touching = false
    @ObservationIgnored private var lastActivity = Date.distantPast
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    var isIdle: Bool { !touching && Date().timeIntervalSince(lastActivity) >= 2 }

    func note(_ phase: ScrollPhase) {
        lastActivity = Date()
        settleTask?.cancel()
        touching = phase != .idle
        guard !touching else { return }
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.settled += 1
        }
    }

    /// `rows` in the order last shown; rows that were not there go last.
    static func ordered<Row: Identifiable>(_ rows: [Row], by held: [Row.ID]) -> [Row] {
        guard !held.isEmpty else { return rows }
        let place = Dictionary(held.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.enumerated().sorted { a, b in
            let pa = place[a.element.id] ?? held.count + a.offset, pb = place[b.element.id] ?? held.count + b.offset
            return pa < pb
        }.map(\.element)
    }
}

enum EvidenceText {
    /// A clock time alone reads as today, so stamps older than 20 hours carry their date.
    static func stamp(_ date: Date, now: Date = Date(), mode: TimeZoneMode, locale: Locale) -> String {
        now.timeIntervalSince(date) < 20 * 3_600 ? TimeDisplay.clock(date, mode: mode, locale: locale) : TimeDisplay.dateTime(date, mode: mode, locale: locale)
    }

    /// Break opportunities after the separators of an address or host name
    /// (".", ":", "/", "-"), so "198.51.100.150:40000" wraps after a dot or the
    /// colon and never inside a number or a word.
    static func breakableAddress(_ value: String) -> String {
        var out = ""
        for character in value {
            out.append(character)
            if ".:/-".contains(character) { out.append("\u{200B}") }
        }
        return out
    }
}

/// Copying and app links for Evidence objects.
enum EvidenceCopy {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    static func link(connection id: String) -> String {
        LatticeDeepLink.connection(id: id).customURL?.absoluteString ?? ""
    }

    /// The console's Collection layer, where policies, sources and budgets are edited.
    static let collection = LatticeConsolePath(path: "/platform/evidence", query: [URLQueryItem(name: "view", value: "collection")])
    static let overview = LatticeConsolePath(path: "/platform/evidence")

    static func explore(nodeID: String?) -> LatticeConsolePath {
        var query = [URLQueryItem(name: "view", value: "explore")]
        if let nodeID, !nodeID.isEmpty { query.append(URLQueryItem(name: "node_id", value: nodeID)) }
        return LatticeConsolePath(path: "/platform/evidence", query: query)
    }

    static func rawLog(sourceID: String?) -> LatticeConsolePath {
        var query = [URLQueryItem(name: "view", value: "explore"), URLQueryItem(name: "lens", value: "log")]
        if let sourceID, !sourceID.isEmpty { query.append(URLQueryItem(name: "source", value: sourceID)) }
        return LatticeConsolePath(path: "/platform/evidence", query: query)
    }
}

/// A capture: its state, nodes and start, with a live countdown while it runs.
/// Laid out like `StatusRow`, which has no slot for a timer.
struct EvidenceCaptureRow: View {
    let session: EvidenceTraceSession
    let nodeNames: [String]

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .title3) private var glyphWidth: CGFloat = 28

    var body: some View {
        let now = Date()
        let style = StatusStyle.evidenceSession(session, now: now)
        let accessible = typeSize.isAccessibilitySize
        let running = session.isActive(now: now)
        let layout = accessible
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.m))
        layout {
            if !accessible {
                StatusGlyph(style: style).frame(width: glyphWidth)
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                if accessible {
                    Text("\(Text(Image(systemName: style.symbol)).foregroundStyle(style.tone.glyph)) \(session.name)")
                        .textRole(.rowTitle).lineLimit(3)
                } else {
                    Text(session.name).textRole(.rowTitle).lineLimit(2)
                }
                Text("\(Text(style.word).foregroundStyle(style.tone.word)) · \(detail)")
                    .textRole(.rowDetail)
                    .lineLimit(accessible ? nil : 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if running, let ends = session.expiresAt, ends > now {
                Text(timerInterval: now...ends, countsDown: true)
                    .textRole(.metric)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: accessible ? nil : 56, alignment: .trailing)
            }
        }
        .frame(minHeight: Spacing.minimumTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(style: style, running: running))
    }

    private var nodes: String {
        if nodeNames.isEmpty { return "every node" }
        if nodeNames.count <= 2 { return nodeNames.joined(separator: ", ") }
        return "\(nodeNames[0]) and \(nodeNames.count - 1) more"
    }

    private var detail: String {
        var parts = [nodes]
        if session.isActive(now: Date()), let ends = session.expiresAt {
            parts.append("ends \(TimeDisplay.clock(ends, mode: mode, locale: locale))")
        } else if let ended = session.endedAt ?? session.expiresAt {
            parts.append("ended \(TimeDisplay.relative(ended, now: Date(), locale: locale))")
        }
        if session.records > 0 { parts.append(session.records == 1 ? "1 record" : "\(session.records) records") }
        return parts.joined(separator: ", ")
    }

    private func spoken(style: StatusStyle, running: Bool) -> String {
        "Capture \(session.name), \(style.word), \(detail)"
    }
}

/// One node's collection: readiness word, trace and raw log, the reason when it cannot record.
struct EvidenceNodeRow: View {
    let row: EvidenceCoverageRow

    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        let style = StatusStyle.evidenceNode(row.state)
        StatusRow(
            style: style,
            title: row.name,
            detail: detail,
            reason: row.state.reason,
            accessibilityPhrase: "\(row.name), \(style.word), \(detail)"
        )
    }

    private var detail: String {
        var parts: [String] = []
        if row.capturing > 0, let ends = row.captureEndsAt {
            parts.append("capture until \(TimeDisplay.clock(ends, mode: mode, locale: locale))")
        } else if let enabled = row.traceEnabled {
            parts.append(enabled ? "trace on\(row.level.map { " at \($0)" } ?? "")" : "trace off")
        }
        if !row.sourcesKnown {
            parts.append("raw log unread")
        } else if row.sources.isEmpty {
            parts.append("no raw log")
        } else if let held = row.heldLines {
            parts.append(held == 1 ? "1 raw line held" : "\(held.formatted()) raw lines held")
        } else {
            parts.append(row.sources.count == 1 ? "1 raw log" : "\(row.sources.count) raw logs")
        }
        return parts.joined(separator: " · ")
    }
}

/// A connection record: how it ended, source to destination, protocol, bytes, duration and time.
struct EvidenceConnectionRow: View {
    let record: EvidenceConnRecord
    let nodeName: String

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        let close = EvidenceCloseState.of(record)
        let style = StatusStyle.evidenceClose(close)
        let time = record.startedAt.map { EvidenceText.stamp($0, mode: mode, locale: locale) }
        StatusRow(
            style: style,
            title: title,
            detail: detail,
            reason: reason(close),
            trailing: time,
            titleIsIdentifier: true,
            accessibilityPhrase: spoken(style: style, time: time)
        )
    }

    /// "198.51.100.150 \u{2192} api.example.org:443". At accessibility sizes the
    /// title keeps three lines and would be cut before the destination, so the
    /// destination alone leads and the source opens the detail line, which
    /// wraps without a limit there.
    private var title: String {
        let destination = record.destination.isEmpty ? "unknown destination" : record.destination
        if typeSize.isAccessibilitySize { return EvidenceText.breakableAddress(destination) }
        return "\(record.srcIP.isEmpty ? "unknown source" : record.srcIP) \u{2192} \(destination)"
    }

    private var protocolText: String {
        [record.network, record.sniffedProtocol].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var detail: String {
        var parts = typeSize.isAccessibilitySize ? ["from \(record.source.isEmpty ? "an unknown source" : record.source)", nodeName] : [nodeName]
        if !protocolText.isEmpty { parts.append(protocolText) }
        parts.append(EvidenceBytes.text(record))
        if let duration = EvidenceDuration.text(milliseconds: record.durationMS) { parts.append(duration) }
        return parts.joined(separator: " · ")
    }

    private func reason(_ close: EvidenceCloseState) -> String? {
        if record.stalledAt != nil { return "Went quiet in both directions." }
        guard close.severity == .warn || close.severity == .fail else { return nil }
        return record.closeError.isEmpty ? nil : record.closeError
    }

    private func spoken(style: StatusStyle, time: String?) -> String {
        let source = record.source.isEmpty ? "unknown source" : record.source
        let destination = record.destination.isEmpty ? "unknown destination" : record.destination
        var parts = ["\(source) to \(destination)", style.word, nodeName]
        if !protocolText.isEmpty { parts.append(protocolText) }
        parts.append(EvidenceBytes.spoken(record))
        if let duration = EvidenceDuration.text(milliseconds: record.durationMS) { parts.append("lasted \(duration)") }
        if let time { parts.append("started \(time)") }
        return parts.joined(separator: ", ")
    }
}

/// A context-menu item the token may not use: disabled, saying why.
struct EvidenceGatedButton: View {
    let title: String
    let systemImage: String
    let blocked: String?
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label {
                Text(title)
                if let blocked { Text(blocked) }
            } icon: {
                Image(systemName: systemImage)
            }
        }
        .disabled(blocked != nil)
    }
}

/// Nothing has loaded and there is no network path: say so instead of
/// showing placeholders that never fill (section 6.11).
struct EvidenceOfflineState: View {
    let noun: String

    var body: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Offline", systemImage: "wifi.slash")
            } description: {
                Text("\(noun) has not loaded yet. It loads when the phone is back online.")
            }
        }
    }
}

/// Pushes a page with no app link, then gets out of the way (demo only).
struct EvidenceDemoPusher: View {
    let route: EvidenceRoute
    @Environment(Router.self) private var router

    var body: some View {
        Color.clear.task {
            router.dismissPresented { router.push(.evidence(route)) }
        }
    }
}
