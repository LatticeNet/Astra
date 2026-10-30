import SwiftUI

/// M13-03 Lines: every vpn-core line, worst first, with its service and
/// config state, its chain health (M3's `/api/network/lines/chains`), where
/// it sends traffic and how many users it holds. Gate vpncore:read or
/// proxy:read, unconfined. Chain plans, removal and managed rollouts stay on
/// the web.
struct VPNLinesScreen: View {
    static let queryKey = "vpn.lines.query"

    @Environment(VPNStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(DeepLinkRouter.self) private var deepLinks
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @SceneStorage(Self.queryKey) private var query = ""
    @State private var stable = VPNStableList<VPNLineEntry> { old, new in
        VPNLineState.of(old.line).isProblem == VPNLineState.of(new.line).isProblem
    }

    private enum Bucket: String, CaseIterable {
        case attention = "Needs attention"
        case running = "Running"
        case unprobed = "Service not proven"
    }

    var body: some View {
        content
            .navigationTitle("Lines")
            .navigationBarTitleDisplayMode(.large)
            .navigationSubtitle(query.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "Filtered: \(query.trimmingCharacters(in: .whitespaces))")
            .searchable(text: $query, prompt: "Node, name or state:down")
            .toolbar { toolbar }
            .onChange(of: store.lines.loadedAt, initial: true) { offer(force: false) }
            .onChange(of: store.chains.loadedAt) { offer(force: false) }
            .onChange(of: query) { offer(force: true) }
            .polling(.standard, version: changes.version([.vpn, .paths])) { await store.refreshLines() }
    }

    @ViewBuilder
    private var content: some View {
        if !network.isSatisfied, store.lines.value == nil, !store.lines.isLoading, store.readMissing == nil {
            VPNOfflineView(noun: "Lines", retry: refresh)
        } else {
            ResourceView(state: store.lines, noun: "lines", retry: refresh) { groups in
                list(groups)
            }
        }
    }

    private var chainRows: [MonitoringLineChain] { store.chains.value ?? [] }

    private func bucket(_ entry: VPNLineEntry) -> Bucket {
        let state = VPNLineState.of(entry.line)
        let chain = VPNLineChain.of(entry.line, chains: chainRows)?.state
        if state.isProblem || chain == .drifted || chain == .failed { return .attention }
        return state == .running ? .running : .unprobed
    }

    private func filtered(_ groups: [VPNLineGroup]) -> (rows: [VPNLineEntry], error: String?) {
        let rows = VPNLineEntry.flatten(groups)
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return (rows, nil) }
        switch LatticeQueryEngine.compile(text, provider: VPNLineQueryFields.self) {
        case .success(let compiled): return (LatticeQueryEngine.apply(compiled, to: rows, now: Date()), nil)
        case .failure(let error): return (rows, error.localizedDescription)
        }
    }

    private func offer(force: Bool) {
        stable.offer(filtered(store.lines.value ?? []).rows, voiceOver: voiceOver, force: force)
    }

    private func summary(_ groups: [VPNLineGroup]) -> String {
        let entries = VPNLineEntry.flatten(groups)
        let nodes = Set(entries.map(\.nodeID)).count
        let head = "\(entries.count == 1 ? "1 line" : "\(entries.count) lines") on \(nodes == 1 ? "1 node" : "\(nodes) nodes")."
        let attention = entries.filter { bucket($0) == .attention }.count
        let chained = entries.filter { VPNLineChain.of($0.line, chains: chainRows) != nil }.count
        var parts: [String] = []
        if attention > 0 { parts.append(attention == 1 ? "1 needs attention" : "\(attention) need attention") }
        if chained > 0 { parts.append("\(chained) in chains") }
        return parts.isEmpty ? head : "\(head) \(parts.joined(separator: ", "))."
    }

    private func list(_ groups: [VPNLineGroup]) -> some View {
        let queryError = filtered(groups).error
        let shown = stable.shown
        let buckets = Bucket.allCases.compactMap { bucket -> (Bucket, [VPNLineEntry])? in
            let rows = shown.filter { self.bucket($0) == bucket }
            return rows.isEmpty ? nil : (bucket, rows)
        }
        return List {
            VPNRefreshError(state: store.lines, noun: "lines", retry: refresh)
            if stable.held != nil, voiceOver {
                Section { PendingUpdatesRow(count: stable.pendingCount) { stable.showHeld() } }
            }
            if let queryError {
                Section {
                    Label(queryError, systemImage: "exclamationmark.magnifyingglass")
                        .foregroundStyle(Color.statusWarnText)
                        .frame(minHeight: Spacing.minimumTarget)
                }
            }
            if !groups.isEmpty, query.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    Text(summary(groups))
                        .textRole(.rowTitle)
                        .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    chainsNotice
                }
            }
            if shown.isEmpty {
                Section { emptyState }
            }
            ForEach(buckets, id: \.0) { bucket, rows in
                Section {
                    ForEach(rows) { row($0, groups: groups) }
                } header: {
                    Text("\(bucket.rawValue) (\(rows.count))").accessibilityAddTraits(.isHeader).id(bucket.rawValue)
                }
            }
            Section {
                NavigationLink(value: AppRoute.vpn(.users)) {
                    VPNLinkRow(title: "VPN users", detail: "The identities bound to these lines", systemImage: "person.2")
                }
                WebLinkRow(title: "Chain plans and rollouts on web", path: .vpnLines)
            } footer: {
                FreshnessFooter(state: store.lines, interval: Polling.standard.interval(lowPower: false))
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await store.refreshLines()
            offer(force: true)
        }
        .onScrollPhaseChange { _, phase in if phase != .idle { stable.noteActivity() } }
        .vpnDemoScroll(ready: !stable.shown.isEmpty)
    }

    /// Chain health comes from a second read; when it fails or is denied the
    /// lines still show, and this says chain health is missing.
    @ViewBuilder
    private var chainsNotice: some View {
        switch store.chains {
        case .failed(let error, nil, _):
            Label("Chain health could not be read: \(error.localizedDescription)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Color.statusWarnText)
                .frame(minHeight: Spacing.minimumTarget)
        case .companionBehind(let surface):
            CompanionBehindRow(surface: surface)
        case .denied(let scope):
            ScopeDeniedRow(scope: scope)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView {
                Label("No lines", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("Lines appear when a node reports its proxy configuration or a managed line is applied.")
            } actions: {
                Button("Open Lines on web") { router.openOnWeb(.vpnLines) }
            }
        }
    }

    private func row(_ entry: VPNLineEntry, groups: [VPNLineGroup]) -> some View {
        let line = entry.line
        let state = VPNLineState.of(line)
        let chain = VPNLineChain.of(line, chains: chainRows)
        let style = VPNStyle.lineRow(state, chain: chain?.state)
        var parts = [entry.nodeName, VPNLineFormat.users(line), VPNLineTarget.of(line, in: groups).sentence]
        if let chain, style != VPNStyle.chain(chain.state) { parts.append(VPNStyle.chain(chain.state).word) }
        let detail = parts.joined(separator: " · ")
        return NavigationLink(value: AppRoute.vpn(.line(id: line.lineHashID))) {
            StatusRow(style: style, title: line.displayName, detail: detail, reason: reason(line, state: state, chain: chain),
                      accessibilityPhrase: "Line \(line.displayName) on \(entry.nodeName), \(style.word), \(detail)")
        }
        .contextMenu {
            Button("Open", systemImage: "point.3.connected.trianglepath.dotted") { router.push(.vpn(.line(id: line.lineHashID))) }
            Button("Copy ID", systemImage: "number") { VPNCopy.copy(line.lineHashID) }
            Button("Open node", systemImage: "server.rack") { router.push(.fleet(.node(id: entry.nodeID))) }
            if chain != nil {
                Button("Open chain", systemImage: "link") { router.push(.monitoring(.chain(id: chain!.chain.id))) }
            }
            Button("Open on web", systemImage: "safari") { router.openOnWeb(.vpnLines) }
        }
        .accessibilityActions {
            Button("Copy ID") { VPNCopy.copy(line.lineHashID) }
            Button("Open node") { router.push(.fleet(.node(id: entry.nodeID))) }
            Button("Open on web") { router.openOnWeb(.vpnLines) }
        }
    }

    private func reason(_ line: VPNLine, state: VPNLineState, chain: VPNLineChain?) -> String? {
        switch state {
        case .down, .restarting, .unproven: if !line.serviceNote.isEmpty { return line.serviceNote }
        case .configError: if !line.lastError.isEmpty { return line.lastError }
        case .pending: return "The configuration change is not applied yet."
        case .stale: return "The node has not reported this line recently."
        case .running, .configOK: break
        }
        if let problem = chain?.problem, chain?.state == .drifted || chain?.state == .failed {
            return "Chain \(chain!.state.rawValue): \(problem)."
        }
        return nil
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("VPN users", systemImage: "person.2") { router.push(.vpn(.users)) }
                // Through the link router, which also picks the Chains view
                // and pops whatever is pushed on the Monitor stack.
                Button {
                    deepLinks.handle(.monitoring(segment: .paths, view: MonitoringPathsView.chains.rawValue, query: nil))
                } label: {
                    Text("Line chains")
                    Text("Opens in Monitor")
                    Image(systemName: "waveform.path.ecg")
                }
                Button("Lines on web", systemImage: "safari") { router.openOnWeb(.vpnLines) }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    private func refresh() {
        Task { await store.refreshLines() }
    }
}
