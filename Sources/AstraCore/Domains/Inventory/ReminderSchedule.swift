import Foundation

/// When a machine's renewal reminder fires next, read from `/api/machines`
/// alone: a port of the console's `views/fleet/reminderModel.ts`.
///
/// The schedule is the server's (`nextReminderFire` in server_inventory.go):
/// an offset fires on the first evaluation at or inside it, so in steady
/// state the next one is the largest offset not yet reached, on the day
/// `next_renewal - offset`. Past the date a machine renewed by hand is
/// reminded once a day for seven days and then left alone; an auto-roll
/// machine's date moves to the next cycle, where the schedule starts over.
/// What the phone cannot see is whether today's reminder already went out,
/// so "today" means "today's run".
public enum ReminderSchedule {
    /// What a profile without offsets of its own is given.
    public static let defaultOffsets = [14, 7, 3, 1, 0]
    /// Days a manual machine past its date keeps being reminded.
    public static let overdueRepeatDays = 7

    public struct Next: Hashable, Sendable {
        /// Days before the renewal date; -1 for an overdue repeat.
        public var offset: Int
        public var at: InventoryDay
        /// Days from today to `at`; 0 is today's run.
        public var inDays: Int
        /// The renewal date this reminder is about (the next cycle's, for an auto-roll machine past its offsets).
        public var renewal: InventoryDay
        /// Set while a manual machine is past its date: the last day it is reminded.
        public var repeatsUntil: InventoryDay?

        public init(offset: Int, at: InventoryDay, inDays: Int, renewal: InventoryDay, repeatsUntil: InventoryDay? = nil) {
            self.offset = offset
            self.at = at
            self.inDays = inDays
            self.renewal = renewal
            self.repeatsUntil = repeatsUntil
        }
    }

    /// A machine and the reminder it sends next.
    public struct Pending: Hashable, Sendable, Identifiable {
        public var machine: MachineProfile
        public var reminder: Next
        public var id: String { machine.id }
    }

    public struct Coverage: Hashable, Sendable {
        /// Machines with a renewal date and reminders on.
        public var covered: Int
        /// Machines with a renewal date whose reminders were turned off.
        public var off: Int
        /// The soonest reminder among the covered machines.
        public var next: Pending?
        /// Covered machines whose next reminder falls on the same day as `next`: one message on that run.
        public var sameDay: Int
        /// Every covered machine's next reminder, soonest first.
        public var pending: [Pending]
    }

    /// The offsets the server will use, largest first; whole days 0 to 365 only.
    public static func offsets(_ machine: MachineProfile) -> [Int] {
        Array(Set(machine.remindDaysBefore.filter { (0...365).contains($0) })).sorted(by: >)
    }

    /// One billing cycle after `day`; nil without a usable cycle.
    public static func advance(_ day: InventoryDay, cycle: String, cycleDays: Int) -> InventoryDay? {
        guard let parsed = RenewalCycle(rawValue: cycle) else { return nil }
        if let months = parsed.months { return day.adding(months: months) }
        return cycleDays > 0 ? day.adding(days: cycleDays) : nil
    }

    /// The first renewal after `today`, stepping a cycle at a time from a date
    /// that has passed; nil when `day` is still ahead or there is no cycle.
    public static func rollForwardPast(_ day: InventoryDay, cycle: String, cycleDays: Int, today: InventoryDay) -> InventoryDay? {
        guard day <= today else { return nil }
        var next = day
        for _ in 0..<1000 {
            guard let advanced = advance(next, cycle: cycle, cycleDays: cycleDays) else { return nil }
            next = advanced
            if next > today { return next }
        }
        return nil
    }

    static func firstInCycle(_ renewal: InventoryDay, offsets: [Int], today: InventoryDay) -> Next? {
        let days = today.days(until: renewal)
        guard let offset = offsets.first(where: { $0 <= days }) else { return nil }
        return Next(offset: offset, at: renewal.adding(days: -offset), inDays: days - offset, renewal: renewal)
    }

    /// The next reminder this machine will send, or nil when none is scheduled.
    public static func nextReminder(_ machine: MachineProfile, today: InventoryDay) -> Next? {
        guard machine.remindersEnabled, let renewal = machine.renewalDay else { return nil }
        let offsets = offsets(machine)
        if let inCycle = firstInCycle(renewal, offsets: offsets, today: today) { return inCycle }

        let days = today.days(until: renewal)
        if machine.autoRoll {
            let rolled = days < 0
                ? rollForwardPast(renewal, cycle: machine.renewalCycleRaw, cycleDays: machine.cycleDays, today: today)
                : advance(renewal, cycle: machine.renewalCycleRaw, cycleDays: machine.cycleDays)
            return rolled.flatMap { firstInCycle($0, offsets: offsets, today: today) }
        }

        // Renewed by hand: every offset has passed, so what is left is the
        // overdue run, daily from the day after the date for seven days.
        let repeatsUntil = renewal.adding(days: overdueRepeatDays)
        if days >= 0 {
            return Next(offset: -1, at: renewal.adding(days: 1), inDays: days + 1, renewal: renewal, repeatsUntil: repeatsUntil)
        }
        if days >= -overdueRepeatDays {
            return Next(offset: -1, at: today, inDays: 0, renewal: renewal, repeatsUntil: repeatsUntil)
        }
        return nil
    }

    public static func coverage(_ machines: [MachineProfile], today: InventoryDay) -> Coverage {
        var covered = 0
        var off = 0
        var pending: [Pending] = []
        for machine in machines where machine.isProfiled && machine.renewalDay != nil {
            guard machine.remindersEnabled else {
                off += 1
                continue
            }
            covered += 1
            if let reminder = nextReminder(machine, today: today) {
                pending.append(Pending(machine: machine, reminder: reminder))
            }
        }
        pending.sort { a, b in
            if a.reminder.inDays != b.reminder.inDays { return a.reminder.inDays < b.reminder.inDays }
            if a.reminder.renewal != b.reminder.renewal { return a.reminder.renewal < b.reminder.renewal }
            return a.machine.inventoryName.localizedStandardCompare(b.machine.inventoryName) == .orderedAscending
        }
        let next = pending.first
        let sameDay = next.map { first in pending.filter { $0.reminder.at == first.reminder.at }.count } ?? 0
        return Coverage(covered: covered, off: off, next: next, sameDay: sameDay, pending: pending)
    }

    /// The reminders today's run would send, soonest renewal first.
    public static func dueToday(_ machines: [MachineProfile], today: InventoryDay) -> [Pending] {
        coverage(machines, today: today).pending.filter { $0.reminder.inDays == 0 }
    }

    /// The first reminder after today, for "Next after today".
    public static func nextAfterToday(_ machines: [MachineProfile], today: InventoryDay) -> Pending? {
        coverage(machines, today: today).pending.first { $0.reminder.inDays > 0 }
    }

    /// What a reminder says about its machine: "renews 3 Nov, 3 days ahead",
    /// "renews today", "renewal 25 Oct passed, daily overdue reminder".
    public static func line(_ reminder: Next, today: InventoryDay, locale: Locale = .current) -> String {
        let date = reminder.renewal.formatted(locale: locale)
        let days = today.days(until: reminder.renewal)
        if days < 0 { return "Renewal \(date) passed, daily overdue reminder" }
        if days == 0 { return "Renews today, \(date)" }
        return days == 1 ? "Renews \(date), 1 day ahead" : "Renews \(date), \(days) days ahead"
    }
}
