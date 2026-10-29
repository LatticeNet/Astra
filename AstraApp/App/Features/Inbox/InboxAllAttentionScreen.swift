import SwiftUI

/// M1-05 Attention: every attention row behind Inbox "Show all". It is
/// restored on relaunch, so it carries every state of section 5.0 itself:
/// placeholders on the first load, what failed, what this token cannot
/// read, and "Nothing needs a look" only when every input is loaded.
struct InboxAllAttentionScreen: View {
    @Environment(InboxStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(PowerMonitor.self) private var power
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        let items = store.displayed.attention
        let statuses = store.attentionStatuses
        let waiting = statuses.contains(where: \.waiting)
        let failures = statuses.compactMap(\.failureSentence)
        let denied = store.attentionDenied
        let offline = !network.isSatisfied
        List {
            Section {
                if offline {
                    offlineRow(loadedBefore: statuses.contains(where: \.everLoaded))
                }
                ForEach(failures, id: \.self) { failure in
                    ErrorRow(message: failure) { Task { await store.refresh(force: true) } }
                }
                ForEach(items) { item in
                    InboxAttentionRow(item: item)
                }
                if waiting, !offline {
                    LoadingRows(label: "Loading attention items", count: items.isEmpty ? 3 : 1)
                }
                ForEach(denied, id: \.self) { scope in
                    ScopeDeniedRow(scope: scope)
                }
                if items.isEmpty, !waiting, !offline, failures.isEmpty, denied.isEmpty {
                    ContentUnavailableView("Nothing needs a look", systemImage: "checkmark.circle")
                }
            } footer: {
                FreshnessFooter(
                    loadedAt: store.oldestLoadedAt,
                    isUpdating: store.isRefreshing || (store.oldestLoadedAt == nil && failures.isEmpty),
                    lastAttemptFailed: store.anyFailed,
                    interval: Polling.inbox.interval(lowPower: power.isLowPower)
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Attention")
        .navigationBarTitleDisplayMode(.inline)
        .polling(.inbox, version: changes.version([.nodes, .tasks, .sshguard, .ddns, .approvals, .upcoming])) {
            await store.refresh()
        }
        .refreshable { await store.refresh(force: true) }
    }

    private func offlineRow(loadedBefore: Bool) -> some View {
        Label {
            Text(loadedBefore ? "No connection. These rows are from the last refresh." : "No connection. Attention items have not loaded yet.")
                .foregroundStyle(Color.statusWarnText)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "wifi.slash").foregroundStyle(Color.statusWarnFill)
        }
        .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
