import SwiftUI

/// M8-09 Bucket: the keys of a KV bucket or the objects of a static one,
/// with size and modified time; search by key prefix. Values are dropped
/// at list time and load only on the entry screen.
struct StoreBucketScreen: View {
    let kind: String
    let name: String

    @Environment(PublishingStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(\.locale) private var locale

    @State private var model = PlatformBucketModel()
    @State private var prefix = ""

    private var storageKind: PlatformStorageKind { PlatformStorageKind(rawValue: kind) ?? .kv }

    var body: some View {
        content
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(prefix.isEmpty ? "\(storageKind.title) bucket" : "Keys starting \(prefix)")
            .refreshable { await reload() }
            .polling(.standard, version: changes.version(.store)) { await reload() }
            .task { if store.buckets[storageKind]?.value == nil { await store.refreshBuckets() } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Copy bucket name", systemImage: "doc.on.doc") { PlatformCopy.copy(name) }
                        Button("Put or delete on web", systemImage: "safari") { router.openOnWeb(.platformStore(kind: kind, bucket: name)) }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
    }

    @discardableResult
    private func reload() async -> Bool {
        guard let client = session.client else { return false }
        if let missing = store.readMissing(storageKind) {
            model.deny(missing)
            return true
        }
        return await model.load(client: client, kind: storageKind, bucket: name)
    }

    private var entry: PlatformBucketInventoryEntry? { store.bucket(kind: storageKind, name: name) }

    @ViewBuilder
    private var content: some View {
        if entry?.reserved == true {
            WholeScreenState {
                ContentUnavailableView {
                    Label("Reserved for the server", systemImage: "lock")
                } description: {
                    Text("\(name) holds typed private state the server owns. Its contents are refused to every scope, so they cannot be listed here or on the web.")
                }
            }
        } else {
            PlatformListState(state: model.rows, noun: "the bucket", retry: { Task { await reload() } }) { rows in
                list(rows)
            }
        }
    }

    private func list(_ all: [PlatformBucketModel.Row]) -> some View {
        let shown = prefix.isEmpty ? all : all.filter { $0.key.hasPrefix(prefix) }
        let owner = PlatformBucketOwner.of(name: name, kind: kind, reserved: false)
        let hasBytes = PlatformBucketOwner.contentAvailable(name: name, kind: kind, reserved: false)
        return List {
            Section {
                DetailRow(label: "Written by", value: owner.sentence, copyable: false)
                if let registered = store.registeredBucket(kind: storageKind, name: name) {
                    if !registered.displayName.isEmpty { DetailRow(label: "Name", value: registered.displayName, copyable: false) }
                    if !registered.description.isEmpty { DetailRow(label: "About", value: registered.description, copyable: false) }
                    if storageKind == .static, !registered.indexDocument.isEmpty { DetailRow(label: "Index document", value: registered.indexDocument, monospaced: true) }
                } else if entry != nil {
                    DetailRow(label: "Registered", value: "No: something wrote into it directly", copyable: false)
                }
                writersRow
                if let pluginID = entry.flatMap(PlatformBucketOwner.pluginID) {
                    NavigationLink(value: AppRoute.platform(.plugin(id: pluginID))) {
                        DetailRow(label: "Plugin", value: pluginID, copyable: false)
                    }
                }
            } footer: {
                if !hasBytes { Text("Nodes install these binaries as root under a task lease, so the listing carries no bytes.") }
            }
            PlatformRefreshError(state: model.rows, noun: "the bucket") { Task { await reload() } }
            Section {
                if all.isEmpty {
                    ContentUnavailableView("Empty bucket", systemImage: "tray", description: Text("Nothing is stored in \(name)."))
                } else if shown.isEmpty {
                    ContentUnavailableView("No key starts with \(prefix)", systemImage: "magnifyingglass")
                }
                ForEach(shown) { row in
                    NavigationLink(value: AppRoute.platform(.storeEntry(kind: kind, bucket: name, key: row.key))) {
                        PlatformEntryRow(row: row, kind: storageKind)
                    }
                    .contextMenu {
                        Button("Copy key", systemImage: "doc.on.doc") { PlatformCopy.copy(row.key) }
                    }
                }
            } header: {
                Text(all.count == 1 ? "1 \(storageKind == .kv ? "key" : "object")" : "\(all.count) \(storageKind == .kv ? "keys" : "objects")")
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Values load when you open an entry and are never kept.")
                    FreshnessFooter(state: model.rows, interval: 60)
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $prefix, prompt: "Key prefix")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    @ViewBuilder
    private var writersRow: some View {
        if let writers = store.tokenWriters(kind: storageKind, bucket: name) {
            let names = writers.map(\.name).filter { !$0.isEmpty }
            DetailRow(label: "Storage tokens that write", value: writers.isEmpty ? "None" : (names.isEmpty ? "\(writers.count) unnamed" : names.joined(separator: ", ")), copyable: false)
        } else if store.adminMissing(storageKind) != nil {
            DetailRow(label: "Storage tokens that write", value: "Unknown: needs \(storageKind.adminScope)", copyable: false)
        }
    }
}

/// One key or object: name, size and type, and how long ago it changed.
struct PlatformEntryRow: View {
    let row: PlatformBucketModel.Row
    let kind: PlatformStorageKind

    @Environment(\.locale) private var locale

    var body: some View {
        let size = ByteFormatter.bytes(UInt64(max(row.size, 0)))
        let detail = row.contentType.isEmpty ? size : "\(size) · \(row.contentType)"
        let modified = row.updatedAt.map { TimeDisplay.relative($0, now: Date(), locale: locale) }
        StatusRow(style: StatusStyle(word: "", symbol: kind == .kv ? "key" : (PlatformStoreContent.isText(contentType: row.contentType) ? "doc.text" : "doc"), tone: .quiet),
                  title: row.key, detail: detail, trailing: modified, titleIsIdentifier: true,
                  accessibilityPhrase: "\(row.key), \(detail)\(modified.map { ", changed \($0)" } ?? "")")
    }
}

/// The bucket listing, held by the screen only.
@MainActor @Observable
final class PlatformBucketModel {
    struct Row: Hashable, Identifiable, Sendable {
        var key: String
        var size: Int
        var contentType: String
        var updatedAt: Date?
        var hasContent: Bool
        var id: String { key }
    }

    private(set) var rows: ResourceState<[Row]> = .idle

    func deny(_ scope: String) {
        rows = .denied(scope: scope)
    }

    func load(client: LatticeClient, kind: PlatformStorageKind, bucket: String) async -> Bool {
        rows = rows.reloading
        do {
            let list: [Row] = switch kind {
            case .kv:
                try await client.platformKVKeys(bucket: bucket).map { Row(key: $0.key, size: $0.size, contentType: "", updatedAt: $0.updatedAt, hasContent: true) }
            case .static:
                try await client.platformStaticObjects(bucket: bucket).map { Row(key: $0.path, size: $0.size, contentType: $0.contentType, updatedAt: $0.updatedAt, hasContent: $0.hasContent) }
            }
            rows = .loaded(list.sorted { $0.key < $1.key }, at: Date())
            return true
        } catch {
            rows = rows.failing(LatticeAPIError(error), surface: "\(kind.title) bucket", missingScope: kind.readScope)
            return false
        }
    }

    func row(key: String) -> Row? { rows.value?.first { $0.key == key } }
}
