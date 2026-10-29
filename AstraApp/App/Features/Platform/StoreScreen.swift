import SwiftUI

/// M8-08 Store: the KV and static buckets, registered or not, with who
/// writes each and how much it holds. Gate kv:read or static:read; each
/// kind is its own section with its own scope.
struct StoreScreen: View {
    static let queryKey = "platform.store.query"

    @Environment(PublishingStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router

    @SceneStorage(StoreScreen.queryKey) private var query = ""

    var body: some View {
        content
            .navigationTitle("Store")
            .navigationSubtitle(query)
            .refreshable { await store.refreshBuckets() }
            .polling(.standard, version: changes.version(.store)) { await store.refreshBuckets() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Publishing", systemImage: "paperplane") { router.push(.platform(.publishing(view: "buckets"))) }
                        Button("Open on web", systemImage: "safari") { router.openOnWeb(.platformStore()) }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let missing = store.storeMissing {
            ScopeDeniedScreen(scope: missing)
        } else if PlatformStorageKind.allCases.allSatisfy({ store.buckets[$0]?.value == nil }),
                  let first = PlatformStorageKind.allCases.lazy.map({ store.buckets[$0] ?? .idle }).first(where: { state in
                      if case .denied = state { return false }
                      return true
                  }) {
            PlatformListState(state: first, noun: "buckets", retry: { Task { await store.refreshBuckets() } }) { _ in EmptyView() }
        } else {
            List {
                ForEach(PlatformStorageKind.allCases, id: \.self) { kind in
                    PlatformBucketSection(kind: kind, query: query)
                }
                Section {
                } footer: {
                    Text("Values load only when you open an entry, and are never kept on this iPhone. Writing and deleting entries happen on the web.")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Search buckets")
        }
    }
}
