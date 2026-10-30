import SwiftUI

/// M2-07 Beacon: the node's UDP responder, its key epoch and age, whether
/// it listens, and which sources reach it. Plan beacon and Disable beacon
/// file approvals (P); Rotate key is a direct T3 change. A server without
/// beacons (404) reads "No beacon on this node", not an error.
struct NodeBeaconScreen: View {
    let nodeID: String

    @Environment(SessionStore.self) private var session
    @Environment(FleetStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @State private var state: ResourceState<FleetBeaconView> = .idle

    private var node: ObjectRef {
        store.record(id: nodeID).map { FleetIntents.nodeRef($0.node) } ?? ObjectRef(kind: "node", id: nodeID)
    }

    var body: some View {
        Group {
            if case .failed(.notFound, _, _) = state {
                WholeScreenState {
                    ContentUnavailableView("No beacon on this node", systemImage: "dot.radiowaves.left.and.right",
                                           description: Text("This server does not run beacons, or the node is gone."))
                }
            } else {
                FleetListState(state: state, noun: "the beacon", retry: { Task { await load() } }) { beacon in
                    content(beacon)
                }
            }
        }
        .navigationTitle(node.name)
        .navigationSubtitle("Beacon")
        // Opened by a link, the nodes list may not be loaded yet; the title, path and group names need it.
        .task { if store.nodes.value == nil { _ = await store.refresh() } }
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .polling(.standard, version: changes.version([.paths, .approvals, .nodes])) { await load() }
    }

    private func content(_ beacon: FleetBeaconView) -> some View {
        List {
            FleetRefreshError(state: state, noun: "the beacon") { Task { await load() } }
            Section {
                StatusRow(style: Self.style(beacon), title: "Beacon", detail: beacon.isEnabled ? beacon.exposureWords : nil,
                          reason: beacon.reason.isEmpty ? nil : PathReason.sentence(for: beacon.reason).sentenceCased)
                if !beacon.pendingApprovalID.isEmpty {
                    Button {
                        router.present(.review(.single(beacon.pendingApprovalID)))
                    } label: {
                        Label("A beacon plan is waiting for approval", systemImage: "hand.raised.fill")
                            .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                    }
                }
                if let replan = beacon.replan {
                    Label {
                        Text(Self.replanSentence(replan)).foregroundStyle(Color.statusWarnText)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarnFill)
                    }
                }
            }
            if let applied = beacon.applied, applied.enabled {
                Section("Applied") {
                    DetailRow(label: "Port", value: "UDP \(applied.port)", copyable: false)
                    if !applied.bind.isEmpty { DetailRow(label: "Bind", value: applied.bind, monospaced: true) }
                    if !applied.endpoint.isEmpty { DetailRow(label: "Endpoint", value: applied.endpoint, monospaced: true) }
                    DetailRow(label: "Key epoch", value: String(beacon.epoch), copyable: false)
                    if let rotated = beacon.rotatedAt {
                        DetailRow(label: "Key age", value: FleetAge.short(rotated) ?? "", secondary: TimeDisplay.dateTime(rotated, mode: mode, locale: locale), copyable: false)
                    }
                    if let applied = beacon.appliedAt {
                        DetailRow(label: "Applied", value: "\(FleetAge.short(applied) ?? "") ago", copyable: false)
                    }
                }
            } else if beacon.suggestedPort > 0 {
                Section("Off") {
                    DetailRow(label: "Port an enable takes", value: "UDP \(beacon.suggestedPort)", copyable: false)
                }
            }
            if let agent = beacon.agent {
                Section("Agent") {
                    DetailRow(label: "Responder", value: agent.responder ? "Supported" : "Not supported by this agent", copyable: false)
                    if !agent.state.isEmpty { DetailRow(label: "Socket", value: agent.state.replacingOccurrences(of: "_", with: " "), copyable: false) }
                    if let auth = beacon.lastAuthAt ?? agent.lastAuthAt {
                        TimelineView(.periodic(from: .now, by: FleetAge.tick)) { context in
                            DetailRow(label: "Last seen by a source", value: "\(FleetAge.short(auth, now: context.date) ?? "") ago", copyable: false)
                        }
                    }
                    if !agent.error.isEmpty {
                        Text(agent.error).textRole(.code).foregroundStyle(Color.statusFailText)
                    }
                }
            }
            if !beacon.reachability.state.isEmpty {
                Section("Reachability") {
                    StatusRow(style: Self.reachStyle(beacon.reachability.state), title: "Check from \(store.record(id: beacon.reachability.source)?.node.displayName ?? beacon.reachability.source)",
                              detail: beacon.reachability.checkedAt.map { "\(FleetAge.short($0) ?? "") ago" })
                }
            }
            if !beacon.sources.isEmpty {
                Section {
                    ForEach(beacon.sources) { source in
                        NavigationLink(value: AppRoute.fleet(.node(id: source.nodeID))) {
                            StatusRow(style: source.approved ? StatusStyle(word: "approved", symbol: "checkmark.circle", tone: .ok)
                                                             : StatusStyle(word: source.reason.isEmpty ? "waiting" : PathReason.sentence(for: source.reason), symbol: "hourglass", tone: .quiet),
                                      title: source.displayName, detail: source.current ? "Probing now" : "Approved, not probing")
                        }
                    }
                } header: {
                    Text("Sources (\(beacon.sources.count))")
                }
            }
            actions(beacon)
            Section {
            } footer: {
                FleetFooter(state: state)
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func actions(_ beacon: FleetBeaconView) -> some View {
        let planScopes = ["monitor:admin", "node:admin", "network:plan"] + (beacon.carriesNetGuard ? ["netguard:admin"] : [])
        let planMissing = missing(planScopes)
        Section {
            FleetActionRow(title: beacon.isEnabled ? "Replan beacon" : "Plan beacon", systemImage: "doc.badge.plus", missing: planMissing) {
                Task { await runner.run(FleetIntents.planBeacon(node, request: beacon.planRequest, netGuard: beacon.carriesNetGuard)) }
            }
            if beacon.isEnabled {
                FleetActionRow(title: "Disable beacon", systemImage: "antenna.radiowaves.left.and.right.slash", missing: planMissing, destructive: true) {
                    Task { await runner.run(FleetIntents.planBeacon(node, request: beacon.disableRequest, netGuard: beacon.carriesNetGuard)) }
                }
                FleetActionRow(title: "Rotate key", systemImage: "key", missing: missing(["monitor:admin", "node:admin"])) {
                    Task { await runner.run(FleetIntents.rotateBeacon(node)) }
                }
            }
        } header: {
            Text("Actions")
        } footer: {
            Text(beacon.carriesNetGuard ? "Plans on this node carry NetGuard rules, so they also need netguard:admin." : "Plans file an approval; nothing changes until someone approves it.")
        }
    }

    private func missing(_ scopes: [String]) -> String? {
        guard let missing = session.missing(ScopeRequirement(groups: scopes.map { [$0] })), !missing.isEmpty else { return nil }
        return missing.joined(separator: " and ")
    }

    static func style(_ beacon: FleetBeaconView) -> StatusStyle {
        switch beacon.state {
        case "listening": StatusStyle(word: "listening", symbol: "dot.radiowaves.left.and.right", tone: .ok)
        case "pending": StatusStyle(word: "pending", symbol: "hourglass", tone: .quiet)
        case "off": StatusStyle(word: "off", symbol: "circle", tone: .quiet)
        default: StatusStyle(word: beacon.stateWord, symbol: "exclamationmark.triangle.fill", tone: .warn)
        }
    }

    static func reachStyle(_ state: String) -> StatusStyle {
        switch state {
        case "reachable": StatusStyle(word: "reachable", symbol: "checkmark.circle.fill", tone: .ok)
        case "pending": StatusStyle(word: "pending", symbol: "hourglass", tone: .quiet)
        default: StatusStyle(word: state.replacingOccurrences(of: "_", with: " "), symbol: "xmark.circle.fill", tone: .fail)
        }
    }

    static func replanSentence(_ replan: FleetBeaconReplan) -> String {
        var parts: [String] = []
        if !replan.added.isEmpty { parts.append(replan.added.count == 1 ? "1 new source waits" : "\(replan.added.count) new sources wait") }
        if !replan.removed.isEmpty { parts.append(replan.removed.count == 1 ? "1 old source is still admitted" : "\(replan.removed.count) old sources are still admitted") }
        return (parts.isEmpty ? "Sources changed" : parts.joined(separator: " and ")) + ". Replan the beacon to match."
    }

    @discardableResult
    private func load() async -> Bool {
        if let missing = session.missing(ScopeRequirement("monitor:read")), !missing.isEmpty {
            state = .denied(scope: missing.joined(separator: " and "))
            return true
        }
        guard let client = session.client else { return false }
        state = state.reloading
        do {
            state = .loaded(try await client.fleetBeacon(nodeID: nodeID), at: Date())
            return true
        } catch {
            state = state.failing(LatticeAPIError(error), surface: "Beacon", missingScope: "monitor:read")
            return false
        }
    }
}

fileprivate extension FleetBeaconView {
    /// "Reached through NetGuard" or "Open to the internet".
    var exposureWords: String {
        exposure == "netguard" ? "Admitted through NetGuard" : (exposure == "internet" ? "Open to the internet" : "")
    }
}
