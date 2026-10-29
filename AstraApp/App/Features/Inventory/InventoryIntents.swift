import Foundation

/// Every Inventory write and reveal, with the tier the parity matrix gives
/// it (section 3.2): renew T2, send reminders T2, delete T4, reveal a
/// stored link S. Nothing here runs a request until ActionRunner gates it.
enum InventoryIntents {
    static func ref(_ machine: MachineProfile) -> ObjectRef {
        ObjectRef(kind: "machine", id: machine.id, name: machine.inventoryName)
    }

    /// "Record renewal of edge-tyo-1 until Nov 3, 2026": always an explicit
    /// date, so the write is idempotent and a lost answer can be re-read.
    static func renew(_ machine: MachineProfile, to day: InventoryDay, locale: Locale) -> WriteIntent {
        let id = machine.id
        let name = machine.inventoryName
        let date = day.formatted(locale: locale)
        return WriteIntent(
            tier: .t2,
            verb: "Record renewal of",
            object: ObjectRef(kind: "machine", id: id, name: "\(name) until \(date)"),
            scopes: [InventoryStore.adminScope],
            consequence: "\(name) is next due \(date), and its reminders start over for that date.",
            affected: [ref(machine)],
            verify: { client in
                let current = InventoryLookup.machine(id, in: try await client.listMachines())
                guard let now = current?.renewalDay else { return "\(name) has no renewal date." }
                return now == day ? "\(name) is now due \(date)." : "\(name) is still due \(now.formatted(locale: locale))."
            },
            idempotent: true,
            changes: [.machines, .upcoming],
            perform: { client, _ in
                let renewed = try await client.renewMachine(id: id, nextRenewal: day.date)
                return .done("Renewal recorded: \(name) is next due \(renewed.renewalDay?.formatted(locale: locale) ?? date)")
            }
        )
    }

    /// Deletes the profile; the node stays. The server has no dry run, so
    /// the profile is read again before the button enables and right before
    /// the delete, and a change in between stops it.
    static func delete(_ machine: MachineProfile, locale: Locale) -> WriteIntent {
        let id = machine.id
        let name = machine.inventoryName
        return WriteIntent(
            tier: .t4,
            verb: "Delete machine profile",
            object: ref(machine),
            scopes: [InventoryStore.adminScope],
            consequence: "Removes the price, renewal date, reminders, stored links and notes recorded for \(name). The node stays enrolled and keeps reporting. This cannot be undone.",
            affected: [ref(machine)],
            dryRun: { client in
                guard let current = try await client.listMachines().first(where: { $0.id == id }) else { return InventoryDeleteReport.gone }
                return InventoryDeleteReport.report(current, locale: locale)
            },
            verify: { client in
                try await client.listMachines().contains { $0.id == id } ? "\(name) still has a profile." : "\(name) no longer has a profile."
            },
            changes: [.machines, .upcoming],
            perform: { client, _ in
                try await client.deleteMachine(id: id)
                return .done("Deleted the machine profile of \(name)")
            }
        )
    }

    /// Sends what is due today; the server skips any reminder it already
    /// sent for the same date and offset, so the answer may list fewer.
    static func sendReminders(_ due: [ReminderSchedule.Pending], sink: InventoryFiredSink) -> WriteIntent {
        let count = due.count
        let names = due.map(\.machine.inventoryName)
        let listed = names.count <= 3 ? names.joined(separator: ", ") : "\(names.prefix(2).joined(separator: ", ")) and \(names.count - 2) more"
        return WriteIntent(
            tier: .t2,
            verb: "Send",
            object: ObjectRef(kind: "reminders", id: "today", name: count == 1 ? "1 renewal reminder" : "\(count) renewal reminders"),
            scopes: [InventoryStore.adminScope],
            consequence: "Sends today's renewal reminders for \(listed) through the notification rules that route inventory.renewal. A reminder already sent today is skipped.",
            changes: [.machines, .upcoming],
            perform: { client, _ in
                let fired = try await client.inventoryRunReminders()
                await sink.set(fired)
                switch fired.count {
                case 0: return .done("No reminder went out: today's were already sent")
                case 1: return .done("Sent 1 renewal reminder")
                default: return .done("Sent \(fired.count) renewal reminders")
                }
            }
        )
    }

    /// Reveals the provider console or detail link once, after step-up on the
    /// session. The value step opens it in an in-app browser, never `openURL`.
    static func revealLink(_ machine: MachineProfile, kind: InventoryLinkKind) -> RevealIntent {
        let id = machine.id
        let name = machine.inventoryName
        return RevealIntent(
            purpose: kind == .console ? .machineLink : .other(secretName: "detail link"),
            object: ref(machine),
            scopes: [InventoryStore.adminScope]
        ) { client, grant in
            let reveal = try await client.inventoryRevealLink(id: id, kind: kind, grant: grant)
            return RevealedSecret(title: "\(kind == .console ? "Console" : "Detail") link for \(name)", value: reveal.url, kind: .consoleLink)
        }
    }
}
