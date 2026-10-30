import SwiftUI

/// M13-04 Line: the line's facts, its chain hops with the path state between
/// each pair of nodes (each opens PathDetail), and the identities bound to
/// it. Plans and rollouts stay on the web. Gate vpncore:read or proxy:read,
/// unconfined; path states need monitor:read.
struct VPNLineDetailScreen: View {
    let id: String

    @Environment(VPNStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(NodeDirectory.self) private var nodes
    @Environment(Router.self) private var router
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    @State private var paths = VPNLinePathsModel()

    var body: some View {
        content
            .navigationTitle(store.line(id: id)?.line.displayName ?? "Line")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(store.line(id: id).map { VPNStyle.line(VPNLineState.of($0.line)).word } ?? "")
            .toolbar { toolbar }
            .polling(.paths, version: changes.version([.vpn, .paths])) {
                await nodes.refreshIfOlder(than: 60)
                if store.users.value == nil { await store.refreshUsers() }
                let ok = await store.refreshLines()
                await paths.refresh(session: session)
                return ok
            }
    }

    @ViewBuilder
    private var content: some View {
        if !network.isSatisfied, store.lines.value == nil, !store.lines.isLoading, store.readMissing == nil {
            VPNOfflineView(noun: "The line", retry: refresh)
        } else {
            ResourceView(state: store.lines, noun: "the line", retry: refresh) { groups in
                if let entry = VPNLineEntry.find(id, in: groups) {
                    detail(entry, groups: groups)
                } else {
                    notFound
                }
            }
        }
    }

    // MARK: Detail

    private func detail(_ entry: VPNLineEntry, groups: [VPNLineGroup]) -> some View {
        let line = entry.line
        let state = VPNLineState.of(line)
        let style = VPNStyle.line(state)
        let chain = VPNLineChain.of(line, chains: store.chains.value ?? [])
        return List {
            VPNRefreshError(state: store.lines, noun: "the line", retry: refresh)
            Section {
                StatusRow(style: style, title: line.displayName,
                          detail: [entry.nodeName, VPNLineFormat.shape(line)].filter { !$0.isEmpty }.joined(separator: " · "),
                          reason: headerReason(line, state: state), reasonLineLimit: nil,
                          accessibilityPhrase: "Line \(line.displayName) on \(entry.nodeName), \(style.word)")
            }
            if let chain {
                chainSection(chain, line: line)
            } else {
                routeSection(line, groups: groups)
            }
            factsSection(entry)
            usersSection(line)
            Section {
                WebLinkRow(title: "Chain plans and rollouts on web", path: .vpnLines)
            } footer: {
                FreshnessFooter(state: store.lines, interval: Polling.paths.interval(lowPower: false))
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await store.refreshLines()
            await paths.refresh(session: session)
        }
        .vpnDemoScroll(ready: store.users.value != nil && !paths.state.isLoading)
    }

    private func headerReason(_ line: VPNLine, state: VPNLineState) -> String? {
        switch state {
        case .configError: line.lastError.isEmpty ? nil : line.lastError
        case .down, .restarting, .unproven: line.serviceNote.isEmpty ? nil : line.serviceNote
        case .pending: "The configuration change is not applied yet."
        case .stale: "The node has not reported this line recently."
        case .running, .configOK: nil
        }
    }

    // MARK: Chain

    @ViewBuilder
    private func chainSection(_ chain: VPNLineChain, line: VPNLine) -> some View {
        let hops = chain.chain.hops
        let first = hops.first.map { nodes.name(for: $0.nodeID) } ?? ""
        let last = hops.last.map { nodes.name(for: $0.nodeID) } ?? ""
        let style = VPNStyle.chain(chain.state)
        Section {
            StatusRow(style: style, title: hops.count > 1 ? "\(first) to \(last)" : first,
                      detail: hops.count == 1 ? "1 hop" : "\(hops.count) hops",
                      reason: chain.problem.map { "\($0.prefix(1).uppercased())\($0.dropFirst())." }, reasonLineLimit: nil,
                      accessibilityPhrase: "Chain from \(first) to \(last), \(style.word)")
            if case .denied(let scope) = paths.state {
                ScopeDeniedRow(scope: scope)
            }
            ForEach(Array(hops.enumerated()), id: \.element.id) { index, hop in
                hopRow(hop, isThis: hop.lineUUID.lowercased() == line.lineUUID.lowercased())
                if index + 1 < hops.count {
                    pathRow(from: hop, to: hops[index + 1])
                }
            }
            NavigationLink(value: AppRoute.monitoring(.chain(id: chain.chain.id))) {
                VPNLinkRow(title: "Open the chain in Monitor", detail: "Latency of each hop over the Monitor window", systemImage: "waveform.path.ecg")
            }
        } header: {
            Text("Chain").accessibilityAddTraits(.isHeader).id("chain")
        } footer: {
            Text("Between each hop is the path from one node to the next as the latency checks measure it.")
        }
    }

    @ViewBuilder
    private func hopRow(_ hop: MonitoringChainHop, isThis: Bool) -> some View {
        let node = nodes.name(for: hop.nodeID)
        let entry = store.line(id: hop.lineUUID)
        let role = "\(hop.role.rawValue.prefix(1).uppercased())\(hop.role.rawValue.dropFirst())"
        let title = "\(role): \(entry?.line.displayName ?? "line") on \(node)"
        let routeWord = hop.route.map { VPNStyle.chain(MonitoringChainState($0)).word }
        let label = VPNGlyphLabel(title: title, titleRole: .rowTitle,
                                  detail: [isThis ? "this line" : nil, routeWord].compactMap { $0 }.joined(separator: " · "),
                                  systemImage: hop.role == .exit ? "arrow.up.right.circle" : "circle.circle", glyphColor: .statusQuiet)
            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
        .accessibilityElement(children: .combine)
        if isThis {
            label
        } else {
            NavigationLink(value: AppRoute.vpn(.line(id: entry?.line.lineHashID ?? hop.lineUUID))) { label }
        }
    }

    @ViewBuilder
    private func pathRow(from hop: MonitoringChainHop, to next: MonitoringChainHop) -> some View {
        let key = MonitoringChain.pathKey(from: hop, to: next)
        let source = nodes.name(for: hop.nodeID)
        let target = nodes.name(for: next.nodeID)
        if let response = paths.state.value, let path = response.path(key: key) {
            NavigationLink(value: AppRoute.monitoring(.path(key: key))) {
                PathRow(path: path, sourceName: source, targetName: target, judgesDegraded: response.judgesDegraded)
            }
        } else if paths.state.value != nil {
            StatusRow(style: StatusStyle(word: "not measured", symbol: "questionmark.circle", tone: .quiet),
                      title: "\(source) → \(target)", detail: "No latency check covers this hop",
                      accessibilityPhrase: "\(source) to \(target), not measured, no latency check covers this hop")
        } else if case .failed(let error, nil, _) = paths.state {
            StatusRow(style: StatusStyle(word: "not read", symbol: "exclamationmark.triangle", tone: .warn),
                      title: "\(source) → \(target)", reason: "Path states could not be read: \(error.localizedDescription)",
                      accessibilityPhrase: "\(source) to \(target), path state not read")
        } else if paths.state.isLoading || paths.state.value == nil, !isDenied {
            StatusRow(style: StatusStyle(word: "", symbol: "circle.fill", tone: .quiet), title: "\(source) → \(target)", detail: "Loading the path")
                .redacted(reason: .placeholder)
                .accessibilityLabel("Loading the path from \(source) to \(target)")
        }
    }

    private var isDenied: Bool {
        if case .denied = paths.state { return true }
        return false
    }

    @ViewBuilder
    private func routeSection(_ line: VPNLine, groups: [VPNLineGroup]) -> some View {
        let target = VPNLineTarget.of(line, in: groups)
        Section {
            switch target {
            case .node(let nodeID, let name, _):
                if let hash = line.jumpEdges.first(where: { edge in groups.contains { $0.lines.contains { $0.lineHashID == edge } } }) {
                    NavigationLink(value: AppRoute.vpn(.line(id: hash))) {
                        VPNLinkRow(title: target.sentence.prefix(1).uppercased() + target.sentence.dropFirst(), detail: "Opens the line it relays to", systemImage: "arrow.right.circle")
                    }
                } else {
                    NavigationLink(value: AppRoute.fleet(.node(id: nodeID))) {
                        VPNLinkRow(title: "Relays to \(name)", systemImage: "arrow.right.circle")
                    }
                }
            default:
                DetailRow(label: "Traffic", value: target.sentence.prefix(1).uppercased() + target.sentence.dropFirst(), copyable: false)
            }
            if store.chains.value != nil {
                Text("This line takes part in no orchestrated chain.")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
            } else if case .denied(let scope) = store.chains {
                ScopeDeniedRow(scope: scope)
            }
        } header: {
            Text("Route").accessibilityAddTraits(.isHeader).id("chain")
        }
    }

    // MARK: Facts

    @ViewBuilder
    private func factsSection(_ entry: VPNLineEntry) -> some View {
        let line = entry.line
        Section {
            NavigationLink(value: AppRoute.fleet(.node(id: entry.nodeID))) {
                DetailRow(label: "Node", value: entry.nodeName, copyable: false)
            }
            DetailRow(label: "Users", value: VPNLineFormat.users(line),
                      secondary: line.unnamedUsers > 0 ? "\(line.unnamedUsers) cannot be counted individually" : nil, copyable: false)
            if line.parkedUsers > 0 || !line.parkedError.isEmpty {
                DetailRow(label: "Parked", value: line.parkedError.isEmpty ? "\(line.parkedUsers)" : "Unknown",
                          secondary: line.parkedError.isEmpty ? "Taken off the line, credentials kept on the node" : "The node found its parked list damaged", copyable: false)
            }
            DetailRow(label: "Service", value: line.serviceState.isEmpty ? "Not probed" : line.serviceState,
                      secondary: line.serviceCheckedAt.map { "Checked \(TimeDisplay.relative($0, now: Date(), locale: locale))" }, copyable: false)
            DetailRow(label: "Config", value: line.status.isEmpty ? "Not reported" : line.status, copyable: false)
            if !VPNLineFormat.endpoint(line).isEmpty {
                DetailRow(label: "Endpoint", value: VPNLineFormat.endpoint(line), monospaced: true)
            }
            if !VPNLineFormat.hostPort(line.listenHost, line.listenPort).isEmpty {
                DetailRow(label: "Listens on", value: VPNLineFormat.hostPort(line.listenHost, line.listenPort), monospaced: true)
            }
            if !line.domain.isEmpty { DetailRow(label: "Domain", value: line.domain, monospaced: true) }
            DetailRow(label: "Protocol", value: [line.type, line.transport, line.security].filter { !$0.isEmpty }.joined(separator: ", "), copyable: false)
            DetailRow(label: "Core", value: line.core.isEmpty ? "Unknown" : line.core, copyable: false)
            DetailRow(label: "Ownership", value: line.managed ? "Managed by Lattice" : "Observed (\(line.source))", copyable: false)
            if line.overlay {
                DetailRow(label: "Managed line", value: line.overlayStatus.isEmpty ? "Defined" : line.overlayStatus,
                          secondary: line.overlayUser.isEmpty ? nil : "For \(line.overlayUser)", copyable: false)
            }
            if !line.lineUUID.isEmpty { DetailRow(label: "Line UUID", value: line.lineUUID, monospaced: true) }
            DetailRow(label: "Handle", value: line.lineHashID, monospaced: true)
        } header: {
            Text("Line").accessibilityAddTraits(.isHeader).id("facts")
        }
    }

    @ViewBuilder
    private func usersSection(_ line: VPNLine) -> some View {
        Section {
            switch store.users {
            case .denied(let scope):
                ScopeDeniedRow(scope: scope)
            default:
                if let listing = store.users.value {
                    let bound = VPNLineUsers.bound(to: line, users: listing.users)
                    if bound.isEmpty {
                        Text(listing.source == .legacyProxyUser ? "Legacy proxy users carry no line bindings." : "No identity is bound to this line.")
                            .foregroundStyle(.secondary)
                            .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                    }
                    ForEach(bound) { user in
                        let binding = user.bindings.first { $0.lineHashID == line.lineHashID }
                        let style = binding?.enabled == false
                            ? StatusStyle(word: "binding off", symbol: "minus.circle", tone: .quiet)
                            : VPNStyle.identity(user, now: Date())
                        NavigationLink(value: AppRoute.vpn(.user(id: user.id))) {
                            StatusRow(style: style, title: user.displayName,
                                      detail: binding.flatMap { VPNBindingCredential.words($0.credential) },
                                      accessibilityPhrase: "\(user.displayName), \(style.word)")
                        }
                    }
                } else {
                    LoadingRows(label: "Loading bound identities", count: 2)
                }
            }
        } header: {
            Text("Bound identities").accessibilityAddTraits(.isHeader).id("users")
        }
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Line not found", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("No node reports a line \(id) now. It may have been removed, or its node has not reported since a restart.")
            } actions: {
                Button("All lines") { router.replaceTop(.vpn(.lines)) }
                    .buttonStyle(.bordered)
                Button("Open on web") { router.openOnWeb(.vpnLines) }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let entry = store.line(id: id) {
                    Button("Open node", systemImage: "server.rack") { router.push(.fleet(.node(id: entry.nodeID))) }
                    if let chain = VPNLineChain.of(entry.line, chains: store.chains.value ?? []) {
                        Button("Open chain", systemImage: "link") { router.push(.monitoring(.chain(id: chain.chain.id))) }
                    }
                    Button("Copy handle", systemImage: "number") { VPNCopy.copy(entry.line.lineHashID) }
                }
                Button("Open on web", systemImage: "safari") { router.openOnWeb(.vpnLines) }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    private func refresh() {
        Task { await store.refreshLines() }
    }
}

/// The path states between chain hops, read with the Shared paths call over
/// the last hour. Owned by the line screen; monitor:read gates it.
@MainActor @Observable
final class VPNLinePathsModel {
    private(set) var state: ResourceState<PathsResponse> = .idle
    static let requirement = ScopeRequirement("monitor:read")

    @discardableResult
    func refresh(session: SessionStore) async -> Bool {
        if let missing = session.missing(Self.requirement), !missing.isEmpty {
            state = .denied(scope: missing[0])
            return true
        }
        guard let client = session.client else { return false }
        let before = state
        state = before.reloading
        do {
            state = .loaded(try await client.fetchPaths(window: .oneHour), at: Date())
            return true
        } catch {
            if VPNStore.isCancellation(error) {
                state = before
                return true
            }
            state = state.failing(LatticeAPIError(error), surface: "Path states", missingScope: "monitor:read")
            return false
        }
    }
}
