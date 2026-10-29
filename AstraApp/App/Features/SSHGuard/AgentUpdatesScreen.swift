import SwiftUI

/// The three views of Agent Updates.
enum SSHGuardAgentView: String, CaseIterable, Hashable {
    case nodes, distribution, mirrors

    var title: String {
        switch self {
        case .nodes: "Nodes"
        case .distribution: "Distribution"
        case .mirrors: "Mirrors"
        }
    }
}

/// M7-03 Agent Updates: each node's running version against the latest
/// release (Nodes), releases and stored binaries (Distribution), and the
/// download mirrors with each node's source order (Mirrors).
struct AgentUpdatesScreen: View {
    var view: String?
    var nodeID: String?

    @Environment(AgentUpdatesStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(ActionRunner.self) private var runner
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale

    @State private var selected = SSHGuardAgentView.nodes
    @State private var nodeFilter: String?
    @State private var query = ""
    @State private var width: CGFloat?
    @State private var applied = false

    var body: some View {
        content
            .navigationTitle("Agent Updates")
            // Inline: a large title would sit under the picker bar's scroll edge effect.
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(subtitle)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .safeAreaBar(edge: .top) {
                if verticalSizeClass != .compact, store.missingGate == nil {
                    picker.padding(.horizontal, Spacing.l).padding(.bottom, Spacing.s)
                }
            }
            .toolbar {
                if verticalSizeClass == .compact, store.missingGate == nil {
                    ToolbarItem(placement: .topBarTrailing) { toolbarPicker.frame(maxWidth: 320) }
                }
                if selected == .nodes, store.missingGate == nil {
                    ToolbarItem(placement: .topBarTrailing) { planAllButton }
                }
                ToolbarItem(placement: .topBarTrailing) { menu }
            }
            .onAppear(perform: applyLink)
            .polling(.standard, version: changes.version([.agentUpdates, .nodes, .approvals])) {
                await store.refresh()
            }
    }

    private var picker: some View {
        AdaptiveSegmentedPicker(
            title: "Agent updates view",
            options: SSHGuardAgentView.allCases.map { ($0, $0.title) },
            selection: $selected,
            containerWidth: width
        )
    }

    /// The bar caps its text size, so at accessibility sizes the segments
    /// would truncate to a letter each; a menu names the view instead.
    private var toolbarPicker: some View {
        AdaptiveSegmentedPicker(
            title: "Agent updates view",
            options: SSHGuardAgentView.allCases.map { ($0, $0.title) },
            selection: $selected,
            containerWidth: typeSize.isAccessibilitySize ? 0 : width
        )
    }

    private var subtitle: String {
        if let nodeFilter { return nodeName(nodeFilter) }
        return query
    }

    private func applyLink() {
        guard !applied else { return }
        applied = true
        if let view, let initial = SSHGuardAgentView(rawValue: view) { selected = initial }
        nodeFilter = nodeID
    }

    private func nodeName(_ id: String) -> String {
        store.nodes.value?.first { $0.id == id }?.displayName ?? id
    }

    @ViewBuilder
    private var content: some View {
        if let missing = store.missingGate {
            ScopeDeniedScreen(scope: missing.joined(separator: " and "))
        } else if store.nodes.value == nil, store.release.value == nil, !network.isSatisfied {
            SSHGuardOfflineState(noun: "Agent Updates")
        } else {
            switch selected {
            case .nodes: nodesView
            case .distribution: distributionView
            case .mirrors: mirrorsView
            }
        }
    }

    // MARK: Nodes

    private var shownRows: (rows: [AgentUpdatesNodeRow], error: String?) {
        var rows = store.rows
        if let nodeFilter { rows = rows.filter { $0.nodeID == nodeFilter } }
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return (rows, nil) }
        switch LatticeQueryEngine.compile(text, provider: AgentUpdatesQueryFields.self) {
        case .success(let compiled): return (LatticeQueryEngine.apply(compiled, to: rows, now: Date()), nil)
        case .failure(let error): return (rows, error.localizedDescription)
        }
    }

    @ViewBuilder
    private var nodesView: some View {
        switch store.nodes {
        case .failed(let error, nil, _):
            failedState(noun: "nodes", error: error)
        case .companionBehind(let surface):
            behindState(surface)
        default:
            if store.nodes.value == nil {
                List { LoadingRows(label: "Loading agent versions", count: 6) }
            } else {
                nodesList
            }
        }
    }

    private var nodesList: some View {
        let shown = shownRows
        let groups = Dictionary(grouping: shown.rows, by: \.standing)
        return List {
            if case .failed(let error, _, _) = store.nodes {
                ErrorRow(message: "Could not refresh nodes: \(error.localizedDescription)") { refresh() }
            }
            summarySection
            if let nodeFilter {
                FilterStateRow(text: "Showing \(nodeName(nodeFilter)) only") { self.nodeFilter = nil }
            }
            if let error = shown.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.statusWarnText)
                    .frame(minHeight: Spacing.minimumTarget)
            }
            if shown.rows.isEmpty {
                Section {
                    if query.isEmpty {
                        ContentUnavailableView("No nodes", systemImage: "server.rack", description: Text("This token can read no node."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            ForEach([AgentUpdatesStanding.behind, .unknown, .ahead, .current], id: \.self) { standing in
                if let rows = groups[standing], !rows.isEmpty {
                    Section {
                        ForEach(rows) { row in nodeRow(row) }
                    } header: {
                        Text("\(SSHGuardAgentWords.sectionTitle(standing)) (\(rows.count))").accessibilityAddTraits(.isHeader)
                    } footer: {
                        if standing == .behind, !store.bulk.skipped.isEmpty {
                            Text("\(store.bulk.skipped.map(\.name).joined(separator: ", ")) \(store.bulk.skipped.count == 1 ? "has" : "have") no update policy, so no plan can be filed. Set a policy on the web.")
                        }
                    }
                }
            }
            Section {
                WebLinkRow(title: "Policies on web", path: LatticeConsolePath(path: "/platform/agent-updates", query: [URLQueryItem(name: "view", value: "nodes")]))
            } footer: {
                FreshnessFooter(loadedAt: store.loadedAt, isUpdating: store.nodes.isLoading && store.nodes.value != nil,
                                lastAttemptFailed: store.anyFailed, interval: Polling.standard.interval(lowPower: false))
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "is:behind, policy:, version:, tag:")
        .refreshable { await store.refresh() }
    }

    @ViewBuilder
    private var summarySection: some View {
        Section {
            switch store.release {
            case .failed(let error, nil, _):
                Label {
                    Text("The latest release could not be read: \(error.localizedDescription). Standing is unknown until it can.")
                        .foregroundStyle(Color.statusWarnText)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarnFill)
                }
                .frame(minHeight: Spacing.minimumTarget)
            default:
                if let latest = store.latest {
                    let rows = store.rows
                    let current = rows.filter { $0.standing == .current || $0.standing == .ahead }.count
                    DetailRow(label: "Latest stable", value: latest, monospaced: true, copyable: false)
                    DetailRow(label: "On it or newer", value: "\(current) of \(rows.count)", copyable: false)
                    if case .failed(let error, _, _) = store.policies {
                        Label("Policies could not be read: \(error.localizedDescription)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.statusWarnText)
                    }
                } else {
                    LoadingRows(label: "Loading the latest release", count: 1)
                }
            }
        } footer: {
            if let reason = store.planBlockReason() {
                Text("Plans need \(reason.replacingOccurrences(of: "Needs ", with: "")).")
            } else {
                Text("Plan update files an approval per node; nothing changes until it is approved.")
            }
        }
    }

    @ViewBuilder
    private func nodeRow(_ row: AgentUpdatesNodeRow) -> some View {
        let style = SSHGuardAgentWords.style(row.standing)
        let target = row.policy?.resolvedTarget(latest: store.latest) ?? store.latest
        let detail = [row.running.isEmpty ? "not reported" : "runs \(row.running)", target.map { "target \($0)" }, row.policyState.word]
            .compactMap { $0 }.joined(separator: ", ")
        let history = SSHGuardAgentWords.history(row, locale: locale)
        NavigationLink(value: AppRoute.fleet(.node(id: row.nodeID))) {
            SSHGuardAgentNodeRow(style: style, title: row.name, detail: detail, reason: SSHGuardAgentWords.reason(row), history: history)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if row.standing == .behind, row.policy != nil, store.planBlockReason() == nil {
                Button("Plan update", systemImage: "arrow.down.circle") { plan(row, force: false) }
                    .tint(Color.accentFill)
            }
        }
        .contextMenu {
            Button("Plan update", systemImage: "arrow.down.circle") { plan(row, force: false) }
                .disabled(row.policy == nil || row.standing != .behind || store.planBlockReason() != nil)
            Button("Force plan", systemImage: "arrow.clockwise.circle") { plan(row, force: true) }
                .disabled(row.policy == nil || store.planBlockReason() != nil)
            if row.policy == nil {
                Text("No update policy: set one on the web")
            } else if let reason = store.planBlockReason() {
                Text(reason)
            }
            Divider()
            Button("Open node", systemImage: "server.rack") { router.push(.fleet(.node(id: row.nodeID))) }
            Button("Copy link", systemImage: "link") { SSHGuardCopy.copy(SSHGuardCopy.agentUpdatesLink(row.nodeID)) }
            Button("Open on web", systemImage: "safari") { router.openOnWeb(.agentUpdates(nodeName: row.name)) }
        }
    }

    private var planAllButton: some View {
        let targets = store.bulk.plan
        return Button {
            let refs = targets.map { ObjectRef(kind: "node", id: $0.nodeID, name: $0.name) }
            Task { await runner.run(AgentUpdatesPlanning.planAllBehind(refs)) }
        } label: {
            Text("Plan all behind (\(targets.count))")
        }
        .disabled(targets.isEmpty || store.planBlockReason() != nil)
        .accessibilityHint(targets.isEmpty ? "No node is behind with a policy" : "Files one plan per node")
    }

    private func plan(_ row: AgentUpdatesNodeRow, force: Bool) {
        let ref = ObjectRef(kind: "node", id: row.nodeID, name: row.name)
        Task { await runner.run(AgentUpdatesPlanning.planOne(ref, force: force)) }
    }

    // MARK: Distribution

    @ViewBuilder
    private var distributionView: some View {
        if store.nodes.value == nil, store.release.value == nil, store.artifacts.value == nil {
            if case .failed(let error, nil, _) = store.release {
                failedState(noun: "releases", error: error)
            } else {
                List { LoadingRows(label: "Loading releases", count: 5) }
            }
        } else {
            distributionList
        }
    }

    private var distributionList: some View {
        let slices = AgentUpdatesBulk.distribution((store.nodes.value ?? []).map(\.agentVersion), latest: store.latest)
        return List {
            Section {
                ForEach(slices, id: \.version) { slice in
                    let style = SSHGuardAgentWords.style(slice.standing)
                    StatusRow(style: style, title: slice.version.isEmpty ? "Not reported" : slice.version,
                              detail: slice.version == store.latest ? "latest stable" : nil,
                              trailing: slice.count == 1 ? "1 node" : "\(slice.count) nodes", titleIsIdentifier: true,
                              accessibilityPhrase: "\(slice.version.isEmpty ? "Not reported" : "Version \(slice.version)"), \(style.word)")
                }
            } header: {
                Text("Running versions").accessibilityAddTraits(.isHeader)
            }
            Section {
                switch store.release {
                case .failed(let error, nil, _):
                    ErrorRow(message: "Could not read releases: \(error.localizedDescription)") { refresh() }
                default:
                    if let release = store.release.value {
                        ForEach(SSHGuardAgentWords.releases(release), id: \.version) { item in
                            NavigationLink(value: AppRoute.sshGuard(.agentRelease(id: item.version))) {
                                StatusRow(style: StatusStyle(word: item.channel, symbol: item.prerelease ? "flask" : "shippingbox", tone: .quiet),
                                          title: item.version, detail: item.latestForChannel ? "newest \(item.channel)" : nil, titleIsIdentifier: true,
                                          accessibilityPhrase: "Release \(item.version), \(item.channel)")
                            }
                        }
                    } else {
                        LoadingRows(label: "Loading releases", count: 2)
                    }
                }
            } header: {
                Text("Releases").accessibilityAddTraits(.isHeader)
            } footer: {
                if let release = store.release.value, let fetched = release.fetchedAt {
                    Text("From \(release.repo), read \(TimeDisplay.relative(fetched, now: .now, locale: locale)).")
                }
            }
            artifactsSection
            Section {
                WebLinkRow(title: "Import or delete artifacts on web", path: LatticeConsolePath(path: "/platform/agent-updates", query: [URLQueryItem(name: "view", value: "distribution")]))
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
    }

    @ViewBuilder
    private var artifactsSection: some View {
        Section {
            switch store.artifacts {
            case .failed(let error, nil, _):
                ErrorRow(message: "Could not read stored artifacts: \(error.localizedDescription)") { refresh() }
            default:
                if let listing = store.artifacts.value {
                    if listing.limitBytes > 0 {
                        ValueBarRow(label: "Storage used",
                                    value: "\(ByteCountFormatter.string(fromByteCount: listing.storedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: listing.limitBytes, countStyle: .file))",
                                    fraction: Double(listing.storedBytes) / Double(listing.limitBytes))
                    }
                    if !listing.servingEnabled {
                        Label("This server has no public HTTPS address to hand nodes, so plans keep downloading from the release host and these binaries sit unused.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.statusWarnText)
                    }
                    if listing.artifacts.isEmpty {
                        Text("No agent binary is stored on this control plane.").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
                    }
                    ForEach(listing.artifacts) { artifact in
                        NavigationLink(value: AppRoute.sshGuard(.agentRelease(id: artifact.version))) {
                            StatusRow(style: StatusStyle(word: artifact.platform, symbol: "internaldrive", tone: .quiet), title: artifact.version,
                                      detail: ByteCountFormatter.string(fromByteCount: artifact.sizeBytes, countStyle: .file), titleIsIdentifier: true,
                                      accessibilityPhrase: "\(artifact.version), \(artifact.platform)")
                        }
                    }
                } else {
                    LoadingRows(label: "Loading stored artifacts", count: 2)
                }
            }
        } header: {
            Text("Stored on the control plane").accessibilityAddTraits(.isHeader)
        } footer: {
            Text("Nodes download stored binaries from this server, so they need no egress to the release host. Each node checks the digest before it installs.")
        }
    }

    // MARK: Mirrors

    @ViewBuilder
    private var mirrorsView: some View {
        switch store.mirrors {
        case .failed(let error, nil, _):
            failedState(noun: "mirrors", error: error)
        case .companionBehind(let surface):
            behindState(surface)
        default:
            if let view = store.mirrors.value {
                mirrorsList(view)
            } else {
                List { LoadingRows(label: "Loading mirrors", count: 4) }
            }
        }
    }

    private func mirrorsList(_ view: AgentUpdatesMirrorsView) -> some View {
        let names = Dictionary(view.mirrors.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let health = Dictionary(view.health.map { ($0.mirror, $0) }, uniquingKeysWith: { first, _ in first })
        let order = nodeFilter.map { id in view.order.filter { $0.nodeID == id } } ?? view.order
        return List {
            if case .failed(let error, _, _) = store.mirrors {
                ErrorRow(message: "Could not refresh mirrors: \(error.localizedDescription)") { refresh() }
            }
            Section {
                if view.mirrors.isEmpty {
                    Text("No mirror: every node downloads from this control plane, then the release host.")
                        .foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
                }
                ForEach(view.mirrors.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }) { mirror in
                    SSHGuardMirrorRow(mirror: mirror, health: health[mirror.id])
                }
            } header: {
                Text("Registry, revision \(view.revision)").accessibilityAddTraits(.isHeader)
            }
            if !view.pending.isEmpty {
                Section {
                    ForEach(view.pending, id: \.self) { id in
                        Button {
                            router.present(.review(.single(id)))
                        } label: {
                            Label("Open plan \(id)", systemImage: "hand.raised.fill").frame(minHeight: Spacing.minimumTarget)
                        }
                    }
                } header: {
                    Text("Registry changes waiting").accessibilityAddTraits(.isHeader)
                }
            }
            Section {
                if let nodeFilter {
                    FilterStateRow(text: "Showing \(nodeName(nodeFilter)) only") { self.nodeFilter = nil }
                }
                ForEach(order) { item in
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(item.name.isEmpty ? item.nodeID : item.name).textRole(.rowTitle)
                        Text(item.sentence(mirrorNames: names)).textRole(.rowDetail)
                    }
                    .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Source order per node").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("The order a plan would list the download sources in, for a version this control plane holds.")
            }
            Section {
                WebLinkRow(title: "Mirror plan on web", path: LatticeConsolePath(path: "/platform/agent-updates", query: [URLQueryItem(name: "view", value: "mirrors")]))
            } footer: {
                FreshnessFooter(state: store.mirrors, interval: Polling.standard.interval(lowPower: false))
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
    }

    // MARK: Shared parts

    private func refresh() {
        Task { await store.refresh() }
    }

    private func failedState(noun: String, error: LatticeAPIError) -> some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Could not load \(noun)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("Retry", action: refresh).buttonStyle(.bordered)
            }
        }
    }

    private func behindState(_ surface: String) -> some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("This app is behind the server", systemImage: "exclamationmark.triangle")
            } description: {
                Text("\(surface) could not be read.")
            } actions: {
                Button("Reload", action: refresh)
            }
        }
    }

    private var menu: some View {
        Menu {
            Button("Open on web", systemImage: "safari") {
                if let nodeFilter {
                    router.openOnWeb(.agentUpdates(nodeName: nodeName(nodeFilter)))
                } else {
                    router.openOnWeb(LatticeConsolePath(path: "/platform/agent-updates", query: [URLQueryItem(name: "view", value: selected.rawValue)]))
                }
            }
            if let nodeFilter {
                Button("Copy link", systemImage: "link") { SSHGuardCopy.copy(SSHGuardCopy.agentUpdatesLink(nodeFilter)) }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }
}

/// A Nodes row: standing, versions and policy, then when it was last
/// planned and how its last download went, as a quiet stamp line.
struct SSHGuardAgentNodeRow: View {
    let style: StatusStyle
    let title: String
    let detail: String
    let reason: String?
    let history: String?

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var glyphWidth: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            StatusRow(style: style, title: title, detail: detail, reason: reason)
            if let history {
                Text(history)
                    .textRole(.stamp)
                    .padding(.leading, typeSize.isAccessibilitySize ? 0 : glyphWidth + Spacing.m)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One mirror registry entry with its health.
struct SSHGuardMirrorRow: View {
    let mirror: AgentUpdatesMirror
    let health: AgentUpdatesMirrorHealth?

    var body: some View {
        let failing = (health?.chunkFailures ?? 0) > 0
        let style: StatusStyle = !mirror.enabled
            ? StatusStyle(word: "disabled", symbol: "minus.circle", tone: .quiet)
            : (failing ? StatusStyle(word: "bad chunks", symbol: "exclamationmark.triangle.fill", tone: .warn)
                       : StatusStyle(word: "enabled", symbol: "checkmark.circle.fill", tone: .ok))
        let count = mirror.preferFor.count
        let scope = mirror.global ? "after the control plane for every node" : (count == 1 ? "first for 1 node or group" : "first for \(count) nodes or groups")
        StatusRow(style: style, title: mirror.displayName, detail: "priority \(mirror.priority), \(scope)",
                  reason: health.map { "\($0.fetches) fetch\($0.fetches == 1 ? "" : "es") in the last downloads, \($0.chunkFailures) with bad chunks" },
                  accessibilityPhrase: "\(mirror.displayName), \(style.word), priority \(mirror.priority)")
        DetailRow(label: "Base URL", value: mirror.baseURL, monospaced: true)
    }
}

enum SSHGuardAgentWords {
    static func style(_ standing: AgentUpdatesStanding) -> StatusStyle {
        switch standing {
        case .behind: StatusStyle(word: "behind", symbol: "arrow.down.circle.fill", tone: .warn)
        case .current: StatusStyle(word: "current", symbol: "checkmark.circle.fill", tone: .ok)
        case .ahead: StatusStyle(word: "ahead", symbol: "arrow.up.circle", tone: .quiet)
        case .unknown: StatusStyle(word: "unknown", symbol: "questionmark.circle", tone: .quiet)
        }
    }

    static func sectionTitle(_ standing: AgentUpdatesStanding) -> String {
        switch standing {
        case .behind: "Behind"
        case .unknown: "Unknown"
        case .ahead: "Ahead of the latest stable"
        case .current: "Current"
        }
    }

    /// "Planned 2 hr. ago, last download from the control plane".
    static func history(_ row: AgentUpdatesNodeRow, locale: Locale) -> String? {
        var parts: [String] = []
        if let planned = row.policy?.lastPlannedAt {
            parts.append("Planned \(TimeDisplay.relative(planned, now: .now, locale: locale))")
        }
        if let fetch = row.policy?.lastFetch {
            switch fetch.outcome {
            case .installed:
                let source = fetch.sources.first { $0.finished }?.label ?? fetch.sources.first?.label
                parts.append(source.map { "last download from the \($0)" } ?? "last download installed")
            case .kept:
                parts.append("last run kept the running binary")
            case .failed:
                break
            }
        }
        guard !parts.isEmpty else { return nil }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The policy's last error, or a failed last download, in the server's words.
    static func reason(_ row: AgentUpdatesNodeRow) -> String? {
        if let error = row.policy?.lastError, !error.isEmpty { return error }
        if let fetch = row.policy?.lastFetch, fetch.outcome == .failed {
            return "Last download failed at \(fetch.stage.isEmpty ? "an unknown stage" : fetch.stage), exit \(fetch.exitCode)."
        }
        return nil
    }

    struct ReleaseItem {
        var version: String
        var channel: String
        var prerelease: Bool
        var latestForChannel: Bool
    }

    /// The latest stable first, then the candidates, each version once.
    static func releases(_ info: AgentUpdatesReleaseInfo) -> [ReleaseItem] {
        var items: [ReleaseItem] = []
        if !info.latestVersion.isEmpty {
            items.append(ReleaseItem(version: info.latestVersion, channel: info.channel.isEmpty ? "stable" : info.channel, prerelease: false, latestForChannel: true))
        }
        for candidate in info.candidates where !items.contains(where: { $0.version == candidate.version }) {
            items.append(ReleaseItem(version: candidate.version, channel: candidate.channel, prerelease: candidate.prerelease, latestForChannel: candidate.latestForChannel))
        }
        return items
    }
}
