import SwiftUI

/// M5-04 Reminders. The preview is computed on this iPhone from the machine
/// list with `ReminderSchedule`: which machines today's run would remind,
/// or the next reminder date when none would. Send is T2 naming the count;
/// the result lists each reminder the server says it sent.
struct RemindersSheet: View {
    @Environment(InventoryStore.self) private var store
    @Environment(ActionRunner.self) private var runner
    @Environment(NetworkMonitor.self) private var network
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @State private var sending = false
    @State private var result: [RenewalReminderFire]?

    @MainActor private static var autoConfirmed = false

    var body: some View {
        NavigationStack {
            InventoryListState(state: store.machines, noun: "machines", retry: { Task { await store.refresh() } }) { machines in
                content(machines)
            }
            .navigationTitle("Renewal reminders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .disabled(sending)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let machines = store.machines.value, result == nil { sendBar(machines) }
            }
            .actionHost(inSheet: true)
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(sending)
        .task {
            if store.machines.value == nil { await store.refresh() }
            await autoConfirmIfAsked()
        }
    }

    private var today: InventoryDay { InventoryDay(date: Date()) }

    @ViewBuilder
    private func content(_ machines: [MachineProfile]) -> some View {
        let due = ReminderSchedule.dueToday(machines, today: today)
        let coverage = ReminderSchedule.coverage(machines, today: today)
        List {
            if let result {
                resultSection(result, machines: machines)
            } else {
                Section {
                    if due.isEmpty {
                        Label {
                            Text("No reminder is due today, so a send would deliver nothing.")
                        } icon: {
                            Image(systemName: "bell.slash").foregroundStyle(Color.statusQuiet)
                        }
                        .frame(minHeight: Spacing.minimumTarget)
                    }
                    ForEach(due) { pending in
                        row(pending)
                    }
                } header: {
                    Text(due.isEmpty ? "Due today" : (due.count == 1 ? "1 reminder due today" : "\(due.count) reminders due today"))
                } footer: {
                    Text("The server skips a reminder it already sent for the same date and offset, so fewer may go out.")
                }
            }

            Section {
                if let next = ReminderSchedule.nextAfterToday(machines, today: today) {
                    let days = next.reminder.inDays
                    DetailRow(label: "Next after today",
                              value: "\(next.machine.inventoryName), \(next.reminder.at.formatted(locale: locale))",
                              secondary: days == 1 ? "In 1 day" : "In \(days) days", copyable: false)
                    let same = coverage.pending.filter { $0.reminder.at == next.reminder.at }.count
                    if same > 1 {
                        DetailRow(label: "Same day", value: "\(same) machines, sent as one message", copyable: false)
                    }
                } else {
                    DetailRow(label: "Next after today", value: "None scheduled", copyable: false)
                }
                DetailRow(label: "Reminders on", value: coverage.covered == 1 ? "1 machine" : "\(coverage.covered) machines", copyable: false)
                if coverage.off > 0 {
                    DetailRow(label: "Reminders off", value: coverage.off == 1 ? "1 machine" : "\(coverage.off) machines", copyable: false)
                }
            } header: {
                Text("Schedule")
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Machines are reminded 14, 7, 3, 1 and 0 days before renewal unless their profile names other days, and daily for 7 days after a missed renewal. Where reminders go is set in Notifications.")
                    FreshnessFooter(state: store.machines, interval: 60)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ pending: ReminderSchedule.Pending) -> some View {
        let state = InventoryRenewalState.of(pending.machine, today: today)
        let style = StatusStyle.inventoryRenewal(state)
        return StatusRow(
            style: style,
            title: pending.machine.inventoryName,
            detail: ReminderSchedule.line(pending.reminder, today: today, locale: locale),
            accessibilityPhrase: "\(pending.machine.inventoryName), \(style.word), \(ReminderSchedule.line(pending.reminder, today: today, locale: locale))"
        )
    }

    @ViewBuilder
    private func resultSection(_ fired: [RenewalReminderFire], machines: [MachineProfile]) -> some View {
        Section {
            if fired.isEmpty {
                Label {
                    Text("Nothing went out: every reminder due today had already been sent.")
                } icon: {
                    Image(systemName: "bell.slash").foregroundStyle(Color.statusQuiet)
                }
                .frame(minHeight: Spacing.minimumTarget)
            }
            ForEach(fired) { fire in
                let name = InventoryLookup.machine(fire.machineID, in: machines)?.inventoryName ?? (fire.nodeName.isEmpty ? fire.nodeID : fire.nodeName)
                StatusRow(
                    style: StatusStyle(word: "sent", symbol: "bell.badge", tone: .ok),
                    title: name,
                    detail: firedLine(fire),
                    accessibilityPhrase: "\(name), sent, \(firedLine(fire))"
                )
            }
        } header: {
            Text(fired.count == 1 ? "1 reminder sent" : "\(fired.count) reminders sent")
        } footer: {
            Button("Done") { dismiss() }
                .frame(minHeight: Spacing.minimumTarget)
        }
    }

    private func firedLine(_ fire: RenewalReminderFire) -> String {
        let date = fire.renewalDay?.formatted(locale: locale) ?? fire.nextRenewal
        if fire.offsetDays < 0 { return "Renewal \(date) passed \(-fire.offsetDays == 1 ? "1 day" : "\(-fire.offsetDays) days") ago" }
        if fire.offsetDays == 0 { return "Renews today, \(date)" }
        return "Renews \(date), \(fire.offsetDays == 1 ? "1 day" : "\(fire.offsetDays) days") ahead"
    }

    private func sendBar(_ machines: [MachineProfile]) -> some View {
        let due = ReminderSchedule.dueToday(machines, today: today)
        let missing = store.adminMissing
        let note: String? = if let missing { "Needs \(missing)" } else if !network.isSatisfied { "No connection" } else if due.isEmpty { "Nothing is due today" } else { nil }
        return VStack(spacing: Spacing.s) {
            if let note {
                Text(note).textRole(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                Task { await send(due) }
            } label: {
                Text(due.count == 1 ? "Send 1 reminder" : "Send \(due.count) reminders")
                    .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .tint(Color.accentFill)
            .disabled(due.isEmpty || missing != nil || sending || !network.isSatisfied)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func send(_ due: [ReminderSchedule.Pending]) async {
        let sink = InventoryFiredSink()
        sending = true
        let outcome = await runner.run(InventoryIntents.sendReminders(due, sink: sink))
        sending = false
        if case .done = outcome {
            result = await sink.fired ?? []
        }
    }

    private func autoConfirmIfAsked() async {
        guard LaunchOverrides.current.autoConfirm, session.isDemo, !Self.autoConfirmed, let machines = store.machines.value else { return }
        let due = ReminderSchedule.dueToday(machines, today: today)
        guard !due.isEmpty else { return }
        Self.autoConfirmed = true
        try? await Task.sleep(for: .milliseconds(600))
        await send(due)
    }
}
