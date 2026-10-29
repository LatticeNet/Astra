import SwiftUI

/// M2-05 Effective network: the outbound policy that decides the node's
/// egress with its rules, the inbound firewall (pushes M6's screen), SSH
/// Guard, the mesh and the tables Lattice writes. Sections the token cannot
/// read are refused by the server whole and say which scope.
struct NodeNetworkScreen: View {
    let nodeID: String

    @Environment(SessionStore.self) private var session
    @Environment(FleetStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @State private var state: ResourceState<FleetNodeNetworkView> = .idle

    var body: some View {
        FleetListState(state: state, noun: "the effective network", retry: { Task { await load() } }) { view in
            List {
                FleetRefreshError(state: state, noun: "the effective network") { Task { await load() } }
                outbound(view)
                inbound(view)
                access(view)
                mesh(view)
                tables(view)
                Section {
                } footer: {
                    FleetFooter(state: state)
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle(store.record(id: nodeID)?.node.displayName ?? nodeID)
        // Opened by a link, the nodes list may not be loaded yet; the title needs it.
        .task { if store.nodes.value == nil { _ = await store.refresh() } }
        .navigationSubtitle("Effective network")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .polling(.standard, version: changes.version([.policies, .netguard, .sshguard])) { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.node(id: nodeID)) }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
    }

    @Environment(Router.self) private var router

    @discardableResult
    private func load() async -> Bool {
        if let missing = session.missing(ScopeRequirement("node:read")), !missing.isEmpty {
            state = .denied(scope: missing.joined(separator: " and "))
            return true
        }
        guard let client = session.client else { return false }
        state = state.reloading
        do {
            state = .loaded(try await client.fleetNodeNetwork(nodeID: nodeID, rules: true), at: Date())
            return true
        } catch {
            state = state.failing(LatticeAPIError(error), surface: "Effective network", missingScope: "node:read")
            return false
        }
    }

    // MARK: Outbound

    @ViewBuilder
    private func outbound(_ view: FleetNodeNetworkView) -> some View {
        if let outbound = view.outbound {
            Section {
                if outbound.section.isRefused {
                    ScopeDeniedRow(scope: outbound.section.scope)
                } else {
                    DetailRow(label: "Effective policy", value: outbound.effectiveTitle, copyable: false)
                    DetailRow(label: "Rules on this node", value: String(outbound.ruleCount), copyable: false)
                    DetailRow(label: "Default", value: outbound.defaultDrop ? "Drop what no rule allows" : "Accept what no rule drops", copyable: false)
                    ForEach(outbound.policies) { policy in
                        NavigationLink(value: AppRoute.networking(.policy(id: policy.id))) {
                            StatusRow(style: Self.policyStyle(policy.state), title: policy.displayName,
                                      detail: "\(policy.reachSentence), priority \(policy.priority)",
                                      trailing: policy.rules == 1 ? "1 rule" : "\(policy.rules) rules")
                        }
                    }
                    NavigationLink(value: AppRoute.networking(.nodePolicy(nodeID: nodeID))) {
                        FleetRelatedRow(title: "Node policy", symbol: "doc.text", detail: outbound.manual == nil ? "No manual document" : "Manual document owns this node")
                    }
                }
            } header: {
                Text("Outbound")
            }
            let rules = view.outboundRules
            if !outbound.section.isRefused, !rules.isEmpty {
                Section {
                    ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                        Text(rule)
                            .textRole(.code)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
                    }
                } header: {
                    Text("Rules as they compile now")
                } footer: {
                    Text("Direction, protocol, ports and peer, as nftables writes them.")
                }
            }
        }
    }

    static func policyStyle(_ state: String) -> StatusStyle {
        switch state {
        case "applies": StatusStyle(word: "applies", symbol: "checkmark.circle.fill", tone: .ok)
        case "blocked": StatusStyle(word: "blocked by the manual policy", symbol: "hand.raised", tone: .warn)
        case "excluded": StatusStyle(word: "excludes this node", symbol: "minus.circle", tone: .quiet)
        case "disabled": StatusStyle(word: "disabled", symbol: "minus.circle", tone: .quiet)
        default: StatusStyle(word: "no rule reaches this node", symbol: "circle", tone: .quiet)
        }
    }

    // MARK: Inbound

    @ViewBuilder
    private func inbound(_ view: FleetNodeNetworkView) -> some View {
        if let inbound = view.inbound {
            Section {
                if inbound.section.isRefused {
                    ScopeDeniedRow(scope: inbound.section.scope)
                } else {
                    NavigationLink(value: AppRoute.networking(.inboundFirewall(nodeID: nodeID))) {
                        FleetRelatedRow(title: "Inbound firewall", symbol: "shield.lefthalf.filled", detail: inboundDetail(inbound))
                    }
                    ForEach(inbound.securityGroups + inbound.derivedSecurityGroups) { group in
                        NavigationLink(value: AppRoute.networking(.securityGroup(id: group.id))) {
                            StatusRow(style: StatusStyle(word: group.state.isEmpty ? "bound" : group.state, symbol: "shield", tone: group.state == "inactive" ? .quiet : .ok),
                                      title: group.displayName,
                                      detail: group.via.map { "Through \($0.displayName)" },
                                      reason: group.reason.isEmpty ? nil : group.reason,
                                      trailing: group.rules == 1 ? "1 rule" : "\(group.rules) rules")
                        }
                    }
                    ForEach(Array(inbound.extraPorts.enumerated()), id: \.offset) { _, port in
                        DetailRow(label: port.source == "beacon" ? "Beacon port" : (port.label.isEmpty ? port.source : port.label),
                                  value: "\(port.protocols.joined(separator: ", ").uppercased()) \(port.port)", copyable: false)
                    }
                }
            } header: {
                Text("Inbound")
            }
        }
    }

    private func inboundDetail(_ inbound: FleetNetworkInbound) -> String {
        var parts = [inbound.firewallTitle]
        if !inbound.zones.isEmpty { parts.append(inbound.zones.map(\.displayName).joined(separator: ", ")) }
        let groups = inbound.securityGroups.count + inbound.derivedSecurityGroups.count
        if groups > 0 { parts.append(groups == 1 ? "1 security group" : "\(groups) security groups") }
        if inbound.driftState == "drift" { parts.append("drift") }
        return parts.joined(separator: ", ")
    }

    // MARK: Access

    @ViewBuilder
    private func access(_ view: FleetNodeNetworkView) -> some View {
        if let access = view.access {
            Section {
                if access.section.isRefused {
                    ScopeDeniedRow(scope: access.section.scope)
                } else {
                    NavigationLink(value: AppRoute.sshGuard(.node(id: nodeID))) {
                        let posture = SSHGuardPostureState(rawValue: access.posture) ?? .unknown
                        StatusRow(style: StatusStyle.posture(posture), title: "SSH Guard",
                                  detail: access.enrolled ? (access.knockRequired ? "Enrolled, knock required" : "Enrolled") : "Not enrolled",
                                  reason: access.revertArmed ? "The automatic revert is armed" : nil)
                    }
                }
            } header: {
                Text("Access")
            }
        }
    }

    // MARK: Mesh

    @ViewBuilder
    private func mesh(_ view: FleetNodeNetworkView) -> some View {
        if let mesh = view.mesh {
            Section {
                if mesh.section.isRefused {
                    ScopeDeniedRow(scope: mesh.section.scope)
                } else {
                    StatusRow(style: mesh.ready ? StatusStyle(word: "ready", symbol: "checkmark.circle.fill", tone: .ok)
                                                : StatusStyle(word: "not in the mesh", symbol: "circle.dashed", tone: .quiet),
                              title: "WireGuard mesh",
                              detail: mesh.missing.isEmpty ? (mesh.peersRefused.isEmpty ? "\(mesh.peers) peers" : "Peers need \(mesh.peersRefused)") : "Missing \(mesh.missing.joined(separator: ", "))")
                    if !mesh.address.isEmpty { DetailRow(label: "Address", value: mesh.address, monospaced: true) }
                    if !mesh.endpoint.isEmpty { DetailRow(label: "Endpoint", value: mesh.endpoint, monospaced: true) }
                }
            } header: {
                Text("Mesh")
            }
        }
    }

    // MARK: Tables

    @ViewBuilder
    private func tables(_ view: FleetNodeNetworkView) -> some View {
        if !view.tables.isEmpty {
            Section {
                ForEach(view.tables) { table in
                    let owners = table.owners.filter { $0.state == "writes" }.map { $0.kind.replacingOccurrences(of: "_", with: " ") }
                    StatusRow(
                        style: table.replanPending
                            ? StatusStyle(word: "replan pending", symbol: "exclamationmark.triangle.fill", tone: .warn)
                            : StatusStyle(word: table.compileNow?.state == "none" ? "nothing to write" : "as applied", symbol: "tablecells", tone: table.replanPending ? .warn : .quiet),
                        title: table.title,
                        detail: owners.isEmpty ? table.table : "\(table.table), written by \(owners.joined(separator: ", "))",
                        reason: table.replanPending ? "What would compile now differs from what was last applied." : (table.rulesWithheld == "knock" ? "Its rules are the knock sequence, so they are never shown." : nil)
                    )
                }
            } header: {
                Text("Tables Lattice writes")
            }
        }
    }
}
