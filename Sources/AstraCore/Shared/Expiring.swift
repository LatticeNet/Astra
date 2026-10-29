import Foundation

/// One dated thing that runs out (`GET /api/expiring`).
public struct ExpiringItem: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// machine_renewal, vpn_user, share or tls_certificate.
    public var kind: String
    public var objectID: String
    public var title: String
    /// Data only, never words: `<vendor> · <region>`, a user name, a host:port.
    public var subtitle: String
    public var dueAt: Date?
    /// Whole UTC days from today to `dueAt`; negative once past.
    public var days: Int
    /// overdue, due, upcoming or auto.
    public var state: String
    public var costCents: Int
    public var currency: String
    /// A console route that opens the object.
    public var href: String
    public var usedBytes: UInt64?
    public var quotaBytes: UInt64?

    /// Kind and id together; ids are unique only within a kind.
    public var id: String { "\(kind):\(objectID)" }

    enum CodingKeys: String, CodingKey {
        case kind, title, subtitle, days, state, currency, href
        case objectID = "id"
        case dueAt = "due_at"
        case costCents = "cost_cents"
        case usedBytes = "used_bytes"
        case quotaBytes = "quota_bytes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        objectID = try c.decodeIfPresent(String.self, forKey: .objectID) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        dueAt = try DateValue.decodeIfPresent(from: c, forKey: .dueAt)
        days = try c.decodeIfPresent(Int.self, forKey: .days) ?? 0
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        costCents = try c.decodeIfPresent(Int.self, forKey: .costCents) ?? 0
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? ""
        href = try c.decodeIfPresent(String.self, forKey: .href) ?? ""
        usedBytes = try c.decodeIfPresent(UInt64.self, forKey: .usedBytes)
        quotaBytes = try c.decodeIfPresent(UInt64.self, forKey: .quotaBytes)
    }
}

public struct ExpiringTotal: Codable, Equatable, Hashable, Sendable {
    public var currency: String
    public var costCents: Int
    public var count: Int

    enum CodingKeys: String, CodingKey {
        case currency, count
        case costCents = "cost_cents"
    }
}

/// `GET /api/expiring?within=`.
public struct ExpiringResponse: Decodable, Equatable, Sendable {
    public var generatedAt: Date?
    public var withinDays: Int
    public var items: [ExpiringItem]
    public var totals: [ExpiringTotal]
    /// Kinds this session cannot read at all; names only, never counts.
    public var hiddenKinds: [String]

    enum CodingKeys: String, CodingKey {
        case items, totals
        case generatedAt = "generated_at"
        case withinDays = "within_days"
        case hiddenKinds = "hidden_kinds"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try DateValue.decodeIfPresent(from: c, forKey: .generatedAt)
        withinDays = try c.decodeIfPresent(Int.self, forKey: .withinDays) ?? 0
        items = try c.decodeIfPresent([ExpiringItem].self, forKey: .items) ?? []
        totals = try c.decodeIfPresent([ExpiringTotal].self, forKey: .totals) ?? []
        hiddenKinds = try c.decodeIfPresent([String].self, forKey: .hiddenKinds) ?? []
    }
}

public extension LatticeClient {
    /// `GET /api/expiring?within=` in whole days, clamped to the server's 1 to 365.
    func fetchExpiring(within days: Int) async throws -> ExpiringResponse {
        let clamped = min(max(days, 1), 365)
        return try await perform(ExpiringResponse.self, path: "/api/expiring", query: [URLQueryItem(name: "within", value: String(clamped))])
    }
}
