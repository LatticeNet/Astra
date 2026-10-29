import Foundation

private struct FiredEnvelope: Decodable { var fired: [RenewalReminderFire] }

/// `POST /api/machines/reminders/run`: `{}` runs every machine, `{id}` one.
struct InventoryRemindersRequest: Encodable {
    var id: String?
}

/// `POST /api/machines/reveal-link`.
struct InventoryRevealLinkRequest: Encodable {
    var id: String
    var kind: String
    var stepUpGrant: String

    enum CodingKeys: String, CodingKey {
        case id, kind
        case stepUpGrant = "step_up_grant"
    }
}

struct MachineDeleteRequest: Encodable {
    var id: String
}

struct MachineRenewRequest: Encodable {
    var id: String
    var nextRenewal: Date
    enum CodingKeys: String, CodingKey {
        case id
        case nextRenewal = "next_renewal"
    }
}

/// Mirrors the server `machineProfileRequest`. Only the fields the edit form
/// owns are sent; the server forces `id = ""` on create.
public struct MachineProfileRequest: Encodable, Sendable {
    public var id: String
    public var nodeID: String
    public var label: String
    public var vendor: String
    public var consoleURL: String
    public var detailURL: String
    public var clearConsoleURL: Bool
    public var clearDetailURL: Bool
    public var region: String
    public var notes: String
    public var priceCents: Int64
    public var currency: String
    public var renewalCycle: String
    public var cycleDays: Int
    public var nextRenewal: Date?
    public var autoRoll: Bool
    public var remindDaysBefore: [Int]
    public var remindersEnabled: Bool

    public init(
        id: String = "",
        nodeID: String = "",
        label: String = "",
        vendor: String = "",
        consoleURL: String = "",
        detailURL: String = "",
        clearConsoleURL: Bool = false,
        clearDetailURL: Bool = false,
        region: String = "",
        notes: String = "",
        priceCents: Int64 = 0,
        currency: String = "",
        renewalCycle: String = "",
        cycleDays: Int = 0,
        nextRenewal: Date? = nil,
        autoRoll: Bool = false,
        remindDaysBefore: [Int] = [],
        remindersEnabled: Bool = false
    ) {
        self.id = id
        self.nodeID = nodeID
        self.label = label
        self.vendor = vendor
        self.consoleURL = consoleURL
        self.detailURL = detailURL
        self.clearConsoleURL = clearConsoleURL
        self.clearDetailURL = clearDetailURL
        self.region = region
        self.notes = notes
        self.priceCents = priceCents
        self.currency = currency
        self.renewalCycle = renewalCycle
        self.cycleDays = cycleDays
        self.nextRenewal = nextRenewal
        self.autoRoll = autoRoll
        self.remindDaysBefore = remindDaysBefore
        self.remindersEnabled = remindersEnabled
    }

    enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case label, vendor
        case consoleURL = "console_url"
        case detailURL = "detail_url"
        case clearConsoleURL = "clear_console_url"
        case clearDetailURL = "clear_detail_url"
        case region, notes
        case priceCents = "price_cents"
        case currency
        case renewalCycle = "renewal_cycle"
        case cycleDays = "cycle_days"
        case nextRenewal = "next_renewal"
        case autoRoll = "auto_roll"
        case remindDaysBefore = "remind_days_before"
        case remindersEnabled = "reminders_enabled"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(nodeID, forKey: .nodeID)
        try container.encode(label, forKey: .label)
        try container.encode(vendor, forKey: .vendor)
        try container.encode(consoleURL, forKey: .consoleURL)
        try container.encode(detailURL, forKey: .detailURL)
        try container.encode(clearConsoleURL, forKey: .clearConsoleURL)
        try container.encode(clearDetailURL, forKey: .clearDetailURL)
        try container.encode(region, forKey: .region)
        try container.encode(notes, forKey: .notes)
        try container.encode(priceCents, forKey: .priceCents)
        try container.encode(currency, forKey: .currency)
        try container.encode(renewalCycle, forKey: .renewalCycle)
        try container.encode(cycleDays, forKey: .cycleDays)
        try container.encodeIfPresent(nextRenewal, forKey: .nextRenewal)
        try container.encode(autoRoll, forKey: .autoRoll)
        try container.encode(remindDaysBefore, forKey: .remindDaysBefore)
        try container.encode(remindersEnabled, forKey: .remindersEnabled)
    }
}

public extension LatticeClient {
    // Machine inventory

    /// `GET /api/machines`: every node the caller can read, profiled or not,
    /// as a bare array or a `{machines}` envelope.
    func listMachines() async throws -> [MachineProfile] {
        let data = try await performData(path: "/api/machines")
        return try LatticeListDecoder.decode(MachineProfile.self, from: data, key: "machines")
    }

    /// `GET /api/machine-vendors`, as a `{vendors}` envelope or a bare array.
    func inventoryVendors() async throws -> [InventoryVendor] {
        let data = try await performData(path: "/api/machine-vendors")
        return try LatticeListDecoder.decode(InventoryVendor.self, from: data, key: "vendors")
    }

    func createMachine(_ request: MachineProfileRequest) async throws -> MachineProfile {
        var req = request
        req.id = ""
        return try await perform(MachineProfile.self, path: "/api/machines", method: "POST", body: req)
    }

    func updateMachine(_ request: MachineProfileRequest) async throws -> MachineProfile {
        try await perform(MachineProfile.self, path: "/api/machines/update", method: "POST", body: request)
    }

    /// `POST /api/machines/delete {id}`: removes the profile; the node stays.
    func deleteMachine(id: String) async throws {
        try await performVoid(path: "/api/machines/delete", body: MachineDeleteRequest(id: id))
    }

    /// `POST /api/machines/renew {id, next_renewal}`; the server stores the UTC day.
    func renewMachine(id: String, nextRenewal: Date) async throws -> MachineProfile {
        try await perform(
            MachineProfile.self,
            path: "/api/machines/renew",
            method: "POST",
            body: MachineRenewRequest(id: id, nextRenewal: nextRenewal)
        )
    }

    @discardableResult
    func runRenewalReminders() async throws -> [RenewalReminderFire] {
        try await inventoryRunReminders()
    }

    /// `POST /api/machines/reminders/run`: sends what is due now, skipping any
    /// reminder already sent for the same date and offset, and answers what fired.
    @discardableResult
    func inventoryRunReminders(machineID: String? = nil) async throws -> [RenewalReminderFire] {
        try await perform(FiredEnvelope.self, path: "/api/machines/reminders/run", method: "POST", body: InventoryRemindersRequest(id: machineID)).fired
    }

    /// `POST /api/machines/reveal-link {id, kind, step_up_grant}` on the session client.
    func inventoryRevealLink(id: String, kind: InventoryLinkKind, grant: StepUpGrant) async throws -> InventoryLinkReveal {
        try await perform(
            InventoryLinkReveal.self,
            path: "/api/machines/reveal-link",
            method: "POST",
            body: InventoryRevealLinkRequest(id: id, kind: kind.rawValue, stepUpGrant: grant.grant)
        )
    }
}
