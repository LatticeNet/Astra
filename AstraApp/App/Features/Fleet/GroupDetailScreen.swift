import SwiftUI

/// M2-11 Group: the selector or static list, members with health, and what
/// names the group. Static groups add and remove members here (T2); delete
/// is T4; editing the selector happens on the web.
struct GroupDetailScreen: View {
    let id: String

    @Environment(GroupsStore.self) private var groups
    @Environment(FleetStore.self) private var fleet
    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var usedBy: ResourceState<FleetGroupUsedBy> = .idle
    @State private var addingMembers = false

    var body: some View {
        FleetListState(state: groups.groups, noun: "groups", retry: { Task { await refresh() } }) { response in
            if let group = response.groups.first(where: { $0.id == id }) {
                content(group)
            } else {
                WholeScreenState {
                    ContentUnavailableView {
                        Label("Not found, or not visible to this token", systemImage: "questionmark.circle")
                    } description: {
                        Text("No node group \(id) in the groups this token can read.")
                    } actions: {
                        Button("Open on web") { router.openOnWeb(.group(id: id)) }
                    }
                }
            }
        }
        .navigationTitle(groups.group(id: id)?.displayName ?? "Group")
        .navigationSubtitle(groups.group(id: id).map { "\($0.kind.word) group" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .polling(.standard, version: changes.version([.groups, .nodes, .policies, .checks])) { await refresh(); return true }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .sheet(isPresented: $addingMembers) {
            if let group = groups.group(id: id) {
                FleetAddMembersSheet(group: group)
            }
        }
    }

    private var ref: ObjectRef {
        ObjectRef(kind: "group", id: id, name: groups.group(id: id)?.displayName)
    }

    private var menu: some View {
        Menu {
            Button("Edit on web", systemImage: "safari") { router.openOnWeb(.group(id: id)) }
            Button("Copy link", systemImage: "link") { FleetCopy.copy(FleetCopy.groupLink(id)) }
            Button("Copy ID", systemImage: "number") { FleetCopy.copy(id) }
            Divider()
            FleetGatedButton(title: "Delete group", systemImage: "trash", missing: deleteMissing(groups.group(id: id)), role: .destructive) {
                Task { await delete() }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    /// Built-in groups are never deleted from here, as in the console and the Groups list.
    private func deleteMissing(_ group: FleetGroupView?) -> String? {
        guard groups.canAdmin else { return "group:admin" }
        return group?.system == true ? "a group that is not built in" : nil
    }

    private func content(_ group: FleetGroupView) -> some View {
        let nodes = Dictionary((fleet.nodes.value ?? []).map { ($0.id, $0.node) }, uniquingKeysWith: { first, _ in first })
        let members = FleetGroupHealth.members(group, nodes: nodes)
        let unknown = group.resolvedMembers.filter { nodes[$0] == nil }
        let canAdmin = groups.canAdmin
        let staticIDs = Set(group.members)
        return List {
            FleetRefreshError(state: groups.groups, noun: "groups") { Task { await refresh() } }
            Section {
                if let selector = group.selector, !selector.isEmpty {
                    DetailRow(label: "Selector", value: selector.sentence, copyable: false)
                }
                if group.kind != .selector {
                    DetailRow(label: "Static members", value: group.members.count == 1 ? "1 node" : "\(group.members.count) nodes", copyable: false)
                }
                let degraded = FleetGroupHealth.degraded(group, nodes: nodes)
                DetailRow(label: "Health", value: group.rollup.sentence + (degraded > 0 ? ", \(degraded) degraded" : ""), copyable: false)
                if !group.description.isEmpty { DetailRow(label: "Description", value: group.description, copyable: false) }
            } header: {
                Text("Definition")
            } footer: {
                if group.kind == .selector {
                    Text("Members follow the selector. Change it on the web.")
                }
            }
            Section {
                if members.isEmpty && unknown.isEmpty {
                    Text("No members").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                }
                ForEach(members) { node in
                    let record = fleet.record(id: node.id) ?? FleetNodeRecord(node: node)
                    let removable = canAdmin && staticIDs.contains(node.id)
                    let remove = { Task { await runner.run(FleetIntents.setGroupMembers(ref, remove: [FleetIntents.nodeRef(node)])) } }
                    NavigationLink(value: AppRoute.fleet(.node(id: node.id))) {
                        NodeRow(node: node)
                    }
                    .fleetNodeMenu(record, extra: removable ? (title: "Remove from \(group.displayName)", action: { _ = remove() }) : nil)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if removable {
                            Button("Remove", systemImage: "minus.circle") { _ = remove() }
                                .tint(.destructiveFill)
                        }
                    }
                }
                ForEach(unknown, id: \.self) { nodeID in
                    StatusRow(style: StatusStyle(word: "loading", symbol: "circle.dashed", tone: .quiet), title: nodeID, titleIsIdentifier: true)
                }
                if group.acceptsStaticMembers {
                    FleetActionRow(title: "Add members", systemImage: "plus.circle", missing: canAdmin ? nil : "group:admin") {
                        addingMembers = true
                    }
                }
            } header: {
                Text("Members (\(group.resolvedMembers.count))")
            } footer: {
                if group.acceptsStaticMembers, canAdmin, !group.members.isEmpty {
                    Text("Swipe a static member to remove it.")
                }
            }
            usedBySection
            Section {
                FleetActionRow(title: "Delete group", systemImage: "trash", missing: deleteMissing(group), destructive: true) {
                    Task { await delete() }
                }
                WebLinkRow(title: "Edit on web", path: .group(id: id))
            } footer: {
                FleetFooter(state: groups.groups)
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private var usedBySection: some View {
        Section {
            switch usedBy {
            case .denied(let scope):
                ScopeDeniedRow(scope: scope)
            default:
                if let value = usedBy.value {
                    if value.usedBy.isEmpty && value.hidden == 0 {
                        Text("Nothing names this group").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                    }
                    ForEach(value.usedBy) { use in
                        NavigationLink(value: route(for: use)) {
                            StatusRow(style: StatusStyle(word: use.roleWord, symbol: symbol(for: use), tone: .quiet), title: use.label, detail: use.kindTitle)
                        }
                    }
                    if value.hidden > 0 {
                        Label(value.hidden == 1 ? "1 more use is hidden from this token" : "\(value.hidden) more uses are hidden from this token", systemImage: "eye.slash")
                            .foregroundStyle(.secondary)
                    }
                } else if case .failed(let error, nil, _) = usedBy {
                    ErrorRow(message: "Could not load what uses this group: \(error.localizedDescription)") { Task { await loadUsedBy() } }
                } else {
                    LoadingRows(label: "Loading what uses this group", count: 1)
                }
            }
        } header: {
            Text("Used by")
        }
    }

    private func route(for use: FleetGroupUse) -> AppRoute {
        switch use.kind {
        case "outbound_policy": .networking(.policy(id: use.id))
        case "security_group_binding": .networking(.securityGroup(id: use.id))
        // The server's only "check" use is a check definition (checkDefinitionGroupUses).
        default: .monitoring(.definition(id: use.id))
        }
    }

    private func symbol(for use: FleetGroupUse) -> String {
        switch use.kind {
        case "outbound_policy": "arrow.up.forward.circle"
        case "security_group_binding": "shield.lefthalf.filled"
        default: "waveform.path.ecg"
        }
    }

    private func refresh() async {
        async let groupsDone = groups.refresh()
        async let nodesDone = fleet.nodes.value == nil ? fleet.refresh() : true
        _ = await (groupsDone, nodesDone)
        await loadUsedBy()
    }

    private func loadUsedBy() async {
        if let missing = session.missing(ScopeRequirement("group:read")), !missing.isEmpty {
            usedBy = .denied(scope: missing.joined(separator: " and "))
            return
        }
        guard let client = session.client else { return }
        usedBy = usedBy.reloading
        do {
            usedBy = .loaded(try await client.fleetGroupUsedBy(groupID: id), at: Date())
        } catch {
            usedBy = usedBy.failing(LatticeAPIError(error), surface: "Used by", missingScope: "group:read")
        }
    }

    private func delete() async {
        if case .done = await runner.run(FleetIntents.deleteGroup(ref)) { dismiss() }
    }
}

/// Picks nodes to add to a static group, then confirms (T2) inside the sheet.
struct FleetAddMembersSheet: View {
    let group: FleetGroupView

    @Environment(FleetStore.self) private var fleet
    @Environment(ActionRunner.self) private var runner
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selection = Set<String>()
    @State private var query = ""

    var body: some View {
        NavigationStack {
            let candidates = FleetGroupHealth.candidates(group, nodes: fleet.allNodes)
            let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
            let shown = needle.isEmpty ? candidates : candidates.filter { $0.displayName.lowercased().contains(needle) }
            List(selection: $selection) {
                if shown.isEmpty {
                    ContentUnavailableView(candidates.isEmpty ? "Every readable node is already a member" : "No matches", systemImage: "rectangle.3.group")
                }
                ForEach(shown) { node in
                    NodeRow(node: node).tag(node.id)
                }
            }
            .environment(\.editMode, .constant(.active))
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter nodes")
            .navigationTitle("Add to \(group.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selection.isEmpty ? "Add" : "Add \(selection.count)") {
                        Task { await add(candidates) }
                    }
                    .disabled(selection.isEmpty)
                }
            }
            .actionHost(inSheet: true)
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func add(_ candidates: [LatticeNode]) async {
        let chosen = candidates.filter { selection.contains($0.id) }.map(FleetIntents.nodeRef)
        let groupRef = ObjectRef(kind: "group", id: group.id, name: group.displayName)
        if case .done = await runner.run(FleetIntents.setGroupMembers(groupRef, add: chosen)) { dismiss() }
    }
}
