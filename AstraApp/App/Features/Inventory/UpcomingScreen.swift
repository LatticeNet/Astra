import SwiftUI

/// M5-05 Upcoming. Everything with a date that runs out in the next 30 days
/// (machine renewals, VPN users, shares, TLS certificates), overdue first
/// and then by week. Machine rows swipe Renew; the footer names the kinds
/// this token cannot read.
struct UpcomingScreen: View {
    static let kindKey = "fleet.upcoming.kind"
    static let queryKey = "fleet.upcoming.query"

    @Environment(InventoryStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(\.locale) private var locale
    @SceneStorage(UpcomingScreen.kindKey) private var kindRaw = UpcomingScreen.allKinds
    @SceneStorage(UpcomingScreen.queryKey) private var query = ""

    static let allKinds = "All"

    private var kind: InventoryUpcomingKind? {
        InventoryUpcomingKind.allCases.first { $0.filterTitle == kindRaw }
    }

    var body: some View {
        InventoryListState(state: store.expiring, noun: "upcoming dates", retry: { Task { await store.refreshUpcoming() } }) { response in
            content(response)
        }
        .navigationTitle("Upcoming")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter upcoming")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .modifier(InventoryFilterSubtitle(text: subtitle))
        .refreshable { await store.refresh() }
        .polling(.standard, version: changes.version([.upcoming, .machines])) { await store.refresh(fromPoll: true) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                FilterMenu(sections: [
                    FilterMenuSection(title: "Kind", options: [Self.allKinds] + InventoryUpcomingKind.allCases.map(\.filterTitle),
                                      defaultOption: Self.allKinds, selection: $kindRaw),
                ])
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Copy link", systemImage: "link") {
                        InventoryCopy.copy(LatticeDeepLink.upcoming.customURL?.absoluteString ?? "lattice://upcoming")
                    }
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.upcoming) }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// The kind filter and an active query, so a filtered list never reads as complete.
    private var subtitle: String? {
        let parts = [kind.map { "Showing \($0.inventoryPlural) only" }, trimmedQuery.isEmpty ? nil : "Filtered: \(trimmedQuery)"].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func content(_ response: ExpiringResponse) -> some View {
        let today = InventoryUpcoming.today(response, now: Date())
        let compiled = trimmedQuery.isEmpty ? nil : InventoryUpcomingQuery.compile(trimmedQuery)
        let kindItems = InventoryUpcoming.filter(response.items, kind: kind)
        let items: [ExpiringItem] = if case .success(let query)? = compiled { LatticeQueryEngine.apply(query, to: kindItems, now: Date()) } else { kindItems }
        let groups = InventoryUpcoming.groupByWeek(items, today: today)
        let hidden = InventoryUpcoming.hiddenKinds(response)
        List {
            Section {
                if kind != nil {
                    FilterStateRow(text: "Showing \(kind?.inventoryPlural ?? "") only.") { kindRaw = Self.allKinds }
                }
                InventoryRefreshError(state: store.expiring, noun: "upcoming dates") { Task { await store.refreshUpcoming() } }
                if case .failure(let error)? = compiled {
                    Label {
                        Text(InventoryUpcomingQuery.message(error)).foregroundStyle(Color.statusWarnText)
                    } icon: {
                        Image(systemName: "exclamationmark.magnifyingglass").foregroundStyle(Color.statusWarnFill)
                    }
                    .frame(minHeight: Spacing.minimumTarget)
                }
                summary(items)
            } footer: {
                hiddenNote(hidden)
            }
            if items.isEmpty, !trimmedQuery.isEmpty {
                Section {
                    ContentUnavailableView.search(text: trimmedQuery)
                } footer: {
                    footer(hidden: hidden, last: true)
                }
            } else if items.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(kind == nil ? "Nothing runs out in the next \(InventoryUpcoming.withinDays) days" : "No \(kind?.inventoryPlural ?? "items") run out in the next \(InventoryUpcoming.withinDays) days",
                              systemImage: "calendar.badge.checkmark")
                    } description: {
                        Text("Overdue items would show here too.")
                    }
                } footer: {
                    footer(hidden: hidden, last: true)
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        row(item)
                    }
                } header: {
                    Text(group.title(locale: locale))
                        .accessibilityAddTraits(.isHeader)
                } footer: {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        if !group.totals.isEmpty {
                            Text("Due in this group: " + group.totals.map { InventoryCurrency.format(cents: Double($0.costCents), currency: $0.currency, locale: locale) }.joined(separator: " · "))
                                .monospacedDigit()
                        }
                        if group.id == groups.last?.id { footer(hidden: hidden, last: true) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// "23 in the next 30 days, 1 overdue" and what they cost, per currency.
    private func summary(_ items: [ExpiringItem]) -> some View {
        let counts = InventoryUpcoming.headerCounts(items)
        let totals = InventoryUpcoming.sumTotals(items)
        let count = items.count == 1 ? "1 item in the next \(InventoryUpcoming.withinDays) days" : "\(items.count) items in the next \(InventoryUpcoming.withinDays) days"
        let money = totals.map { InventoryCurrency.format(cents: Double($0.costCents), currency: $0.currency, locale: locale) }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: Spacing.xxs) {
            Group {
                if counts.overdue > 0 {
                    Text("\(count), \(Text("\(counts.overdue) overdue").foregroundStyle(Color.statusFailText))")
                } else {
                    Text(count)
                }
            }
            .textRole(.rowTitle)
            Text(money.isEmpty ? "No prices recorded" : "Costs \(money)")
                .textRole(.rowDetail)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The kinds this token cannot read, named so the list never looks complete when it is not.
    @ViewBuilder
    private func hiddenNote(_ hidden: [String]) -> some View {
        if !hidden.isEmpty {
            // Each kind names its own scope: no admin scope implies read (section 6.12).
            let names = hidden.map { raw in
                guard let kind = InventoryUpcomingKind(rawValue: raw) else { return raw.replacingOccurrences(of: "_", with: " ") }
                return "\(kind.inventoryPlural) (needs \(kind.readScope))"
            }
            let allowlist = store.isConfined ? " VPN users and shares also need a token without a node allowlist." : ""
            Label {
                Text("Hidden from this token: \(names.joined(separator: ", "))." + allowlist)
            } icon: {
                Image(systemName: "eye.slash").foregroundStyle(Color.statusQuiet)
            }
        }
    }

    private func footer(hidden: [String], last: Bool) -> some View {
        FreshnessFooter(state: store.expiring, interval: 60)
    }

    @ViewBuilder
    private func row(_ item: ExpiringItem) -> some View {
        let style = StatusStyle.inventoryUpcoming(item)
        let money = item.costCents > 0 ? InventoryCurrency.format(cents: Double(item.costCents), currency: item.currency, locale: locale) : nil
        // The glyph names the kind; machines, the common case, need no second word for it.
        let kindWord = item.kind == InventoryUpcomingKind.machineRenewal.rawValue ? nil : InventoryUpcomingKind.title(for: item.kind)
        let detail = [kindWord, item.subtitle.isEmpty ? nil : item.subtitle].compactMap { $0 }.joined(separator: ", ")
        let label = StatusRow(style: style, title: item.title, detail: detail, trailing: money)
            .accessibilityLabel([item.title, InventoryUpcomingKind.title(for: item.kind), style.word, item.subtitle.isEmpty ? nil : item.subtitle, money].compactMap { $0 }.joined(separator: ", "))
        let machine = item.kind == InventoryUpcomingKind.machineRenewal.rawValue ? store.machine(id: item.objectID) : nil
        if let route = route(for: item) {
            NavigationLink(value: route) { label }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if let machine, machine.inventoryCanRenew, store.adminMissing == nil {
                        Button("Renew", systemImage: "calendar.badge.plus") {
                            router.present(.renew(machineID: machine.id))
                        }
                        .tint(.accentFill)
                    }
                }
                .contextMenu {
                    Button("Open", systemImage: "arrow.right.circle") { router.push(route) }
                    if let machine, machine.inventoryCanRenew {
                        InventoryGatedButton(title: "Record renewal", systemImage: "calendar.badge.plus", missing: store.adminMissing) {
                            router.present(.renew(machineID: machine.id))
                        }
                    }
                    if let path = webPath(for: item) {
                        Button("Open on web", systemImage: "safari") { router.openOnWeb(path) }
                    }
                }
        } else {
            label
        }
    }

    /// Where a row opens: the machine, the VPN identity, the share or the check.
    private func route(for item: ExpiringItem) -> AppRoute? {
        guard !item.objectID.isEmpty else { return nil }
        switch InventoryUpcomingKind(rawValue: item.kind) {
        case .machineRenewal: return .inventory(.machine(id: item.objectID))
        case .vpnUser: return .vpn(.user(id: item.objectID))
        case .share: return .platform(.share(id: item.objectID))
        case .tlsCertificate: return .monitoring(.check(id: item.objectID))
        case nil: return nil
        }
    }

    /// The server's console path for the row, when it is a path on the console.
    private func webPath(for item: ExpiringItem) -> LatticeConsolePath? {
        guard item.href.hasPrefix("/"), !item.href.hasPrefix("//"), let components = URLComponents(string: item.href) else { return nil }
        return LatticeConsolePath(path: components.path, query: components.queryItems ?? [])
    }
}
