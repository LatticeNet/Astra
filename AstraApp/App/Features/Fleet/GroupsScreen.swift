import SwiftUI

/// M2-10 Groups. A scope root, frozen as `init()`. Each group with its kind
/// and member health; swipe to Delete (T4, the sheet lists Used by first).
struct GroupsScreen: View {
    static let queryKey = "fleet.groups.query"

    @Environment(GroupsStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @SceneStorage(GroupsScreen.queryKey) private var query = ""

    var body: some View {
        FleetListState(state: store.groups, noun: "groups", retry: { Task { await store.refresh() } }) { response in
            let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
            let groups = needle.isEmpty ? response.groups : response.groups.filter {
                $0.displayName.lowercased().contains(needle) || $0.slug.lowercased().contains(needle) || $0.description.lowercased().contains(needle)
            }
            if response.groups.isEmpty {
                WholeScreenState {
                    ContentUnavailableView {
                        Label("No node groups", systemImage: "rectangle.3.group")
                    } description: {
                        Text("Groups are written with a selector or a member list, which happens on the web.")
                    } actions: {
                        Button("New group on web") { router.openOnWeb(.nodeGroups) }.buttonStyle(.bordered)
                    }
                }
            } else {
                List {
                    FleetRefreshError(state: store.groups, noun: "groups") { Task { await store.refresh() } }
                    if groups.isEmpty { ContentUnavailableView.search(text: query) }
                    Section {
                        ForEach(groups) { group in
                            NavigationLink(value: AppRoute.fleet(.group(id: group.id))) {
                                FleetGroupRow(group: group)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if store.canAdmin, !group.system {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        Task { await runner.run(FleetIntents.deleteGroup(ObjectRef(kind: "group", id: group.id, name: group.displayName))) }
                                    }
                                    .tint(.destructiveFill)
                                }
                            }
                            .contextMenu {
                                Button("Open", systemImage: "arrow.right.circle") { router.push(.fleet(.group(id: group.id))) }
                                Button("Copy link", systemImage: "link") { FleetCopy.copy(FleetCopy.groupLink(group.id)) }
                                Button("Open on web", systemImage: "safari") { router.openOnWeb(.group(id: group.id)) }
                                FleetGatedButton(title: "Delete", systemImage: "trash", missing: store.canAdmin ? (group.system ? "a group that is not built in" : nil) : "group:admin", role: .destructive) {
                                    Task { await runner.run(FleetIntents.deleteGroup(ObjectRef(kind: "group", id: group.id, name: group.displayName))) }
                                }
                            }
                        }
                    } footer: {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            if response.ungroupedRollup.total > 0 {
                                Text("\(response.ungroupedRollup.sentence) in no group.")
                            }
                            FleetFooter(state: store.groups)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter groups")
        .refreshable { await store.refresh() }
        .polling(.standard, version: changes.version([.groups, .nodes])) { await store.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    router.openOnWeb(.nodeGroups)
                } label: {
                    Label("New group on web", systemImage: "plus")
                }
            }
        }
        .onAppear {
            if let pending = appState.consumeQuery(FleetScope.groups.rawValue) { query = pending }
        }
        .modifier(FleetFilterSubtitle(query: query))
    }
}

/// One group: its name, kind and member health. A group with offline
/// members carries the warning glyph and word.
struct FleetGroupRow: View {
    let group: FleetGroupView

    var body: some View {
        let rollup = group.rollup
        let style: StatusStyle = rollup.offline > 0
            ? StatusStyle(word: "\(rollup.offline) offline", symbol: "exclamationmark.triangle.fill", tone: .warn)
            : (rollup.total == 0
                ? StatusStyle(word: "empty", symbol: "rectangle.3.group", tone: .quiet)
                : (rollup.disabled > 0
                    ? StatusStyle(word: "\(rollup.online) reporting, \(rollup.disabled) disabled", symbol: "rectangle.3.group.fill", tone: .ok)
                    : StatusStyle(word: "all reporting", symbol: "rectangle.3.group.fill", tone: .ok)))
        StatusRow(
            style: style,
            title: group.displayName,
            detail: "\(group.kind.word), \(rollup.total == 1 ? "1 node" : "\(rollup.total) nodes")",
            accessibilityPhrase: "\(group.displayName), \(group.kind.word) group, \(rollup.sentence)"
        )
    }
}
