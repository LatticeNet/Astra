import SwiftUI
import UIKit

// Pieces the Fleet screens share: the node context menu with its glance
// preview, menu buttons that stay visible when the token lacks a scope, and
// the copy helpers. Shared object rows come from Design/ObjectRows.swift.

/// A menu or toolbar button that stays in place, disabled, with the missing
/// scope as its subtitle (section 5.0).
struct FleetGatedButton: View {
    let title: String
    let systemImage: String
    /// "node:admin" when the token lacks it; nil when the action is allowed.
    let missing: String?
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            if let missing {
                Text(title)
                Text("Needs \(missing)")
                Image(systemName: systemImage)
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        .disabled(missing != nil)
    }
}

enum FleetCopy {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    static func nodeLink(_ id: String, tab: NodeDetailTab? = nil) -> String {
        LatticeDeepLink.node(id: id, view: tab).customURL?.absoluteString ?? "lattice://nodes/\(id)"
    }

    static func groupLink(_ id: String) -> String {
        LatticeDeepLink.group(id: id).customURL?.absoluteString ?? "lattice://groups/\(id)"
    }
}

/// The compact preview a node's context menu shows: its row and a few facts.
struct FleetNodeGlance: View {
    let record: FleetNodeRecord

    var body: some View {
        let node = record.node
        VStack(alignment: .leading, spacing: Spacing.s) {
            NodeRow(node: node)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if let ip = node.publicIP, !ip.isEmpty { fact("Public IP", ip, mono: true) }
                if !record.facts.provider.isEmpty { fact("Provider", record.facts.provider) }
                if let agent = node.agentVersion, !agent.isEmpty { fact("Agent", agent) }
                if let os = node.hostFacts.platform { fact("System", [os, node.hostFacts.platformVersion, node.hostFacts.arch].compactMap { $0 }.joined(separator: " ")) }
            }
        }
        .padding(Spacing.l)
        .frame(width: 320, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private func fact(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: Spacing.s)
            Text(value).font(mono ? TextRole.identifierInRow.font : .subheadline)
        }
        .font(.subheadline)
    }
}

/// The context menu every node row carries: Open, Copy link, Copy ID,
/// Copy IP, Open terminal on web, Open on web, and Disable or Enable
/// (shown disabled with the missing scope when the token cannot).
struct FleetNodeMenu: ViewModifier {
    let record: FleetNodeRecord

    @Environment(FleetStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(ActionRunner.self) private var runner

    func body(content: Content) -> some View {
        let node = record.node
        let ref = FleetIntents.nodeRef(node)
        let missing = store.missing("node:admin")
        content.contextMenu {
            Button("Open", systemImage: "arrow.right.circle") { router.push(.fleet(.node(id: node.id))) }
            Button("Copy link", systemImage: "link") { FleetCopy.copy(FleetCopy.nodeLink(node.id)) }
            Button("Copy ID", systemImage: "number") { FleetCopy.copy(node.id) }
            if let ip = node.publicIP, !ip.isEmpty {
                Button("Copy IP", systemImage: "doc.on.doc") { FleetCopy.copy(ip) }
            }
            Button("Open terminal on web", systemImage: "terminal") {
                router.openOnWeb(LatticeConsolePath(path: "/terminal", query: [URLQueryItem(name: "node_id", value: node.id)]))
            }
            Button("Open on web", systemImage: "safari") { router.openOnWeb(.node(id: node.id)) }
            Divider()
            if node.honesty == .disabled {
                FleetGatedButton(title: "Enable", systemImage: "checkmark.circle", missing: missing) {
                    Task { await runner.run(FleetIntents.enable(ref)) }
                }
            } else {
                FleetGatedButton(title: "Disable", systemImage: "minus.circle", missing: missing, role: .destructive) {
                    Task { await runner.run(FleetIntents.disable(ref)) }
                }
            }
        } preview: {
            FleetNodeGlance(record: record)
        }
    }
}

extension View {
    func fleetNodeMenu(_ record: FleetNodeRecord) -> some View {
        modifier(FleetNodeMenu(record: record))
    }

    /// The trailing swipe on a node row: Disable (T3) or Enable (T2), never a full swipe.
    func fleetNodeSwipe(_ node: LatticeNode, canAdmin: Bool, runner: ActionRunner) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canAdmin {
                let ref = FleetIntents.nodeRef(node)
                if node.honesty == .disabled {
                    Button("Enable", systemImage: "checkmark.circle") { Task { await runner.run(FleetIntents.enable(ref)) } }
                        .tint(.accentFill)
                } else {
                    Button("Disable", systemImage: "minus.circle") { Task { await runner.run(FleetIntents.disable(ref)) } }
                        .tint(.destructiveFill)
                }
            }
        }
    }
}

/// A whole-list state for Fleet lists: denied, companion behind, a failed
/// first load, and first-load placeholders. Content renders otherwise.
struct FleetListState<Value: Sendable, Content: View>: View {
    let state: ResourceState<Value>
    let noun: String
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        // Polling stops while the path is unsatisfied, so a screen opened offline
        // would otherwise keep its placeholders forever and read as still loading.
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

    private static func isWaiting(_ state: ResourceState<Value>) -> Bool {
        switch state {
        case .idle, .loading, .failed: true
        case .loaded, .denied, .companionBehind: false
        }
    }
}

/// "Updated 12 s ago" under a list, in the style of its state.
struct FleetFooter<Value: Sendable>: View {
    let state: ResourceState<Value>
    var interval: TimeInterval = 60

    var body: some View {
        FreshnessFooter(state: state, interval: interval)
    }
}

/// The error row for a section whose last refresh failed while earlier data stays.
struct FleetRefreshError<Value: Sendable>: View {
    let state: ResourceState<Value>
    let noun: String
    let retry: () -> Void

    var body: some View {
        if case .failed(let error, let last, _) = state, last != nil {
            ErrorRow(message: "Could not refresh \(noun): \(error.localizedDescription)", retry: retry)
        }
    }
}

/// The relative age in the short form rows use ("12 s", "3 h").
enum FleetAge {
    static func short(_ date: Date?, now: Date = Date()) -> String? {
        date.map { RelativeDateFormatter.shortDuration(now.timeIntervalSince($0)) }
    }
}
