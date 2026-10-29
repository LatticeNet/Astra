import SwiftUI
import UIKit

// Pieces the Platform screens share: the plugin, route, share, token and
// bucket vocabulary, whole-screen states, gated menu buttons, copy helpers
// and the read-only, find-enabled text view for store values.

extension StatusStyle {
    /// A plugin's health. Without the lifecycle read an active plugin reads
    /// "active" in the quiet style, never "running".
    static func platformPlugin(_ row: PlatformPluginRow) -> StatusStyle {
        switch row.health {
        case .running: StatusStyle(word: "running", symbol: "checkmark.circle.fill", tone: .ok)
        case .failed: StatusStyle(word: "failed", symbol: "xmark.octagon.fill", tone: .fail)
        case .missing: StatusStyle(word: "bundle missing", symbol: "shippingbox.and.arrow.backward", tone: .fail)
        case .stopped: StatusStyle(word: "stopped", symbol: "stop.circle", tone: .warn)
        case .disabled: StatusStyle(word: "disabled", symbol: "minus.circle", tone: .quiet)
        case .pending: StatusStyle(word: "waiting to activate", symbol: "hourglass", tone: .quiet)
        case .unknown:
            row.status == "active"
                ? StatusStyle(word: "active", symbol: "puzzlepiece.extension", tone: .quiet)
                : StatusStyle(word: row.status.isEmpty ? "unknown" : row.status, symbol: "questionmark.circle", tone: .quiet)
        }
    }

    static func platformRoute(_ state: PlatformRouteState) -> StatusStyle {
        switch state {
        case .serving: StatusStyle(word: "serving", symbol: "checkmark.circle.fill", tone: .ok)
        case .disabled: StatusStyle(word: "disabled", symbol: "minus.circle", tone: .quiet)
        case .expired: StatusStyle(word: "expired", symbol: "clock.badge.xmark", tone: .warn)
        }
    }

    static func platformShare(_ state: PlatformShareState) -> StatusStyle {
        switch state {
        case .live: StatusStyle(word: "live", symbol: "checkmark.circle.fill", tone: .ok)
        case .expiring: StatusStyle(word: "expires soon", symbol: "calendar.badge.clock", tone: .warn)
        case .paused: StatusStyle(word: "paused", symbol: "pause.circle", tone: .quiet)
        case .expired: StatusStyle(word: "expired", symbol: "clock.badge.xmark", tone: .warn)
        }
    }

    static func platformToken(_ token: PlatformStorageToken) -> StatusStyle {
        token.isRevoked
            ? StatusStyle(word: "revoked", symbol: "slash.circle", tone: .quiet)
            : StatusStyle(word: "active", symbol: "key.fill", tone: .ok)
    }

    static func platformBucket(_ entry: PlatformBucketInventoryEntry) -> StatusStyle {
        if entry.reserved { return StatusStyle(word: "reserved", symbol: "lock", tone: .quiet) }
        switch PlatformBucketOwner.of(entry) {
        case .operator: return StatusStyle(word: "", symbol: entry.kind == "kv" ? "tablecells" : "doc.on.doc", tone: .quiet)
        case .plugin: return StatusStyle(word: "", symbol: "puzzlepiece.extension", tone: .quiet)
        case .server: return StatusStyle(word: "", symbol: "server.rack", tone: .quiet)
        case .agent: return StatusStyle(word: "", symbol: "arrow.down.circle", tone: .quiet)
        }
    }
}

extension PlatformStorageKind {
    /// "KV" or "static", inside a sentence.
    var platformNoun: String { self == .kv ? "KV" : "static" }
}

extension PlatformCapabilityRisk {
    /// "Host risk", for detail rows.
    var platformTitle: String {
        switch self {
        case .read: "Read"
        case .write: "Write"
        case .host: "Host"
        case .unknown: "Unknown"
        }
    }

    var platformSentence: String {
        switch self {
        case .read: "Reads data only."
        case .write: "Writes data it is allowed to."
        case .host: "Can change hosts or reach the network; needs a trusted publisher's signature."
        case .unknown: "Not in this app's risk table."
        }
    }
}

extension PlatformPluginHealth {
    /// The section heading Plugins groups by.
    var platformHeading: String {
        switch self {
        case .failed: "Failed"
        case .missing: "Bundle missing"
        case .stopped: "Stopped"
        case .pending: "Waiting to activate"
        case .unknown: "Active"
        case .running: "Running"
        case .disabled: "Disabled"
        }
    }
}

/// The whole-screen states: offline before anything loaded, then the
/// foundation's denied, companion-behind, failed and loading states.
struct PlatformListState<Value: Sendable, Content: View>: View {
    let state: ResourceState<Value>
    let noun: String
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        // Polling stops offline, so a screen opened offline would otherwise
        // keep its placeholders and read as still loading.
        if !network.isSatisfied, state.value == nil, Self.isWaiting(state) {
            PlatformOfflineState()
        } else {
            ResourceView(state: state, noun: noun, retry: retry, content: content)
        }
    }

    static func isWaiting(_ state: ResourceState<Value>) -> Bool {
        switch state {
        case .idle, .loading, .failed: true
        case .loaded, .denied, .companionBehind: false
        }
    }
}

struct PlatformOfflineState: View {
    var body: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Offline", systemImage: "wifi.slash")
            } description: {
                Text("There is no connection, and nothing was loaded here before it dropped. This screen loads when the connection returns.")
            }
        }
    }
}

/// The error row for a section whose last refresh failed while earlier data stays.
struct PlatformRefreshError<Value: Sendable>: View {
    let state: ResourceState<Value>
    let noun: String
    let retry: () -> Void

    var body: some View {
        if case .failed(let error, let last, _) = state, last != nil {
            ErrorRow(message: "Could not refresh \(noun): \(error.localizedDescription)", retry: retry)
        }
    }
}

/// A section's state when it is not loaded content: denied, behind, failed
/// with nothing to show, or still loading.
struct PlatformSectionState<Value: Sendable>: View {
    let state: ResourceState<Value>
    let noun: String
    let retry: () -> Void

    var body: some View {
        switch state {
        case .denied(let scope):
            ScopeDeniedRow(scope: scope)
        case .companionBehind(let surface):
            CompanionBehindRow(surface: surface)
        case .failed(let error, nil, _):
            ErrorRow(message: "Could not load \(noun): \(error.localizedDescription)", retry: retry)
        case .idle, .loading(nil, _):
            LoadingRows(label: "Loading \(noun)", count: 2)
        default:
            PlatformRefreshError(state: state, noun: noun, retry: retry)
        }
    }
}

/// Sections 5.0 and 6.11: while the data behind a verdict is stale, failed
/// or offline, the verdict stops claiming health and says why it cannot.
enum PlatformConfidence {
    static let style = StatusStyle(word: "cannot confirm", symbol: "questionmark.circle", tone: .quiet)

    /// Nil when the data is fresh enough to claim health; otherwise the
    /// sentence that replaces the claim.
    static func doubt<Value>(_ state: ResourceState<Value>, offline: Bool, now: Date, interval: TimeInterval = 60,
                             mode: TimeZoneMode, locale: Locale) -> String? {
        if offline {
            return state.loadedAt.map { "Cannot confirm. Offline since \(TimeDisplay.clock($0, mode: mode, locale: locale))." } ?? "Cannot confirm. Offline."
        }
        switch Freshness.of(state, now: now, interval: interval) {
        case .fresh:
            return nil
        case .stale(let since):
            if case .failed = state { return "Cannot confirm. The last refresh failed." }
            return since.map { "Cannot confirm. Last good refresh \(TimeDisplay.duration(now.timeIntervalSince($0), locale: locale)) ago." } ?? "Cannot confirm."
        case .unknown:
            return state.value == nil ? "Cannot confirm." : nil
        }
    }
}

/// A menu button that stays visible when the token cannot run it, with the
/// scope it needs as its second line (section 5.0).
struct PlatformGatedButton: View {
    let title: String
    let systemImage: String
    /// "plugin:admin" when the token lacks it; nil when allowed.
    let missing: String?
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            if let missing {
                Text(title)
                Text(missing.hasPrefix("Needs") ? missing : "Needs \(missing)")
                Image(systemName: systemImage)
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        .disabled(missing != nil)
    }
}

/// An action row inside a list: a full-width button with a second line
/// saying why it is off, at least 44 pt tall. Icon and title share one
/// colour, as FleetActionRow does: secondary when off, the fail text colour
/// when destructive, the accent otherwise.
struct PlatformActionRow: View {
    let title: String
    let systemImage: String
    var note: String?
    var missing: String?
    var role: ButtonRole?
    let action: () -> Void

    private var reason: String? {
        missing.map { $0.hasPrefix("Needs") || $0.hasPrefix("No ") ? $0 : "Needs \($0)" }
    }

    private var tint: Color {
        if missing != nil { return .secondary }
        return role == .destructive ? .statusFailText : .accentText
    }

    var body: some View {
        Button(role: role, action: action) {
            Label {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title).foregroundStyle(tint)
                    if let line = reason ?? note {
                        Text(line).textRole(.footnote)
                    }
                }
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(missing != nil)
        .accessibilityHint(reason.map { "Unavailable. \($0)." } ?? "")
    }
}

enum PlatformCopy {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    static func pluginLink(_ id: String) -> String {
        LatticeDeepLink.plugin(id: id).customURL?.absoluteString ?? "lattice://plugins/\(id)"
    }

    static func shareLink(_ id: String) -> String {
        LatticeDeepLink.share(id: id).customURL?.absoluteString ?? "lattice://shares/\(id)"
    }
}

enum PlatformFormat {
    /// Hostnames, paths, keys and ids break after ".", "/", ":" and "-"
    /// instead of being hyphenated mid-word at large text sizes.
    static func breakable(_ identifier: String) -> String {
        var out = ""
        for character in identifier {
            out.append(character)
            if ".:/-_".contains(character) { out.append("\u{200B}") }
        }
        return out
    }

    static func bytes(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "Not reported" }
        return ByteFormatter.bytes(UInt64(value))
    }

    static func bytes(_ value: UInt64?) -> String {
        value.map(ByteFormatter.bytes) ?? "Not reported"
    }

    /// "41 ms", "1.4 s".
    static func latency(_ seconds: Double) -> String {
        if seconds <= 0 { return "0 ms" }
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        return String(format: "%.1f s", seconds)
    }

    static func count(_ value: UInt64) -> String {
        value.formatted(.number.notation(.compactName))
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0...1)))
    }

    /// "Every 6 hours".
    static func interval(hours: Int) -> String {
        switch hours {
        case ..<1: "Server default"
        case 1: "Every hour"
        default: "Every \(hours) hours"
        }
    }
}

/// The console route of a store bucket (the console reads `kind` and `bucket`).
extension LatticeConsolePath {
    static func platformStore(kind: String? = nil, bucket: String? = nil) -> LatticeConsolePath {
        var query: [URLQueryItem] = []
        if let kind { query.append(URLQueryItem(name: "kind", value: kind)) }
        if let bucket { query.append(URLQueryItem(name: "bucket", value: bucket)) }
        return LatticeConsolePath(path: "/platform/store", query: query)
    }

    static func platformPublishing(view: String? = nil) -> LatticeConsolePath {
        LatticeConsolePath(path: "/platform/publishing", query: view.map { [URLQueryItem(name: "view", value: $0)] } ?? [])
    }

    static let platformPlugins = LatticeConsolePath(path: "/platform/plugins")
    static let platformSystem = LatticeConsolePath(path: "/platform/system")
}

/// A read-only text view with the system find bar, for store values (M8-10).
/// The text lives only in this view; nothing writes it anywhere else.
struct PlatformFindableText: UIViewRepresentable {
    let text: String
    @Binding var finding: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.isFindInteractionEnabled = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.font = UIFontMetrics(forTextStyle: .callout).scaledFont(for: .monospacedSystemFont(ofSize: 16, weight: .regular))
        view.textColor = .label
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        if finding {
            view.findInteraction?.presentFindNavigator(showingReplace: false)
            DispatchQueue.main.async { finding = false }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? max(uiView.bounds.width, 280)
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }
}
