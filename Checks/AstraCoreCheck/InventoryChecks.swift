import Foundation
import AstraCore

public func checkInventory() async throws {
    try await checkMachineDecoding()
    try checkInventorySummary()
}

private func checkMachineDecoding() async throws {
    let transport = MockTransport(responses: [
        "https://lattice.example.com/api/machines": (
            200,
            """
            [
              {"id":"m1","node_id":"node-a","node_name":"Edge","label":"Tokyo box","online":true,
               "host_facts":{"hostname":"edge"},"vendor":"Vultr","region":"nrt","has_console_url":true,
               "has_detail_url":false,"price_cents":600,"currency":"usd","renewal_cycle":"monthly",
               "cycle_days":0,"next_renewal":"2026-06-20T00:00:00Z","days_until_renewal":3,"auto_roll":true,
               "remind_days_before":[7,1],"reminders_enabled":true,"created_at":"2026-01-01T00:00:00Z"}
            ]
            """.data(using: .utf8)!
        ),
    ])
    let session = LatticeClient(baseURL: URL(string: "https://lattice.example.com")!, credential: LatticeCredential(sessionCookie: "sid", csrfToken: "csrf-token"), transport: transport)

    let machines = try await session.listMachines()
    let machine = try expectUnwrapped(machines.first, "machine decoded")
    try expectEqual(machine.nodeName, "Edge", "machine node name from view")
    try expect(machine.hasConsoleURL, "machine has console url flag")
    try expect(!machine.hasDetailURL, "machine has no detail url flag")
    try expectEqual(machine.serverDaysUntilRenewal, 3, "machine server days until renewal")
    let monthly = try expectUnwrapped(machine.monthlyCost, "machine monthly cost")
    try expect(abs(monthly - 6.0) < 0.001, "monthly cost of a $6/mo box")
    try expectEqual(machine.hostFacts.hostname, "edge", "machine host facts")
}

private func checkInventorySummary() throws {
    let now = ISO8601DateFormatter().date(from: "2026-06-17T02:00:00Z")!
    let machines = [
        MachineProfile(id: "m1", priceCents: 1200, currency: "USD", renewalCycleRaw: "annual", cycleDays: 0, nextRenewal: now.addingTimeInterval(5 * 86_400)),
        MachineProfile(id: "m2", priceCents: 500, currency: "USD", renewalCycleRaw: "monthly", cycleDays: 0, nextRenewal: now.addingTimeInterval(-2 * 86_400)),
        MachineProfile(id: "m3", priceCents: 0, currency: "USD", renewalCycleRaw: "monthly")
    ]
    let inventory = InventorySummary(machines: machines, window: 14, now: now)
    try expectEqual(inventory.machineCount, 3, "inventory machine count")
    let usd = try expectUnwrapped(inventory.monthlyCostByCurrency["USD"], "USD monthly cost")
    try expect(abs(usd - (12.0 * 30 / 365 + 5.0)) < 0.01, "monthly cost normalizes annual + monthly")
    try expectEqual(inventory.dueSoon.map(\.id), ["m1"], "renewal due soon within window")
    try expectEqual(inventory.overdue.map(\.id), ["m2"], "overdue renewal")
}
