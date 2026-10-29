import SwiftUI

/// M6-03 One node's outbound document: its rules, where its last plan
/// stands and the policies it is built from. Plan node policy (P), convert
/// a manual document into an outbound policy (T3, then P), edit on web.
struct NodePolicyScreen: View {
    let nodeID: String

    @Environment(NetworkingStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    @State private var convertName = ""
    @State private var convertPriority = ""
    @FocusState private var focused: Bool

    private var web: LatticeConsolePath { LatticeConsolePath(path: "/network/outbound", query: [URLQueryItem(name: "view", value: "nodes"), URLQueryItem(name: "open", value: nodeID)]) }

    var body: some View {
        NetworkingListState(state: store.netPolicies, noun: "the node's policy", web: web,
                            retry: { Task { await store.refreshPolicies() } }) { docs in
            content(docs.first { $0.targetNodeID == nodeID })
        }
        .navigationTitle(nodeName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NetworkingMoreMenu(link: nil, web: web) {
                    if let doc {
                        NetworkingGatedButton(title: "Plan this node", systemImage: "doc.badge.gearshape", blocked: planBlocked(doc)) { plan() }
                    }
                    Button("Open node", systemImage: "server.rack") { router.push(.fleet(.node(id: nodeID))) }
                    Button("Inbound firewall", systemImage: "shield.lefthalf.filled") { router.push(.networking(.inboundFirewall(nodeID: nodeID))) }
                    Button("Edit on web", systemImage: "square.and.pencil") { router.openOnWeb(web) }
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
            }
        }
        .refreshable { await store.refreshPolicies() }
        .polling(.standard, version: changes.version([.policies, .nodes, .groups])) {
            await nodes.refreshIfOlder(than: 60)
            return await store.refreshPolicies()
        }
    }

    private var doc: NetPolicy? { store.netPolicies.value?.first { $0.targetNodeID == nodeID } }
    private var nodeName: String { nodes.nodes[nodeID]?.displayName ?? doc?.displayName ?? nodeID }

    private var subtitle: String {
        guard let doc else { return store.netPolicies.value == nil ? "" : "No policy" }
        return NetworkingPolicyState.of(doc).word.networkingCapitalized
    }

    private func name(_ id: String) -> String {
        nodes.nodes[id]?.displayName ?? store.groupNames[id] ?? id
    }

    @ViewBuilder
    private func content(_ doc: NetPolicy?) -> some View {
        List {
            Section {
                NetworkingRefreshError(state: store.netPolicies, noun: "the node's policy") { Task { await store.refreshPolicies() } }
                let row = NetworkingNodePolicyRow(nodeID: nodeID, nodeName: nodeName, policy: doc)
                StatusRow(style: .networkingNodePolicy(row), title: nodeName,
                          detail: doc == nil ? "egress not filtered" : row.kind.word,
                          reason: doc.flatMap { $0.lastError.isEmpty ? nil : $0.lastError })
            }
            if let doc {
                facts(doc)
                rules(doc)
                builtFrom(doc)
                actions(doc)
            } else {
                Section {
                    Text("No outbound policy reaches \(nodeName) and it has no policy of its own, so nothing filters its egress.")
                        .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                    WebLinkRow(title: "Write a policy on web", path: LatticeConsolePath(path: "/network/outbound"))
                }
            }
            Section {
                NetworkingNodeLink(nodeID: nodeID)
                NavigationLink(value: AppRoute.networking(.inboundFirewall(nodeID: nodeID))) {
                    Label("Inbound firewall", systemImage: "shield.lefthalf.filled").frame(minHeight: Spacing.minimumTarget)
                }
            } header: {
                Text("Node")
            } footer: {
                FreshnessFooter(state: store.netPolicies, interval: Polling.standard.interval(lowPower: false))
            }
        }
        .listStyle(.insetGrouped)
    }

    private func facts(_ doc: NetPolicy) -> some View {
        Section("Last plan") {
            DetailRow(label: "State", value: NetworkingPolicyState.of(doc).word.networkingCapitalized, copyable: false)
            if !doc.lastPlanSHA.isEmpty {
                DetailRow(label: "Plan hash", value: doc.lastPlanSHA, monospaced: true)
            }
            if let applied = doc.lastAppliedAt {
                DetailRow(label: "Applied", value: TimeDisplay.dateTime(applied, mode: mode, locale: locale),
                          secondary: TimeDisplay.otherZone(applied, mode: mode, locale: locale), copyable: false)
            }
            if let updated = doc.updatedAt {
                DetailRow(label: "Changed", value: TimeDisplay.relative(updated, now: .now, locale: locale), copyable: false)
            }
            if !doc.lastError.isEmpty {
                DetailRow(label: "Last error", value: doc.lastError)
            }
        }
    }

    private func rules(_ doc: NetPolicy) -> some View {
        Section {
            if doc.rules.isEmpty {
                Text("No rules").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
            }
            ForEach(doc.rules) { rule in
                NetworkingRuleRow(rule: rule, names: name)
            }
        } header: {
            Text("Rules (\(doc.rules.count))")
        }
    }

    @ViewBuilder
    private func builtFrom(_ doc: NetPolicy) -> some View {
        if doc.groupDerived {
            let sources = (store.groupPolicies.value ?? []).filter { $0.enabled && $0.targetNodeIDs.contains(nodeID) }
            Section {
                if sources.isEmpty {
                    Text("No enabled outbound policy reaches this node any more. Plan all outbound policies reports it as orphaned.")
                        .foregroundStyle(Color.statusWarnText)
                        .frame(minHeight: Spacing.minimumTarget)
                }
                ForEach(sources) { policy in
                    NavigationLink(value: AppRoute.networking(.policy(id: policy.id))) {
                        StatusRow(style: StatusStyle(word: "priority \(policy.priority)", symbol: "arrow.up.forward.circle", tone: .quiet),
                                  title: policy.displayName, detail: NetworkingText.plural(policy.rules.count, "rule"))
                    }
                }
            } header: {
                Text("Built from")
            } footer: {
                Text("This document is compiled from outbound policies. Change them on the web, then plan all outbound policies.")
            }
        }
    }

    @ViewBuilder
    private func actions(_ doc: NetPolicy) -> some View {
        Section {
            NetworkingActionRow(title: "Plan this node", systemImage: "doc.badge.gearshape",
                                detail: "Files the compiled ruleset for approval", blocked: planBlocked(doc)) { plan() }
            WebLinkRow(title: "Edit on web", path: web)
        }
        if !doc.groupDerived {
            Section {
                TextField("Name (optional)", text: $convertName)
                    .textInputAutocapitalization(.never)
                    .focused($focused)
                    .frame(minHeight: Spacing.minimumTarget)
                TextField("Priority (optional, lower merges first)", text: $convertPriority)
                    .keyboardType(.numberPad)
                    .focused($focused)
                    .frame(minHeight: Spacing.minimumTarget)
                NetworkingActionRow(title: "Convert to an outbound policy", systemImage: "arrow.triangle.branch",
                                    detail: nil, blocked: convertBlocked) { convert() }
            } header: {
                Text("Convert")
            } footer: {
                Text("Creates \(convertName.trimmingCharacters(in: .whitespaces).isEmpty ? "an outbound policy" : "outbound policy \"\(convertName.trimmingCharacters(in: .whitespaces))\"") directly with these rules, targeting \(nodeName), then files a plan for \(nodeName). The policy stays even if the plan is rejected.")
            }
        }
    }

    // MARK: Actions

    private func planBlocked(_ doc: NetPolicy) -> String? {
        if let blocked = store.blocked([NetworkingIntents.policyAdmin]) { return blocked }
        if !doc.enabled { return "The policy is disabled; enable it on the web first" }
        return nil
    }

    private var convertBlocked: String? {
        if let blocked = store.blocked([NetworkingIntents.policyAdmin]) { return blocked }
        let priority = convertPriority.trimmingCharacters(in: .whitespaces)
        if !priority.isEmpty, Int(priority) == nil { return "Priority must be a whole number" }
        return nil
    }

    private var ref: ObjectRef { ObjectRef(kind: "node", id: nodeID, name: nodeName) }

    private func plan() {
        Task { await runner.run(NetworkingIntents.planNodePolicy(ref)) }
    }

    private func convert() {
        focused = false
        let priority = Int(convertPriority.trimmingCharacters(in: .whitespaces))
        Task {
            let outcome = await runner.run(NetworkingIntents.convertPolicy(ref, name: convertName, priority: priority))
            switch outcome {
            case .done, .filed:
                convertName = ""
                convertPriority = ""
            default:
                break
            }
        }
    }
}

extension String {
    /// "Apply failed" from "apply failed".
    var networkingCapitalized: String {
        prefix(1).uppercased() + dropFirst()
    }
}
