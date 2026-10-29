import SwiftUI

/// M8-06 Binding: the route a host binding publishes, the bucket behind it,
/// who may read it, and when it was made. Delete is T4 (`<kind>:admin`).
struct BindingDetailScreen: View {
    let id: String

    @Environment(PublishingStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlatformListState(state: store.bindingsState, noun: "the binding", retry: { Task { await store.refresh() } }) { _ in
            if let binding = store.binding(id: id) {
                detail(binding)
            } else {
                notFound
            }
        }
        .navigationTitle(store.binding(id: id).map(label) ?? "Binding")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(store.binding(id: id).map { $0.enabled ? "serving" : "disabled" } ?? "")
        .refreshable { await store.refresh() }
        .polling(.standard, version: changes.version([.publishing, .store])) { await store.refresh() }
        .toolbar { toolbar }
    }

    private func label(_ binding: PlatformStorageBinding) -> String {
        let path = binding.pathPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? binding.hostname : "\(binding.hostname)/\(path)"
    }

    @ViewBuilder
    private func detail(_ binding: PlatformStorageBinding) -> some View {
        let kind = PlatformStorageKind(rawValue: binding.kind) ?? .kv
        let missing = store.adminMissing(kind)
        let style = StatusStyle.platformRoute(binding.enabled ? .serving : .disabled)
        List {
            Section {
                StatusRow(style: style, title: PlatformFormat.breakable(label(binding)), detail: "\(kind.title) binding", titleIsIdentifier: true,
                          accessibilityPhrase: "\(label(binding)), \(style.word)")
            }
            Section("Route") {
                DetailRow(label: "Host", value: binding.hostname, monospaced: true)
                DetailRow(label: "Path", value: binding.pathPrefix.isEmpty ? "/" : "/\(binding.pathPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")))", monospaced: true)
                DetailRow(label: "Who can read", value: PlatformAccessMode.of(origin: binding.kind).sentence, copyable: false)
                DetailRow(label: "Enabled", value: binding.enabled ? "Yes" : "No, the route answers nothing", copyable: false)
                if let created = binding.createdAt {
                    DetailRow(label: "Created", value: TimeDisplay.dateTime(created, mode: mode, locale: locale),
                              secondary: TimeDisplay.relative(created, now: Date(), locale: locale), copyable: false)
                }
                if let updated = binding.updatedAt {
                    DetailRow(label: "Updated", value: TimeDisplay.dateTime(updated, mode: mode, locale: locale),
                              secondary: TimeDisplay.relative(updated, now: Date(), locale: locale), copyable: false)
                }
            }
            Section("Serves") {
                NavigationLink(value: AppRoute.platform(.bucket(kind: kind.rawValue, name: binding.bucket))) {
                    DetailRow(label: "\(kind.title) bucket", value: binding.bucket, copyable: false)
                }
            }
            Section {
                WebLinkRow(title: "Edit on web", path: .platformPublishing(view: "routes"))
                PlatformActionRow(title: "Delete binding \(label(binding))", systemImage: "trash", note: "The route stops answering at once", missing: missing, role: .destructive) {
                    Task { await delete(binding, kind: kind) }
                }
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Deleting removes only the route. The bucket and its contents stay.")
                    FreshnessFooter(state: store.bindings[kind] ?? .idle, interval: 60)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func delete(_ binding: PlatformStorageBinding, kind: PlatformStorageKind) async {
        let outcome = await runner.run(PlatformIntents.deleteBinding(kind: kind, id: binding.id, route: label(binding), bucket: binding.bucket))
        if case .done = outcome { dismiss() }
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Binding not found", systemImage: "link")
            } description: {
                Text("This binding was deleted, or its kind is hidden from this token.")
            } actions: {
                Button("Open on web") { router.openOnWeb(.platformPublishing(view: "routes")) }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let binding = store.binding(id: id), let kind = PlatformStorageKind(rawValue: binding.kind) {
                    Button("Copy ID", systemImage: "doc.on.doc") { PlatformCopy.copy(binding.id) }
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.platformPublishing(view: "routes")) }
                    Section {
                        PlatformGatedButton(title: "Delete binding", systemImage: "trash", missing: store.adminMissing(kind), role: .destructive) {
                            Task { await delete(binding, kind: kind) }
                        }
                    }
                } else {
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.platformPublishing(view: "routes")) }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}
