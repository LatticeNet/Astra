import SwiftUI

/// M6-13 Security group: its rules and the nodes and node groups it is
/// bound to. Read only; changes are made on the web.
struct SecurityGroupScreen: View {
    let id: String

    @Environment(NetworkingStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router

    var body: some View {
        NetworkingListState(state: store.guardNodes, noun: "the security group", web: InboundFirewallScreen.pluginPage,
                            retry: { Task { await store.refreshFirewall() } }) { _ in
            if let group = snapshot.group(id: id) {
                detail(group)
            } else if store.guardGroups.value == nil, !store.isConfined, isLoadingGroups {
                List { LoadingRows(label: "Loading the security group", count: 3) }
            } else {
                notFound
            }
        }
        .navigationTitle(snapshot.group(id: id)?.displayName ?? "Security group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NetworkingMoreMenu(link: nil, web: InboundFirewallScreen.pluginPage) {
                    Button("Copy ID", systemImage: "number") { NetworkingCopy.copy(id) }
                }
            }
        }
        .refreshable { await store.refreshFirewall() }
        .polling(.standard, version: changes.version([.netguard, .nodes, .groups])) {
            await nodes.refreshIfOlder(than: 60)
            return await store.refreshFirewall()
        }
    }

    private var isLoadingGroups: Bool {
        switch store.guardGroups {
        case .idle, .loading: true
        default: false
        }
    }

    private var snapshot: NetworkingFirewallSnapshot {
        NetworkingFirewallSnapshot(groups: store.guardGroups.value ?? [], zones: store.guardZones.value ?? [],
                                   nodes: store.guardNodes.value ?? [], nodeGroupBindings: store.nodeGroupBindings.value ?? [])
    }

    @ViewBuilder
    private func detail(_ group: NetworkingSecurityGroup) -> some View {
        let bound = snapshot.boundNodes(of: group.id)
        let boundGroups = snapshot.boundNodeGroups(of: group.id)
        List {
            Section {
                NetworkingSecurityGroupRow(group: group, boundCount: bound.count)
                if !group.description.isEmpty {
                    Text(group.description).frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                }
                if group.isLegacy {
                    Text("Converted on read from \(nodes.name(for: group.nodeID))'s legacy ruleset; it binds only to that node.")
                        .textRole(.footnote)
                }
            }

            Section {
                if group.rules.isEmpty {
                    Text(group.ruleCount > 0 ? "\(NetworkingText.plural(group.ruleCount, "rule")), not shown to a token confined to some nodes." : "No rules")
                        .foregroundStyle(.secondary)
                        .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                }
                ForEach(group.rules) { rule in
                    let remote = NetworkingText.remote(rule.remote, names: { nodes.nodes[$0]?.displayName ?? store.groupNames[$0] ?? $0 })
                    StatusRow(style: StatusStyle(word: rule.disabled ? "\(rule.action), off" : rule.action,
                                                 symbol: rule.isAllow ? "checkmark.circle" : "nosign",
                                                 tone: .quiet),
                              title: "\(rule.direction == "egress" ? "To" : "From") \(remote)",
                              detail: rule.comment.isEmpty ? rule.trafficText : "\(rule.trafficText), \(rule.comment)",
                              accessibilityPhrase: "\(rule.action) \(rule.direction == "egress" ? "to" : "from") \(remote), \(rule.trafficText)\(rule.disabled ? ", rule off" : "")\(rule.comment.isEmpty ? "" : ", \(rule.comment)")")
                }
            } header: {
                Text("Rules (\(group.visibleRuleCount))")
            }

            Section {
                if bound.isEmpty {
                    Text("No visible node is bound to this group.").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
                }
                ForEach(bound) { node in
                    NavigationLink(value: AppRoute.networking(.inboundFirewall(nodeID: node.nodeID))) {
                        NetworkingGuardNodeRow(node: node)
                    }
                }
            } header: {
                Text("Nodes (\(bound.count))")
            }

            if !boundGroups.isEmpty {
                Section("Node groups") {
                    ForEach(boundGroups) { binding in
                        NavigationLink(value: AppRoute.fleet(.group(id: binding.groupID))) {
                            StatusRow(style: StatusStyle(word: "\(binding.activeCount) of \(binding.members.count) members enforced", symbol: "square.stack.3d.up", tone: .quiet),
                                      title: binding.displayName)
                        }
                    }
                }
            }

            Section {
                WebLinkRow(title: "Open plugin page on web", path: InboundFirewallScreen.pluginPage)
            } footer: {
                FreshnessFooter(state: store.guardNodes, interval: Polling.standard.interval(lowPower: false))
            }
        }
        .listStyle(.insetGrouped)
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Not found", systemImage: "questionmark.square.dashed")
            } description: {
                Text(store.isConfined ? "Security groups are fleet-wide, and this token is confined to some nodes." : "This security group was deleted.")
            } actions: {
                Button("Open plugin page on web") { router.openOnWeb(InboundFirewallScreen.pluginPage) }.buttonStyle(.bordered)
            }
        }
    }
}
