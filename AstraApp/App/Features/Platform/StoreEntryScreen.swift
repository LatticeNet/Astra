import SwiftUI

/// M8-10 Entry: the metadata of a KV entry or static object; the value
/// loads only on tap into a find-enabled text view (text) or a size and
/// type summary (binary). The value lives in this view's state alone and is
/// cleared when the screen goes away or the app leaves the foreground.
/// Put and delete stay on the web.
struct StoreEntryScreen: View {
    let kind: String
    let bucket: String
    let key: String

    @Environment(PublishingStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    @State private var listing = PlatformBucketModel()
    @State private var value: PlatformStoreValue?
    @State private var valueMissing = false
    @State private var loadingValue = false
    @State private var valueError: String?
    @State private var finding = false
    /// Bumped by clear(), so a value still in flight is dropped when it lands.
    @State private var generation = 0

    private var storageKind: PlatformStorageKind { PlatformStorageKind(rawValue: kind) ?? .kv }

    var body: some View {
        PlatformListState(state: listing.rows, noun: "the entry", retry: { Task { await loadListing() } }) { _ in
            if let row = listing.row(key: key) {
                detail(row)
            } else {
                WholeScreenState {
                    ContentUnavailableView {
                        Label("Entry not found", systemImage: "questionmark.square.dashed")
                    } description: {
                        Text("\(key) is no longer in \(bucket).")
                    }
                }
            }
        }
        .navigationTitle(key)
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(bucket)
        .task { await loadListing() }
        .onDisappear(perform: clear)
        .onChange(of: scenePhase) { _, phase in if phase != .active { clear() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if value != nil, isText {
                        Button("Find in value", systemImage: "magnifyingglass") { finding = true }
                    }
                    Button("Copy key", systemImage: "doc.on.doc") { PlatformCopy.copy(key) }
                    Button("Put or delete on web", systemImage: "safari") { router.openOnWeb(.platformStore(kind: kind, bucket: bucket)) }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
    }

    private var isText: Bool {
        storageKind == .kv || PlatformStoreContent.isText(contentType: value?.contentType ?? listing.row(key: key)?.contentType ?? "")
    }

    private func loadListing() async {
        guard let client = session.client else { return }
        if let missing = store.readMissing(storageKind) {
            listing.deny(missing)
            return
        }
        _ = await listing.load(client: client, kind: storageKind, bucket: bucket)
    }

    private func clear() {
        generation += 1
        value = nil
        valueMissing = false
        finding = false
    }

    private func loadValue() async {
        guard let client = session.client else { return }
        let started = generation
        loadingValue = true
        valueError = nil
        defer { loadingValue = false }
        do {
            let loaded = try await client.platformStoreValue(kind: storageKind, bucket: bucket, key: key)
            guard started == generation, scenePhase == .active else { return }
            value = loaded
            valueMissing = loaded == nil
        } catch {
            valueError = "Could not load the value: \(LatticeAPIError(error).localizedDescription)"
        }
    }

    @ViewBuilder
    private func detail(_ row: PlatformBucketModel.Row) -> some View {
        List {
            Section("Entry") {
                DetailRow(label: storageKind == .kv ? "Key" : "Path", value: row.key, monospaced: true)
                DetailRow(label: "Bucket", value: bucket, monospaced: true)
                DetailRow(label: "Size", value: ByteFormatter.bytes(UInt64(max(row.size, 0))), copyable: false)
                if storageKind == .static {
                    DetailRow(label: "Type", value: row.contentType.isEmpty ? "Not set" : row.contentType, copyable: false)
                }
                if let updated = row.updatedAt {
                    TimeRow(label: "Modified", date: updated)
                }
            }
            valueSection(row)
            Section {
                WebLinkRow(title: "Put or delete on web", path: .platformStore(kind: kind, bucket: bucket))
            } footer: {
                Text("Values are not cached: leaving this screen or the app clears it.")
            }
        }
        .listStyle(.insetGrouped)
        .announcing(valueError)
    }

    private var listingSummary: String {
        let rows = listing.rows.value ?? []
        let total = rows.reduce(Int64(0)) { $0 + Int64(max($1.size, 0)) }
        return "\(rows.count == 1 ? "1 entry" : "\(rows.count) entries"), \(ByteFormatter.bytes(UInt64(total))) in all"
    }

    @ViewBuilder
    private func valueSection(_ row: PlatformBucketModel.Row) -> some View {
        Section {
            if storageKind == .static, !PlatformBucketOwner.contentAvailable(name: bucket, kind: kind, reserved: false) {
                Label("This listing carries no bytes: nodes fetch them under a task lease.", systemImage: "lock.doc")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: Spacing.minimumTarget)
            } else if let value {
                if isText {
                    PlatformFindableText(text: value.text, finding: $finding)
                        .padding(.vertical, Spacing.xs)
                        .accessibilityLabel("Value")
                        .accessibilityValue(value.text)
                    Button("Find in value", systemImage: "magnifyingglass") { finding = true }
                        .frame(minHeight: Spacing.minimumTarget)
                } else {
                    DetailRow(label: "Binary", value: "\(ByteFormatter.bytes(UInt64(max(value.size, 0)))) of \(value.contentType.isEmpty ? "unknown type" : value.contentType)", copyable: false)
                    Text("Binary content is not shown on this iPhone. Download it on the web.")
                        .textRole(.footnote)
                }
                Button("Hide value", systemImage: "eye.slash", action: clear)
                    .frame(minHeight: Spacing.minimumTarget)
            } else if valueMissing {
                Label("The entry was removed before its value loaded.", systemImage: "questionmark.square.dashed")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: Spacing.minimumTarget)
            } else {
                if let valueError {
                    ErrorRow(message: valueError) { Task { await loadValue() } }
                }
                Button {
                    Task { await loadValue() }
                } label: {
                    Label(loadingValue ? "Loading value" : "Load value", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
                }
                .disabled(loadingValue)
            }
        } header: {
            Text("Value")
        } footer: {
            if value == nil, storageKind == .kv || PlatformBucketOwner.contentAvailable(name: bucket, kind: kind, reserved: false) {
                Text("Reads the bucket listing again (\(listingSummary)) and shows only this value, for as long as this screen is open.")
            }
        }
    }
}
