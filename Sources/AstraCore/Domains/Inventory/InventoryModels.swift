import Foundation

public enum RenewalCycle: String, Codable, CaseIterable, Sendable {
    case monthly
    case quarterly
    case semiannual
    case annual
    case customDays = "custom_days"

    public var displayName: String {
        switch self {
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        case .semiannual: "Semi-annual"
        case .annual: "Annual"
        case .customDays: "Custom"
        }
    }

    /// Approximate number of days in one cycle.
    public func approximateDays(customDays: Int) -> Int {
        switch self {
        case .monthly: 30
        case .quarterly: 91
        case .semiannual: 182
        case .annual: 365
        case .customDays: max(customDays, 1)
        }
    }

    /// Months per cycle for the named cycles; nil for custom days.
    public var months: Int? {
        switch self {
        case .monthly: 1
        case .quarterly: 3
        case .semiannual: 6
        case .annual: 12
        case .customDays: nil
        }
    }
}

/// Operator-authored inventory, cost and renewal metadata bound to a node. This
/// is the secret-free `machineView` returned by the server: console/detail URLs
/// are never sent back, only `hasConsoleURL`/`hasDetailURL` booleans. The
/// write-only `consoleURL`/`detailURL` fields hold values the edit form is about
/// to submit and are always empty when decoded from the server.
///
/// `GET /api/machines` lists every node the caller can read, profiled or not;
/// a node nobody profiled arrives with an empty `id`.
public struct MachineProfile: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var nodeID: String
    public var nodeName: String
    public var label: String
    public var online: Bool
    public var hostFacts: LatticeHostFacts
    public var vendor: String
    public var region: String
    public var notes: String
    public var hasConsoleURL: Bool
    public var hasDetailURL: Bool
    public var priceCents: Int64
    public var currency: String
    public var renewalCycleRaw: String
    public var cycleDays: Int
    public var nextRenewal: Date?
    public var serverDaysUntilRenewal: Int
    public var autoRoll: Bool
    public var remindDaysBefore: [Int]
    public var remindersEnabled: Bool
    public var createdAt: Date?
    public var updatedAt: Date?
    /// The vendor record whose name matches `vendor`, when one exists.
    public var vendorProfile: InventoryVendor? = nil
    public var purchasedAt: Date? = nil

    // Write-only, never populated by the server; used by the edit form.
    public var consoleURL: String
    public var detailURL: String

    public init(
        id: String,
        nodeID: String = "",
        nodeName: String = "",
        label: String = "",
        online: Bool = false,
        hostFacts: LatticeHostFacts = LatticeHostFacts(),
        vendor: String = "",
        region: String = "",
        notes: String = "",
        hasConsoleURL: Bool = false,
        hasDetailURL: Bool = false,
        priceCents: Int64 = 0,
        currency: String = "",
        renewalCycleRaw: String = "",
        cycleDays: Int = 0,
        nextRenewal: Date? = nil,
        serverDaysUntilRenewal: Int = 0,
        autoRoll: Bool = false,
        remindDaysBefore: [Int] = [],
        remindersEnabled: Bool = false,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        consoleURL: String = "",
        detailURL: String = ""
    ) {
        self.id = id
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.label = label
        self.online = online
        self.hostFacts = hostFacts
        self.vendor = vendor
        self.region = region
        self.notes = notes
        self.hasConsoleURL = hasConsoleURL
        self.hasDetailURL = hasDetailURL
        self.priceCents = priceCents
        self.currency = currency
        self.renewalCycleRaw = renewalCycleRaw
        self.cycleDays = cycleDays
        self.nextRenewal = nextRenewal
        self.serverDaysUntilRenewal = serverDaysUntilRenewal
        self.autoRoll = autoRoll
        self.remindDaysBefore = remindDaysBefore
        self.remindersEnabled = remindersEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.consoleURL = consoleURL
        self.detailURL = detailURL
    }

    public var renewalCycle: RenewalCycle? { RenewalCycle(rawValue: renewalCycleRaw) }

    public var displayLabel: String {
        if !label.isEmpty { return label }
        if !nodeName.isEmpty { return nodeName }
        if !vendor.isEmpty { return vendor }
        return nodeID
    }

    /// The name the console prints: the label, else the node's name, else its id.
    public var inventoryName: String {
        [label, nodeName, nodeID].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? nodeID
    }

    /// False for a node nobody has profiled yet.
    public var isProfiled: Bool { !id.isEmpty }

    public var priceMajorUnits: Double { Double(priceCents) / 100 }

    /// The monthly-equivalent cost of a recurring machine in major currency
    /// units (`inventoryCostModel.ts`); nil for every other billing category.
    public var monthlyCost: Double? {
        let cents = InventoryCost.monthlyEquivalentCents(self)
        return cents > 0 ? cents / 100 : nil
    }

    /// Whole UTC days from today to the renewal day, as the server and the
    /// console count them; negative once past.
    public func daysUntilRenewal(now: Date = Date()) -> Int? {
        guard let renewalDay else { return nil }
        return InventoryDay(date: now).days(until: renewalDay)
    }

    /// The renewal date as a UTC day; Go's zero time (year 1) is no date.
    public var renewalDay: InventoryDay? {
        guard let nextRenewal else { return nil }
        let day = InventoryDay(date: nextRenewal)
        return day.year > 1 ? day : nil
    }

    /// The currency as totals key it: trimmed, upper-cased, CHY folded into CNY.
    public var canonicalCurrency: String { InventoryCurrency.canonical(currency) }

    enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case nodeName = "node_name"
        case label
        case online
        case hostFacts = "host_facts"
        case vendor
        case vendorProfile = "vendor_profile"
        case region
        case notes
        case hasConsoleURL = "has_console_url"
        case hasDetailURL = "has_detail_url"
        case priceCents = "price_cents"
        case currency
        case purchasedAt = "purchased_at"
        case renewalCycleRaw = "renewal_cycle"
        case cycleDays = "cycle_days"
        case nextRenewal = "next_renewal"
        case serverDaysUntilRenewal = "days_until_renewal"
        case autoRoll = "auto_roll"
        case remindDaysBefore = "remind_days_before"
        case remindersEnabled = "reminders_enabled"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        nodeName = try container.decodeIfPresent(String.self, forKey: .nodeName) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        online = try container.decodeIfPresent(Bool.self, forKey: .online) ?? false
        hostFacts = try container.decodeIfPresent(LatticeHostFacts.self, forKey: .hostFacts) ?? LatticeHostFacts()
        vendor = try container.decodeIfPresent(String.self, forKey: .vendor) ?? ""
        vendorProfile = try container.decodeIfPresent(InventoryVendor.self, forKey: .vendorProfile)
        region = try container.decodeIfPresent(String.self, forKey: .region) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        hasConsoleURL = try container.decodeIfPresent(Bool.self, forKey: .hasConsoleURL) ?? false
        hasDetailURL = try container.decodeIfPresent(Bool.self, forKey: .hasDetailURL) ?? false
        priceCents = try container.decodeIfPresent(Int64.self, forKey: .priceCents) ?? 0
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? ""
        purchasedAt = try DateValue.decodeIfPresent(from: container, forKey: .purchasedAt)
        renewalCycleRaw = try container.decodeIfPresent(String.self, forKey: .renewalCycleRaw) ?? ""
        cycleDays = try container.decodeIfPresent(Int.self, forKey: .cycleDays) ?? 0
        nextRenewal = try DateValue.decodeIfPresent(from: container, forKey: .nextRenewal)
        serverDaysUntilRenewal = try container.decodeIfPresent(Int.self, forKey: .serverDaysUntilRenewal) ?? 0
        autoRoll = try container.decodeIfPresent(Bool.self, forKey: .autoRoll) ?? false
        remindDaysBefore = try container.decodeIfPresent([Int].self, forKey: .remindDaysBefore) ?? []
        remindersEnabled = try container.decodeIfPresent(Bool.self, forKey: .remindersEnabled) ?? false
        createdAt = try DateValue.decodeIfPresent(from: container, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: container, forKey: .updatedAt)
        consoleURL = ""
        detailURL = ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(nodeID, forKey: .nodeID)
        try container.encode(label, forKey: .label)
        try container.encode(vendor, forKey: .vendor)
        try container.encode(region, forKey: .region)
        try container.encode(notes, forKey: .notes)
        try container.encode(priceCents, forKey: .priceCents)
        try container.encode(currency, forKey: .currency)
        try container.encode(renewalCycleRaw, forKey: .renewalCycleRaw)
        try container.encode(cycleDays, forKey: .cycleDays)
        try container.encode(autoRoll, forKey: .autoRoll)
        try container.encode(remindDaysBefore, forKey: .remindDaysBefore)
        try container.encode(remindersEnabled, forKey: .remindersEnabled)
    }
}

/// One vendor record (`model.MachineVendor`). Vendors the operator never
/// saved but a profile names arrive with an id of `derived:<name>`.
public struct InventoryVendor: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var url: String
    public var logoURL: String
    public var description: String
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(id: String, name: String, url: String = "", logoURL: String = "", description: String = "") {
        self.id = id
        self.name = name
        self.url = url
        self.logoURL = logoURL
        self.description = description
    }

    /// A vendor the server derived from a profile's vendor name, not one saved on its own.
    public var isDerived: Bool { id.hasPrefix("derived:") }

    enum CodingKeys: String, CodingKey {
        case id, name, url, description
        case logoURL = "logo_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        logoURL = try c.decodeIfPresent(String.self, forKey: .logoURL) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        createdAt = try DateValue.decodeIfPresent(from: c, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: c, forKey: .updatedAt)
    }
}

/// `POST /api/machines/reveal-link`: the stored link, once, after step-up.
public struct InventoryLinkReveal: Decodable, Equatable, Sendable {
    public var ok: Bool
    public var id: String
    public var kind: String
    public var url: String

    enum CodingKeys: String, CodingKey { case ok, id, kind, url }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
    }
}

/// Which stored link a reveal asks for.
public enum InventoryLinkKind: String, Sendable, Hashable, CaseIterable {
    case console, detail

    public var title: String {
        switch self {
        case .console: "console link"
        case .detail: "detail link"
        }
    }
}

public struct RenewalReminderFire: Identifiable, Decodable, Equatable, Hashable, Sendable {
    public var machineID: String
    public var nodeID: String
    public var nodeName: String
    public var offsetDays: Int
    public var nextRenewal: String

    public var id: String { "\(machineID).\(offsetDays)" }

    /// The renewal day the reminder is about; the server writes YYYY-MM-DD.
    public var renewalDay: InventoryDay? { InventoryDay(String(nextRenewal.prefix(10))) }

    enum CodingKeys: String, CodingKey {
        case machineID = "machine_id"
        case nodeID = "node_id"
        case nodeName = "node_name"
        case offsetDays = "offset_days"
        case nextRenewal = "next_renewal"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        machineID = try container.decodeIfPresent(String.self, forKey: .machineID) ?? ""
        nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        nodeName = try container.decodeIfPresent(String.self, forKey: .nodeName) ?? ""
        offsetDays = try container.decodeIfPresent(Int.self, forKey: .offsetDays) ?? 0
        nextRenewal = try container.decodeIfPresent(String.self, forKey: .nextRenewal) ?? ""
    }
}

public struct InventorySummary: Equatable, Sendable {
    public var machineCount: Int
    public var monthlyCostByCurrency: [String: Double]
    public var dueSoon: [MachineProfile]
    public var overdue: [MachineProfile]

    public init(machines: [MachineProfile], window: Int = 14, now: Date = Date()) {
        machineCount = machines.count

        var costs: [String: Double] = [:]
        for spend in InventoryCost.aggregate(machines) {
            costs[spend.currency] = spend.monthlyCents / 100
        }
        monthlyCostByCurrency = costs

        let today = InventoryDay(date: now)
        var due: [MachineProfile] = []
        var over: [MachineProfile] = []
        for machine in machines {
            guard let day = machine.renewalDay else { continue }
            let days = today.days(until: day)
            if days < 0 {
                over.append(machine)
            } else if days <= window {
                due.append(machine)
            }
        }
        dueSoon = due.sorted { ($0.nextRenewal ?? .distantFuture) < ($1.nextRenewal ?? .distantFuture) }
        overdue = over.sorted { ($0.nextRenewal ?? .distantPast) < ($1.nextRenewal ?? .distantPast) }
    }

    public var primaryMonthlyCost: (currency: String, amount: Double)? {
        guard let entry = monthlyCostByCurrency.max(by: { $0.value < $1.value }) else { return nil }
        return (entry.key, entry.value)
    }
}

// MARK: Days

/// A calendar day read in UTC, the way the server and the console count
/// renewal days. Month arithmetic overflows as Go's `time.AddDate` does
/// (31 January plus one month is 3 March), which is how the server rolls a
/// renewal forward.
public struct InventoryDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private init(components: DateComponents) {
        year = components.year ?? 1
        month = components.month ?? 1
        day = components.day ?? 1
    }

    /// The UTC day an instant falls on.
    public init(date: Date) {
        self.init(components: Self.calendar.dateComponents([.year, .month, .day], from: date))
    }

    /// A real day written YYYY-MM-DD; nil for anything else, 2026-02-30 included.
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        let built = Self.normalized(year: year, month: month, day: day)
        guard built.year == year, built.month == month, built.day == day else { return nil }
        self = built
    }

    /// A day from parts that may overflow (month 14, day 31 of February).
    public static func normalized(year: Int, month: Int, day: Int) -> InventoryDay {
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: 0)
        return InventoryDay(date: date)
    }

    /// UTC midnight of this day, the instant the server stores for a renewal.
    public var date: Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: 0)
    }

    public func adding(days: Int) -> InventoryDay {
        Self.normalized(year: year, month: month, day: day + days)
    }

    public func adding(months: Int) -> InventoryDay {
        Self.normalized(year: year, month: month + months, day: day)
    }

    /// Whole days from this day to `other`; negative when `other` is earlier.
    public func days(until other: InventoryDay) -> Int {
        Int((other.date.timeIntervalSince(date) / 86_400).rounded())
    }

    /// The same calendar day in another time zone, at noon, for date pickers
    /// and formatters that read the device's zone.
    public func localDate(in timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? date
    }

    /// The calendar day a date picker shows, read in the device's zone.
    public static func picked(_ date: Date, in timeZone: TimeZone = .current) -> InventoryDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return normalized(year: parts.year ?? 1, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// "3 Nov 2026" in the locale's order; a day has no time zone to show.
    public func formatted(locale: Locale = .current, withYear: Bool = true) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, timeZone: TimeZone(identifier: "UTC")!)
            .day().month(.abbreviated)
        if withYear { style = style.year() }
        return date.formatted(style)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: InventoryDay, rhs: InventoryDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

// MARK: Currency and cost

/// One code per currency (`lib/currency.ts`): the yuan entered as CHY totals as CNY.
public enum InventoryCurrency {
    static let aliases = ["CHY": "CNY"]

    public static func canonical(_ value: String) -> String {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return aliases[code] ?? code
    }

    /// "USD 12.00" in the locale's number format; cents may carry a fraction
    /// (a monthly equivalent) and are rounded to whole cents first.
    public static func format(cents: Double, currency: String, locale: Locale = .current) -> String {
        let code = canonical(currency).isEmpty ? "USD" : canonical(currency)
        let amount = (cents.rounded() / 100)
        return amount.formatted(.currency(code: code).locale(locale).presentation(.isoCode))
    }
}

/// Which billing category a machine is in (`inventoryCostModel.ts`).
public enum InventoryBilling: String, Sendable, Hashable, CaseIterable {
    case renewalIncomplete, recurring, unpriced, onetime, free, unprofiled

    public var title: String {
        switch self {
        case .renewalIncomplete: "Renewal setup needed"
        case .recurring: "Recurring"
        case .onetime: "One-time"
        case .free: "Free"
        case .unpriced: "Needs pricing"
        case .unprofiled: "Needs profile"
        }
    }
}

/// Recurring spend in one canonical currency.
public struct InventorySpend: Hashable, Sendable {
    public var currency: String
    public var monthlyCents: Double
    public var annualCents: Double
    public var count: Int
}

/// What Inventory counts as spend (`inventoryCostModel.ts`).
public enum InventoryCost {
    /// 365.25 / 12, to turn a custom day count into a monthly figure.
    public static let daysPerMonth = 30.4375

    public static func hasRenewalIntent(_ machine: MachineProfile) -> Bool {
        !machine.renewalCycleRaw.isEmpty || machine.renewalDay != nil || machine.autoRoll
            || machine.remindersEnabled || !machine.remindDaysBefore.isEmpty
    }

    public static func renewalSetupIncomplete(_ machine: MachineProfile) -> Bool {
        hasRenewalIntent(machine) && (machine.renewalCycleRaw.isEmpty || machine.renewalDay == nil)
    }

    public static func billing(_ machine: MachineProfile) -> InventoryBilling {
        if !machine.isProfiled { return .unprofiled }
        if renewalSetupIncomplete(machine) { return .renewalIncomplete }
        if machine.priceCents > 0 { return machine.renewalCycleRaw.isEmpty ? .onetime : .recurring }
        // Billed (a cycle or a tracked date) but no price entered needs pricing;
        // no billing signal at all is genuinely free.
        return hasRenewalIntent(machine) ? .unpriced : .free
    }

    /// Monthly-equivalent cost in cents for a recurring machine; 0 otherwise.
    public static func monthlyEquivalentCents(_ machine: MachineProfile) -> Double {
        guard billing(machine) == .recurring else { return 0 }
        let price = Double(machine.priceCents)
        if machine.renewalCycleRaw == RenewalCycle.customDays.rawValue {
            // An unknown custom span reads as monthly rather than dropping out.
            return machine.cycleDays <= 0 ? price : price * daysPerMonth / Double(machine.cycleDays)
        }
        return price / Double(machine.renewalCycle?.months ?? 1)
    }

    /// Recurring spend per canonical currency, largest monthly total first.
    public static func aggregate(_ machines: [MachineProfile]) -> [InventorySpend] {
        var order: [String] = []
        var totals: [String: InventorySpend] = [:]
        for machine in machines where billing(machine) == .recurring {
            let currency = machine.canonicalCurrency.isEmpty ? "USD" : machine.canonicalCurrency
            let monthly = monthlyEquivalentCents(machine)
            if totals[currency] == nil {
                order.append(currency)
                totals[currency] = InventorySpend(currency: currency, monthlyCents: 0, annualCents: 0, count: 0)
            }
            totals[currency]!.monthlyCents += monthly
            totals[currency]!.annualCents += monthly * 12
            totals[currency]!.count += 1
        }
        let listed = order.compactMap { totals[$0] }
        // A stable sort, so equal totals keep the order they first appeared in.
        return listed.enumerated().sorted { a, b in
            a.element.monthlyCents != b.element.monthlyCents ? a.element.monthlyCents > b.element.monthlyCents : a.offset < b.offset
        }.map(\.element)
    }

    /// "USD 12.00 a month" lines, one per currency.
    public static func spendLine(_ spend: [InventorySpend], locale: Locale = .current) -> String {
        spend.map { InventoryCurrency.format(cents: $0.monthlyCents, currency: $0.currency, locale: locale) }.joined(separator: " · ")
    }

    /// The price as the list prints it: "USD 24.00 monthly", "One-time", "Free".
    public static func priceLine(_ machine: MachineProfile, locale: Locale = .current) -> String {
        switch billing(machine) {
        case .free: return "Free"
        case .unprofiled: return "No profile"
        default: break
        }
        guard machine.priceCents > 0 else { return "Not priced" }
        let price = InventoryCurrency.format(cents: Double(machine.priceCents), currency: machine.currency, locale: locale)
        return "\(price) \(cycleWord(machine))"
    }

    /// "monthly", "every 60 days", "one-time".
    public static func cycleWord(_ machine: MachineProfile) -> String {
        guard let cycle = machine.renewalCycle else { return machine.renewalCycleRaw.isEmpty ? "one-time" : machine.renewalCycleRaw }
        switch cycle {
        case .customDays: return machine.cycleDays == 1 ? "every day" : "every \(max(machine.cycleDays, 0)) days"
        default: return cycle.displayName.lowercased()
        }
    }
}

// MARK: Renewal state

/// Where a machine stands against its renewal date, for its row and its
/// detail screen. Days are UTC days, as the server counts them.
public enum InventoryRenewalState: Hashable, Sendable {
    case unprofiled
    /// A renewal is intended but the cycle or the date is missing.
    case setupIncomplete
    /// No renewal: one-time, free, or nothing tracked.
    case notTracked
    /// Past its date and renewed by hand; `days` is how long ago, at least 1.
    case overdue(days: Int)
    /// Due within the warning window (0 to 6 days).
    case dueSoon(days: Int)
    case upcoming(days: Int)
    /// Renews by itself; a passed date reads as the date it rolls to.
    case autoRenews(days: Int, on: InventoryDay)

    /// Days under which a renewal warns.
    public static let warnDays = 7

    public static func of(_ machine: MachineProfile, today: InventoryDay) -> InventoryRenewalState {
        if !machine.isProfiled { return .unprofiled }
        if InventoryCost.renewalSetupIncomplete(machine) { return .setupIncomplete }
        guard let renewal = machine.renewalDay else { return .notTracked }
        let days = today.days(until: renewal)
        if machine.autoRoll {
            if days < 0, let rolled = ReminderSchedule.rollForwardPast(renewal, cycle: machine.renewalCycleRaw, cycleDays: machine.cycleDays, today: today) {
                return .autoRenews(days: today.days(until: rolled), on: rolled)
            }
            return .autoRenews(days: max(days, 0), on: renewal)
        }
        if days < 0 { return .overdue(days: -days) }
        if days < warnDays { return .dueSoon(days: days) }
        return .upcoming(days: days)
    }

    /// The countdown in words: "renews in 6 days", "2 days overdue".
    public var word: String {
        switch self {
        case .unprofiled: "no profile"
        case .setupIncomplete: "renewal setup needed"
        case .notTracked: "no renewal"
        case .overdue(let days): days == 1 ? "1 day overdue" : "\(days) days overdue"
        case .dueSoon(0): "renews today"
        case .dueSoon(let days), .upcoming(let days): days == 1 ? "renews in 1 day" : "renews in \(days) days"
        case .autoRenews(0, _): "auto-renews today"
        case .autoRenews(let days, _): days == 1 ? "auto-renews in 1 day" : "auto-renews in \(days) days"
        }
    }

    /// Days until the renewal the state is about; nil without a date.
    public var days: Int? {
        switch self {
        case .overdue(let days): -days
        case .dueSoon(let days), .upcoming(let days), .autoRenews(let days, _): days
        case .unprofiled, .setupIncomplete, .notTracked: nil
        }
    }
}

// MARK: Grouping

/// How the Machines list groups (section 5.6): Region, Country, Role, Group,
/// Status (where each machine stands against its renewal), Tag, or None.
public enum InventoryGroupBy: String, Sendable, Hashable, CaseIterable {
    case region, country, role, group, status, tag, none

    public var title: String {
        switch self {
        case .region: "Region"
        case .country: "Country"
        case .role: "Role"
        case .group: "Group"
        case .status: "Status"
        case .tag: "Tag"
        case .none: "None"
        }
    }
}

/// One section of the Machines list.
public struct InventorySection: Identifiable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var machines: [MachineProfile]
    public var spend: [InventorySpend]
}

/// The node facts the grouping and the query read beside a machine.
public struct InventoryNodeFacts: Sendable, Hashable {
    public var country: String
    public var role: String
    public var tags: [String]
    public var groupIDs: [String]
    public var status: String

    public init(country: String = "", role: String = "", tags: [String] = [], groupIDs: [String] = [], status: String = "") {
        self.country = country
        self.role = role
        self.tags = tags
        self.groupIDs = groupIDs
        self.status = status
    }

    public init(node: LatticeNode) {
        self.init(country: node.geo?.country ?? "", role: node.role ?? "", tags: node.tags, groupIDs: node.groupIDs, status: node.status)
    }
}

public enum InventoryGrouping {
    /// Renewal buckets for the Status grouping, in reading order.
    static let statusOrder: [(id: String, title: String)] = [
        ("incomplete", "Renewal setup needed"),
        ("overdue", "Overdue"),
        ("dueSoon", "Due within 14 days"),
        ("later", "Later"),
        ("notTracked", "Not tracked"),
        ("unprofiled", "No profile"),
    ]

    static func statusBucket(_ machine: MachineProfile, today: InventoryDay) -> String {
        switch InventoryRenewalState.of(machine, today: today) {
        case .unprofiled: "unprofiled"
        case .setupIncomplete: "incomplete"
        case .notTracked: "notTracked"
        case .overdue: "overdue"
        case .dueSoon(let days), .upcoming(let days), .autoRenews(let days, _): days <= 14 ? "dueSoon" : "later"
        }
    }

    /// A country code as its name in the locale ("JP" reads "Japan").
    public static func countryName(_ code: String, locale: Locale = .current) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 2 else { return trimmed }
        return locale.localizedString(forRegionCode: trimmed.uppercased()) ?? trimmed.uppercased()
    }

    /// Profiles before unprofiled nodes; by due day under Status, by name otherwise.
    public static func ordered(_ machines: [MachineProfile], byDue: Bool, today: InventoryDay) -> [MachineProfile] {
        machines.sorted { a, b in
            if a.isProfiled != b.isProfiled { return a.isProfiled }
            if byDue {
                let da = InventoryRenewalState.of(a, today: today).days
                let db = InventoryRenewalState.of(b, today: today).days
                if da != db {
                    guard let da else { return false }
                    guard let db else { return true }
                    return da < db
                }
            }
            return a.inventoryName.localizedStandardCompare(b.inventoryName) == .orderedAscending
        }
    }

    public static func sections(
        _ machines: [MachineProfile],
        by group: InventoryGroupBy,
        today: InventoryDay,
        facts: (String) -> InventoryNodeFacts?,
        groupName: (String) -> String?,
        locale: Locale = .current
    ) -> [InventorySection] {
        guard !machines.isEmpty else { return [] }
        func build(_ id: String, _ title: String, _ items: [MachineProfile]) -> InventorySection {
            InventorySection(id: id, title: title, machines: ordered(items, byDue: group == .status, today: today), spend: InventoryCost.aggregate(items))
        }
        switch group {
        case .none:
            return [build("all", "All machines", machines)]
        case .status:
            return statusOrder.compactMap { bucket in
                let items = machines.filter { statusBucket($0, today: today) == bucket.id }
                return items.isEmpty ? nil : build(bucket.id, bucket.title, items)
            }
        case .region, .country, .role, .group, .tag:
            let unknown: String = switch group {
            case .region: "No region"
            case .country: "No country"
            case .role: "No role"
            case .group: "No group"
            default: "No tags"
            }
            var keys: [String] = []
            var buckets: [String: [MachineProfile]] = [:]
            for machine in machines {
                let node = facts(machine.nodeID)
                let values: [String] = switch group {
                case .region: [machine.region]
                case .country: [countryName(node?.country ?? "", locale: locale)]
                case .role: [node?.role ?? ""]
                case .group: (node?.groupIDs ?? []).map { groupName($0) ?? $0 }
                default: node?.tags ?? []
                }
                let cleaned = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                for key in Set(cleaned.isEmpty ? [""] : cleaned).sorted() {
                    if buckets[key] == nil { keys.append(key) }
                    buckets[key, default: []].append(machine)
                }
            }
            // Biggest groups first, then by name; the unknown group last.
            let sorted = keys.sorted { a, b in
                if a.isEmpty != b.isEmpty { return b.isEmpty }
                let ca = buckets[a]?.count ?? 0, cb = buckets[b]?.count ?? 0
                return ca != cb ? ca > cb : a.localizedStandardCompare(b) == .orderedAscending
            }
            return sorted.map { key in build(key.isEmpty ? "__unknown__" : key, key.isEmpty ? unknown : key, buckets[key] ?? []) }
        }
    }
}

// MARK: Query

/// Machines' query fields (`inventoryQuery.ts`): what the operator recorded
/// about each machine, then a few node fields reached through its node. A
/// page field wins a name it shares with a node field: `region:` is the
/// vendor's region.
public enum InventoryQuery {
    public struct Row: Sendable {
        public var machine: MachineProfile
        public var facts: InventoryNodeFacts?
        public var groupNames: [String]
        public var today: InventoryDay

        public init(machine: MachineProfile, facts: InventoryNodeFacts?, groupNames: [String] = [], today: InventoryDay) {
            self.machine = machine
            self.facts = facts
            self.groupNames = groupNames
            self.today = today
        }
    }

    static func optional(_ value: String) -> LatticeQueryFieldValue {
        value.isEmpty ? .none : .string(value)
    }

    public static var fields: [LatticeQueryField<Row>] {
        [
            LatticeQueryField(key: "name", type: .string, get: { .string($0.machine.inventoryName) }),
            LatticeQueryField(key: "label", type: .string, get: { optional($0.machine.label) }),
            LatticeQueryField(key: "vendor", aliases: ["provider"], type: .string, get: { optional($0.machine.vendor) }),
            LatticeQueryField(key: "region", type: .string, get: { optional($0.machine.region) }),
            LatticeQueryField(
                key: "billing", aliases: ["cost"], type: .enumeration,
                values: InventoryBilling.allCases.map(\.rawValue),
                valueAliases: ["incomplete": "renewalIncomplete", "one-time": "onetime", "none": "unprofiled"],
                get: { .string(InventoryCost.billing($0.machine).rawValue) }
            ),
            // The server omits a zero price, so the console reads a free profile as no price.
            LatticeQueryField(key: "price", type: .number, get: { $0.machine.isProfiled && $0.machine.priceCents != 0 ? .number(Double($0.machine.priceCents) / 100) : .none }),
            LatticeQueryField(key: "currency", type: .string, get: { optional($0.machine.canonicalCurrency) }),
            LatticeQueryField(key: "cycle", type: .string, get: { optional($0.machine.renewalCycleRaw) }),
            LatticeQueryField(key: "renews_in", aliases: ["renewal"], type: .duration, get: { row in
                guard let day = row.machine.renewalDay else { return .none }
                return .number(Double(row.today.days(until: day)) * 86_400)
            }),
            LatticeQueryField(key: "purchased", type: .time, get: { $0.machine.purchasedAt.map { .time($0) } ?? .none }),
            LatticeQueryField(key: "autoroll", aliases: ["auto_roll"], type: .bool, flag: true, sortable: false,
                              get: { $0.machine.isProfiled ? .bool($0.machine.autoRoll) : .none }),
            LatticeQueryField(key: "reminders", type: .bool, flag: true, sortable: false,
                              get: { $0.machine.isProfiled ? .bool($0.machine.remindersEnabled) : .none }),
            LatticeQueryField(key: "profiled", type: .bool, flag: true, sortable: false, get: { .bool($0.machine.isProfiled) }),
            LatticeQueryField(key: "node", type: .list, get: { row in
                .strings([row.machine.nodeName, row.machine.nodeID].filter { !$0.isEmpty })
            }),
            LatticeQueryField(key: "status", type: .string, get: { optional($0.facts?.status ?? "") }),
            LatticeQueryField(key: "role", type: .string, get: { optional($0.facts?.role ?? "") }),
            LatticeQueryField(key: "tag", aliases: ["tags"], type: .list, get: { .strings($0.facts?.tags ?? []) }),
            LatticeQueryField(key: "group", aliases: ["groups"], type: .list, get: { .strings($0.groupNames) }),
            LatticeQueryField(key: "country", type: .string, get: { optional($0.facts?.country ?? "") }),
        ]
    }

    public static func text(_ row: Row) -> [String] {
        [row.machine.inventoryName, row.machine.nodeName, row.machine.nodeID, row.machine.vendor, row.machine.region,
         row.machine.hostFacts.hostname ?? ""].filter { !$0.isEmpty }
    }

    public static func compile(_ source: String) -> Result<LatticeCompiledQuery<Row>, LatticeQueryError> {
        LatticeQueryEngine.compile(source, fields: fields, text: { text($0) })
    }

    /// One sentence for a query the engine refused, so a typo never reads as
    /// an empty inventory.
    public static func message(_ error: LatticeQueryError) -> String {
        let field = error.params["field"] ?? ""
        let hint = error.params["suggestion"].flatMap { $0.isEmpty ? nil : " Did you mean \($0)?" } ?? ""
        switch error.code {
        case .unknownField: return "Machines have no field \"\(field)\".\(hint)"
        case .unknownSort: return "Machines cannot sort by \"\(field)\".\(hint)"
        default: return "This query cannot be read at character \(error.start + 1)."
        }
    }
}

// MARK: Upcoming

/// The kinds `GET /api/expiring` lists, in the order the filter shows them.
public enum InventoryUpcomingKind: String, Sendable, Hashable, CaseIterable {
    case machineRenewal = "machine_renewal"
    case vpnUser = "vpn_user"
    case share
    case tlsCertificate = "tls_certificate"

    /// "Machine renewal"
    public var title: String {
        switch self {
        case .machineRenewal: "Machine renewal"
        case .vpnUser: "VPN user"
        case .share: "Share"
        case .tlsCertificate: "TLS certificate"
        }
    }

    /// The filter's option: "Machines"
    public var filterTitle: String {
        switch self {
        case .machineRenewal: "Machines"
        case .vpnUser: "VPN users"
        case .share: "Shares"
        case .tlsCertificate: "Certificates"
        }
    }

    /// The scope that reads this kind's own list, for the hidden-kinds footer.
    public var readScope: String {
        switch self {
        case .machineRenewal: "inventory:read"
        case .vpnUser: "proxy:read"
        case .share: "proxy:admin"
        case .tlsCertificate: "monitor:read"
        }
    }

    public static func title(for kind: String) -> String {
        InventoryUpcomingKind(rawValue: kind)?.title ?? kind.replacingOccurrences(of: "_", with: " ")
    }
}

/// One week's rows on the Upcoming list.
public struct InventoryUpcomingGroup: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case overdue, thisWeek, nextWeek, dated }
    public var id: String
    public var kind: Kind
    public var weekStart: InventoryDay?
    public var items: [ExpiringItem]
    public var totals: [ExpiringTotal]

    public func title(locale: Locale = .current) -> String {
        switch kind {
        case .overdue: "Overdue"
        case .thisWeek: "This week"
        case .nextWeek: "Next week"
        case .dated: "Week of \(weekStart?.formatted(locale: locale, withYear: false) ?? "")"
        }
    }
}

/// What the Upcoming list does with `/api/expiring` (`upcomingModel.ts`).
public enum InventoryUpcoming {
    /// The window Machines and Upcoming read (section 5.6).
    public static let withinDays = 30

    /// Past due and renewed by hand. An auto-roll row is charged on its date, so it never counts.
    public static func isOverdue(_ item: ExpiringItem) -> Bool {
        item.state == "overdue" || (item.days < 0 && item.state != "auto")
    }

    /// The server's today: the UTC day of `generated_at`, else the device's.
    public static func today(_ response: ExpiringResponse?, now: Date) -> InventoryDay {
        InventoryDay(date: response?.generatedAt ?? now)
    }

    public static func filter(_ items: [ExpiringItem], kind: InventoryUpcomingKind?) -> [ExpiringItem] {
        guard let kind else { return items }
        return items.filter { $0.kind == kind.rawValue }
    }

    /// Cost per canonical currency; a row without a price counts in none.
    public static func sumTotals(_ items: [ExpiringItem]) -> [ExpiringTotal] {
        var totals: [String: (cents: Int, count: Int)] = [:]
        for item in items {
            let currency = InventoryCurrency.canonical(item.currency)
            guard !currency.isEmpty, item.costCents > 0 else { continue }
            totals[currency, default: (0, 0)].cents += item.costCents
            totals[currency, default: (0, 0)].count += 1
        }
        return totals.keys.sorted().map { code in
            ExpiringTotal(currency: code, costCents: totals[code]!.cents, count: totals[code]!.count)
        }
    }

    /// Overdue first, then this week, next week, and one group per later
    /// week named by its Monday. Weeks are UTC days counted from the server's today.
    public static func groupByWeek(_ items: [ExpiringItem], today: InventoryDay) -> [InventoryUpcomingGroup] {
        let weekday = InventoryDay.calendar.component(.weekday, from: today.date)
        let monday = today.adding(days: -((weekday + 5) % 7))
        let sorted = items.enumerated().sorted { a, b in
            if a.element.days != b.element.days { return a.element.days < b.element.days }
            let order = a.element.title.localizedStandardCompare(b.element.title)
            return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
        }.map(\.element)
        var overdue: [ExpiringItem] = []
        var weeks: [Int: [ExpiringItem]] = [:]
        for item in sorted {
            if isOverdue(item) {
                overdue.append(item)
                continue
            }
            let due = item.dueAt.map { InventoryDay(date: $0) } ?? today.adding(days: item.days)
            let index = max(0, Int((Double(monday.days(until: due)) / 7).rounded(.down)))
            weeks[index, default: []].append(item)
        }
        var groups: [InventoryUpcomingGroup] = []
        if !overdue.isEmpty {
            groups.append(InventoryUpcomingGroup(id: "overdue", kind: .overdue, weekStart: nil, items: overdue, totals: sumTotals(overdue)))
        }
        for index in weeks.keys.sorted() {
            let rows = weeks[index] ?? []
            let start = monday.adding(days: index * 7)
            let kind: InventoryUpcomingGroup.Kind = index == 0 ? .thisWeek : (index == 1 ? .nextWeek : .dated)
            groups.append(InventoryUpcomingGroup(id: "week:\(start)", kind: kind, weekStart: start, items: rows, totals: sumTotals(rows)))
        }
        return groups
    }

    /// The due date in words: "due in 3 days", "2 days overdue", "auto-renews in 12 days".
    public static func dueWords(_ item: ExpiringItem) -> String {
        if item.state == "auto" {
            if item.days <= 0 { return "auto-renews today" }
            return item.days == 1 ? "auto-renews in 1 day" : "auto-renews in \(item.days) days"
        }
        if item.days < 0 { return item.days == -1 ? "1 day overdue" : "\(-item.days) days overdue" }
        if item.days == 0 { return "due today" }
        return item.days == 1 ? "due in 1 day" : "due in \(item.days) days"
    }

    /// The kinds this session cannot read, in filter order, then any kind
    /// the app does not know yet.
    public static func hiddenKinds(_ response: ExpiringResponse?) -> [String] {
        let raw = (response?.hiddenKinds ?? []).filter { !$0.isEmpty }
        let known = InventoryUpcomingKind.allCases.map(\.rawValue).filter { raw.contains($0) }
        var unknown: [String] = []
        for kind in raw where InventoryUpcomingKind(rawValue: kind) == nil && !unknown.contains(kind) {
            unknown.append(kind)
        }
        return known + unknown
    }

    /// "4 due in 30 days, 1 overdue"
    public static func headerCounts(_ items: [ExpiringItem]) -> (due: Int, overdue: Int) {
        let overdue = items.filter(isOverdue).count
        return (items.count - overdue, overdue)
    }
}

// MARK: Lookup

/// Finds a machine for a route id. The console opens a machine from
/// `?machine=<profile id>` and from `?node=<node id>`, so a node id finds
/// the node's row too, profiled or not.
public enum InventoryLookup {
    public static func machine(_ id: String, in machines: [MachineProfile]) -> MachineProfile? {
        guard !id.isEmpty else { return nil }
        return machines.first { $0.id == id } ?? machines.first { $0.nodeID == id }
    }
}

// MARK: Delete

/// What deleting a machine profile removes, read fresh from the server right
/// before the delete (the server has no dry run). The fingerprint stops the
/// delete when the profile changed after the operator reviewed it.
public enum InventoryDeleteReport {
    static let group = "Removed from the profile"

    public static func report(_ machine: MachineProfile, locale: Locale = .current) -> DryRunReport {
        var lines = [DetailLine(label: "Price", value: InventoryCost.priceLine(machine, locale: locale), group: group)]
        if let day = machine.renewalDay {
            lines.append(DetailLine(label: "Renewal", value: "Due \(day.formatted(locale: locale))", group: group))
        }
        if machine.remindersEnabled {
            let offsets = ReminderSchedule.offsets(machine).map(String.init).joined(separator: ", ")
            lines.append(DetailLine(label: "Reminders", value: offsets.isEmpty ? "On" : "On, \(offsets) days before", group: group))
        }
        let links = [machine.hasConsoleURL ? "console" : nil, machine.hasDetailURL ? "detail" : nil].compactMap { $0 }
        if !links.isEmpty {
            lines.append(DetailLine(label: "Stored links", value: links.count == 2 ? "Console and detail links" : "\(links[0].capitalized) link", group: group))
        }
        if !machine.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(DetailLine(label: "Notes", value: "Kept nowhere else", group: group))
        }
        lines.append(DetailLine(label: "Node", value: "\(machine.nodeName.isEmpty ? machine.nodeID : machine.nodeName) stays enrolled", group: "Not affected"))
        let fingerprint = [machine.id, machine.updatedAt.map { String($0.timeIntervalSince1970) } ?? "", machine.renewalDay?.description ?? "",
                           String(machine.priceCents), machine.currency, String(machine.hasConsoleURL), String(machine.hasDetailURL)].joined(separator: "|")
        return DryRunReport(lines: lines, blocking: false, fingerprint: fingerprint)
    }

    /// The answer when the profile is already gone: nothing to delete.
    public static let gone = DryRunReport(lines: [DetailLine(label: "Profile", value: "Already deleted", group: group)], blocking: true, fingerprint: "gone")
}

// MARK: Upcoming query

/// The Upcoming search (section 5.0): `kind:`, `state:`, `due_in:`, `cost:`
/// and free text over the title, the subtitle and the kind.
public enum InventoryUpcomingQuery {
    public static var fields: [LatticeQueryField<ExpiringItem>] {
        [
            LatticeQueryField(
                key: "kind", aliases: ["type"], type: .enumeration,
                values: InventoryUpcomingKind.allCases.map(\.rawValue),
                valueAliases: ["machine": "machine_renewal", "machines": "machine_renewal", "renewal": "machine_renewal",
                               "vpn": "vpn_user", "user": "vpn_user", "cert": "tls_certificate", "certificate": "tls_certificate",
                               "tls": "tls_certificate", "shares": "share"],
                get: { .string($0.kind) }
            ),
            LatticeQueryField(key: "state", type: .enumeration, values: ["overdue", "due", "upcoming", "auto"],
                              get: { .string(InventoryUpcoming.isOverdue($0) ? "overdue" : $0.state) }),
            LatticeQueryField(key: "title", aliases: ["name"], type: .string, get: { .string($0.title) }),
            LatticeQueryField(key: "subtitle", type: .string, get: { $0.subtitle.isEmpty ? .none : .string($0.subtitle) }),
            LatticeQueryField(key: "due_in", aliases: ["days"], type: .duration, get: { .number(Double($0.days) * 86_400) }),
            LatticeQueryField(key: "cost", aliases: ["price"], type: .number, get: { $0.costCents > 0 ? .number(Double($0.costCents) / 100) : .none }),
            LatticeQueryField(key: "currency", type: .string, get: { $0.currency.isEmpty ? .none : .string($0.currency) }),
        ]
    }

    public static func text(_ item: ExpiringItem) -> [String] {
        [item.title, item.subtitle, InventoryUpcomingKind(rawValue: item.kind)?.title ?? item.kind].filter { !$0.isEmpty }
    }

    public static func compile(_ source: String) -> Result<LatticeCompiledQuery<ExpiringItem>, LatticeQueryError> {
        LatticeQueryEngine.compile(source, fields: fields, text: { text($0) })
    }

    public static func message(_ error: LatticeQueryError) -> String {
        let field = error.params["field"] ?? ""
        let hint = error.params["suggestion"].flatMap { $0.isEmpty ? nil : " Did you mean \($0)?" } ?? ""
        switch error.code {
        case .unknownField: return "Upcoming items have no field \"\(field)\".\(hint)"
        case .unknownSort: return "Upcoming items cannot sort by \"\(field)\".\(hint)"
        default: return "This query cannot be read at character \(error.start + 1)."
        }
    }
}
