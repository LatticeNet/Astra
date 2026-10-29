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

    /// Approximate number of days in one cycle, for normalizing cost to monthly.
    public func approximateDays(customDays: Int) -> Int {
        switch self {
        case .monthly: 30
        case .quarterly: 91
        case .semiannual: 182
        case .annual: 365
        case .customDays: max(customDays, 1)
        }
    }
}

/// Operator-authored inventory, cost and renewal metadata bound to a node. This
/// is the secret-free `machineView` returned by the server: console/detail URLs
/// are never sent back, only `hasConsoleURL`/`hasDetailURL` booleans. The
/// write-only `consoleURL`/`detailURL` fields hold values the edit form is about
/// to submit and are always empty when decoded from the server.
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

    public var priceMajorUnits: Double { Double(priceCents) / 100 }

    /// Cost normalized to a 30-day month, in major currency units.
    public var monthlyCost: Double? {
        guard priceCents > 0, let cycle = renewalCycle else { return nil }
        let days = cycle.approximateDays(customDays: cycleDays)
        return priceMajorUnits * 30 / Double(days)
    }

    public func daysUntilRenewal(now: Date = Date()) -> Int? {
        guard let nextRenewal else { return nil }
        let seconds = nextRenewal.timeIntervalSince(now)
        return Int((seconds / 86_400).rounded(.towardZero))
    }

    enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case nodeName = "node_name"
        case label
        case online
        case hostFacts = "host_facts"
        case vendor
        case region
        case notes
        case hasConsoleURL = "has_console_url"
        case hasDetailURL = "has_detail_url"
        case priceCents = "price_cents"
        case currency
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
        region = try container.decodeIfPresent(String.self, forKey: .region) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        hasConsoleURL = try container.decodeIfPresent(Bool.self, forKey: .hasConsoleURL) ?? false
        hasDetailURL = try container.decodeIfPresent(Bool.self, forKey: .hasDetailURL) ?? false
        priceCents = try container.decodeIfPresent(Int64.self, forKey: .priceCents) ?? 0
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? ""
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

public struct RenewalReminderFire: Identifiable, Decodable, Equatable, Hashable, Sendable {
    public var machineID: String
    public var nodeID: String
    public var nodeName: String
    public var offsetDays: Int
    public var nextRenewal: String

    public var id: String { "\(machineID).\(offsetDays)" }

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
        for machine in machines {
            guard let monthly = machine.monthlyCost else { continue }
            let currency = machine.currency.isEmpty ? "USD" : machine.currency.uppercased()
            costs[currency, default: 0] += monthly
        }
        monthlyCostByCurrency = costs

        var due: [MachineProfile] = []
        var over: [MachineProfile] = []
        for machine in machines {
            guard let days = machine.daysUntilRenewal(now: now) else { continue }
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
