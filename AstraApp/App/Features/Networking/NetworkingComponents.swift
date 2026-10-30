import SwiftUI
import UIKit

// Pieces the Networking screens share: the status vocabulary for policies,
// deployments, profiles and firewalls, the whole-screen states, gated menu
// buttons, rule rows, the stable-list holder and copy helpers.

extension StatusStyle {
    static func networkingPolicyState(_ state: NetworkingPolicyState) -> StatusStyle {
        switch state {
        case .failed: StatusStyle(word: state.word, symbol: "xmark.circle.fill", tone: .fail)
        case .blocked: StatusStyle(word: state.word, symbol: "exclamationmark.triangle.fill", tone: .warn)
        case .planned: StatusStyle(word: state.word, symbol: "clock.arrow.circlepath", tone: .warn)
        case .notPlanned: StatusStyle(word: state.word, symbol: "circle.dashed", tone: .quiet)
        case .applied: StatusStyle(word: state.word, symbol: "checkmark.circle.fill", tone: .ok)
        case .off: StatusStyle(word: state.word, symbol: "minus.circle", tone: .quiet)
        }
    }

    /// A node on the Nodes view: its state, or "no policy" in the quiet style.
    static func networkingNodePolicy(_ row: NetworkingNodePolicyRow) -> StatusStyle {
        guard let state = row.state else { return StatusStyle(word: "no policy", symbol: "circle", tone: .quiet) }
        return .networkingPolicyState(state)
    }

    /// An outbound policy: off when disabled, otherwise the worst state among
    /// its target nodes, counted. `reach` is nil when the node documents did
    /// not load, and then nothing is claimed.
    static func networkingGroupPolicy(_ policy: NetworkingGroupPolicy, reach: NetworkingPolicyReach?) -> StatusStyle {
        if !policy.enabled { return StatusStyle(word: "disabled", symbol: "minus.circle", tone: .quiet) }
        guard let reach else { return StatusStyle(word: "state unknown", symbol: "questionmark.circle", tone: .quiet) }
        if reach.targets == 0 { return StatusStyle(word: "reaches no visible node", symbol: "circle.dashed", tone: .quiet) }
        if reach.failed > 0 { return StatusStyle(word: "\(NetworkingText.plural(reach.failed, "node")) failed to apply", symbol: "xmark.circle.fill", tone: .fail) }
        var parts: [String] = []
        if reach.notApplied > 0 { parts.append("\(NetworkingText.plural(reach.notApplied, "node")) not applied") }
        if reach.noDocument > 0 { parts.append("\(NetworkingText.plural(reach.noDocument, "node")) not planned") }
        if !parts.isEmpty { return StatusStyle(word: parts.joined(separator: ", "), symbol: "clock.arrow.circlepath", tone: .warn) }
        return StatusStyle(word: "applied", symbol: "arrow.up.forward.circle.fill", tone: .ok)
    }

    static func networkingDNS(_ health: NetworkingDNSHealth) -> StatusStyle {
        switch health {
        case .failing: StatusStyle(word: "failing", symbol: "xmark.octagon.fill", tone: .fail)
        case .warning: StatusStyle(word: "needs attention", symbol: "exclamationmark.triangle.fill", tone: .warn)
        case .pending(let word): StatusStyle(word: word, symbol: "hourglass", tone: .quiet)
        case .off(let word): StatusStyle(word: word, symbol: "minus.circle", tone: .quiet)
        case .ok(let word): StatusStyle(word: word, symbol: "checkmark.circle.fill", tone: .ok)
        }
    }

    static func networkingDDNS(_ health: DDNSHealth) -> StatusStyle {
        switch health {
        case .failing: StatusStyle(word: "failing", symbol: "xmark.octagon.fill", tone: .fail)
        case .stale: StatusStyle(word: "stale", symbol: "clock.badge.exclamationmark", tone: .warn)
        case .current: StatusStyle(word: "current", symbol: "checkmark.circle.fill", tone: .ok)
        }
    }

    static func networkingGeo(_ routing: NetworkingGeoRouting) -> StatusStyle {
        if !routing.lastError.isEmpty || routing.status == "failed" { return StatusStyle(word: "failed", symbol: "xmark.octagon.fill", tone: .fail) }
        if routing.lastAppliedAt == nil { return StatusStyle(word: "not applied", symbol: "circle.dashed", tone: .quiet) }
        return StatusStyle(word: "applied", symbol: "checkmark.circle.fill", tone: .ok)
    }

    static func networkingGuard(_ state: NetworkingGuardState) -> StatusStyle {
        switch state {
        case .failed: StatusStyle(word: state.word, symbol: "xmark.shield", tone: .fail)
        case .pending: StatusStyle(word: state.word, symbol: "clock.arrow.circlepath", tone: .warn)
        case .enforced: StatusStyle(word: state.word, symbol: "checkmark.shield", tone: .ok)
        case .observing: StatusStyle(word: state.word, symbol: "eye", tone: .quiet)
        case .legacy: StatusStyle(word: state.word, symbol: "shield.lefthalf.filled", tone: .quiet)
        }
    }

    static let networkingTunnel = StatusStyle(word: "", symbol: "point.topleft.down.to.point.bottomright.curvepath", tone: .quiet)
}

extension NetworkingDNSHealth {
    /// The sentence under the row; healthy states have none.
    var reason: String? {
        switch self {
        case .failing(let text), .warning(let text): text
        case .pending, .off, .ok: nil
        }
    }
}

/// The whole-screen states of a Networking screen: denied, companion
/// behind, a failed first load, offline before anything loaded, and
/// first-load placeholders. Never blank.
struct NetworkingListState<Value: Sendable, Content: View>: View {
    let state: ResourceState<Value>
    let noun: String
    let web: LatticeConsolePath
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content
    @Environment(NetworkMonitor.self) private var network
    @Environment(Router.self) private var router

    var body: some View {
        switch state {
        case .companionBehind(let surface):
            WholeScreenState {
                ContentUnavailableView {
                    Label("This app is behind the server", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("\(surface) could not be read.")
                } actions: {
                    Button("Reload", action: retry).buttonStyle(.bordered)
                    Button("Open on web") { router.openOnWeb(web) }
                }
            }
        default:
            // Polling stops offline, so a screen opened offline would keep its
            // placeholders forever and read as still loading.
            if !network.isSatisfied, state.value == nil, Self.isWaiting(state) {
                WholeScreenState {
                    ContentUnavailableView {
                        Label("Offline", systemImage: "wifi.slash")
                    } description: {
                        Text("There is no connection, and nothing was loaded here before it dropped. This screen loads when the connection returns.")
                    }
                }
            } else {
                ResourceView(state: state, noun: noun, retry: retry, content: content)
            }
        }
    }

    private static func isWaiting(_ state: ResourceState<Value>) -> Bool {
        switch state {
        case .idle, .loading, .failed: true
        case .loaded, .denied, .companionBehind: false
        }
    }
}

/// The row for a second resource a screen derives from, when it has no
/// data: its error, companion-behind or loading state, so derived words
/// never read as healthy over a resource that did not load.
struct NetworkingDependencyRow<Value: Sendable>: View {
    let state: ResourceState<Value>
    let noun: String
    let retry: () -> Void

    var body: some View {
        if state.value == nil {
            switch state {
            case .failed(let error, _, _):
                ErrorRow(message: "Could not load \(noun), so their state is unknown: \(error.localizedDescription)", retry: retry)
            case .companionBehind(let surface):
                CompanionBehindRow(surface: surface)
            case .denied(let scope):
                Label("\(noun.sentenceCased) need \(scope), so their state is unknown", systemImage: "lock")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: Spacing.minimumTarget)
            case .idle, .loading, .loaded:
                Label("Loading \(noun)", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: Spacing.minimumTarget)
            }
        }
    }
}

/// The error row for a list whose last refresh failed while earlier data stays.
struct NetworkingRefreshError<Value: Sendable>: View {
    let state: ResourceState<Value>
    let noun: String
    let retry: () -> Void

    var body: some View {
        if case .failed(let error, let last, _) = state, last != nil {
            ErrorRow(message: "Could not refresh \(noun): \(error.localizedDescription)", retry: retry)
        }
    }
}

/// A menu button that stays in place, disabled, with why as its subtitle (section 5.0).
struct NetworkingGatedButton: View {
    let title: String
    let systemImage: String
    /// "Needs dns:admin" or another reason; nil when allowed.
    let blocked: String?
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
            if let blocked { Text(blocked) }
        }
        .disabled(blocked != nil)
    }
}

/// A full-width action row in a list section, disabled with its reason below.
struct NetworkingActionRow: View {
    let title: String
    let systemImage: String
    var detail: String?
    let blocked: String?
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    // A disabled row in a list keeps a primary title; dim it as Settings does.
                    if blocked != nil { Text(title).foregroundStyle(.secondary) } else { Text(title) }
                    if let note = blocked ?? detail {
                        Text(note).textRole(.footnote)
                    }
                }
            } icon: {
                if blocked != nil { Image(systemName: systemImage).foregroundStyle(.tertiary) } else { Image(systemName: systemImage) }
            }
            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
        }
        .disabled(blocked != nil)
        .accessibilityHint(blocked ?? "")
    }
}

/// One outbound rule: the action's symbol and word, the traffic, and the remote with names.
struct NetworkingRuleRow: View {
    let rule: NetRule
    let names: (String) -> String

    var body: some View {
        StatusRow(
            style: StatusStyle(word: rule.disabled ? "\(rule.action), off" : rule.action,
                               symbol: rule.isAllow ? "checkmark.circle" : "nosign",
                               tone: .quiet),
            title: "\(rule.direction == "ingress" ? "From" : "To") \(NetworkingText.remote(rule.remote, names: names))",
            detail: NetworkingText.traffic(proto: rule.proto, ports: rule.ports),
            reason: nil,
            trailing: nil,
            accessibilityPhrase: "\(rule.action) \(rule.direction == "ingress" ? "from" : "to") \(NetworkingText.remote(rule.remote, names: names)), \(NetworkingText.traffic(proto: rule.proto, ports: rule.ports))\(rule.disabled ? ", rule off" : "")\(rule.comment.isEmpty ? "" : ", \(rule.comment)")"
        )
        .contextMenu {
            if !rule.comment.isEmpty { Text(rule.comment) }
            Button("Copy rule ID", systemImage: "number") { NetworkingCopy.copy(rule.id) }
        }
    }
}

/// Short words the screens share.
enum NetworkingText {
    /// "group DNS nodes", "node core-sjc-1", "10.0.0.0/8", "any address".
    static func remote(_ endpoint: NetEndpoint, names: (String) -> String) -> String {
        switch endpoint.kind {
        case "node": "node \(names(endpoint.nodeID))"
        case "group": "group \(names(endpoint.groupID))"
        case "zone": "zone \(endpoint.zoneID)"
        case "cidr": endpoint.cidr
        case "domain": endpoint.domain
        case "any", "": "any address"
        default: endpoint.displayText
        }
    }

    /// "tcp 80, 443", "udp, all ports", "any protocol".
    static func traffic(proto: String, ports: [Int]) -> String {
        let protoText = proto.isEmpty || proto == "any" ? "any protocol" : proto
        if proto == "any" || proto.isEmpty { return protoText }
        return ports.isEmpty ? "\(protoText), all ports" : "\(protoText) \(ports.map(String.init).joined(separator: ", "))"
    }

    /// "the whole fleet except 2", "Asia edge", "build-fra-4".
    static func target(_ selector: NetworkingTargetSelector, groupNames: [String: String], nodeName: (String) -> String) -> String {
        var parts: [String] = []
        if selector.all { parts.append("whole fleet") }
        parts += selector.groups.map { groupNames[$0] ?? $0 }
        parts += selector.nodes.map(nodeName)
        var text = parts.isEmpty ? "no target" : ListFormatter.localizedString(byJoining: parts)
        if !selector.exclude.isEmpty {
            text += selector.exclude.count == 1 ? " except \(nodeName(selector.exclude[0]))" : " except \(selector.exclude.count) nodes"
        }
        return text
    }

    static func plural(_ count: Int, _ one: String, _ many: String? = nil) -> String {
        count == 1 ? "1 \(one)" : "\(count) \(many ?? one + "s")"
    }

    /// "3f9a…c210", for a plan hash shown as a fact rather than a decision.
    static func shortHash(_ sha: String) -> String {
        sha.count > 12 ? "\(sha.prefix(4))…\(sha.suffix(4))" : sha
    }
}

/// The query error under a search field, so a typo never reads as an empty list.
struct NetworkingQueryError: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Color.statusWarnText)
                .frame(minHeight: Spacing.minimumTarget)
        }
    }
}

/// A fleet-wide NetGuard section a node-confined token cannot read.
struct NetworkingConfinedRow: View {
    let what: String

    var body: some View {
        Label {
            Text("Hidden: \(what) are fleet-wide, so the server answers them only to a token without a node allowlist.")
        } icon: {
            Image(systemName: "lock").foregroundStyle(Color.statusQuiet)
        }
        .foregroundStyle(.secondary)
        .frame(minHeight: Spacing.minimumTarget)
    }
}

/// Holds a poll's reorder, insert or removal while the list is in use, and
/// behind a row while VoiceOver runs (section 5.0). Values inside rows that
/// stay put apply at once.
@MainActor @Observable
final class NetworkingStableList<Row: Identifiable & Sendable> where Row.ID: Sendable {
    private(set) var shown: [Row] = []
    private(set) var held: [Row]?
    @ObservationIgnored private var lastActivity = Date.distantPast
    @ObservationIgnored private var hasShown = false
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var voiceOver = false
    @ObservationIgnored private var release: Task<Void, Never>?

    var pendingCount: Int {
        guard let held else { return 0 }
        let moved = zip(shown.map(\.id), held.map(\.id)).contains { $0 != $1 }
        return max(Set(shown.map(\.id)).symmetricDifference(Set(held.map(\.id))).count, moved ? 1 : 0)
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

    /// `force` applies at once: pull to refresh, a filter or query change, a confirmed write.
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

/// Copies values and app links.
enum NetworkingCopy {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    static func link(_ deepLink: LatticeDeepLink, fallback: String) -> String {
        deepLink.customURL?.absoluteString ?? fallback
    }
}

/// The trailing "More" menu every Networking object screen has: its own
/// items first, then Copy link and Open on web.
struct NetworkingMoreMenu<Items: View>: View {
    var link: String?
    let web: LatticeConsolePath
    @ViewBuilder var items: Items
    @Environment(Router.self) private var router

    var body: some View {
        Menu {
            items
            Section {
                if let link {
                    Button("Copy link", systemImage: "link") { NetworkingCopy.copy(link) }
                }
                Button("Open on web", systemImage: "safari") { router.openOnWeb(web) }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }
}

extension NetworkingMoreMenu where Items == EmptyView {
    init(link: String?, web: LatticeConsolePath) {
        self.init(link: link, web: web) { EmptyView() }
    }
}

/// A node mention: a row that pushes NodeDetail, with its honesty when known.
struct NetworkingNodeLink: View {
    let nodeID: String
    var label: String?
    @Environment(NodeDirectory.self) private var nodes

    var body: some View {
        NavigationLink(value: AppRoute.fleet(.node(id: nodeID))) {
            if let node = nodes.nodes[nodeID] {
                if let label {
                    LabeledContent(label) { Text(node.displayName).foregroundStyle(.secondary) }
                        .frame(minHeight: Spacing.minimumTarget)
                } else {
                    NodeRow(node: node, provider: nil)
                }
            } else {
                LabeledContent(label ?? "Node") { Text(nodeID).font(TextRole.identifierInRow.font).foregroundStyle(.secondary) }
                    .frame(minHeight: Spacing.minimumTarget)
            }
        }
    }
}
