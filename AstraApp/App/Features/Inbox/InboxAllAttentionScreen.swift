import SwiftUI

/// M1-05 Attention: every attention row behind Inbox "Show all".
struct InboxAllAttentionScreen: View {
    @Environment(InboxStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(PowerMonitor.self) private var power

    var body: some View {
        let items = store.displayed.attention
        List {
            if items.isEmpty {
                ContentUnavailableView("Nothing needs a look", systemImage: "checkmark.circle")
            } else {
                Section {
                    ForEach(items) { item in
                        InboxAttentionRow(item: item)
                    }
                } footer: {
                    FreshnessFooter(loadedAt: store.oldestLoadedAt, lastAttemptFailed: store.anyFailed, interval: Polling.inbox.interval(lowPower: power.isLowPower))
                }
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
}
