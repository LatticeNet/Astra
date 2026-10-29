import SwiftUI

/// The per-node detail model (section 8.1: view-owned, never registered).
/// The node and its incidents poll every 15 s; the slower sections load on
/// appear and whenever a write changes them.
@MainActor @Observable
final class FleetNodeDetailModel {
    let nodeID: String
    @ObservationIgnored private let session: SessionStore

    var record: ResourceState<FleetNodeRecord> = .idle
    var incidents: ResourceState<[Incident]> = .idle
    var paths: ResourceState<PathsResponse> = .idle
    var network: ResourceState<FleetNodeNetworkView> = .idle
    var sshGuard: ResourceState<SSHGuardNodeStatus> = .idle
    var capabilities: ResourceState<[NodeCapabilityEffective]> = .idle
    var beacon: ResourceState<FleetBeaconView> = .idle
    var queued: ResourceState<[LatticeTask]> = .idle
    var history: ResourceState<FleetMetricsQuery> = .idle
    var historyRange: FleetMetricsRange = .oneDay
    var audit: ResourceState<[AuditEvent]> = .idle
    var tasks: ResourceState<[LatticeTask]> = .idle
    var approvals: ResourceState<[Approval]> = .idle
    /// Agent versions across the fleet, for "n behind".
    var fleetVersions: [String?] = []

    init(nodeID: String, session: SessionStore) {
        self.nodeID = nodeID
        self.session = session
    }

    var node: LatticeNode? { record.value?.node }
    var ref: ObjectRef { node.map(FleetIntents.nodeRef) ?? ObjectRef(kind: "node", id: nodeID) }

    func missing(_ scopes: [String]) -> String? {
        guard let missing = session.missing(ScopeRequirement(groups: scopes.map { [$0] })), !missing.isEmpty else { return nil }
        return missing.joined(separator: " and ")
    }

    /// Runs one read: denied when the token lacks a scope, earlier data kept on failure.
    private func fetch<T: Sendable>(scopes: [String], surface: String, previous: ResourceState<T>,
                                    _ read: @Sendable (LatticeClient) async throws -> T) async -> ResourceState<T> {
        if let missing = missing(scopes) { return .denied(scope: missing) }
        guard let client = session.client else { return previous }
        do {
            return .loaded(try await read(client), at: Date())
        } catch {
            return previous.failing(LatticeAPIError(error), surface: surface, missingScope: scopes.joined(separator: " and "))
        }
    }

    /// The node and its open incidents: the 15 s poll.
    @discardableResult
    func refreshCore() async -> Bool {
        let id = nodeID
        if let missing = missing(["node:read"]) {
            record = .denied(scope: missing)
            return true
        }
        guard let client = session.client else { return false }
        record = record.reloading
        do {
            let records = try await client.fleetFetchNodeRecords()
            fleetVersions = records.map(\.node.agentVersion)
            if let found = records.first(where: { $0.id == id }) {
                record = .loaded(found, at: Date())
            } else {
                record = .failed(.notFound, last: nil, lastAt: nil)
            }
        } catch {
            record = record.failing(LatticeAPIError(error), surface: "Node", missingScope: "node:read")
            return false
        }
        incidents = incidents.reloading
        incidents = await fetch(scopes: ["monitor:read"], surface: "Incidents", previous: incidents) { client in
            try await client.listIncidents(states: [.open, .acknowledged], nodeID: id).incidents
        }
        return true
    }

    func refreshOverview() async {
        let id = nodeID
        let before = (paths.reloading, network.reloading, sshGuard.reloading, capabilities.reloading, beacon.reloading, queued.reloading)
        (paths, network, sshGuard, capabilities, beacon, queued) = before
        async let p = fetch(scopes: ["monitor:read"], surface: "Paths", previous: before.0) { try await $0.fetchPaths(window: .oneHour) }
        async let n = fetch(scopes: ["node:read"], surface: "Effective network", previous: before.1) { try await $0.fleetNodeNetwork(nodeID: id, rules: false) }
        async let g = fetch(scopes: ["sshguard:read", "network:plan"], surface: "SSH Guard", previous: before.2) { try await $0.fetchSSHGuardStatus(nodeID: id) }
        async let c = fetch(scopes: ["node:read"], surface: "Capabilities", previous: before.3) { try await $0.fetchNodeCapabilities(nodeID: id) }
        async let b = fetch(scopes: ["monitor:read"], surface: "Beacon", previous: before.4) { try await $0.fleetBeacon(nodeID: id) }
        async let q = fetch(scopes: ["task:read"], surface: "Tasks", previous: before.5) { client in
            try await client.listTasks(query: TaskQuery(statuses: ["pending", "queued", "leased"], nodeID: id, limit: 20)).tasks
        }
        async let h: Void = refreshHistory()
        paths = await p
        network = await n
        sshGuard = await g
        capabilities = await c
        beacon = await b
        queued = await q
        await h
    }

    func refreshHistory() async {
        let id = nodeID
        let range = historyRange
        history = history.reloading
        history = await fetch(scopes: ["node:read"], surface: "History", previous: history) { try await $0.fleetNodeHistory(nodeID: id, range: range) }
    }

    func refreshActivity() async {
        let id = nodeID
        let before = (audit.reloading, tasks.reloading, approvals.reloading)
        (audit, tasks, approvals) = before
        async let a = fetch(scopes: ["audit:read"], surface: "Audit", previous: before.0) { client in
            try await client.fetchAudit(query: AuditQuery(nodeID: id, limit: 50)).events
        }
        async let t = fetch(scopes: ["task:read"], surface: "Tasks", previous: before.1) { client in
            try await client.listTasks(query: TaskQuery(nodeID: id, limit: 50)).tasks
        }
        async let r = fetch(scopes: ["network:plan"], surface: "Approvals", previous: before.2) { client in
            try await client.listApprovals(query: ApprovalQuery(nodeID: id, includeDismissed: true, limit: 50)).approvals
        }
        audit = await a
        tasks = await t
        approvals = await r
    }

    func refreshSettings() async {
        let id = nodeID
        let before = (capabilities.reloading, beacon.reloading)
        (capabilities, beacon) = before
        async let c = fetch(scopes: ["node:read"], surface: "Capabilities", previous: before.0) { try await $0.fetchNodeCapabilities(nodeID: id) }
        async let b = fetch(scopes: ["monitor:read"], surface: "Beacon", previous: before.1) { try await $0.fleetBeacon(nodeID: id) }
        capabilities = await c
        beacon = await b
    }
}

/// M2-03 Node: a header block, then Overview, Activity and Settings behind a
/// segmented control pinned under the navigation bar (mirrors `?view=`).
struct NodeDetailScreen: View {
    let id: String
    var tab: NodeDetailTab = .overview

    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var model: FleetNodeDetailModel?
    @State private var selected: NodeDetailTab = .overview
    @State private var showsIdentity = false
    @State private var width: CGFloat?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                List { LoadingRows(label: "Loading node") }
            }
        }
        .navigationTitle(model?.node?.displayName ?? displayFallback)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                selected = tab
                model = FleetNodeDetailModel(nodeID: id, session: session)
            }
        }
    }

    private var displayFallback: String {
        "Node"
    }

    @ViewBuilder
    private func content(_ model: FleetNodeDetailModel) -> some View {
        let picker = AdaptiveSegmentedPicker(
            title: "Node view",
            options: [(NodeDetailTab.overview, "Overview"), (.activity, "Activity"), (.settings, "Settings")],
            selection: $selected,
            containerWidth: width
        )
        FleetListState(state: model.record, noun: "node", retry: { Task { await model.refreshCore() } }) { record in
            Group {
                switch selected {
                case .overview: NodeOverviewSection(model: model)
                case .activity: NodeActivitySection(model: model)
                case .settings: NodeSettingsSection(model: model, showsIdentity: $showsIdentity)
                }
            }
            .navigationSubtitle(StatusStyle.node(record.node.honesty).word)
        }
        .overlay {
            if case .failed(.notFound, nil, _) = model.record {
                WholeScreenState {
                    ContentUnavailableView {
                        Label("Not found, or not visible to this token", systemImage: "questionmark.circle")
                    } description: {
                        Text("The node list this token can read has no node \(id).")
                    } actions: {
                        Button("Token scopes") { router.openSettings([.page(.scopes)]) }
                        Button("Open on web") { router.openOnWeb(.node(id: id)) }
                    }
                }
                .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .safeAreaBar(edge: .top) {
            if verticalSizeClass != .compact, model.record.value != nil {
                picker.padding(.horizontal, Spacing.l).padding(.bottom, Spacing.s)
            }
        }
        .toolbar {
            if verticalSizeClass == .compact, model.record.value != nil {
                // Trailing, not principal: a principal item replaces the title,
                // and landscape would lose which node this is.
                ToolbarItem(placement: .topBarTrailing) { picker.frame(maxWidth: 320) }
            }
            ToolbarItem(placement: .topBarTrailing) { menu(model) }
        }
        .polling(.inbox, version: changes.version([.nodes, .incidents])) { await model.refreshCore() }
        .task(id: PollKey(version: changes.version([.nodes, .paths, .tasks, .gates, .approvals]), cadence: .standard)) {
            switch selected {
            case .overview: await model.refreshOverview()
            case .activity: await model.refreshActivity()
            case .settings: await model.refreshSettings()
            }
        }
        .onChange(of: selected) { _, tab in
            Task {
                switch tab {
                case .overview: if model.paths.value == nil { await model.refreshOverview() }
                case .activity: if model.audit.value == nil { await model.refreshActivity() }
                case .settings: if model.capabilities.value == nil { await model.refreshSettings() }
                }
            }
        }
        .sheet(isPresented: $showsIdentity) {
            NodeIdentitySheet(nodeID: id)
        }
    }

    private func menu(_ model: FleetNodeDetailModel) -> some View {
        Menu {
            Button("Open terminal on web", systemImage: "terminal") {
                router.openOnWeb(LatticeConsolePath(path: "/terminal", query: [URLQueryItem(name: "node_id", value: id)]))
            }
            Button("Terminal sessions", systemImage: "list.bullet.rectangle") { router.push(.terminal(.sessions(nodeID: id))) }
            Button("Start maintenance", systemImage: "wrench.and.screwdriver") { router.present(.maintenanceStart(nodeID: id)) }
            Divider()
            Button("Open on web", systemImage: "safari") { router.openOnWeb(.node(id: id, view: selected == .overview ? nil : selected)) }
            Button("Copy link", systemImage: "link") { FleetCopy.copy(FleetCopy.nodeLink(id, tab: selected == .overview ? nil : selected)) }
            Button("Copy ID", systemImage: "number") { FleetCopy.copy(id) }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }
}

/// The header block every tab of a node starts with: honesty with its
/// duration, last seen, agent version, place and public address.
struct FleetNodeHeader: View {
    let record: FleetNodeRecord
    let fleetVersions: [String?]

    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        let node = record.node
        let honesty = node.honesty
        let style = StatusStyle.node(honesty)
        let behind = FleetAgentVersion.newer(than: node.agentVersion, in: fleetVersions)
        Section {
            FleetHonestyRow(
                style: style,
                headline: headline(node),
                detail: detail(node),
                reason: honesty == .degraded || honesty == .offline ? (node.statusReason.isEmpty ? nil : node.statusReason) : nil,
                behind: behind
            )
            if let ip = node.publicIP, !ip.isEmpty { DetailRow(label: "Public IP", value: ip, monospaced: true) }
        }
    }

    /// "seen 15s ago at 02:40, agent 0.3.10, Tokyo, JP, Northwind Cloud", or
    /// "seen 2d ago, Oct 27 at 03:52, ..." once the clock alone is ambiguous.
    private func detail(_ node: LatticeNode) -> String {
        var parts: [String] = []
        if let seen = node.lastSeen {
            // The date form already reads "Oct 27 at 03:52", so it follows a comma, not "at".
            let when = Date().timeIntervalSince(seen) > 20 * 3_600
                ? ", " + TimeDisplay.dateTime(seen, mode: mode, locale: locale)
                : " at " + TimeDisplay.clock(seen, mode: mode, locale: locale)
            parts.append("seen \(FleetAge.short(seen) ?? "") ago\(when)")
        }
        if let agent = node.agentVersion, !agent.isEmpty { parts.append("agent \(agent)") }
        let place = [node.geo?.city, node.geo?.country, record.facts.provider.isEmpty ? nil : record.facts.provider]
            .compactMap { $0 }.filter { !$0.isEmpty }
        parts += place
        return parts.joined(separator: ", ")
    }

    private func headline(_ node: LatticeNode) -> String {
        let since = node.statusSince.flatMap { FleetAge.short($0) }
        switch node.honesty {
        case .online: return since.map { "Online for \($0)" } ?? "Online"
        case .degraded: return since.map { "Degraded for \($0)" } ?? "Degraded"
        case .offline: return since.map { "Offline for \($0)" } ?? "Offline"
        case .neverReported: return "Never reported"
        case .disabled: return since.map { "Disabled for \($0), cannot authenticate" } ?? "Disabled, cannot authenticate"
        }
    }

}

/// The node's state as the header's first row: glyph, the word with its
/// duration ("Offline for 12m"), colored for problems, and the reason.
struct FleetHonestyRow: View {
    let style: StatusStyle
    let headline: String
    var detail: String?
    let reason: String?
    var behind = 0

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var glyphWidth: CGFloat = 28

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            if !typeSize.isAccessibilitySize {
                StatusGlyph(style: style).frame(width: glyphWidth)
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Group {
                    if typeSize.isAccessibilitySize {
                        Text("\(Text(Image(systemName: style.symbol)).foregroundStyle(style.tone.glyph)) \(headline)")
                    } else {
                        Text(headline)
                    }
                }
                .font(.headline)
                .foregroundStyle(style.tone.isProblem ? style.tone.word : Color.primary)
                if let reason {
                    Text(reason).textRole(.rowReason(style.tone.word))
                }
                if let detail, !detail.isEmpty {
                    Text(detail).textRole(.rowDetail)
                }
                if behind > 0 {
                    Label {
                        Text(behind == 1 ? "1 behind the newest agent in this fleet" : "\(behind) behind the newest agent in this fleet")
                            .foregroundStyle(Color.statusWarnText)
                    } icon: {
                        Image(systemName: "arrow.down.circle").foregroundStyle(Color.statusWarnFill)
                    }
                    .font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Spacing.xs)
        .frame(minHeight: Spacing.minimumTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([headline, reason, detail, behind > 0 ? "\(behind) behind the newest agent" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isHeader)
    }
}
