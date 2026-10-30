import SwiftUI

/// NodeDetail's Settings tab (M2-03): identity, groups, location, address
/// discovery, diagnostics, agent updates, beacon, token and the danger zone.
/// Every write goes through ActionRunner at its parity-matrix tier; without
/// node:admin the rows stay, disabled, with "Needs node:admin".
struct NodeSettingsSection: View {
    let model: FleetNodeDetailModel
    @Binding var showsIdentity: Bool

    @Environment(ActionRunner.self) private var runner
    @Environment(FleetStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var debugOverride: Bool?
    @State private var preparingDelete = false
    @State private var deleteError: String?

    var body: some View {
        if let record = model.record.value {
            let admin = store.missing("node:admin")
            List {
                FleetNodeHeader(record: record, fleetVersions: model.fleetVersions)
                if let admin {
                    Section {
                        Label("Changing these settings needs \(admin); this token can read them.", systemImage: "lock")
                            .foregroundStyle(.secondary)
                    }
                }
                identity(record, admin: admin)
                groups(record)
                geo(record, admin: admin)
                ipDiscovery(record)
                diagnostics(record, admin: admin)
                agentUpdates(record)
                beacon(record)
                token(record, admin: admin)
                danger(record, admin: admin)
            }
            .listStyle(.insetGrouped)
            .refreshable {
                await model.refreshCore()
                await model.refreshSettings()
            }
            .announcing(deleteError)
        }
    }

    // MARK: Identity

    private func identity(_ record: FleetNodeRecord, admin: String?) -> some View {
        let node = record.node
        return Section {
            DetailRow(label: "Name", value: node.displayName)
            DetailRow(label: "Tags", value: node.tags.isEmpty ? "None" : node.tags.joined(separator: ", "), copyable: !node.tags.isEmpty)
            DetailRow(label: "Role", value: (node.role ?? "").isEmpty ? "None" : node.role ?? "", copyable: false)
            if !node.comment.isEmpty { DetailRow(label: "Comment", value: node.comment, copyable: false) }
            FleetActionRow(title: "Edit identity", systemImage: "pencil", missing: admin) { showsIdentity = true }
        } header: {
            Text("Identity")
        }
    }

    // MARK: Groups

    @ViewBuilder
    private func groups(_ record: FleetNodeRecord) -> some View {
        Section("Groups") {
            if record.node.groupIDs.isEmpty {
                Text("In no group").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget, alignment: .leading)
            }
            ForEach(record.node.groupIDs, id: \.self) { id in
                NavigationLink(value: AppRoute.fleet(.group(id: id))) {
                    Label(store.groupName(id) ?? id, systemImage: "rectangle.3.group")
                        .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                }
            }
        }
    }

    // MARK: Location

    private func geo(_ record: FleetNodeRecord, admin: String?) -> some View {
        let node = record.node
        let ref = FleetIntents.nodeRef(node)
        return Section {
            DetailRow(label: "Country", value: node.geo?.country ?? "Not set", copyable: false)
            DetailRow(label: "City", value: [node.geo?.city, node.geo?.region].compactMap { $0 }.first { !$0.isEmpty } ?? "Not set", copyable: false)
            FleetActionRow(title: "Resolve from public IP", systemImage: "location.magnifyingglass", missing: admin) {
                Task { await runner.run(FleetIntents.resolveGeo(ref, ip: node.publicIP ?? "")) }
            }
            FleetActionRow(title: "Clear location", systemImage: "location.slash", missing: admin ?? (node.geo == nil ? "a location to clear" : nil)) {
                Task { await runner.run(FleetIntents.clearGeo(ref)) }
            }
            WebLinkRow(title: "Set location on web", path: .node(id: node.id, view: .settings))
        } header: {
            Text("Location")
        }
    }

    // MARK: Address discovery

    private func ipDiscovery(_ record: FleetNodeRecord) -> some View {
        let config = record.facts.ipConfig
        return Section {
            DetailRow(label: "Mode", value: Self.modeWord(config?.mode ?? ""), copyable: false)
            if let config, !config.staticIPv4.isEmpty { DetailRow(label: "Static IPv4", value: config.staticIPv4, monospaced: true) }
            if let config, !config.staticIPv6.isEmpty { DetailRow(label: "Static IPv6", value: config.staticIPv6, monospaced: true) }
            if let config, !config.resolvers.isEmpty { DetailRow(label: "Resolvers", value: config.resolvers.joined(separator: "\n"), monospaced: true) }
            if let config, !config.scriptSHA256.isEmpty { DetailRow(label: "Script digest", value: config.scriptSHA256, monospaced: true) }
            WebLinkRow(title: "Change on web", path: .node(id: record.id, view: .settings))
        } header: {
            Text("IP discovery")
        } footer: {
            Text("A wrong override can cut the node off, so it changes on the web.")
        }
    }

    static func modeWord(_ mode: String) -> String {
        switch mode {
        case "", "auto": "Automatic"
        case "static": "Static address"
        case "resolver": "IP-echo resolvers"
        case "script": "Script"
        default: mode
        }
    }

    // MARK: Diagnostics

    private func diagnostics(_ record: FleetNodeRecord, admin: String?) -> some View {
        let enabled = debugOverride ?? record.facts.agentDebug.enabled
        let ref = FleetIntents.nodeRef(record.node)
        return Section {
            Toggle(isOn: Binding(get: { enabled }, set: { wanted in
                Task {
                    let outcome = await runner.run(FleetIntents.agentDebug(ref, enabled: wanted))
                    if case .done = outcome { debugOverride = wanted }
                }
            })) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Agent debug")
                    Text(admin.map { "Needs \($0)" } ?? "Verbose, non-secret diagnostics, collected in Logs")
                        .textRole(.rowDetail)
                }
            }
            .disabled(admin != nil)
            .frame(minHeight: Spacing.minimumTarget)
            // The written value shows until the next read; from then on the server's state wins.
            .onChange(of: model.record.loadedAt) { debugOverride = nil }
        } header: {
            Text("Diagnostics")
        }
    }

    // MARK: Agent updates

    private func agentUpdates(_ record: FleetNodeRecord) -> some View {
        let ref = FleetIntents.nodeRef(record.node)
        let missing = store.missing("node:admin", "network:plan")
        return Section {
            NavigationLink(value: AppRoute.sshGuard(.agentUpdates(view: "nodes", nodeID: record.id))) {
                FleetRelatedRow(title: "Agent updates", symbol: "arrow.down.circle", detail: "Running \(record.node.agentVersion ?? "no agent yet")")
            }
            FleetActionRow(title: "Plan update", systemImage: "doc.badge.plus", missing: missing) {
                Task { await runner.run(FleetIntents.planAgentUpdate(ref, force: false)) }
            }
            FleetActionRow(title: "Force plan", systemImage: "doc.badge.ellipsis", missing: missing) {
                Task { await runner.run(FleetIntents.planAgentUpdate(ref, force: true)) }
            }
            policyRow
            WebLinkRow(title: "Auto-update policy on web", path: .agentUpdatePolicy(nodeID: record.id))
        } header: {
            Text("Agent update")
        } footer: {
            Text("Plans file an approval; nothing changes until someone approves it.")
        }
    }

    /// The policy is edited on the web (parity matrix W); here it is read.
    @ViewBuilder
    private var policyRow: some View {
        switch model.agentPolicy {
        case .denied(let scope):
            ScopeDeniedRow(scope: scope)
        case .companionBehind:
            DetailRow(label: "Auto-update policy", value: "Not on this server", copyable: false)
        case .failed(_, nil, _):
            DetailRow(label: "Auto-update policy", value: "Could not load", copyable: false)
        default:
            DetailRow(label: "Auto-update policy", value: model.agentPolicy.value.map(Self.policySummary) ?? "Loading", copyable: false)
        }
    }

    /// "Automatic, target latest", "Manual, target 0.4.1", "Policy off" or "No policy".
    static func policySummary(_ policy: AgentUpdatesPolicy?) -> String {
        let state = AgentUpdatesPolicyState.of(policy)
        guard let policy, state == .manual || state == .auto else { return state.word.prefix(1).uppercased() + state.word.dropFirst() }
        let target = policy.targetVersion.isEmpty ? "latest" : policy.targetVersion
        return "\(state == .auto ? "Automatic" : "Manual"), target \(target)"
    }

    // MARK: Beacon

    @ViewBuilder
    private func beacon(_ record: FleetNodeRecord) -> some View {
        let ref = FleetIntents.nodeRef(record.node)
        Section {
            switch model.beacon {
            case .denied(let scope):
                ScopeDeniedRow(scope: scope)
            default:
                let view = model.beacon.value
                let planScopes = ["monitor:admin", "node:admin", "network:plan"] + (view?.carriesNetGuard == true ? ["netguard:admin"] : [])
                let planMissing = missingAll(planScopes) ?? (view == nil ? "the beacon state" : nil)
                FleetActionRow(title: view?.isEnabled == true ? "Replan beacon" : "Plan beacon", systemImage: "dot.radiowaves.left.and.right", missing: planMissing) {
                    guard let view else { return }
                    Task { await runner.run(FleetIntents.planBeacon(ref, request: view.planRequest, netGuard: view.carriesNetGuard)) }
                }
                FleetActionRow(title: "Rotate beacon key", systemImage: "key", missing: missingAll(["monitor:admin", "node:admin"]) ?? (view?.isEnabled == true ? nil : "an enabled beacon")) {
                    Task { await runner.run(FleetIntents.rotateBeacon(ref)) }
                }
            }
        } header: {
            Text("Beacon")
        }
    }

    private func missingAll(_ scopes: [String]) -> String? {
        guard let missing = session.missing(ScopeRequirement(groups: scopes.map { [$0] })), !missing.isEmpty else { return nil }
        return missing.joined(separator: " and ")
    }

    // MARK: Token

    private func token(_ record: FleetNodeRecord, admin: String?) -> some View {
        Section {
            FleetActionRow(title: "Rotate token", systemImage: "key.horizontal", missing: admin) {
                Task { await runner.run(FleetIntents.rotateToken(FleetIntents.nodeRef(record.node))) }
            }
            WebLinkRow(title: "Reconfigure on web", path: .node(id: record.id, view: .settings))
        } header: {
            Text("Token")
        } footer: {
            Text("\(record.node.displayName) stops reporting until the new token is installed on the host. To cut off a leaked token, disable the node instead.")
        }
    }

    // MARK: Danger

    private func danger(_ record: FleetNodeRecord, admin: String?) -> some View {
        let node = record.node
        let ref = FleetIntents.nodeRef(node)
        return Section {
            if node.honesty == .disabled {
                FleetActionRow(title: "Enable \(node.displayName)", systemImage: "checkmark.circle", missing: admin) {
                    Task { await runner.run(FleetIntents.enable(ref)) }
                }
            } else {
                FleetActionRow(title: "Disable \(node.displayName)", systemImage: "minus.circle", missing: admin, destructive: true) {
                    Task { await runner.run(FleetIntents.disable(ref)) }
                }
            }
            FleetActionRow(title: preparingDelete ? "Checking what would be deleted" : "Delete node", systemImage: "trash",
                           missing: admin, destructive: true, busy: preparingDelete) {
                Task { await delete(ref) }
            }
            if let deleteError {
                Text(deleteError).foregroundStyle(Color.statusFailText).font(.subheadline)
            }
        } header: {
            Text("Danger")
        } footer: {
            Text("Disabling refuses the agent's token until you enable it again; nothing is deleted. Deleting removes the node and what refers to it, and shows everything first.")
        }
    }

    private func delete(_ ref: ObjectRef) async {
        guard let client = session.client else { return }
        deleteError = nil
        preparingDelete = true
        let intent: WriteIntent
        do {
            intent = try await NodeDeleteIntent.make(node: ref, client: client)
        } catch {
            preparingDelete = false
            deleteError = "Could not check what would be deleted: \(LatticeAPIError(error).localizedDescription)"
            return
        }
        preparingDelete = false
        switch await runner.run(intent) {
        case .done, .partial: dismiss()
        default: break
        }
    }
}

/// A button row for an action, with its symbol; disabled with the reason
/// as a second line when it cannot run.
struct FleetActionRow: View {
    let title: String
    let systemImage: String
    let missing: String?
    var destructive = false
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            HStack(spacing: Spacing.m) {
                if busy {
                    ProgressView()
                } else {
                    Image(systemName: systemImage)
                        .foregroundStyle(missing != nil ? Color.secondary : (destructive ? Color.statusFailText : Color.accentText))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title)
                        .foregroundStyle(missing != nil ? Color.secondary : (destructive ? Color.statusFailText : Color.accentText))
                    if let missing {
                        Text("Needs \(missing)").textRole(.rowDetail)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Spacing.minimumTarget)
            .contentShape(Rectangle())
        }
        .disabled(missing != nil || busy)
        .accessibilityHint(missing.map { "Unavailable. Needs \($0)." } ?? "")
    }
}
