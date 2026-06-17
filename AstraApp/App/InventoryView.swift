import SwiftUI

// MARK: - Inventory root

/// Cost and renewal inventory for the fleet. Lists every operator-authored
/// `MachineProfile`, surfaces upcoming/overdue renewals, and lets the operator
/// add, edit, renew, and delete machines. Mirrors the visual language of the
/// Overview screen: a hero card, stat grid, grouped section cards.
struct InventoryView: View {
    @EnvironmentObject private var model: DashboardModel
    @State private var showingAdd = false
    @State private var runningReminders = false
    @State private var reminderResult: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !model.configured {
                        notConfiguredCard
                    }

                    heroCard

                    renewalsSection

                    machinesSection

                    InlineStatusView(
                        isLoading: model.isLoading("machines"),
                        error: model.error(for: "machines")
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(backgroundGradient)
            .navigationTitle("Inventory")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        runReminders()
                    } label: {
                        if runningReminders {
                            ProgressView()
                        } else {
                            Image(systemName: "bell.badge")
                        }
                    }
                    .disabled(!model.configured || runningReminders)

                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!model.configured)
                }
            }
            .refreshable {
                await model.loadMachines()
            }
            .task {
                if model.configured {
                    await model.loadMachines()
                }
            }
            .sheet(isPresented: $showingAdd) {
                MachineEditView(isNew: true)
                    .environmentObject(model)
            }
            .alert("Renewal reminders", isPresented: reminderAlertBinding) {
                Button("OK", role: .cancel) { reminderResult = nil }
            } message: {
                Text(reminderResult ?? "")
            }
        }
    }

    private var reminderAlertBinding: Binding<Bool> {
        Binding(
            get: { reminderResult != nil },
            set: { if !$0 { reminderResult = nil } }
        )
    }

    private func runReminders() {
        guard !runningReminders else { return }
        runningReminders = true
        Task {
            let count = await model.runRenewalReminders()
            runningReminders = false
            reminderResult = count == 1
                ? "Sent 1 renewal reminder."
                : "Sent \(count) renewal reminders."
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Theme.violet.opacity(0.08), Color.clear],
            startPoint: .top,
            endPoint: .center
        )
        .ignoresSafeArea()
    }

    private var notConfiguredCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connect to Lattice", systemImage: "link.circle.fill")
                .font(.headline)
                .foregroundStyle(Theme.accent)
            Text("Add your Lattice server URL and a token (or log in) in More → Settings to manage your inventory.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .latticeCard()
    }

    // MARK: Hero

    private var heroCard: some View {
        let summary = model.inventorySummary
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Monthly spend")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(primarySpendText(summary))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                Spacer()
                Image(systemName: "shippingbox.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.violet)
                    .frame(width: 44, height: 44)
                    .background(Theme.violet.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if let secondary = secondaryCurrencyText(summary) {
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                heroStat(value: "\(summary.machineCount)", label: "machines", tint: Theme.secondary)
                heroStat(value: "\(summary.dueSoon.count)", label: "due soon", tint: summary.dueSoon.isEmpty ? Theme.online : Theme.warning)
                heroStat(value: "\(summary.overdue.count)", label: "overdue", tint: summary.overdue.isEmpty ? Theme.online : Theme.critical)
            }
        }
        .latticeCard(padding: 18)
    }

    private func heroStat(value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func primarySpendText(_ summary: InventorySummary) -> String {
        guard let cost = summary.primaryMonthlyCost else { return "—" }
        return CurrencyFormatter.string(amountMajorUnits: cost.amount, currency: cost.currency)
    }

    /// When more than one currency is tracked, list the others so the headline
    /// figure isn't mistaken for the whole spend.
    private func secondaryCurrencyText(_ summary: InventorySummary) -> String? {
        let costs = summary.monthlyCostByCurrency
        guard costs.count > 1, let primary = summary.primaryMonthlyCost else { return nil }
        let others = costs
            .filter { $0.key != primary.currency }
            .sorted { $0.value > $1.value }
            .map { CurrencyFormatter.string(amountMajorUnits: $0.value, currency: $0.key) }
        guard !others.isEmpty else { return nil }
        return "plus " + others.joined(separator: " · ") + " /mo"
    }

    // MARK: Renewals

    @ViewBuilder
    private var renewalsSection: some View {
        let summary = model.inventorySummary
        if !summary.overdue.isEmpty || !summary.dueSoon.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeaderView(
                    "Renewals",
                    systemImage: "calendar.badge.clock",
                    accessory: "\(summary.overdue.count + summary.dueSoon.count)"
                )
                VStack(spacing: 0) {
                    ForEach(Array(summary.overdue.enumerated()), id: \.element.id) { index, machine in
                        if index > 0 { Divider() }
                        renewalRow(machine: machine, overdue: true)
                    }
                    ForEach(Array(summary.dueSoon.enumerated()), id: \.element.id) { index, machine in
                        if index > 0 || !summary.overdue.isEmpty { Divider() }
                        renewalRow(machine: machine, overdue: false)
                    }
                }
            }
            .latticeCard()
        }
    }

    @ViewBuilder
    private func renewalRow(machine: MachineProfile, overdue: Bool) -> some View {
        let days = machine.daysUntilRenewal()
        let tint = overdue ? Theme.critical : Theme.warning
        NavigationLink {
            MachineDetailView(machineID: machine.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: overdue ? "exclamationmark.circle.fill" : "clock.fill")
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(machine.displayLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let next = machine.nextRenewal {
                        Text("Renews \(RelativeDateFormatter.string(from: next))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                StatusPill(
                    text: renewalLabel(days: days, overdue: overdue),
                    systemImage: overdue ? "exclamationmark.triangle.fill" : "hourglass",
                    color: tint
                )
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func renewalLabel(days: Int?, overdue: Bool) -> String {
        guard let days else { return overdue ? "overdue" : "due" }
        if overdue {
            let magnitude = abs(days)
            return magnitude == 1 ? "1d overdue" : "\(magnitude)d overdue"
        }
        if days == 0 { return "due today" }
        return days == 1 ? "in 1d" : "in \(days)d"
    }

    // MARK: Machines

    @ViewBuilder
    private var machinesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView("Machines", systemImage: "server.rack", accessory: "\(model.machines.count)")
            if model.machines.isEmpty {
                if model.isLoading("machines") {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                        .latticeCard()
                } else {
                    AstraEmptyStateView(
                        title: "No machines yet",
                        systemImage: "shippingbox",
                        message: model.configured
                            ? "Tap + to add a machine and track its cost and renewal date."
                            : "Connect to Lattice in Settings to load your inventory."
                    )
                    .latticeCard()
                }
            } else {
                ForEach(model.machines) { machine in
                    NavigationLink {
                        MachineDetailView(machineID: machine.id)
                    } label: {
                        MachineRow(machine: machine)
                            .latticeCard()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Machine row

struct MachineRow: View {
    var machine: MachineProfile

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(machine.online ? Theme.online : Theme.offline)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(machine.displayLabel)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                if let monthly = machine.monthlyCost {
                    Text(CurrencyFormatter.string(amountMajorUnits: monthly, currency: machine.currency) + "/mo")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                } else {
                    Text("—")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                if let next = machine.nextRenewal {
                    Text("renews \(RelativeDateFormatter.string(from: next))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var subtitle: String {
        let parts = [machine.vendor, machine.region].filter { !$0.isEmpty }
        if parts.isEmpty { return "No vendor" }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Machine detail

struct MachineDetailView: View {
    @EnvironmentObject private var model: DashboardModel
    @Environment(\.dismiss) private var dismiss

    let machineID: String

    @State private var showingEdit = false
    @State private var showingRenew = false
    @State private var renewDate = Date()
    @State private var confirmingDelete = false
    @State private var working = false

    private var machine: MachineProfile? {
        model.machines.first { $0.id == machineID }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let machine {
                    headerCard(machine)
                    detailsCard(machine)
                    renewalCard(machine)
                    if !machine.notes.isEmpty {
                        notesCard(machine)
                    }
                    actionsCard(machine)
                } else {
                    AstraEmptyStateView(
                        title: "Machine unavailable",
                        systemImage: "shippingbox",
                        message: "This machine is no longer in your inventory."
                    )
                    .latticeCard()
                }
            }
            .padding(16)
        }
        .background(
            LinearGradient(colors: [Theme.violet.opacity(0.08), Color.clear], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        )
        .navigationTitle(machine?.displayLabel ?? "Machine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { showingEdit = true }
                    .disabled(machine == nil)
            }
        }
        .sheet(isPresented: $showingEdit) {
            if let machine {
                MachineEditView(isNew: false, machine: machine)
                    .environmentObject(model)
            }
        }
        .sheet(isPresented: $showingRenew) {
            renewSheet
        }
        .confirmationDialog(
            "Delete this machine?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the machine and its cost/renewal metadata from Lattice.")
        }
    }

    // MARK: Cards

    private func headerCard(_ machine: MachineProfile) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(Theme.violet)
                .frame(width: 46, height: 46)
                .background(Theme.violet.opacity(0.16), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(machine.displayLabel)
                    .font(.headline)
                Text(machine.vendor.isEmpty ? "No vendor" : machine.vendor)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            StatusPill(
                text: machine.online ? "Online" : "Offline",
                systemImage: machine.online ? "bolt.horizontal.circle.fill" : "bolt.slash.fill",
                color: machine.online ? Theme.online : Theme.offline
            )
        }
        .latticeCard(padding: 18)
    }

    private func detailsCard(_ machine: MachineProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView("Details", systemImage: "info.circle")
            VStack(spacing: 10) {
                DetailRow(label: "Vendor", value: machine.vendor.isEmpty ? "—" : machine.vendor)
                DetailRow(label: "Region", value: machine.region.isEmpty ? "—" : machine.region)
                DetailRow(label: "Linked node", value: machine.nodeName.isEmpty ? machine.nodeID : machine.nodeName)
                DetailRow(label: "Node status", value: machine.online ? "Online" : "Offline")
                DetailRow(label: "Console URL", value: machine.hasConsoleURL ? "Set" : "—")
                DetailRow(label: "Detail URL", value: machine.hasDetailURL ? "Set" : "—")
            }
        }
        .latticeCard()
    }

    private func renewalCard(_ machine: MachineProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView("Cost & renewal", systemImage: "creditcard")
            VStack(spacing: 10) {
                DetailRow(
                    label: "Price",
                    value: machine.priceCents > 0
                        ? CurrencyFormatter.string(amountMajorUnits: machine.priceMajorUnits, currency: machine.currency)
                        : "—"
                )
                DetailRow(label: "Cycle", value: machine.renewalCycle?.displayName ?? "—")
                DetailRow(
                    label: "Monthly cost",
                    value: machine.monthlyCost.map { CurrencyFormatter.string(amountMajorUnits: $0, currency: machine.currency) } ?? "—"
                )
                DetailRow(label: "Next renewal", value: nextRenewalText(machine))
                DetailRow(label: "Auto-roll", value: machine.autoRoll ? "On" : "Off")
                DetailRow(label: "Reminders", value: machine.remindersEnabled ? "On" : "Off")
            }
        }
        .latticeCard()
    }

    private func notesCard(_ machine: MachineProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeaderView("Notes", systemImage: "note.text")
            Text(machine.notes)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .latticeCard()
    }

    private func actionsCard(_ machine: MachineProfile) -> some View {
        VStack(spacing: 12) {
            Button {
                renewDate = machine.nextRenewal ?? Date()
                showingRenew = true
            } label: {
                Label("Renew", systemImage: "arrow.clockwise.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(working)

            Button {
                showingEdit = true
            } label: {
                Label("Edit", systemImage: "square.and.pencil")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(Theme.secondary)

            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(Theme.critical)
            .disabled(working)
        }
        .latticeCard()
    }

    // MARK: Renew sheet

    private var renewSheet: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Next renewal", selection: $renewDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                } header: {
                    Text("Set the new renewal date")
                } footer: {
                    Text("The machine's renewal countdown updates to this date.")
                }
            }
            .navigationTitle("Renew")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingRenew = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { performRenew() }
                        .disabled(working)
                }
            }
        }
    }

    // MARK: Helpers

    private func nextRenewalText(_ machine: MachineProfile) -> String {
        guard let next = machine.nextRenewal else { return "—" }
        let absolute = next.formatted(date: .abbreviated, time: .omitted)
        return "\(absolute) (\(RelativeDateFormatter.string(from: next)))"
    }

    private func performRenew() {
        guard !working else { return }
        working = true
        let date = renewDate
        Task {
            let ok = await model.renewMachine(id: machineID, nextRenewal: date)
            working = false
            if ok { showingRenew = false }
        }
    }

    private func performDelete() {
        guard !working else { return }
        working = true
        Task {
            let ok = await model.deleteMachine(id: machineID)
            working = false
            if ok { dismiss() }
        }
    }
}

// MARK: - Machine edit/create form

struct MachineEditView: View {
    @EnvironmentObject private var model: DashboardModel
    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool
    private let machine: MachineProfile?

    @State private var nodeID: String
    @State private var label: String
    @State private var vendor: String
    @State private var region: String
    @State private var notes: String
    @State private var priceText: String
    @State private var currency: String
    @State private var cycle: RenewalCycle
    @State private var cycleDays: Int
    @State private var hasRenewalDate: Bool
    @State private var nextRenewal: Date
    @State private var autoRoll: Bool
    @State private var remindersEnabled: Bool

    @State private var saving = false

    init(isNew: Bool, machine: MachineProfile? = nil) {
        self.isNew = isNew
        self.machine = machine
        _nodeID = State(initialValue: machine?.nodeID ?? "")
        _label = State(initialValue: machine?.label ?? "")
        _vendor = State(initialValue: machine?.vendor ?? "")
        _region = State(initialValue: machine?.region ?? "")
        _notes = State(initialValue: machine?.notes ?? "")
        if let cents = machine?.priceCents, cents > 0 {
            _priceText = State(initialValue: String(format: "%.2f", Double(cents) / 100))
        } else {
            _priceText = State(initialValue: "")
        }
        _currency = State(initialValue: machine?.currency.isEmpty == false ? (machine?.currency ?? "USD") : "USD")
        _cycle = State(initialValue: machine?.renewalCycle ?? .monthly)
        _cycleDays = State(initialValue: max(1, machine?.cycleDays ?? 30))
        _hasRenewalDate = State(initialValue: machine?.nextRenewal != nil)
        _nextRenewal = State(initialValue: machine?.nextRenewal ?? Date())
        _autoRoll = State(initialValue: machine?.autoRoll ?? false)
        _remindersEnabled = State(initialValue: machine?.remindersEnabled ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isNew {
                    Section {
                        Picker("Node", selection: $nodeID) {
                            Text("Select a node").tag("")
                            ForEach(model.nodes) { node in
                                Text(node.displayName).tag(node.id)
                            }
                        }
                    } header: {
                        Text("Linked node")
                    } footer: {
                        Text("The Lattice node this machine maps to.")
                    }
                } else if let machine {
                    Section("Linked node") {
                        DetailRow(label: "Node", value: machine.nodeName.isEmpty ? machine.nodeID : machine.nodeName)
                    }
                }

                Section("Identity") {
                    TextField("Label", text: $label)
                    TextField("Vendor", text: $vendor)
                    TextField("Region", text: $region)
                }

                Section("Cost") {
                    HStack {
                        Text("Price")
                        Spacer()
                        TextField("0.00", text: $priceText)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .frame(maxWidth: 120)
                    }
                    HStack {
                        Text("Currency")
                        Spacer()
                        TextField("USD", text: $currency)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .frame(maxWidth: 100)
                    }
                    Picker("Cycle", selection: $cycle) {
                        ForEach(RenewalCycle.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    if cycle == .customDays {
                        Stepper("Every \(cycleDays) day\(cycleDays == 1 ? "" : "s")", value: $cycleDays, in: 1...3650)
                    }
                }

                Section("Renewal") {
                    Toggle("Set renewal date", isOn: $hasRenewalDate)
                    if hasRenewalDate {
                        DatePicker("Next renewal", selection: $nextRenewal, displayedComponents: .date)
                    }
                    Toggle("Auto-roll renewal", isOn: $autoRoll)
                    Toggle("Renewal reminders", isOn: $remindersEnabled)
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                if !isNew, let machine, (machine.hasConsoleURL || machine.hasDetailURL) {
                    Section {
                        if machine.hasConsoleURL {
                            DetailRow(label: "Console URL", value: "Set")
                        }
                        if machine.hasDetailURL {
                            DetailRow(label: "Detail URL", value: "Set")
                        }
                    } footer: {
                        Text("Console and detail URLs are write-only and are not returned by the server, so they aren't shown for editing here.")
                    }
                }
            }
            .navigationTitle(isNew ? "New machine" : "Edit machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saving || !canSave)
                }
            }
            .overlay {
                if saving {
                    ProgressView()
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private var canSave: Bool {
        if isNew && nodeID.isEmpty { return false }
        return true
    }

    private func save() {
        guard !saving, canSave else { return }
        saving = true

        let dollars = Double(priceText.trimmingCharacters(in: .whitespaces)) ?? 0
        let priceCents = Int64((dollars * 100).rounded())
        let trimmedCurrency = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let request = MachineProfileRequest(
            id: machine?.id ?? "",
            nodeID: nodeID,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            vendor: vendor.trimmingCharacters(in: .whitespacesAndNewlines),
            region: region.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes,
            priceCents: priceCents,
            currency: trimmedCurrency.isEmpty ? "USD" : trimmedCurrency,
            renewalCycle: cycle.rawValue,
            cycleDays: cycle == .customDays ? cycleDays : 0,
            nextRenewal: hasRenewalDate ? nextRenewal : nil,
            autoRoll: autoRoll,
            remindersEnabled: remindersEnabled
        )

        Task {
            let ok = await model.saveMachine(request, isNew: isNew)
            saving = false
            if ok { dismiss() }
        }
    }
}
