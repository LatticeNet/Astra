import SwiftUI

/// M4-07 Verify chain. Runs `GET /api/audit/verify` when it opens and shows
/// the head hash, the events checked and the result: intact, or the first
/// broken link. Non-mutating, so it asks nothing first.
struct AuditVerifySheet: View {
    @Environment(AuditStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Verify chain")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Button {
                        Task { await store.runVerify() }
                    } label: {
                        Text(store.verify.isLoading ? "Verifying" : (store.verify.value == nil ? "Verify" : "Verify again"))
                            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget)
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.verify.isLoading)
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.s)
                    .background(Color(uiColor: .systemGroupedBackground))
                }
                .actionHost(inSheet: true)
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        // Rows stay opaque at the medium detent too, where the sheet would otherwise be glass (4.11).
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .task { await store.runVerify() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.verify {
        case .denied(let scope):
            ScopeDeniedScreen(scope: scope)
        case .failed(let error, nil, _):
            WholeScreenState {
                ContentUnavailableView {
                    Label("Could not verify", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    Button("Retry") { Task { await store.runVerify() } }.buttonStyle(.bordered)
                }
            }
        case .idle:
            List {
                Section {
                    Text("Not verified on this iPhone yet. Verify walks the audit log and checks every link of its hash chain.")
                        .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                }
            }
            .listStyle(.insetGrouped)
        default:
            if let status = store.verify.value, !store.verify.isLoading || store.verify.loadedAt != nil {
                result(status)
            } else {
                List {
                    Section {
                        Text("Walking the audit log and checking every link")
                            .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private func result(_ status: AuditChainStatus) -> some View {
        List {
            if case .failed(let error, _, _) = store.verify {
                ErrorRow(message: "Could not verify again: \(error.localizedDescription)") { Task { await store.runVerify() } }
            }
            Section {
                ActivityStateHeader(style: ActivityStyle.chain(status), reason: reason(status))
            }
            if status.enabled {
                Section {
                    DetailRow(label: "Events checked", value: status.count.formatted(.number.locale(locale)), copyable: false)
                    if !status.head.isEmpty { DetailRow(label: "Head hash", value: status.head, monospaced: true) }
                    DetailRow(label: "Anchor", value: status.anchored ? "guards the end of the log" : "none", copyable: false)
                    if let count = status.anchorCount { DetailRow(label: "Anchor count", value: count.formatted(.number.locale(locale)), copyable: false) }
                    if let head = status.anchorHead, head != status.head { DetailRow(label: "Anchor head", value: head, monospaced: true) }
                    if let pending = status.anchorPending {
                        DetailRow(label: "Pending anchor", value: "\(pending.count.formatted(.number.locale(locale))), \(pending.head)", monospaced: true)
                    }
                    if let at = store.verify.loadedAt {
                        DetailRow(label: "Verified", value: TimeDisplay.dateTime(at, mode: mode, locale: locale), copyable: false)
                    }
                } header: {
                    Text("Chain").accessibilityAddTraits(.isHeader)
                } footer: {
                    Text("Tap a hash to copy it. Compare the head with one kept off the box to see the log was not cut.")
                }
                if let at = store.verify.loadedAt, let record = AuditExport.headRecord(status, verifiedAt: at) {
                    Section {
                        ShareLink(item: ActivityExportFile(name: AuditExport.fileName(.head, partial: false), format: .head, data: Data(record.utf8)),
                                  preview: SharePreview("Audit head")) {
                            Label("Share audit head", systemImage: "square.and.arrow.up")
                                .frame(minHeight: Spacing.minimumTarget)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .announcing(announcement(status))
    }

    private func reason(_ status: AuditChainStatus) -> String {
        if !status.enabled { return "This server keeps no audit WAL, so there is no chain to check." }
        if !status.ok { return status.error.map { "First broken link: \($0)" } ?? "The chain does not verify." }
        return "Every link of the hash chain matches."
    }

    private func announcement(_ status: AuditChainStatus) -> String? {
        guard store.verify.loadedAt != nil else { return nil }
        if !status.enabled { return "Verification is off on this server" }
        return status.ok ? "Chain intact, \(status.count) events checked" : "Chain broken"
    }
}
