import SwiftUI

/// M5-03 Record renewal. The machine, the date it is due now, and the date
/// it is paid until, prefilled one cycle on and editable. Record is T2:
/// "Record renewal of edge-tyo-1 until Nov 26, 2026".
struct RenewSheet: View {
    let machineID: String

    @Environment(InventoryStore.self) private var store
    @Environment(ActionRunner.self) private var runner
    @Environment(NetworkMonitor.self) private var network
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var chosen = Date()
    @State private var prefilledFor: String?
    @State private var saving = false

    /// `-AstraAutoConfirm YES` taps Record once per launch, so the dialog can be captured.
    @MainActor private static var autoConfirmed = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(machine.map { "Renew \($0.inventoryName)" } ?? "Record renewal")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                            .disabled(saving)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if let machine, machine.isProfiled { saveBar(machine) }
                }
                .actionHost(inSheet: true)
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        // At the medium detent the sheet is glass; the form stays opaque (sections 1 and 4.11).
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(saving)
        .task {
            if store.machines.value == nil { await store.refresh() }
            prefill()
            await autoConfirmIfAsked()
        }
        .onChange(of: machine?.renewalDay) { prefill() }
    }

    private var machine: MachineProfile? { store.machine(id: machineID) }

    private var today: InventoryDay { InventoryDay(date: Date()) }

    private var waitingForFirstRead: Bool {
        switch store.machines {
        case .idle: true
        case .loading(let previous, _): previous == nil
        default: false
        }
    }

    private var chosenDay: InventoryDay { InventoryDay.picked(chosen) }

    @ViewBuilder
    private var content: some View {
        if let machine, machine.isProfiled {
            form(machine)
        } else if waitingForFirstRead {
            List { LoadingRows(label: "Reading the machine", count: 2) }
        } else {
            WholeScreenState {
                ContentUnavailableView {
                    Label("No profile to renew", systemImage: "questionmark.square.dashed")
                } description: {
                    Text(store.machines.value == nil
                         ? "The machine could not be read. Try again when the inventory loads."
                         : "This machine has no profile any more, or this token cannot read it.")
                }
            }
        }
    }

    /// One section, so the current date, the picker and what recording
    /// would do all fit at the medium detent above the pinned action.
    private func form(_ machine: MachineProfile) -> some View {
        let state = InventoryRenewalState.of(machine, today: today)
        let billing = [machine.vendor, InventoryCost.priceLine(machine, locale: locale)].filter { !$0.isEmpty }.joined(separator: ", ")
        return Form {
            Section {
                LabeledContent {
                    // LabeledContent stacks at accessibility sizes; the value then reads from the leading edge.
                    VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: Spacing.xxs) {
                        Text(machine.renewalDay?.formatted(locale: locale) ?? "No date")
                        if machine.renewalDay != nil {
                            Text(state.word.sentenceCased)
                                .font(TextRole.footnote.font)
                                .foregroundStyle(state.inventoryTone.isProblem ? state.inventoryTone.word : Color.secondary)
                        }
                    }
                    .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                } label: {
                    Text("Current renewal")
                }
                .frame(minHeight: Spacing.minimumTarget)
                DatePicker("Paid until", selection: $chosen, displayedComponents: .date)
                    .frame(minHeight: Spacing.minimumTarget)
                if let rolled = rolledSuggestion(machine) {
                    Button("Use \(rolled.formatted(locale: locale))") { chosen = rolled.localDate() }
                        .frame(minHeight: Spacing.minimumTarget)
                }
            } header: {
                // At accessibility sizes the header would push the picker off an iPhone SE; it moves under the preview.
                if !billing.isEmpty, !typeSize.isAccessibilitySize { Text(billing) }
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    preview(machine).announcing(problem(machine))
                    if !billing.isEmpty, typeSize.isAccessibilitySize { Text(billing) }
                    if machine.autoRoll {
                        Text("This machine renews by itself and its date moves forward when it passes. Record a renewal only to set a different date.")
                    }
                }
            }
        }
    }

    /// What recording would do, or why it cannot, under the date picker.
    private func preview(_ machine: MachineProfile) -> Text {
        let day = chosenDay
        if let problem = problem(machine) {
            return Text(problem).foregroundStyle(Color.statusWarnText)
        }
        let days = today.days(until: day)
        let when = days == 0 ? "today" : (days == 1 ? "in 1 day" : (days < 0 ? "\(-days) days ago" : "in \(days) days"))
        if let current = machine.renewalDay {
            return Text("The next renewal moves from \(current.formatted(locale: locale)) to \(day.formatted(locale: locale)), \(when). Reminders start over for that date.")
        }
        return Text("The next renewal is set to \(day.formatted(locale: locale)), \(when).")
    }

    private func problem(_ machine: MachineProfile) -> String? {
        let day = chosenDay
        if day == machine.renewalDay {
            return "\(day.formatted(locale: locale)) is already recorded. Pick the date the machine is now paid until."
        }
        if day < today {
            return "\(day.formatted(locale: locale)) has already passed, so the machine stays overdue."
        }
        return nil
    }

    /// The first renewal after today, offered when the chosen date has passed.
    private func rolledSuggestion(_ machine: MachineProfile) -> InventoryDay? {
        guard chosenDay < today else { return nil }
        return ReminderSchedule.rollForwardPast(chosenDay, cycle: machine.renewalCycleRaw, cycleDays: machine.cycleDays, today: today)
    }

    private func saveBar(_ machine: MachineProfile) -> some View {
        let missing = store.adminMissing
        let unchanged = chosenDay == machine.renewalDay
        let note: String? = if let missing { "Needs \(missing)" } else if !network.isSatisfied { "No connection" } else { nil }
        return VStack(spacing: Spacing.s) {
            if let note {
                Text(note).textRole(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                Task { await record(machine) }
            } label: {
                Text(typeSize.isAccessibilitySize ? "Record renewal" : "Record renewal until \(chosenDay.formatted(locale: locale))")
                    .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget)
            }
            .accessibilityLabel("Record renewal of \(machine.inventoryName) until \(chosenDay.formatted(locale: locale))")
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .tint(Color.accentFill)
            .disabled(missing != nil || unchanged || saving || !network.isSatisfied)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        // The pinned action must leave room for the content above it at AX5, as in ConfirmSheet.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func prefill() {
        guard let machine, machine.isProfiled, prefilledFor != machine.id else { return }
        prefilledFor = machine.id
        let base = machine.renewalDay ?? today
        let next = ReminderSchedule.advance(base, cycle: machine.renewalCycleRaw, cycleDays: machine.cycleDays) ?? base
        chosen = next.localDate()
    }

    private func record(_ machine: MachineProfile) async {
        saving = true
        let outcome = await runner.run(InventoryIntents.renew(machine, to: chosenDay, locale: locale))
        saving = false
        if case .done = outcome { dismiss() }
    }

    private func autoConfirmIfAsked() async {
        guard LaunchOverrides.current.autoConfirm, session.isDemo, !Self.autoConfirmed, let machine, machine.isProfiled,
              chosenDay != machine.renewalDay else { return }
        Self.autoConfirmed = true
        try? await Task.sleep(for: .milliseconds(600))
        await record(machine)
    }
}

extension InventoryRenewalState {
    var inventoryTone: StatusTone { StatusStyle.inventoryRenewal(self).tone }
}
