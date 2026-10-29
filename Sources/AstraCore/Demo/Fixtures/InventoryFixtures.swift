import Foundation

/// Demo routes for the Inventory domain, owned by the Inventory module (section 8.6).
///
/// Every node outside the home lab has a machine profile with invented
/// vendors, prices and renewal dates; the home lab nodes are listed without
/// one, as the server lists every node it can read. Renewals, deletes and
/// reminder runs change `DemoState`, so the list reads them back.
public enum InventoryFixtures {
    /// One invented machine profile, its renewal given as days from the demo clock.
    public struct Machine: Sendable, Hashable {
        public var node: String
        public var label = ""
        public var vendor: String
        public var region: String
        public var priceCents: Int = 0
        public var currency = "USD"
        public var cycle = ""
        public var cycleDays = 0
        /// Days from now to the next renewal; nil for none.
        public var renews: Int?
        public var autoRoll = false
        public var reminders = true
        public var offsets = ReminderSchedule.defaultOffsets
        public var console = true
        public var detail = false
        public var notes = ""
        public var purchased: Int?

        public var id: String { "m-\(node)" }
        public var world: DemoWorldNode { DemoWorld.node(node) }
    }

    public static let machines: [Machine] = [
        Machine(node: "edge-tyo-1", vendor: "Northwind Cloud", region: "Tokyo", priceCents: 1_200, cycle: "monthly", renews: -2, detail: true,
                notes: "Card on file expired; pay the invoice in the provider panel."),
        Machine(node: "edge-tyo-2", vendor: "Northwind Cloud", region: "Tokyo", priceCents: 1_200, cycle: "monthly", renews: 19, autoRoll: true),
        Machine(node: "edge-tyo-3", vendor: "Northwind Cloud", region: "Tokyo", priceCents: 1_200, cycle: "monthly", renews: 19, autoRoll: true),
        Machine(node: "relay-tyo-1", vendor: "Northwind Cloud", region: "Tokyo", priceCents: 3_600, cycle: "quarterly", renews: 47, detail: true),
        Machine(node: "dns-tyo-1", vendor: "Northwind Cloud", region: "Tokyo", priceCents: 600, cycle: "monthly", renews: 25, autoRoll: true),
        Machine(node: "edge-sin-1", vendor: "Northwind Cloud", region: "Singapore", priceCents: 1_000, cycle: "monthly", renews: 6),
        Machine(node: "edge-sin-2", vendor: "Northwind Cloud", region: "Singapore", priceCents: 1_000, cycle: "monthly", renews: 21, autoRoll: true),
        Machine(node: "probe-sin-3", label: "Probe (sponsored)", vendor: "Northwind Cloud", region: "Singapore", reminders: false, console: false,
                notes: "Donated credit; nothing is billed."),
        Machine(node: "relay-hkg-1", vendor: "Contoso VPS", region: "Hong Kong", priceCents: 2_000, cycle: "monthly", renews: 33),
        Machine(node: "edge-hkg-2", vendor: "Contoso VPS", region: "Hong Kong", priceCents: 1_500, cycle: "monthly", renews: 9),
        Machine(node: "relay-fra-1", vendor: "Fabrikam Hosting", region: "Frankfurt", priceCents: 2_400, currency: "EUR", cycle: "monthly", renews: 3, detail: true),
        Machine(node: "relay-fra-2", vendor: "Fabrikam Hosting", region: "Frankfurt", priceCents: 24_000, currency: "EUR", cycle: "annual", renews: 142, purchased: 223),
        Machine(node: "edge-fra-3", vendor: "Fabrikam Hosting", region: "Frankfurt", priceCents: 900, currency: "EUR", cycle: "monthly", renews: 16, autoRoll: true),
        Machine(node: "dns-fra-1", vendor: "Fabrikam Hosting", region: "Frankfurt", priceCents: 500, currency: "EUR", cycle: "monthly", renews: 16, autoRoll: true),
        Machine(node: "build-fra-4", label: "Build box", vendor: "Fabrikam Hosting", region: "Frankfurt", priceCents: 45_000, currency: "EUR", reminders: false,
                notes: "Dedicated server bought outright; colocation is billed with relay-fra-2.", purchased: 410),
        Machine(node: "edge-ams-1", vendor: "Fabrikam Hosting", region: "Amsterdam", priceCents: 900, currency: "EUR", cycle: "monthly", renews: 14),
        Machine(node: "edge-ams-2", vendor: "Fabrikam Hosting", region: "Amsterdam", priceCents: 900, currency: "EUR", cycle: "monthly", renews: 28, autoRoll: true),
        Machine(node: "probe-ams-3", vendor: "Fabrikam Hosting", region: "Amsterdam", priceCents: 300, currency: "EUR", cycle: "custom_days", cycleDays: 60, renews: 40),
        Machine(node: "backup-ams-4", vendor: "Fabrikam Hosting", region: "Amsterdam", priceCents: 1_800, currency: "EUR", cycle: "quarterly", reminders: false,
                notes: "Storage box; renewal date not entered yet."),
        Machine(node: "edge-lon-1", vendor: "Tailspin Metal", region: "London", priceCents: 1_100, cycle: "monthly", renews: 11),
        Machine(node: "core-lon-1", vendor: "Tailspin Metal", region: "London", priceCents: 4_900, cycle: "monthly", renews: 12, autoRoll: true, detail: true),
        Machine(node: "edge-iad-1", vendor: "Contoso VPS", region: "Ashburn", priceCents: 1_200, cycle: "monthly", renews: 23, autoRoll: true),
        Machine(node: "edge-iad-2", vendor: "Contoso VPS", region: "Ashburn", priceCents: 1_200, cycle: "monthly", renews: 23, autoRoll: true),
        Machine(node: "relay-iad-3", vendor: "Contoso VPS", region: "Ashburn", priceCents: 12_000, cycle: "annual", renews: 201, reminders: false, purchased: 164),
        Machine(node: "dns-iad-1", vendor: "Contoso VPS", region: "Ashburn", priceCents: 600, cycle: "monthly", renews: 0),
        Machine(node: "edge-sjc-1", vendor: "Tailspin Metal", region: "San Jose", priceCents: 1_100, cycle: "monthly", renews: 30),
        Machine(node: "edge-sjc-2", vendor: "Tailspin Metal", region: "San Jose", priceCents: 1_100, cycle: "monthly", renews: 30, autoRoll: true),
        Machine(node: "core-sjc-1", vendor: "Tailspin Metal", region: "San Jose", priceCents: 52_800, cycle: "annual", renews: 260, reminders: false, detail: true, purchased: 105),
        Machine(node: "edge-syd-1", vendor: "Northwind Cloud", region: "Sydney", priceCents: 1_400, cycle: "monthly", renews: 18),
        Machine(node: "relay-syd-2", vendor: "Northwind Cloud", region: "Sydney", cycle: "monthly", renews: 26),
    ]

    /// Vendors saved on their own; Contoso VPS is only named by profiles, so the server derives it.
    static let vendors: [DemoJSON] = [
        .object(["id": "vendor_northwind", "name": "Northwind Cloud", "url": "https://northwind.example.net",
                 "description": "Cloud VPS, billed monthly to the operations card.", "created_at": .time("-400d"), "updated_at": .time("-30d")]),
        .object(["id": "vendor_fabrikam", "name": "Fabrikam Hosting", "url": "https://fabrikam.example.org",
                 "description": "Dedicated and VPS in Frankfurt and Amsterdam, invoiced in EUR.", "created_at": .time("-380d"), "updated_at": .time("-90d")]),
        .object(["id": "vendor_tailspin", "name": "Tailspin Metal", "url": "https://tailspin.example.net", "created_at": .time("-300d"), "updated_at": .time("-300d")]),
    ]

    static func vendorJSON(named name: String) -> DemoJSON? {
        vendors.first { vendor in
            guard case .object(let pairs) = vendor, case .string(let vendorName)? = pairs.first(where: { $0.0 == "name" })?.1 else { return false }
            return vendorName == name
        }
    }

    public static func machine(id: String) -> Machine? {
        machines.first { $0.id == id || $0.world.id == id }
    }

    static let renewedKey = "inventory.renewed."
    static let deletedSet = "inventory.deleted"
    static let firedSet = "inventory.fired"

    // MARK: Routes

    public static let routes: [DemoRoute] = [
        DemoRoute(pathPattern: "/api/machines", body: machinesBody(renewed: [:], deleted: [], visible: nil)) { request, state in
            .json(await machinesAnswer(request, state))
        }.requiring("inventory:read"),
        DemoRoute(pathPattern: "/api/machine-vendors", body: vendorsBody(), emptyBody: #"{"vendors":[]}"#).requiring("inventory:read"),
        DemoRoute(method: "POST", pathPattern: "/api/machines/renew") { request, state in
            await renewAnswer(request, state)
        }.requiring("inventory:admin"),
        DemoRoute(method: "POST", pathPattern: "/api/machines/delete") { request, state in
            let id = request.bodyStrings["id"] ?? ""
            if machine(id: id) != nil { await state.insert(id, into: deletedSet) }
            return .json(#"{"ok":true}"#)
        }.requiring("inventory:admin"),
        DemoRoute(method: "POST", pathPattern: "/api/machines/reminders/run") { request, state in
            await remindersAnswer(request, state)
        }.requiring("inventory:admin"),
        DemoRoute(method: "POST", pathPattern: "/api/machines/reveal-link") { request, state in
            await revealAnswer(request, state)
        }.requiring("inventory:admin"),
        // Upcoming reads 30 days; this answer carries the profiles above and the
        // kinds the token cannot read. Inbox's 7-day read stays on the shared route.
        DemoRoute(pathPattern: "/api/expiring", query: ["within": "30"], body: SharedFixtures.expiringBody(within: 30),
                  emptyBody: #"{"generated_at":"{{now}}","within_days":30,"items":[],"totals":[],"hidden_kinds":[]}"#) { request, state in
            .json(await expiringAnswer(request, state))
        },
    ]

    // MARK: Machines

    static func visibleNodeIDs(_ request: DemoRequest) -> Set<String>? {
        let scopes = DemoTransport.scopes(for: request.identity, scenario: request.scenario)
        return scopes.isConfined ? Set(scopes.serverAllowlist) : nil
    }

    static func overrides(_ state: DemoState) async -> (renewed: [String: String], deleted: Set<String>) {
        var renewed: [String: String] = [:]
        for fixture in machines {
            if let day = await state.value(for: renewedKey + fixture.id) { renewed[fixture.id] = day }
        }
        return (renewed, await state.members(of: deletedSet))
    }

    static func machinesAnswer(_ request: DemoRequest, _ state: DemoState) async -> String {
        let (renewed, deleted) = await overrides(state)
        return machinesBody(renewed: renewed, deleted: deleted, visible: visibleNodeIDs(request))
    }

    /// The server's order: by node name, profiled or not.
    static func machinesBody(renewed: [String: String], deleted: Set<String>, visible: Set<String>?) -> String {
        let profiled = Dictionary(uniqueKeysWithValues: machines.filter { !deleted.contains($0.id) }.map { ($0.world.id, $0) })
        let rows = DemoWorld.nodes
            .filter { visible?.contains($0.id) ?? true }
            .sorted { $0.name < $1.name }
            .map { node in
                profiled[node.id].map { machineJSON($0, renewedDay: renewed[$0.id]) } ?? unprofiledJSON(node)
            }
        return DemoJSON.array(rows).text
    }

    static func hostFacts(_ node: DemoWorldNode) -> DemoJSON? {
        guard node.lastSeen != nil else { return nil }
        return .object([
            "hostname": .string(node.hostname),
            "os": node.platform == "darwin" ? "darwin" : "linux",
            "platform": .string(node.platform),
            "platform_version": .string(node.platformVersion),
            "arch": .string(node.arch),
            "cpu_cores": .number(Double(node.cpuCores)),
            "memory_total": .number(Double(node.memoryGiB) * 1_073_741_824),
        ])
    }

    static func unprofiledJSON(_ node: DemoWorldNode) -> DemoJSON {
        .object([
            "node_id": .string(node.id),
            "node_name": .string(node.name),
            "online": .bool(node.isReporting),
            "host_facts": hostFacts(node) ?? .object([:]),
            "has_console_url": false,
            "has_detail_url": false,
            "auto_roll": false,
            "reminders_enabled": false,
        ])
    }

    static func machineJSON(_ fixture: Machine, renewedDay: String?) -> DemoJSON {
        let node = fixture.world
        let renewal: DemoJSON? = renewedDay.map { .string($0) } ?? fixture.renews.map { .time($0 >= 0 ? "+\($0)d" : "\($0)d") }
        let days: DemoJSON? = renewedDay == nil ? fixture.renews.map { .number(Double($0)) } : nil
        return .object([
            "id": .string(fixture.id),
            "node_id": .string(node.id),
            "node_name": .string(node.name),
            "label": fixture.label.isEmpty ? nil : .string(fixture.label),
            "online": .bool(node.isReporting),
            "host_facts": hostFacts(node) ?? .object([:]),
            "vendor": .string(fixture.vendor),
            "vendor_profile": vendorJSON(named: fixture.vendor),
            "region": .string(fixture.region),
            "has_console_url": .bool(fixture.console),
            "has_detail_url": .bool(fixture.detail),
            "notes": fixture.notes.isEmpty ? nil : .string(fixture.notes),
            "price_cents": fixture.priceCents > 0 ? .number(Double(fixture.priceCents)) : nil,
            "currency": fixture.priceCents > 0 ? .string(fixture.currency) : nil,
            "purchased_at": fixture.purchased.map { .time("-\($0)d") },
            "renewal_cycle": fixture.cycle.isEmpty ? nil : .string(fixture.cycle),
            "cycle_days": fixture.cycleDays > 0 ? .number(Double(fixture.cycleDays)) : nil,
            "next_renewal": renewal,
            "days_until_renewal": days,
            "auto_roll": .bool(fixture.autoRoll),
            "remind_days_before": fixture.reminders ? .array(fixture.offsets.map { .number(Double($0)) }) : nil,
            "reminders_enabled": .bool(fixture.reminders && fixture.renews != nil),
            "created_at": .time("-\(fixture.purchased ?? 200)d"),
            "updated_at": .time("-\(abs(fixture.node.hashValueStable) % 40 + 1)d"),
        ])
    }

    static func vendorsBody() -> String {
        let derived: DemoJSON = .object(["id": "derived:contoso vps", "name": "Contoso VPS", "created_at": "0001-01-01T00:00:00Z", "updated_at": "0001-01-01T00:00:00Z"])
        return DemoJSON.object(["vendors": .array([vendors[0], derived, vendors[1], vendors[2]])]).text
    }

    // MARK: Writes

    static func renewAnswer(_ request: DemoRequest, _ state: DemoState) async -> DemoResponse {
        let id = request.bodyStrings["id"] ?? ""
        guard let fixture = machine(id: id), await !state.contains(fixture.id, in: deletedSet) else {
            return .error(status: 404, code: "not_found", message: "machine profile not found")
        }
        let raw = request.bodyStrings["next_renewal"] ?? ""
        guard let day = InventoryDay(String(raw.prefix(10))) else {
            return .error(status: 400, code: "bad_request", message: "next_renewal is required when auto_roll is disabled")
        }
        let stored = "\(day)T00:00:00Z"
        await state.setValue(stored, for: renewedKey + fixture.id)
        return .json(machineJSON(fixture, renewedDay: stored).text)
    }

    /// Which fixtures today's run fires, read on a fixed reference day so the
    /// relative renewal offsets decide it whatever the demo clock says.
    static func firingToday(renewed: [String: String], deleted: Set<String>) -> [(Machine, Int)] {
        let reference = InventoryDay("2000-01-01")!
        return machines.compactMap { fixture in
            guard !deleted.contains(fixture.id), renewed[fixture.id] == nil, fixture.reminders, let renews = fixture.renews else { return nil }
            let profile = MachineProfile(
                id: fixture.id, nodeID: fixture.world.id, renewalCycleRaw: fixture.cycle, cycleDays: fixture.cycleDays,
                nextRenewal: reference.adding(days: renews).date, autoRoll: fixture.autoRoll,
                remindDaysBefore: fixture.offsets, remindersEnabled: true
            )
            guard let next = ReminderSchedule.nextReminder(profile, today: reference), next.inDays == 0 else { return nil }
            // The server keys an overdue repeat by how many days overdue it is.
            return (fixture, next.offset < 0 ? renews : next.offset)
        }
    }

    static func remindersAnswer(_ request: DemoRequest, _ state: DemoState) async -> DemoResponse {
        let only = request.bodyStrings["id"] ?? ""
        if !only.isEmpty, machine(id: only) == nil {
            return .error(status: 400, code: "bad_request", message: "machine profile not found")
        }
        let (renewed, deleted) = await overrides(state)
        let fired = await state.members(of: firedSet)
        var rows: [DemoJSON] = []
        for (fixture, offset) in firingToday(renewed: renewed, deleted: deleted) where !fired.contains(fixture.id) {
            if !only.isEmpty, fixture.id != only { continue }
            await state.insert(fixture.id, into: firedSet)
            rows.append(.object([
                "machine_id": .string(fixture.id),
                "node_id": .string(fixture.world.id),
                "node_name": .string(fixture.world.name),
                "offset_days": .number(Double(offset)),
                "next_renewal": .time(fixture.renews! >= 0 ? "+\(fixture.renews!)d" : "\(fixture.renews!)d"),
            ]))
        }
        return .json(DemoJSON.object(["fired": .array(rows)]).text)
    }

    static func revealAnswer(_ request: DemoRequest, _ state: DemoState) async -> DemoResponse {
        guard request.identity == .session else {
            return .error(status: 403, code: "secret_reveal_scope_required", message: "revealing a secret with a token needs secrets:reveal")
        }
        guard !(request.bodyStrings["step_up_grant"] ?? "").isEmpty else {
            return .error(status: 403, code: "step_up_required", message: "step-up required")
        }
        let id = request.bodyStrings["id"] ?? ""
        guard let fixture = machine(id: id), await !state.contains(fixture.id, in: deletedSet) else {
            return .error(status: 404, code: "not_found", message: "machine profile not found")
        }
        let kind = request.bodyStrings["kind"] ?? ""
        let host = fixture.vendor.lowercased().split(separator: " ").first.map(String.init) ?? "panel"
        let url: String? = switch kind {
        case "console": fixture.console ? "https://console.\(host).example.net/servers/\(fixture.node)" : nil
        case "detail": fixture.detail ? "https://billing.\(host).example.net/services/\(fixture.node)" : nil
        default: nil
        }
        guard ["console", "detail"].contains(kind) else {
            return .error(status: 400, code: "bad_request", message: "kind must be console or detail")
        }
        guard let url else { return .error(status: 404, code: "not_found", message: "link is not set") }
        return .json(DemoJSON.object(["ok": true, "id": .string(fixture.id), "kind": .string(kind), "url": .string(url)]).text)
    }

    // MARK: Upcoming

    static func expiringAnswer(_ request: DemoRequest, _ state: DemoState) async -> String {
        let scopes = DemoTransport.scopes(for: request.identity, scenario: request.scenario)
        let unrestricted = !scopes.isConfined
        let readable: [String: Bool] = [
            "machine_renewal": scopes.allows("inventory:read"),
            "vpn_user": unrestricted && scopes.allows("proxy:read"),
            "share": unrestricted && scopes.allows("proxy:admin"),
            "tls_certificate": scopes.allows("monitor:read"),
        ]
        let (renewed, deleted) = await overrides(state)
        let visible = visibleNodeIDs(request)

        var items: [(days: Int, title: String, json: DemoJSON)] = []
        if readable["machine_renewal"] == true {
            for fixture in machines where !deleted.contains(fixture.id) && (visible?.contains(fixture.world.id) ?? true) {
                guard renewed[fixture.id] == nil, let renews = fixture.renews else { continue }
                var days = renews
                if fixture.autoRoll, days < 0 { days += 30 }
                guard days <= 30 else { continue }
                let state = fixture.autoRoll ? "auto" : (days < 0 ? "overdue" : (days <= 7 ? "due" : "upcoming"))
                let title = fixture.label.isEmpty ? fixture.node : fixture.label
                items.append((days, title, .object([
                    "kind": "machine_renewal",
                    "id": .string(fixture.id),
                    "title": .string(title),
                    "subtitle": .string("\(fixture.vendor) · \(fixture.region)"),
                    "due_at": .time(days >= 0 ? "+\(days)d" : "\(days)d"),
                    "days": .number(Double(days)),
                    "state": .string(state),
                    "cost_cents": .number(Double(fixture.priceCents)),
                    "currency": fixture.priceCents > 0 ? .string(fixture.currency) : "",
                    "reminder": .object(["enabled": .bool(fixture.reminders)]),
                    "href": .string("/inventory?machine=\(fixture.id)"),
                ])))
            }
        }
        // The other kinds come from the shared answer, as the server lists them.
        if let data = SharedFixtures.expiringBody(within: 30).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let shared = object["items"] as? [[String: Any]] {
            for item in shared {
                let kind = item["kind"] as? String ?? ""
                guard kind != "machine_renewal", readable[kind] == true,
                      let json = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]),
                      let text = String(data: json, encoding: .utf8) else { continue }
                items.append(((item["days"] as? Int) ?? 0, item["title"] as? String ?? "", .raw(text)))
            }
        }
        items.sort { $0.days != $1.days ? $0.days < $1.days : $0.title < $1.title }

        var totals: [String: (cents: Int, count: Int)] = [:]
        for fixture in machines where !deleted.contains(fixture.id) && renewed[fixture.id] == nil && readable["machine_renewal"] == true {
            guard let renews = fixture.renews, renews <= 30, fixture.priceCents > 0, visible?.contains(fixture.world.id) ?? true else { continue }
            totals[fixture.currency, default: (0, 0)].cents += fixture.priceCents
            totals[fixture.currency, default: (0, 0)].count += 1
        }
        let hidden = ["machine_renewal", "vpn_user", "share", "tls_certificate"].filter { readable[$0] != true }
        return DemoJSON.object([
            "generated_at": .time(),
            "within_days": 30,
            "items": .array(items.map(\.json)),
            "totals": .array(totals.keys.sorted().map { code in
                .object(["currency": .string(code), "cost_cents": .number(Double(totals[code]!.cents)), "count": .number(Double(totals[code]!.count))])
            }),
            "hidden_kinds": .strings(hidden),
        ]).text
    }
}

private extension String {
    /// A hash that is the same on every launch, unlike `hashValue`.
    var hashValueStable: Int {
        unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
    }
}
