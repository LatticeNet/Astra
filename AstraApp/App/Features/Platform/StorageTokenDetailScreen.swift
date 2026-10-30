import SwiftUI

/// M8-07 Storage token: its name, access, buckets, when it was made and
/// last used. Revoke is T4 (`<kind>:admin`, the scope the token list needs too).
struct StorageTokenDetailScreen: View {
    let id: String

    @Environment(PublishingStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        PlatformListState(state: store.tokensState, noun: "the storage token", retry: { Task { await store.refresh() } }) { _ in
            if let token = store.token(id: id) {
                detail(token)
            } else {
                notFound
            }
        }
        .navigationTitle(store.token(id: id)?.name ?? "Storage token")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(store.token(id: id).map { StatusStyle.platformToken($0).word } ?? "")
        .refreshable { await store.refresh() }
        .polling(.standard, version: changes.version([.publishing, .store])) { await store.refresh() }
        .toolbar { toolbar }
    }

    @ViewBuilder
    private func stamp(_ label: String, _ date: Date?) -> some View {
        if let date {
            TimeRow(label: label, date: date)
        } else {
            DetailRow(label: label, value: label == "Last used" ? "Never" : "Not recorded", copyable: false)
        }
    }

    @ViewBuilder
    private func detail(_ token: PlatformStorageToken) -> some View {
        let kind = PlatformStorageKind(rawValue: token.kind) ?? .kv
        let style = StatusStyle.platformToken(token)
        let missing = store.adminMissing(kind)
        List {
            Section {
                StatusRow(style: style, title: token.name.isEmpty ? token.id : token.name, detail: "\(kind.title) storage token",
                          accessibilityPhrase: "\(token.name), \(style.word)")
            }
            Section("Token") {
                DetailRow(label: "Access", value: accessSentence(token.access), copyable: false)
                DetailRow(label: "Buckets", value: PlatformStorageTokens.bucketsLabel(token), copyable: false)
                stamp("Created", token.createdAt)
                stamp("Last used", token.lastUsedAt)
                if token.isRevoked { stamp("Revoked", token.revokedAt) }
                DetailRow(label: "ID", value: token.id, monospaced: true)
            }
            if !token.buckets.isEmpty, !token.buckets.contains("*") {
                Section("Bucket pages") {
                    ForEach(token.buckets, id: \.self) { bucket in
                        NavigationLink(value: AppRoute.platform(.bucket(kind: kind.rawValue, name: bucket))) {
                            Label(bucket, systemImage: kind == .kv ? "tablecells" : "doc.on.doc")
                                .frame(minHeight: Spacing.minimumTarget)
                        }
                    }
                }
            }
            Section {
                if token.isRevoked {
                    DetailRow(label: "Revoke", value: "Already revoked", copyable: false)
                } else {
                    PlatformActionRow(title: "Revoke \(token.name)", systemImage: "xmark.circle", note: "Stops working at once; cannot be restored", missing: missing, role: .destructive) {
                        Task { await runner.run(PlatformIntents.revokeToken(kind: kind, id: token.id, name: token.name, buckets: PlatformStorageTokens.bucketsLabel(token))) }
                    }
                }
                WebLinkRow(title: "Create a replacement on web", path: .platformPublishing(view: "tokens"))
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("The token's secret was shown once when it was created and is not stored here.")
                    FreshnessFooter(state: store.tokens[kind] ?? .idle, interval: 60)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func accessSentence(_ access: String) -> String {
        switch access {
        case "read": "Read: fetch entries"
        case "write": "Write: put and delete entries"
        case "admin": "Admin: every operation on its buckets"
        default: access
        }
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Storage token not found", systemImage: "key")
            } description: {
                Text("No storage token has this id, or its kind is hidden from this token.")
            } actions: {
                Button("Open on web") { router.openOnWeb(.platformPublishing(view: "tokens")) }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let token = store.token(id: id), let kind = PlatformStorageKind(rawValue: token.kind) {
                    Button("Copy ID", systemImage: "doc.on.doc") { PlatformCopy.copy(token.id) }
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.platformPublishing(view: "tokens")) }
                    if !token.isRevoked {
                        Section {
                            PlatformGatedButton(title: "Revoke token", systemImage: "xmark.circle", missing: store.adminMissing(kind), role: .destructive) {
                                Task { await runner.run(PlatformIntents.revokeToken(kind: kind, id: token.id, name: token.name, buckets: PlatformStorageTokens.bucketsLabel(token))) }
                            }
                        }
                    }
                } else {
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.platformPublishing(view: "tokens")) }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}
