import SwiftUI

/// M5-02 Machine. Vendor, price and cycle, the monthly equivalent, the next
/// renewal and reminder, the linked node, notes; Record renewal (T2), reveal
/// the stored console or detail link (S), delete the profile (T4), edit on web.
struct MachineDetailScreen: View {
    let id: String

    @Environment(InventoryStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        InventoryListState(state: store.machines, noun: "the machine", retry: { Task { await store.refresh() } }) { machines in
            if let machine = InventoryLookup.machine(id, in: machines) {
                if machine.isProfiled {
                    detail(machine)
                } else {
                    unprofiled(machine)
                }
            } else {
                notFound
            }
        }
        .navigationTitle(store.machine(id: id)?.inventoryName ?? "Machine")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(InventoryFilterSubtitle(text: subtitle))
        .refreshable { await store.refresh() }
        .polling(.standard, version: changes.version([.machines, .nodes])) { await store.refresh(fromPoll: true) }
        .task { await nodes.refreshIfOlder(than: 60) }
        .toolbar { toolbar }
    }

    private var subtitle: String? {
        guard let machine = store.machine(id: id) else { return nil }
        return InventoryRenewalState.of(machine, today: InventoryDay(date: Date())).word.inventoryCapitalized
    }

    // MARK: Profile

    @ViewBuilder
    private func detail(_ machine: MachineProfile) -> some View {
        let today = InventoryDay(date: Date())
        let state = InventoryRenewalState.of(machine, today: today)
        let style = StatusStyle.inventoryRenewal(state)
        let missing = store.adminMissing
        List {
            Section {
                StatusRow(style: style, title: machine.inventoryName, detail: machine.vendor.isEmpty ? nil : machine.vendor,
                          accessibilityPhrase: "\(machine.inventoryName), \(style.word)")
                InventoryRefreshError(state: store.machines, noun: "the machine") { Task { await store.refresh() } }
            }

            Section {
                renewalRows(machine, state: state, today: today)
                if machine.inventoryCanRenew {
                    Button {
                        router.present(.renew(machineID: machine.id))
                    } label: {
                        Label("Record renewal", systemImage: "calendar.badge.plus")
                            .frame(minHeight: Spacing.minimumTarget)
                    }
                    .disabled(missing != nil)
                    if let missing { Text("Needs \(missing)").textRole(.footnote) }
                }
            } header: {
                Text("Renewal")
            } footer: {
                if machine.autoRoll {
                    Text("Renews by itself: the date moves forward each cycle. Record a renewal only to set a different date.")
                }
            }

            Section("Billing") {
                DetailRow(label: "Vendor", value: machine.vendor.isEmpty ? "None recorded" : machine.vendor, copyable: false)
                if !machine.label.isEmpty {
                    DetailRow(label: "Label", value: machine.label, copyable: false)
                }
                DetailRow(label: "Price", value: InventoryCost.priceLine(machine, locale: locale), copyable: false)
                let monthly = InventoryCost.monthlyEquivalentCents(machine)
                if monthly > 0, machine.renewalCycle != .monthly {
                    DetailRow(label: "Per month", value: InventoryCurrency.format(cents: monthly, currency: machine.currency, locale: locale), copyable: false)
                }
                DetailRow(label: "Billing", value: InventoryCost.billing(machine).title, copyable: false)
                if !machine.region.isEmpty {
                    DetailRow(label: "Region", value: machine.region, copyable: false)
                }
                if let purchased = machine.purchasedAt {
                    DetailRow(label: "Purchased", value: InventoryDay(date: purchased).formatted(locale: locale), copyable: false)
                }
                if let vendor = store.vendor(named: machine.vendor) ?? machine.vendorProfile, let url = URL(string: vendor.url), ["https", "http"].contains(url.scheme ?? "") {
                    Button {
                        openURL(url)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text("Vendor site").foregroundStyle(Color.accentText)
                                Text(url.host() ?? vendor.url).textRole(.footnote)
                            }
                        } icon: {
                            Image(systemName: "globe").foregroundStyle(Color.accentText)
                        }
                        .frame(minHeight: Spacing.minimumTarget)
                    }
                    .accessibilityHint("Opens the vendor's public site in your browser")
                }
            }

            if !machine.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Notes") {
                    Text(machine.notes)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
                }
            }

            Section {
                if let node = nodes.nodes[machine.nodeID] {
                    NavigationLink(value: AppRoute.fleet(.node(id: node.id))) {
                        NodeRow(node: node, provider: nil)
                    }
                } else {
                    NavigationLink(value: AppRoute.fleet(.node(id: machine.nodeID))) {
                        StatusRow(style: StatusStyle(word: machine.online ? "online" : "not reporting", symbol: machine.online ? "checkmark.circle.fill" : "questionmark.circle", tone: machine.online ? .ok : .quiet),
                                  title: machine.nodeName.isEmpty ? machine.nodeID : machine.nodeName, detail: machine.hostFacts.hostname)
                    }
                }
            } header: {
                Text("Linked node")
            }

            Section {
                linkRow(machine, kind: .console)
                linkRow(machine, kind: .detail)
            } header: {
                Text("Provider links")
            } footer: {
                Text("Stored links are never sent to this iPhone until you reveal one with your authenticator code. It opens here in a private browser and is not kept.")
            }

            Section {
                WebLinkRow(title: "Edit on web", path: .machine(id: machine.id))
                Button(role: .destructive) {
                    Task { await deleteProfile(machine) }
                } label: {
                    Label("Delete machine profile", systemImage: "trash")
                        .foregroundStyle(missing == nil ? Color.statusFailText : Color.secondary)
                        .frame(minHeight: Spacing.minimumTarget)
                }
                .disabled(missing != nil)
                if let missing { Text("Needs \(missing)").textRole(.footnote) }
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Deleting removes the price, renewal and stored links. The node stays enrolled.")
                    FreshnessFooter(state: store.machines, interval: 60)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func renewalRows(_ machine: MachineProfile, state: InventoryRenewalState, today: InventoryDay) -> some View {
        DetailRow(label: "Cycle", value: machine.renewalCycleRaw.isEmpty ? "None" : InventoryCost.cycleWord(machine).inventoryCapitalized, copyable: false)
        if let day = machine.renewalDay {
            let shown: InventoryDay = if case .autoRenews(_, let rolled) = state { rolled } else { day }
            DetailRow(label: "Next renewal", value: shown.formatted(locale: locale), secondary: state.word.inventoryCapitalized, copyable: false)
        } else {
            DetailRow(label: "Next renewal", value: InventoryCost.renewalSetupIncomplete(machine) ? "Not set yet" : "Not tracked", copyable: false)
        }
        if machine.renewalDay != nil {
            if !machine.remindersEnabled {
                DetailRow(label: "Reminders", value: "Off", copyable: false)
            } else if let next = ReminderSchedule.nextReminder(machine, today: today) {
                let when = reminderWhen(next)
                DetailRow(label: "Next reminder", value: when.value, secondary: when.detail, copyable: false)
                let offsets = ReminderSchedule.offsets(machine).map(String.init).joined(separator: ", ")
                if !offsets.isEmpty {
                    DetailRow(label: "Reminder days", value: "\(offsets) before", copyable: false)
                }
            } else {
                DetailRow(label: "Reminders", value: "None scheduled", copyable: false)
            }
        }
    }

    private func reminderWhen(_ next: ReminderSchedule.Next) -> (value: String, detail: String?) {
        let date = next.at.formatted(locale: locale)
        if next.offset < 0 {
            let until = next.repeatsUntil?.formatted(locale: locale) ?? date
            return (next.inDays == 0 ? "Today" : date, "Daily overdue reminder until \(until)")
        }
        let ahead = next.offset == 0 ? "On the renewal day" : (next.offset == 1 ? "1 day before renewal" : "\(next.offset) days before renewal")
        switch next.inDays {
        case 0: return ("Today", ahead)
        case 1: return ("Tomorrow", ahead)
        default: return (date, "In \(next.inDays) days, \(ahead.lowercased())")
        }
    }

    @ViewBuilder
    private func linkRow(_ machine: MachineProfile, kind: InventoryLinkKind) -> some View {
        let stored = kind == .console ? machine.hasConsoleURL : machine.hasDetailURL
        let title = kind == .console ? "Reveal console link" : "Reveal detail link"
        let missing = store.revealMissing
        if stored {
            Button {
                Task { await runner.reveal(InventoryIntents.revealLink(machine, kind: kind)) }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(title)
                        Text(revealNote(missing: missing))
                            .textRole(.footnote)
                    }
                } icon: {
                    Image(systemName: kind == .console ? "terminal" : "doc.text.magnifyingglass")
                }
                .frame(minHeight: Spacing.minimumTarget)
            }
            .disabled(missing != nil)
        } else {
            DetailRow(label: kind == .console ? "Console link" : "Detail link", value: "Not stored", copyable: false)
        }
    }

    private func revealNote(missing: String?) -> String {
        if let missing { return "Needs \(missing) on the signed-in account" }
        return session.revealClient == nil ? "Needs a signed-in session and your code" : "Asks for your authenticator code"
    }

    private func deleteProfile(_ machine: MachineProfile) async {
        let outcome = await runner.run(InventoryIntents.delete(machine, locale: locale))
        // The screen closes only once the server confirmed the delete.
        if case .done = outcome { dismiss() }
    }

    // MARK: States

    @ViewBuilder
    private func unprofiled(_ machine: MachineProfile) -> some View {
        List {
            Section {
                StatusRow(style: .inventoryRenewal(.unprofiled), title: machine.inventoryName, detail: "Node \(machine.nodeName.isEmpty ? machine.nodeID : machine.nodeName)")
            } footer: {
                Text("Nobody has recorded a vendor, price or renewal for this node. Profiles are written on the web.")
            }
            Section {
                NavigationLink("Open node", value: AppRoute.fleet(.node(id: machine.nodeID)))
                    .frame(minHeight: Spacing.minimumTarget)
                WebLinkRow(title: "Add a profile on web", path: LatticeConsolePath(path: "/inventory", query: [URLQueryItem(name: "node", value: machine.nodeID)]))
            }
        }
        .listStyle(.insetGrouped)
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Not in the inventory", systemImage: "questionmark.square.dashed")
            } description: {
                Text("This machine's profile was deleted, or it belongs to a node this token cannot read.")
            } actions: {
                Button("Token scopes") { router.openSettings([.page(.scopes)]) }
                    .buttonStyle(.bordered)
                Button("Open on web") { router.openOnWeb(.machine(id: id)) }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let machine = store.machine(id: id), machine.isProfiled {
                    let missing = store.adminMissing
                    if machine.inventoryCanRenew {
                        InventoryGatedButton(title: "Record renewal", systemImage: "calendar.badge.plus", missing: missing) {
                            router.present(.renew(machineID: machine.id))
                        }
                    }
                    if machine.hasConsoleURL {
                        InventoryGatedButton(title: "Reveal console link", systemImage: "terminal", missing: store.revealMissing) {
                            Task { await runner.reveal(InventoryIntents.revealLink(machine, kind: .console)) }
                        }
                    }
                    Section {
                        Button("Copy link", systemImage: "link") { InventoryCopy.copy(InventoryCopy.machineLink(machine.id)) }
                        Button("Open on web", systemImage: "safari") { router.openOnWeb(.machine(id: machine.id)) }
                        Button("Edit on web", systemImage: "square.and.pencil") { router.openOnWeb(.machine(id: machine.id)) }
                    }
                    Section {
                        InventoryGatedButton(title: "Delete machine profile", systemImage: "trash", missing: missing, role: .destructive) {
                            Task { await deleteProfile(machine) }
                        }
                    }
                } else {
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.machine(id: id)) }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}

extension String {
    /// "Renews in 6 days" from "renews in 6 days".
    var inventoryCapitalized: String {
        prefix(1).uppercased() + dropFirst()
    }
}
