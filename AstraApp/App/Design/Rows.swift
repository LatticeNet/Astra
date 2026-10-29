import SwiftUI
import UIKit

/// The one row for objects with a state (section 4.5). The layout follows the
/// Dynamic Type category, never the content width, so a whole list switches
/// together. Every state shows its symbol and its word (4.2): the word leads
/// the detail line, colored for problems and secondary for healthy and quiet
/// states (4.1). `trailing` is for a metric, never the state word.
struct StatusRow: View {
    let style: StatusStyle
    let title: String
    var detail: String?
    var reason: String?
    /// Lines the reason may take below accessibility sizes; nil shows it in
    /// full, for a reason that is the only place a fix is named.
    var reasonLineLimit: Int? = 2
    var trailing: String?
    /// Ids, hashes and IPs truncate in the middle; names never do.
    var titleIsIdentifier = false
    /// The vocabulary phrase ("fra-2, offline for 12 minutes"); defaults to title and word.
    var accessibilityPhrase: String?

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .title3) private var glyphWidth: CGFloat = 28

    /// Server reasons embed RFC 3339 stamps; show them in the chosen zone.
    private var shownReason: String? {
        reason.map { TimeDisplay.localizingStamps(in: $0, mode: mode, locale: locale) }
    }

    var body: some View {
        let accessible = typeSize.isAccessibilitySize
        let layout = accessible
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.m))
        layout {
            if !accessible {
                StatusGlyph(style: style)
                    .frame(width: glyphWidth)
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                titleLine(accessible: accessible)
                if let statusLine {
                    statusLine
                        .textRole(.rowDetail)
                        .lineLimit(accessible ? nil : 2)
                }
                if let reason = shownReason {
                    Text(reason)
                        .textRole(.rowReason(style.tone.word))
                        .lineLimit(accessible ? nil : reasonLineLimit)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing {
                Text(trailing)
                    .textRole(.metric)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .frame(minHeight: Spacing.minimumTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    @ViewBuilder
    private func titleLine(accessible: Bool) -> some View {
        if accessible {
            Text("\(Text(Image(systemName: style.symbol)).foregroundStyle(style.tone.glyph)) \(title)")
                .textRole(.rowTitle)
                .lineLimit(3)
        } else {
            Text(title)
                .textRole(.rowTitle)
                .lineLimit(2)
                .truncationMode(titleIsIdentifier ? .middle : .tail)
        }
    }

    /// The state word followed by the detail, or whichever of the two exists.
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

    private var spokenLabel: String {
        let phrase = accessibilityPhrase ?? "\(title), \(style.word)"
        return [phrase, shownReason, trailing].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Label and value. Long monospaced values wrap by character; the whole row
/// copies the value.
struct DetailRow: View {
    let label: String
    let value: String
    var monospaced = false
    var secondary: String?
    var copyable = true

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if copyable {
            Button {
                UIPasteboard.general.string = value
            } label: {
                content
            }
            .tint(.primary)
            .accessibilityHint("Copies the value")
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = value }
            }
        } else {
            content
        }
    }

    private var content: some View {
        let accessible = typeSize.isAccessibilitySize
        let layout = accessible
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.m))
        return layout {
            Text(label)
                .foregroundStyle(accessible ? .secondary : .primary)
            if !accessible { Spacer(minLength: Spacing.s) }
            VStack(alignment: accessible ? .leading : .trailing, spacing: Spacing.xxs) {
                Text(monospaced ? Self.breakable(value) : value)
                    .font(monospaced ? TextRole.identifierInDetail.font : .body)
                    .foregroundStyle(accessible ? .primary : .secondary)
                    .multilineTextAlignment(accessible ? .leading : .trailing)
                if let secondary {
                    Text(secondary).textRole(.stamp)
                }
            }
        }
        .frame(minHeight: Spacing.minimumTarget)
        .accessibilityElement(children: .combine)
    }

    /// Inserts zero-width spaces so digests and addresses wrap anywhere.
    static func breakable(_ value: String) -> String {
        value.map(String.init).joined(separator: "\u{200B}")
    }
}

/// A metric with a 4 pt inline bar, colored only past its threshold.
struct ValueBarRow: View {
    let label: String
    let value: String
    /// 0 to 1, or nil when the value is unknown (no bar is drawn).
    let fraction: Double?
    var threshold: Double = 0.85

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let accessible = typeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                Spacer(minLength: Spacing.s)
                if !accessible { bar.frame(width: 72) }
                Text(value).textRole(.metric).foregroundStyle(.secondary)
            }
            if accessible { bar }
        }
        .frame(minHeight: Spacing.minimumTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }

    @ViewBuilder
    private var bar: some View {
        if let fraction {
            let clamped = min(max(fraction, 0), 1)
            Capsule()
                .fill(Color(uiColor: .tertiarySystemFill))
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(clamped >= threshold ? Color.statusWarnFill : Color.statusQuiet)
                            .frame(width: proxy.size.width * clamped)
                    }
                }
                .frame(height: 4)
        }
    }
}

/// A web-only destination: "Open on web" with the console path as a footnote.
struct WebLinkRow: View {
    var title = "Open on web"
    let path: LatticeConsolePath
    @Environment(Router.self) private var router

    var body: some View {
        Button {
            router.openOnWeb(path)
        } label: {
            HStack(spacing: Spacing.m) {
                Image(systemName: "safari")
                    .foregroundStyle(Color.accentText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title).foregroundStyle(Color.accentText)
                    Text(path.display).textRole(.footnote).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Spacing.minimumTarget)
        }
        .accessibilityHint("Opens the console in your browser")
    }
}

extension LatticeConsolePath {
    /// "/monitoring?view=checks&open=c-12", for footnotes.
    var display: String {
        var components = URLComponents()
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        return components.string ?? path
    }
}

/// A section the token cannot read (section 5.0). Never removed, never blank.
struct ScopeDeniedRow: View {
    let scope: String
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label {
                Text(AccessState.denied(scope: scope).text)
            } icon: {
                Image(systemName: "lock").foregroundStyle(Color.statusQuiet)
            }
            .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.l) { actions }
                VStack(alignment: .leading, spacing: Spacing.s) { actions }
            }
            // Borderless, so each button keeps its own hit area in a list row.
            .buttonStyle(.borderless)
            .font(.subheadline)
        }
        .frame(minHeight: Spacing.minimumTarget)
    }

    @ViewBuilder
    private var actions: some View {
        Button("Token scopes") { router.openSettings([.page(.scopes)]) }
        Button("Manage tokens on web") { router.openOnWeb(.tokens) }
    }
}

/// The freshness line under a section (sections 4.2 and 5.0).
struct FreshnessFooter: View {
    let loadedAt: Date?
    var isUpdating = false
    var lastAttemptFailed = false
    var interval: TimeInterval = 60

    @Environment(NetworkMonitor.self) private var network
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let state = accessState(now: context.date)
            Label {
                Text(state.text)
            } icon: {
                if let symbol = state.symbol {
                    Image(systemName: symbol).foregroundStyle(state.tone.glyph)
                }
            }
            .labelStyle(FootnoteLabelStyle())
            .foregroundStyle(state.tone.isProblem ? state.tone.word : .secondary)
            .textRole(.stamp)
        }
    }

    private func accessState(now: Date) -> AccessState {
        let time = loadedAt.map { TimeDisplay.clock($0, mode: mode, locale: locale) }
        if !network.isSatisfied { return .offline(since: time) }
        if isUpdating { return .updating }
        // Nothing loaded: the first read is still running unless it failed.
        guard let loadedAt else { return lastAttemptFailed ? .stale(asOf: nil) : .updating }
        if lastAttemptFailed || now.timeIntervalSince(loadedAt) > 3 * interval { return .stale(asOf: time) }
        return .fresh(age: TimeDisplay.duration(now.timeIntervalSince(loadedAt), locale: locale))
    }
}

extension FreshnessFooter {
    init<Value>(state: ResourceState<Value>, interval: TimeInterval) {
        var failed = false
        if case .failed = state { failed = true }
        self.init(loadedAt: state.loadedAt, isUpdating: state.isLoading && state.value != nil, lastAttemptFailed: failed, interval: interval)
    }
}

private struct FootnoteLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            configuration.icon
            configuration.title
        }
    }
}

/// A failed refresh at the top of its section, with the data kept below.
struct ErrorRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label {
                Text(message).foregroundStyle(Color.statusFailText)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusFailFill)
            }
            Button("Retry", systemImage: "arrow.clockwise", action: retry)
                .font(.subheadline)
        }
        .frame(minHeight: Spacing.minimumTarget)
    }
}

/// Held reorders and inserts while the list is busy or VoiceOver is running.
struct PendingUpdatesRow: View {
    let count: Int
    let show: () -> Void

    var body: some View {
        Button(action: show) {
            HStack {
                Text(count == 1 ? "1 update" : "\(count) updates")
                Spacer()
                Text("Show").foregroundStyle(Color.accentText)
            }
            .frame(minHeight: Spacing.minimumTarget)
        }
        .tint(.primary)
        .accessibilityLabel(count == 1 ? "1 update. Show" : "\(count) updates. Show")
    }
}

/// "Showing approvals only. Show all"
struct FilterStateRow: View {
    let text: String
    let showAll: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Side by side at accessibility sizes, the button squeezes the
        // sentence into hyphenated fragments; stack them instead.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.s))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        layout {
            Text(text).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Show all", action: showAll)
        }
        .frame(minHeight: Spacing.minimumTarget)
    }
}
