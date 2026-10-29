import Foundation
import AstraCore

public func checkInventory() async throws {
    try await checkInventoryDecoding()
    try await checkInventoryRequestBodies()
    try checkInventoryDays()
    try checkInventoryCost()
    try checkInventoryReminderSchedule()
    try checkInventoryRenewalStates()
    try checkInventoryGrouping()
    try checkInventoryQuery()
    try checkInventoryUpcoming()
    try checkInventorySummary()
    try await checkInventoryDemo()
}

private let inventoryBase = "https://lattice.example.com"

private func inventoryClient(_ responses: [String: (Int, Data)]) -> (LatticeClient, MockTransport) {
    let transport = MockTransport(responses: responses)
    let client = LatticeClient(baseURL: URL(string: inventoryBase)!, credential: LatticeCredential(sessionCookie: "sid", csrfToken: "csrf-token"), transport: transport)
    return (client, transport)
}

private func instant(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

/// Money and dates format with no-break spaces; the goldens use plain ones.
private func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
}

private func day(_ text: String) -> InventoryDay {
    InventoryDay(text)!
}

/// A profile the way the console's tests build one: monthly, reminders on, the default offsets.
private func reminderMachine(_ name: String, _ renewal: String?, autoRoll: Bool = false, reminders: Bool = true, offsets: [Int] = [14, 7, 3, 1, 0], id: String? = nil) -> MachineProfile {
    MachineProfile(
        id: id ?? "mch_\(name)", nodeID: "node_\(name)", label: name, renewalCycleRaw: "monthly",
        nextRenewal: renewal.map { instant("\($0)T00:00:00Z") }, autoRoll: autoRoll,
        remindDaysBefore: offsets, remindersEnabled: reminders
    )
}

/// A profile the way the console's cost tests build one: monthly, renewing 2026-11-01.
private func costMachine(_ cents: Int64, _ currency: String, cycle: String = "monthly", renewal: String? = "2026-11-01T00:00:00Z", cycleDays: Int = 0, id: String = "machine") -> MachineProfile {
    MachineProfile(id: id, nodeID: "node", priceCents: cents, currency: currency, renewalCycleRaw: cycle, cycleDays: cycleDays, nextRenewal: renewal.map(instant))
}

// MARK: Decoding

private func checkInventoryDecoding() async throws {
    let machinesJSON = try fixture("inventory-machines.json")
    let envelope = Data(#"{"machines":"#.utf8) + machinesJSON + Data("}".utf8)
    let (client, _) = inventoryClient(["\(inventoryBase)/api/machines": (200, machinesJSON)])
    let machines = try await client.listMachines()
    try expectEqual(machines.count, 3, "every node the caller can read, profiled or not")
    let tokyo = machines[0]
    try expectEqual(tokyo.inventoryName, "Tokyo edge", "the label names the machine")
    try expectEqual(tokyo.nodeName, "edge-tyo-1", "node name from the view")
    try expect(tokyo.hasConsoleURL && !tokyo.hasDetailURL, "link flags, never the links")
    try expectEqual(tokyo.vendorProfile?.url, "https://northwind.example.net", "vendor profile decodes")
    try expectEqual(tokyo.renewalDay, day("2026-10-26"), "renewal as a UTC day")
    try expectEqual(tokyo.serverDaysUntilRenewal, -2, "server days until renewal")
    try expectEqual(tokyo.purchasedAt, instant("2025-03-01T00:00:00Z"), "purchased_at decodes")
    try expectEqual(tokyo.canonicalCurrency, "USD", "a lower-case code reads upper-case")
    try expectEqual(tokyo.hostFacts.hostname, "edge-tyo-1.example.net", "host facts")
    try expect(tokyo.updatedAt != nil, "nanosecond stamps decode")
    try expectEqual(machines[1].canonicalCurrency, "CNY", "CHY folds into CNY")
    try expectEqual(machines[1].cycleDays, 60, "custom cycle days")
    let bare = machines[2]
    try expect(!bare.isProfiled && bare.id.isEmpty, "a node nobody profiled has no id")
    try expectEqual(bare.inventoryName, "home-nas", "an unprofiled row is named by its node")
    try expectEqual(InventoryCost.billing(bare), .unprofiled, "unprofiled billing")

    let (enveloped, _) = inventoryClient(["\(inventoryBase)/api/machines": (200, envelope)])
    try expectEqual(try await enveloped.listMachines().map(\.nodeID), machines.map(\.nodeID), "the {machines} envelope decodes the same")

    let vendorsEnvelope = json(#"{"vendors":[{"id":"vendor_1","name":"Northwind Cloud","url":"https://northwind.example.net","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"},{"id":"derived:contoso vps","name":"Contoso VPS","created_at":"0001-01-01T00:00:00Z","updated_at":"0001-01-01T00:00:00Z"}]}"#)
    let (vendorClient, _) = inventoryClient(["\(inventoryBase)/api/machine-vendors": (200, vendorsEnvelope)])
    let vendors = try await vendorClient.inventoryVendors()
    try expectEqual(vendors.map(\.name), ["Northwind Cloud", "Contoso VPS"], "vendors envelope")
    try expect(vendors[1].isDerived && !vendors[0].isDerived, "a vendor only profiles name is derived")
    let (bareVendors, _) = inventoryClient(["\(inventoryBase)/api/machine-vendors": (200, json(#"[{"id":"vendor_1","name":"Northwind Cloud"}]"#))])
    try expectEqual(try await bareVendors.inventoryVendors().count, 1, "vendors as a bare array")

    let (badClient, _) = inventoryClient(["\(inventoryBase)/api/machines": (200, json("<html>"))])
    do {
        _ = try await badClient.listMachines()
        throw CheckFailure.failed("an undecodable machines body must fail")
    } catch let error as LatticeAPIError {
        try expectEqual(error, .invalidResponse, "an undecodable body is companion behind, never an empty list")
    }
}

// MARK: Request bodies

private func checkInventoryRequestBodies() async throws {
    let view = json(#"{"id":"machine_1","node_id":"node_1","next_renewal":"2026-11-03T00:00:00Z","online":true,"host_facts":{},"has_console_url":false,"has_detail_url":false,"auto_roll":false,"reminders_enabled":true}"#)
    let (client, transport) = inventoryClient([
        "\(inventoryBase)/api/machines/renew": (200, view),
        "\(inventoryBase)/api/machines/delete": (200, json(#"{"ok":true}"#)),
        "\(inventoryBase)/api/machines/reminders/run": (200, json(#"{"fired":[{"machine_id":"machine_1","node_id":"node_1","node_name":"edge-tyo-1","offset_days":3,"next_renewal":"2026-10-31"},{"machine_id":"machine_2","node_id":"node_2","offset_days":-2,"next_renewal":"2026-10-26"}]}"#)),
        "\(inventoryBase)/api/machines/reveal-link": (200, json(#"{"ok":true,"id":"machine_1","kind":"console","url":"https://console.northwind.example.net/servers/1"}"#)),
    ])

    let renewed = try await client.renewMachine(id: "machine_1", nextRenewal: day("2026-11-03").date)
    try expectEqual(renewed.renewalDay, day("2026-11-03"), "renew answers the machine view")
    var body = try bodyObject(await transport.lastBody)
    try expectEqual(body as NSDictionary, ["id": "machine_1", "next_renewal": "2026-11-03T00:00:00Z"] as NSDictionary, "renew body golden")

    try await client.deleteMachine(id: "machine_1")
    body = try bodyObject(await transport.lastBody)
    try expectEqual(body as NSDictionary, ["id": "machine_1"] as NSDictionary, "delete body golden")

    let fired = try await client.inventoryRunReminders()
    body = try bodyObject(await transport.lastBody)
    try expectEqual(body.count, 0, "a run over every machine sends {}")
    try expectEqual(fired.map(\.offsetDays), [3, -2], "fired reminders decode")
    try expectEqual(fired[0].renewalDay, day("2026-10-31"), "a fired reminder's day")
    try expectEqual(fired[1].nodeName, "", "node_name is optional")

    let transport2 = MockTransport(responses: ["\(inventoryBase)/api/machines/reminders/run": (200, json(#"{"fired":[]}"#))])
    let client2 = LatticeClient(baseURL: URL(string: inventoryBase)!, credential: LatticeCredential(bearerToken: "tok"), transport: transport2)
    _ = try await client2.inventoryRunReminders(machineID: "machine_9")
    try expectEqual(try bodyObject(await transport2.lastBody) as NSDictionary, ["id": "machine_9"] as NSDictionary, "a run for one machine sends {id}")

    let grant = StepUpGrant(grant: "grant_1", expiresAt: Date().addingTimeInterval(60))
    let reveal = try await client.inventoryRevealLink(id: "machine_1", kind: .console, grant: grant)
    try expectEqual(reveal.url, "https://console.northwind.example.net/servers/1", "reveal answers the link")
    body = try bodyObject(await transport.lastBody)
    try expectEqual(body as NSDictionary, ["id": "machine_1", "kind": "console", "step_up_grant": "grant_1"] as NSDictionary, "reveal body golden")
    try expectEqual(await transport.methods.compactMap { $0 }, ["POST", "POST", "POST", "POST"], "every write is a POST")

    let (missing, _) = inventoryClient(["\(inventoryBase)/api/machines/reveal-link": (404, json(#"{"error":{"code":"not_found","message":"link is not set"}}"#))])
    do {
        _ = try await missing.inventoryRevealLink(id: "machine_1", kind: .detail, grant: grant)
        throw CheckFailure.failed("a link that is not set must fail")
    } catch let error as LatticeAPIError {
        try expectEqual(error, .notFound, "a missing link maps to not found")
    }
}

// MARK: Days

private func checkInventoryDays() throws {
    try expectEqual(day("2026-01-31").adding(months: 1), day("2026-03-03"), "31 January plus a month is 3 March, as Go's AddDate")
    try expectEqual(day("2024-02-29").adding(months: 12), day("2025-03-01"), "a leap day plus a year overflows")
    try expectEqual(day("2026-12-15").adding(months: 3), day("2027-03-15"), "months roll the year")
    try expectEqual(day("2026-10-28").adding(days: -30), day("2026-09-28"), "days back")
    try expect(InventoryDay("2026-02-30") == nil && InventoryDay("2026-13-01") == nil && InventoryDay("26-01-01") == nil, "only real days parse")
    try expectEqual(day("2026-09-29").days(until: day("2026-10-06")), 7, "days between")
    try expectEqual(day("2026-03-28").days(until: day("2026-03-30")), 2, "no daylight saving drift in UTC days")
    try expectEqual(InventoryDay(date: instant("2026-11-01T23:30:00-05:00")).description, "2026-11-02", "renewal days are UTC days")
    try expectEqual(InventoryDay.picked(day("2026-11-03").localDate(in: TimeZone(identifier: "Pacific/Honolulu")!), in: TimeZone(identifier: "Pacific/Honolulu")!), day("2026-11-03"), "a picked day survives the device zone")
    try expectEqual(plain(day("2026-11-03").formatted(locale: Locale(identifier: "en_US"))), "Nov 3, 2026", "a day formats without a zone shift")
}

// MARK: Cost (inventoryCostModel.test.ts)

private func checkInventoryCost() throws {
    let spend = InventoryCost.aggregate([
        costMachine(80_460, "CHY", cycle: "semiannual"),
        costMachine(2_000, "chy "),
        costMachine(1_500, "CNY"),
        costMachine(990, "USD"),
    ])
    try expectEqual(spend.map(\.currency), ["CNY", "USD"], "CHY and CNY are one CNY line")
    try expectEqual(spend.map(\.monthlyCents), [13_410 + 2_000 + 1_500, 990], "monthly totals per currency")
    try expectEqual(spend.map(\.count), [3, 1], "counts per currency")
    try expectEqual(spend[0].annualCents, Double(13_410 + 2_000 + 1_500) * 12, "annual total")

    let stored = InventoryCost.aggregate([costMachine(100, "usdtxx"), costMachine(100, "USDTXX"), costMachine(100, "")])
    try expectEqual(stored.map(\.currency), ["USDTXX", "USD"], "a stored code is summed as stored; none reads USD")
    try expectEqual(stored.map(\.count), [2, 1], "counts for stored codes")

    let list = [
        costMachine(500, "CNY"),
        costMachine(900, "CNY", cycle: "", renewal: nil),
        costMachine(0, "CNY"),
        costMachine(700, "CNY", renewal: "0001-01-01T00:00:00Z"),
        costMachine(800, "CNY", id: ""),
    ]
    try expectEqual(list.map(InventoryCost.billing), [.recurring, .onetime, .unpriced, .renewalIncomplete, .unprofiled], "billing categories")
    try expectEqual(InventoryCost.aggregate(list).map(\.monthlyCents), [500], "only recurring machines count toward spend")

    try expectEqual(InventoryCost.monthlyEquivalentCents(costMachine(1_200, "USD", cycle: "annual")), 100, "annual to monthly")
    try expectEqual(InventoryCost.monthlyEquivalentCents(costMachine(900, "USD", cycle: "quarterly")), 300, "quarterly to monthly")
    try expectEqual(InventoryCost.monthlyEquivalentCents(costMachine(3_000, "USD", cycle: "custom_days", cycleDays: 60)), 3_000 * 30.4375 / 60, "custom days to monthly")
    try expectEqual(InventoryCost.monthlyEquivalentCents(costMachine(3_000, "USD", cycle: "custom_days")), 3_000, "an unknown custom span reads as monthly")
    try expectEqual(InventoryCost.monthlyEquivalentCents(costMachine(3_000, "USD", cycle: "", renewal: nil)), 0, "one-time has no monthly figure")
    try expectEqual(costMachine(3_000, "USD", cycle: "semiannual").monthlyCost, 5, "monthlyCost is the console's figure in major units")
    try expect(costMachine(0, "USD").monthlyCost == nil, "an unpriced machine has no monthly cost")
    try expect(MachineProfile(id: "m", nextRenewal: instant("0001-01-01T00:00:00Z")).renewalDay == nil, "Go's zero time is no date")

    let us = Locale(identifier: "en_US")
    try expectEqual(plain(InventoryCost.priceLine(costMachine(2_400, "EUR"), locale: us)), "EUR 24.00 monthly", "price line")
    try expectEqual(plain(InventoryCost.priceLine(costMachine(300, "EUR", cycle: "custom_days", cycleDays: 60), locale: us)), "EUR 3.00 every 60 days", "custom cycle price line")
    try expectEqual(InventoryCost.priceLine(MachineProfile(id: "m"), locale: us), "Free", "a profile with nothing billed is free")
    var doomed = costMachine(1_200, "USD", id: "m-1")
    doomed.nodeName = "edge-tyo-1"
    doomed.hasConsoleURL = true
    doomed.remindersEnabled = true
    doomed.remindDaysBefore = [7, 14, 0]
    let report = InventoryDeleteReport.report(doomed, locale: us)
    try expectEqual(report.lines.map(\.label), ["Price", "Renewal", "Reminders", "Stored links", "Node"], "what a delete removes")
    try expectEqual(report.lines[2].value, "On, 14, 7, 0 days before", "reminder offsets in the report")
    try expectEqual(report.lines.last?.group, "Not affected", "the node is named as staying")
    var changed = doomed
    changed.priceCents = 1_500
    try expect(InventoryDeleteReport.report(changed, locale: us).fingerprint != report.fingerprint, "a changed profile stops the delete")
    try expect(InventoryDeleteReport.gone.blocking, "a profile already gone blocks the delete")
    try expectEqual(plain(InventoryCurrency.format(cents: 13_409.6, currency: "chy", locale: us)), "CNY 134.10", "money rounds to whole cents and folds the alias")
}

// MARK: Reminder schedule (reminderModel.test.ts)

private func checkInventoryReminderSchedule() throws {
    let today = day("2026-09-29")
    func next(_ machine: MachineProfile) -> ReminderSchedule.Next? { ReminderSchedule.nextReminder(machine, today: today) }

    try expectEqual(next(reminderMachine("relay-tyo-nat", "2026-10-06")), .init(offset: 7, at: day("2026-09-29"), inDays: 0, renewal: day("2026-10-06")), "seven days out is today's run")
    try expectEqual(next(reminderMachine("relay-fra-1", "2026-10-20")), .init(offset: 14, at: day("2026-10-06"), inDays: 7, renewal: day("2026-10-20")), "21 days out: the 14-day reminder")
    try expectEqual(next(reminderMachine("x", "2026-10-09"))?.offset, 7, "ten days out: 7 lands in three days")

    try expect(next(reminderMachine("off", "2026-10-06", reminders: false)) == nil, "reminders off has no next reminder")
    try expect(next(reminderMachine("none", nil)) == nil, "no date has no next reminder")
    try expect(next(reminderMachine("zero", "0001-01-01")) == nil, "a zero date has no next reminder")

    try expectEqual(next(reminderMachine("late", "2026-09-30", offsets: [7, 3])),
                    .init(offset: -1, at: day("2026-10-01"), inDays: 2, renewal: day("2026-09-30"), repeatsUntil: day("2026-10-07")), "past its offsets: daily from the day after")
    try expectEqual(next(reminderMachine("overdue", "2026-09-25")),
                    .init(offset: -1, at: today, inDays: 0, renewal: day("2026-09-25"), repeatsUntil: day("2026-10-02")), "overdue: today's run")
    try expectEqual(next(reminderMachine("d7", "2026-09-22"))?.offset, -1, "day seven past is the last")
    try expect(next(reminderMachine("d8", "2026-09-21")) == nil, "day eight past is silence")

    try expectEqual(next(reminderMachine("auto", "2026-09-30", autoRoll: true, offsets: [14, 7, 3])),
                    .init(offset: 14, at: day("2026-10-16"), inDays: 17, renewal: day("2026-10-30")), "auto-roll starts over in the next cycle")
    try expectEqual(next(reminderMachine("auto-stale", "2026-09-10", autoRoll: true))?.renewal, day("2026-10-10"), "an unrolled date rolls past today first")

    try expectEqual(ReminderSchedule.offsets(MachineProfile(id: "m", remindDaysBefore: [1, 14, 7, 7, -1, 400, 0])), [14, 7, 1, 0], "offsets 0 to 365, deduplicated, largest first")
    try expectEqual(ReminderSchedule.offsets(MachineProfile(id: "m")), [], "no offsets")

    let fleet = [
        reminderMachine("relay-tyo-nat", "2026-10-06"),
        reminderMachine("relay-fra-1", "2026-10-20", autoRoll: true),
        reminderMachine("relay-fra-2", "2026-10-20", autoRoll: true),
        reminderMachine("turned-off", "2026-10-08", reminders: false),
        reminderMachine("no-date", nil, reminders: false),
        reminderMachine("bare", "2026-10-01", id: ""),
    ]
    let coverage = ReminderSchedule.coverage(fleet, today: today)
    try expectEqual(coverage.covered, 3, "covered machines")
    try expectEqual(coverage.off, 1, "machines with reminders off")
    try expectEqual(coverage.next?.machine.label, "relay-tyo-nat", "the soonest reminder")
    try expectEqual(coverage.next?.reminder, .init(offset: 7, at: today, inDays: 0, renewal: day("2026-10-06")), "the soonest reminder's schedule")
    try expectEqual(coverage.sameDay, 1, "one message today")
    try expectEqual(ReminderSchedule.dueToday(fleet, today: today).map(\.machine.label), ["relay-tyo-nat"], "today's run")
    try expectEqual(ReminderSchedule.nextAfterToday(fleet, today: today)?.reminder.at, day("2026-10-06"), "next after today")

    let four = (1...4).map { reminderMachine("relay-sin-\($0)", "2026-10-20", autoRoll: true) }
    let same = ReminderSchedule.coverage(four, today: today)
    try expectEqual(same.next?.reminder.at, day("2026-10-06"), "same-day reminders")
    try expectEqual(same.next?.machine.label, "relay-sin-1", "name order breaks ties")
    try expectEqual(same.sameDay, 4, "one message on that run")
    let empty = ReminderSchedule.coverage([], today: today)
    try expect(empty.covered == 0 && empty.off == 0 && empty.next == nil && empty.sameDay == 0, "empty coverage")

    let us = Locale(identifier: "en_US")
    try expectEqual(plain(ReminderSchedule.line(.init(offset: 3, at: today, inDays: 0, renewal: day("2026-10-02")), today: today, locale: us)), "Renews Oct 2, 2026, 3 days ahead", "before line")
    try expectEqual(plain(ReminderSchedule.line(.init(offset: -1, at: today, inDays: 0, renewal: day("2026-09-25")), today: today, locale: us)), "Renewal Sep 25, 2026 passed, daily overdue reminder", "overdue line")
}

// MARK: Renewal states

private func checkInventoryRenewalStates() throws {
    let today = day("2026-10-28")
    func state(_ machine: MachineProfile) -> InventoryRenewalState { InventoryRenewalState.of(machine, today: today) }
    let manual = { (renewal: String) in costMachine(1_000, "USD", renewal: "\(renewal)T00:00:00Z") }

    try expectEqual(state(manual("2026-10-26")), .overdue(days: 2), "overdue")
    try expectEqual(state(manual("2026-10-26")).word, "2 days overdue", "overdue words")
    try expectEqual(state(manual("2026-10-27")).word, "1 day overdue", "one day overdue")
    try expectEqual(state(manual("2026-10-28")).word, "renews today", "due today")
    try expectEqual(state(manual("2026-11-03")), .dueSoon(days: 6), "six days warns")
    try expectEqual(state(manual("2026-11-04")), .upcoming(days: 7), "seven days does not")
    var auto = manual("2026-10-20")
    auto.autoRoll = true
    try expectEqual(state(auto), .autoRenews(days: 23, on: day("2026-11-20")), "a passed auto-roll date reads as the date it rolls to")
    try expectEqual(state(auto).word, "auto-renews in 23 days", "auto words")
    try expectEqual(state(costMachine(1_000, "USD", id: "")), .unprofiled, "unprofiled")
    try expectEqual(state(costMachine(1_000, "USD", renewal: nil)), .setupIncomplete, "a cycle without a date needs setup")
    try expectEqual(state(costMachine(1_000, "USD", cycle: "", renewal: nil)), .notTracked, "one-time is not tracked")
}

// MARK: Grouping

private func checkInventoryGrouping() throws {
    let today = day("2026-10-28")
    func machine(_ node: String, region: String, renewal: String?, autoRoll: Bool = false) -> MachineProfile {
        var m = costMachine(1_000, "USD", renewal: renewal.map { "\($0)T00:00:00Z" }, id: "m-\(node)")
        m.nodeID = "n-\(node)"
        m.nodeName = node
        m.region = region
        m.autoRoll = autoRoll
        return m
    }
    var bare = MachineProfile(id: "", nodeID: "n-home-nas", nodeName: "home-nas")
    bare.online = true
    let machines = [
        machine("edge-tyo-2", region: "Tokyo", renewal: "2026-11-20"),
        machine("edge-tyo-1", region: "Tokyo", renewal: "2026-10-26"),
        machine("relay-fra-1", region: "Frankfurt", renewal: "2026-10-31"),
        machine("edge-sin-1", region: "", renewal: "2027-02-01"),
        bare,
    ]
    let facts: [String: InventoryNodeFacts] = [
        "n-edge-tyo-2": InventoryNodeFacts(country: "JP", role: "edge", tags: ["edge", "asia"], groupIDs: ["g1"], status: "online"),
        "n-edge-tyo-1": InventoryNodeFacts(country: "JP", role: "edge", tags: ["edge"], groupIDs: ["g1", "g2"], status: "offline"),
        "n-relay-fra-1": InventoryNodeFacts(country: "DE", role: "relay", tags: [], status: "online"),
    ]
    let names = ["g1": "Asia edge", "g2": "Canary"]
    func sections(_ by: InventoryGroupBy) -> [InventorySection] {
        InventoryGrouping.sections(machines, by: by, today: today, facts: { facts[$0] }, groupName: { names[$0] }, locale: Locale(identifier: "en_US"))
    }

    let region = sections(.region)
    try expectEqual(region.map(\.title), ["Tokyo", "Frankfurt", "No region"], "regions: biggest first, unknown last")
    try expectEqual(region[0].machines.map(\.nodeName), ["edge-tyo-1", "edge-tyo-2"], "name order inside a region")
    try expectEqual(region.last?.machines.last?.nodeName, "home-nas", "profiles before unprofiled nodes")
    try expectEqual(region[0].spend.first?.monthlyCents, 2_000, "group spend")
    try expectEqual(sections(.country).map(\.title), ["Japan", "Germany", "No country"], "countries by name")
    try expectEqual(sections(.group).map(\.title), ["Asia edge", "Canary", "No group"], "groups by name, a machine in each of its groups")
    try expectEqual(sections(.tag).first.map { ($0.title, $0.machines.count) }?.1, 2, "tags put a machine under each tag")
    let status = sections(.status)
    try expectEqual(status.map(\.title), ["Overdue", "Due within 14 days", "Later", "No profile"], "status buckets in reading order")
    try expectEqual(status[1].machines.map(\.nodeName), ["relay-fra-1"], "due soon")
    try expectEqual(sections(.none).map(\.title), ["All machines"], "no grouping")
    try expectEqual(InventoryLookup.machine("n-home-nas", in: machines)?.nodeName, "home-nas", "a node id finds its row")
    try expectEqual(InventoryLookup.machine("m-edge-tyo-1", in: machines)?.nodeName, "edge-tyo-1", "a profile id finds its machine")
    try expect(InventoryLookup.machine("", in: machines) == nil, "an empty id finds nothing")
}

// MARK: Query

private func checkInventoryQuery() throws {
    let today = day("2026-10-28")
    let rows = [
        InventoryQuery.Row(machine: MachineProfile(id: "m1", nodeID: "n-edge-tyo-1", nodeName: "edge-tyo-1", vendor: "Northwind Cloud", region: "Tokyo",
                                                   priceCents: 1_200, currency: "USD", renewalCycleRaw: "monthly", nextRenewal: day("2026-10-26").date, remindersEnabled: true),
                           facts: InventoryNodeFacts(role: "edge", tags: ["asia"], status: "online"), today: today),
        InventoryQuery.Row(machine: MachineProfile(id: "m2", nodeID: "n-relay-fra-1", nodeName: "relay-fra-1", vendor: "Fabrikam Hosting", region: "Frankfurt",
                                                   priceCents: 2_400, currency: "EUR", renewalCycleRaw: "monthly", nextRenewal: day("2026-12-01").date, autoRoll: true),
                           facts: InventoryNodeFacts(role: "relay", status: "offline"), today: today),
        InventoryQuery.Row(machine: MachineProfile(id: "", nodeID: "n-home-nas", nodeName: "home-nas"), facts: nil, today: today),
    ]
    func run(_ query: String) throws -> [String] {
        switch InventoryQuery.compile(query) {
        case .success(let compiled): return LatticeQueryEngine.apply(compiled, to: rows, now: Date()).map(\.machine.nodeName)
        case .failure(let error): throw CheckFailure.failed("query \(query) failed: \(error)")
        }
    }
    try expectEqual(try run("vendor:fabrikam"), ["relay-fra-1"], "vendor:")
    try expectEqual(try run("region:tokyo"), ["edge-tyo-1"], "region: is the vendor's region")
    try expectEqual(try run("node:home-nas"), ["home-nas"], "node:")
    try expectEqual(try run("renews_in<7d"), ["edge-tyo-1"], "renews_in counts days to the renewal")
    try expectEqual(try run("is:autoroll"), ["relay-fra-1"], "is:autoroll")
    try expectEqual(try run("-is:profiled"), ["home-nas"], "unprofiled nodes")
    try expectEqual(try run("billing:unprofiled"), ["home-nas"], "billing:")
    try expectEqual(try run("status:offline"), ["relay-fra-1"], "node status")
    try expectEqual(try run("tokyo"), ["edge-tyo-1"], "free text")
    try expectEqual(try run("sort:-price"), ["relay-fra-1", "edge-tyo-1", "home-nas"], "sort by price")
    guard case .failure(let error) = InventoryQuery.compile("vendr:x") else { throw CheckFailure.failed("an unknown field must fail") }
    try expect(InventoryQuery.message(error).contains("vendr") && InventoryQuery.message(error).contains("vendor"), "unknown field sentence names it and the suggestion: \(InventoryQuery.message(error))")
}

// MARK: Upcoming (upcomingModel.test.ts)

private func checkInventoryUpcoming() throws {
    func item(_ kind: String, _ title: String, days: Int, state: String, cost: Int = 0, currency: String = "", due: String) throws -> ExpiringItem {
        let text = #"{"kind":"\#(kind)","id":"\#(title)","title":"\#(title)","due_at":"\#(due)T00:00:00Z","days":\#(days),"state":"\#(state)","cost_cents":\#(cost),"currency":"\#(currency)","href":""}"#
        return try JSONDecoder().decode(ExpiringItem.self, from: json(text))
    }
    let today = day("2026-10-28")
    let items = [
        try item("tls_certificate", "tls-api.example.org", days: 12, state: "upcoming", due: "2026-11-09"),
        try item("machine_renewal", "edge-tyo-1", days: -2, state: "overdue", cost: 1_200, currency: "USD", due: "2026-10-26"),
        try item("machine_renewal", "core-lon-1", days: -1, state: "auto", cost: 4_900, currency: "USD", due: "2026-10-27"),
        try item("machine_renewal", "relay-fra-1", days: 3, state: "due", cost: 2_400, currency: "EUR", due: "2026-10-31"),
        try item("vpn_user", "alice", days: 5, state: "due", due: "2026-11-02"),
        try item("share", "family", days: 9, state: "upcoming", due: "2026-11-06"),
    ]
    let groups = InventoryUpcoming.groupByWeek(items, today: today)
    try expectEqual(groups.map { plain($0.title(locale: Locale(identifier: "en_US"))) }, ["Overdue", "This week", "Next week", "Week of Nov 9"], "weeks start on Monday")
    try expectEqual(groups.map { $0.items.map(\.title) }, [["edge-tyo-1"], ["core-lon-1", "relay-fra-1"], ["alice", "family"], ["tls-api.example.org"]], "rows by due date")
    try expectEqual(groups[1].totals.map(\.currency), ["EUR", "USD"], "totals per currency, by code")
    try expect(!InventoryUpcoming.isOverdue(items[2]), "an auto-roll row is never overdue")
    try expectEqual(InventoryUpcoming.filter(items, kind: .machineRenewal).count, 3, "kind filter")
    try expectEqual(InventoryUpcoming.filter(items, kind: nil).count, 6, "All shows every row")
    try expectEqual(InventoryUpcoming.headerCounts(items).due, 5, "rows not overdue")
    try expectEqual(InventoryUpcoming.headerCounts(items).overdue, 1, "overdue rows")

    let totals = InventoryUpcoming.sumTotals([
        try item("machine_renewal", "a", days: 1, state: "due", cost: 100, currency: "CHY", due: "2026-10-29"),
        try item("machine_renewal", "b", days: 1, state: "due", cost: 50, currency: "CNY", due: "2026-10-29"),
        try item("machine_renewal", "c", days: 1, state: "due", cost: 990, currency: "USD", due: "2026-10-29"),
        try item("machine_renewal", "d", days: 1, state: "due", cost: 300, currency: "", due: "2026-10-29"),
    ])
    try expectEqual(totals.map(\.currency), ["CNY", "USD"], "a row without a currency counts in none; CHY is CNY")
    try expectEqual(totals.map(\.costCents), [150, 990], "summed cents")

    let response = try JSONDecoder().decode(ExpiringResponse.self, from: json(#"{"generated_at":"2026-10-28T23:50:00Z","within_days":30,"items":[],"totals":[],"hidden_kinds":["share","future_kind","vpn_user","share",""]}"#))
    try expectEqual(InventoryUpcoming.hiddenKinds(response), ["vpn_user", "share", "future_kind"], "hidden kinds in filter order, then unknown ones")
    try expectEqual(InventoryUpcoming.today(response, now: Date()), day("2026-10-28"), "today is the server's UTC day")

    try expectEqual(InventoryUpcoming.dueWords(items[1]), "2 days overdue", "overdue words")
    try expectEqual(InventoryUpcoming.dueWords(items[3]), "due in 3 days", "due words")
    try expectEqual(InventoryUpcoming.dueWords(items[2]), "auto-renews today", "auto words")
    try expectEqual(InventoryUpcomingKind.allCases.map(\.filterTitle), ["Machines", "VPN users", "Shares", "Certificates"], "the filter's options")
}

private func checkInventorySummary() throws {
    let now = instant("2026-06-17T02:00:00Z")
    let machines = [
        MachineProfile(id: "m1", priceCents: 1200, currency: "USD", renewalCycleRaw: "annual", cycleDays: 0, nextRenewal: now.addingTimeInterval(5 * 86_400)),
        MachineProfile(id: "m2", priceCents: 500, currency: "USD", renewalCycleRaw: "monthly", cycleDays: 0, nextRenewal: now.addingTimeInterval(-2 * 86_400)),
        MachineProfile(id: "m3", priceCents: 0, currency: "USD", renewalCycleRaw: "monthly"),
    ]
    let inventory = InventorySummary(machines: machines, window: 14, now: now)
    try expectEqual(inventory.machineCount, 3, "inventory machine count")
    let usd = try expectUnwrapped(inventory.monthlyCostByCurrency["USD"], "USD monthly cost")
    try expect(abs(usd - (12.0 / 12 + 5.0)) < 0.001, "monthly cost normalizes annual and monthly")
    try expectEqual(inventory.dueSoon.map(\.id), ["m1"], "renewal due soon within window")
    try expectEqual(inventory.overdue.map(\.id), ["m2"], "overdue renewal")
}

// MARK: Demo routes

private func checkInventoryDemo() async throws {
    let state = DemoState()
    let clock = DemoClock(pinned: "2026-10-28T12:00:00Z")!
    func client(_ identity: DemoIdentity = .pat, scenario: DemoScenario = .normal) -> LatticeClient {
        let credential = identity == .pat ? LatticeCredential(bearerToken: DemoWorld.token) : LatticeCredential(sessionCookie: "sid_demo", csrfToken: "csrf_demo")
        return LatticeClient(baseURL: DemoWorld.baseURL, credential: credential, transport: DemoTransport(identity: identity, scenario: scenario, clock: clock, state: state))
    }
    let today = InventoryDay(date: clock.anchor)

    let machines = try await client().listMachines()
    try expectEqual(machines.count, DemoWorld.nodes.count, "the demo lists every node")
    try expectEqual(machines.filter(\.isProfiled).count, 30, "every node outside the home lab has a profile")
    let billing = Set(machines.map(InventoryCost.billing))
    try expectEqual(billing, Set(InventoryBilling.allCases), "the demo covers every billing category")
    let states = machines.map { InventoryRenewalState.of($0, today: today) }
    try expect(states.contains(.overdue(days: 2)) && states.contains(.dueSoon(days: 0)) && states.contains { if case .autoRenews = $0 { true } else { false } },
               "the demo covers overdue, due today and auto-renewing machines")
    try expectEqual(InventoryCost.aggregate(machines).map(\.currency), ["USD", "EUR"], "two currencies of spend")
    try expectEqual(ReminderSchedule.dueToday(machines, today: today).map(\.machine.nodeName).sorted(), ["dns-iad-1", "edge-ams-1", "edge-tyo-1", "relay-fra-1"], "four reminders due today")

    let vendors = try await client().inventoryVendors()
    try expect(vendors.contains { $0.isDerived && $0.name == "Contoso VPS" }, "a derived vendor")

    let confined = try await client(scenario: .confinedToken).listMachines()
    try expectEqual(Set(confined.map(\.nodeID)), Set(DemoWorld.confinedNodeIDs), "a confined token lists only its nodes")

    let upcoming = try await client().fetchExpiring(within: 30)
    try expect(upcoming.items.contains { $0.kind == "machine_renewal" && $0.objectID == "m-edge-tyo-1" && $0.state == "overdue" }, "Upcoming machine rows carry profile ids")
    try expectEqual(Set(upcoming.items.map(\.kind)), Set(InventoryUpcomingKind.allCases.map(\.rawValue)), "every kind in 30 days")
    try expectEqual(upcoming.hiddenKinds, [], "nothing hidden from the Operator token")
    let limited = try await client(scenario: .limitedToken).fetchExpiring(within: 30)
    try expectEqual(InventoryUpcoming.hiddenKinds(limited), ["vpn_user", "share"], "the Triage token cannot read VPN users or shares")
    try expect(!limited.items.contains { $0.kind == "vpn_user" || $0.kind == "share" }, "hidden kinds list no rows")

    let renewed = try await client().renewMachine(id: "m-edge-tyo-1", nextRenewal: today.adding(days: 29).date)
    try expectEqual(renewed.renewalDay, today.adding(days: 29), "renew answers the new day")
    let reread = try await client().listMachines()
    try expectEqual(InventoryLookup.machine("m-edge-tyo-1", in: reread)?.renewalDay, today.adding(days: 29), "the list reads the renewal back")

    let fired = try await client().inventoryRunReminders()
    try expectEqual(fired.map(\.machineID).sorted(), ["m-dns-iad-1", "m-edge-ams-1", "m-relay-fra-1"], "a renewed machine no longer fires")
    try expectEqual(fired.first { $0.machineID == "m-relay-fra-1" }?.offsetDays, 3, "the offset that fired")
    try expectEqual(try await client().inventoryRunReminders().count, 0, "a second run sends nothing again")

    let grant = StepUpGrant(grant: "grant_demo_notasecret", expiresAt: clock.anchor.addingTimeInterval(60))
    let link = try await client(.session).inventoryRevealLink(id: "m-edge-tyo-1", kind: .console, grant: grant)
    try expect(link.url.hasPrefix("https://console.northwind.example.net/"), "a console link under example.net")
    do {
        _ = try await client(.pat).inventoryRevealLink(id: "m-edge-tyo-1", kind: .console, grant: grant)
        throw CheckFailure.failed("a token reveal must be refused")
    } catch let error as LatticeAPIError {
        guard case .forbidden(let code, _) = error else { throw CheckFailure.failed("token reveal refusal: \(error)") }
        try expectEqual(code, "secret_reveal_scope_required", "a token needs secrets:reveal")
    }
    do {
        _ = try await client(.session).inventoryRevealLink(id: "m-edge-sin-1", kind: .detail, grant: grant)
        throw CheckFailure.failed("a missing detail link must fail")
    } catch let error as LatticeAPIError {
        try expectEqual(error, .notFound, "a link that is not set")
    }

    do {
        _ = try await client(scenario: .limitedToken).renewMachine(id: "m-edge-sin-1", nextRenewal: today.date)
        throw CheckFailure.failed("a Triage token cannot renew")
    } catch let error as LatticeAPIError {
        guard case .forbidden = error else { throw CheckFailure.failed("limited renew: \(error)") }
    }

    try await client().deleteMachine(id: "m-probe-sin-3")
    let afterDelete = try await client().listMachines()
    let probe = try expectUnwrapped(InventoryLookup.machine(DemoWorld.node("probe-sin-3").id, in: afterDelete), "the node stays after its profile goes")
    try expect(!probe.isProfiled, "a deleted profile leaves an unprofiled row")
}
