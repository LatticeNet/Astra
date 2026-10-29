import SwiftUI

/// M6-02 Outbound policy: its rules, the nodes it targets and where each
/// node's last plan stands. Plan all outbound policies (P); edit and delete
/// on the web.
struct PolicyDetailScreen: View {
    let id: String

    @Environment(NetworkingStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        NetworkingListState(state: store.groupPolicies, noun: "the outbound policy", web: .policy(id: id),
                            retry: { Task { await store.refreshPolicies() } }) { policies in
            if let policy = policies.first(where: { $0.id == id }) {
                detail(policy)
            } else {
                notFound
            }
        }
        .navigationTitle(policy?.displayName ?? "Outbound policy")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(policy.map { $0.enabled ? "Enabled, priority \($0.priority)" : "Disabled" } ?? "")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NetworkingMoreMenu(link: NetworkingCopy.link(.policy(id: id), fallback: "lattice://policies/\(id)"), web: .policy(id: id)) {
                    NetworkingGatedButton(title: "Plan all outbound policies", systemImage: "doc.badge.gearshape", blocked: planAllBlocked) { planAll() }
                    Button("Edit on web", systemImage: "square.and.pencil") { router.openOnWeb(.policy(id: id)) }
                }
            }
        }
        .refreshable { await store.refreshPolicies() }
        .polling(.standard, version: changes.version([.policies, .nodes, .groups])) {
            await nodes.refreshIfOlder(than: 60)
            return await store.refreshPolicies()
        }
    }

    private var policy: NetworkingGroupPolicy? {
        store.groupPolicies.value?.first { $0.id == id }
    }

    private var docsByNode: [String: NetPolicy] {
        Dictionary((store.netPolicies.value ?? []).map { ($0.targetNodeID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func name(_ id: String) -> String {
        nodes.nodes[id]?.displayName ?? store.groupNames[id] ?? docsByNode[id]?.displayName ?? id
    }

    @ViewBuilder
    private func detail(_ policy: NetworkingGroupPolicy) -> some View {
        let docs = docsByNode
        let members = policy.targetNodeIDs.map { NetworkingNodePolicyRow(nodeID: $0, nodeName: name($0), policy: docs[$0]) }
            .sorted { ($0.state.map(rank) ?? 9, $0.nodeName) < ($1.state.map(rank) ?? 9, $1.nodeName) }
        let failed = members.filter { $0.state == .failed }.count
        let pending = members.filter { $0.state == .planned || $0.state == .notPlanned }.count
        List {
            Section {
                NetworkingRefreshError(state: store.groupPolicies, noun: "the outbound policy") { Task { await store.refreshPolicies() } }
                StatusRow(style: .networkingGroupPolicy(policy, failed: failed, pending: pending), title: policy.displayName,
                          detail: NetworkingText.target(policy.target, groupNames: store.groupNames, nodeName: name))
            }

            Section("Target") {
                if policy.target.all {
                    DetailRow(label: "Applies to", value: "The whole fleet", copyable: false)
                }
                ForEach(policy.target.groups, id: \.self) { group in
                    NavigationLink(value: AppRoute.fleet(.group(id: group))) {
                        LabeledContent("Node group") { Text(store.groupNames[group] ?? group).foregroundStyle(.secondary) }
                            .frame(minHeight: Spacing.minimumTarget)
                    }
                }
                ForEach(policy.target.nodes, id: \.self) { node in
                    NetworkingNodeLink(nodeID: node, label: "Node")
                }
                if !policy.target.exclude.isEmpty {
                    DetailRow(label: "Leaves out", value: ListFormatter.localizedString(byJoining: policy.target.exclude.map(name)), copyable: false)
                }
                if policy.hiddenTargetNodes > 0 {
                    Label("\(NetworkingText.plural(policy.hiddenTargetNodes, "named node")) this token cannot see", systemImage: "eye.slash")
                        .foregroundStyle(.secondary)
                        .frame(minHeight: Spacing.minimumTarget)
                }
                DetailRow(label: "Priority", value: "\(policy.priority)", secondary: "Lower merges first when several policies reach a node", copyable: false)
            }

            Section {
                if policy.rules.isEmpty {
                    Text("No rules").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
                }
                ForEach(policy.rules) { rule in
                    NetworkingRuleRow(rule: rule, names: name)
                }
            } header: {
                Text("Rules (\(policy.rules.count))")
            } footer: {
                Text("Rules merge into each target node's document in priority order. A group remote expands to the group's members when the plan compiles.")
            }

            Section {
                if members.isEmpty {
                    Text("The target resolves to no node this token can see.").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
                }
                ForEach(members) { member in
                    NavigationLink(value: AppRoute.networking(.nodePolicy(nodeID: member.nodeID))) {
                        StatusRow(style: .networkingNodePolicy(member), title: member.nodeName,
                                  detail: lastPlanText(member.policy),
                                  reason: member.policy.flatMap { $0.lastError.isEmpty ? nil : $0.lastError })
                    }
                }
            } header: {
                Text("Nodes (\(members.count))")
            } footer: {
                Text("Each node's last plan, built from every policy that reaches it.")
            }

            Section {
                NetworkingActionRow(title: "Plan all outbound policies", systemImage: "doc.badge.gearshape",
                                    detail: "Plans every covered node, not only this policy's", blocked: planAllBlocked) { planAll() }
                WebLinkRow(title: "Edit on web", path: .policy(id: policy.id))
                WebLinkRow(title: "Delete on web", path: .policy(id: policy.id))
            } footer: {
                FreshnessFooter(state: store.groupPolicies, interval: Polling.standard.interval(lowPower: false))
            }
        }
        .listStyle(.insetGrouped)
    }

    private func rank(_ state: NetworkingPolicyState) -> Int {
        switch state {
        case .failed: 0
        case .planned: 1
        case .notPlanned: 2
        case .applied: 3
        case .off: 4
        }
    }

    private func lastPlanText(_ doc: NetPolicy?) -> String {
        guard let doc else { return "no document yet" }
        guard !doc.lastPlanSHA.isEmpty else { return "never planned" }
        if let applied = doc.lastAppliedAt {
            return "plan \(NetworkingText.shortHash(doc.lastPlanSHA)), applied \(TimeDisplay.relative(applied, now: .now, locale: locale))"
        }
        return "plan \(NetworkingText.shortHash(doc.lastPlanSHA)), not applied"
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Not found", systemImage: "questionmark.square.dashed")
            } description: {
                Text("This outbound policy was deleted, or it is not visible to this token.")
            } actions: {
                Button("Token scopes") { router.openSettings([.page(.scopes)]) }.buttonStyle(.bordered)
                Button("Open on web") { router.openOnWeb(.policy(id: id)) }
            }
        }
    }

    private var coveredNodes: [ObjectRef] {
        let ids = Set((store.groupPolicies.value ?? []).filter(\.enabled).flatMap(\.targetNodeIDs))
        return ids.map { ObjectRef(kind: "node", id: $0, name: name($0)) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var planAllBlocked: String? {
        if let blocked = store.blocked([NetworkingIntents.policyAdmin]) { return blocked }
        return coveredNodes.isEmpty ? "No enabled policy covers a node" : nil
    }

    private func planAll() {
        Task { await runner.run(NetworkingIntents.planAllGroupPolicies(covered: coveredNodes)) }
    }
}
