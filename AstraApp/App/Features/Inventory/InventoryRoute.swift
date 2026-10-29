import SwiftUI

/// M5 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M5 may add cases but must not rename or remove these.
enum InventoryRoute: Hashable, Codable, Sendable {
    case machine(id: String)
    case upcoming
}

/// M5's demo intents and sheets for `-AstraPresent`:
/// `confirm:inventory.renew:<machineID>`, `confirm:inventory.delete:<machineID>`,
/// `confirm:inventory.reminders`, `reveal:inventory.console:<machineID>`,
/// `reveal:inventory.detail:<machineID>`, the global `renew:<machineID>`, and
/// the module sheet `reminders`. Machine ids are the demo's `m-<node name>`.
extension InventoryRoute: DemoHooks {
    static func demoIntent(_ id: String, session: SessionStore) -> WriteIntent? {
        guard session.isDemo, id.hasPrefix("inventory.") else { return nil }
        let parts = id.dropFirst("inventory.".count).split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        let locale = Locale.current
        switch parts[0] {
        case "renew":
            guard let machine = demoProfile(argument), let current = machine.renewalDay else { return nil }
            let next = ReminderSchedule.advance(current, cycle: machine.renewalCycleRaw, cycleDays: machine.cycleDays) ?? current.adding(days: 30)
            return InventoryIntents.renew(machine, to: next, locale: locale)
        case "delete":
            return demoProfile(argument).map { InventoryIntents.delete($0, locale: locale) }
        case "reminders":
            let machines = InventoryFixtures.machines.compactMap { demoProfile($0.id) }
            return InventoryIntents.sendReminders(ReminderSchedule.dueToday(machines, today: InventoryDay(date: Date())), sink: InventoryFiredSink())
        default:
            return nil
        }
    }

    static func demoReveal(_ id: String) -> RevealIntent? {
        guard id.hasPrefix("inventory.") else { return nil }
        let parts = id.dropFirst("inventory.".count).split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = InventoryLinkKind(rawValue: parts[0]), let machine = demoProfile(parts[1]) else { return nil }
        return InventoryIntents.revealLink(machine, kind: kind)
    }

    static func demoSheet(_ name: String, argument: String?) -> AnyView? {
        name == "reminders" ? AnyView(RemindersSheet()) : nil
    }

    /// A demo machine as the list would decode it, renewal dates counted from now.
    private static func demoProfile(_ id: String) -> MachineProfile? {
        guard let fixture = InventoryFixtures.machine(id: id) else { return nil }
        return MachineProfile(
            id: fixture.id, nodeID: fixture.world.id, nodeName: fixture.world.name, label: fixture.label,
            online: fixture.world.isReporting, vendor: fixture.vendor, region: fixture.region, notes: fixture.notes,
            hasConsoleURL: fixture.console, hasDetailURL: fixture.detail,
            priceCents: Int64(fixture.priceCents), currency: fixture.priceCents > 0 ? fixture.currency : "",
            renewalCycleRaw: fixture.cycle, cycleDays: fixture.cycleDays,
            nextRenewal: fixture.renews.map { Date().addingTimeInterval(Double($0) * 86_400) },
            autoRoll: fixture.autoRoll, remindDaysBefore: fixture.reminders ? fixture.offsets : [],
            remindersEnabled: fixture.reminders && fixture.renews != nil
        )
    }
}
