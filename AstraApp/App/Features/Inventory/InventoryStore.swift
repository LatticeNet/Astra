import Foundation
import UIKit

/// The machines list and the 30-day Upcoming read (M5-01, M5-05), created
/// by StoreRegistry and read from the environment.
@MainActor @Observable
final class InventoryStore {
    nonisolated static let readScope = "inventory:read"
    nonisolated static let adminScope = "inventory:admin"
    /// Each Upcoming kind needs its own list's read scope; any one opens the screen.
    nonisolated static let upcomingRequirement = ScopeRequirement.anyOf("inventory:read", "proxy:read", "proxy:admin", "monitor:read")

    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let changes: ChangeLog

    private(set) var machines: ResourceState<[MachineProfile]> = .idle
    private(set) var expiring: ResourceState<ExpiringResponse> = .idle
    private(set) var vendors: [InventoryVendor] = []
    /// Node group names by id, for the Group grouping; empty without group:read.
    private(set) var groupNames: [String: String] = [:]

    /// A poll that would move, add or remove rows while the list is in use waits here (section 5.0).
    private(set) var held: [MachineProfile]?
    private(set) var heldForVoiceOver = false
    @ObservationIgnored var interactionBusy = false
    @ObservationIgnored private var lastInteraction = Date.distantPast
    @ObservationIgnored private var releaseTask: Task<Void, Never>?

    init(session: SessionStore, changes: ChangeLog) {
        self.session = session
        self.changes = changes
    }

    /// The scope a write lacks ("inventory:admin"), or nil when it is held or not known yet.
    func missing(_ scope: String, on kind: ClientKind = .primary) -> String? {
        guard let missing = session.missing(ScopeRequirement(scope), on: kind), !missing.isEmpty else { return nil }
        return missing.joined(separator: ", ")
    }

    var adminMissing: String? { missing(Self.adminScope) }

    /// The reveal runs on the signed-in session (S tier), so only the
    /// session's scopes gate it. Without a session the reveal flow offers
    /// sign in, so nothing is missing yet.
    var revealMissing: String? { missing(Self.adminScope, on: .session) }

    var allowlist: [String] { session.primaryIdentity?.serverAllowlist ?? [] }
    var isConfined: Bool { session.primaryIdentity?.scopeSet.isConfined ?? false }

    func machine(id: String) -> MachineProfile? {
        InventoryLookup.machine(id, in: machines.value ?? [])
    }

    func vendor(named name: String) -> InventoryVendor? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return vendors.first { $0.name.lowercased() == key }
    }

    // MARK: Reads

    @discardableResult
    func refresh(fromPoll: Bool = false) async -> Bool {
        if let missing = session.missing(ScopeRequirement(Self.readScope)), !missing.isEmpty {
            machines = .denied(scope: missing.joined(separator: " and "))
            // Upcoming still opens for a token that reads only VPN users or certificates.
            await refreshUpcoming()
            return true
        }
        guard let client = session.client else { return false }
        machines = machines.reloading
        let writeVersion = changes.version([.machines, .upcoming, .nodes, .groups])
        async let vendorsRead = readVendors(client)
        async let namesRead = readGroupNames(client)
        async let upcomingRead = refreshUpcoming()
        var ok = true
        do {
            apply(try await client.listMachines(), fromPoll: fromPoll, writeVersion: writeVersion)
        } catch {
            let apiError = LatticeAPIError(error)
            machines = machines.failing(apiError, surface: "Machines", missingScope: Self.readScope)
            if case .forbidden = apiError { session.noteForbidden() }
            ok = false
        }
        if let list = await vendorsRead { vendors = list }
        if let names = await namesRead { groupNames = names }
        _ = await upcomingRead
        return ok
    }

    /// `GET /api/expiring?within=30`, for the Machines header row and Upcoming.
    @discardableResult
    func refreshUpcoming() async -> Bool {
        if let missing = session.missing(Self.upcomingRequirement), !missing.isEmpty {
            expiring = .denied(scope: "any of inventory:read, proxy:read, proxy:admin or monitor:read")
            return true
        }
        guard let client = session.client else { return false }
        expiring = expiring.reloading
        do {
            expiring = .loaded(try await client.fetchExpiring(within: InventoryUpcoming.withinDays), at: Date())
            return true
        } catch {
            let apiError = LatticeAPIError(error)
            expiring = expiring.failing(apiError, surface: "Upcoming", missingScope: Self.readScope)
            if case .forbidden = apiError { session.noteForbidden() }
            return false
        }
    }

    private func readVendors(_ client: LatticeClient) async -> [InventoryVendor]? {
        try? await client.inventoryVendors()
    }

    private func readGroupNames(_ client: LatticeClient) async -> [String: String]? {
        guard session.missing(ScopeRequirement("group:read"))?.isEmpty ?? true,
              let groups = try? await client.fleetGroups() else { return nil }
        return Dictionary(groups.groups.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Stable list

    func noteInteraction() {
        lastInteraction = Date()
    }

    private var isIdle: Bool {
        !interactionBusy && Date().timeIntervalSince(lastInteraction) >= 2
    }

    /// Where a row sits on Machines: its section and its place in it.
    struct Slot: Hashable {
        var section: String
        var index: Int
    }

    /// Slots by row key under the grouping, filter and sort the operator
    /// chose on Machines; InventoryScreen sets it. Until then rows sit in
    /// server order.
    @ObservationIgnored var layout: @MainActor ([MachineProfile], [String: String]) -> [String: Slot] = { list, _ in
        Dictionary(list.enumerated().map { (InventoryStore.rowKey($1), Slot(section: "", index: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    nonisolated static func rowKey(_ machine: MachineProfile) -> String {
        machine.id.isEmpty ? machine.nodeID : machine.id
    }

    /// The ChangeLog version the last applied read saw; a newer one means
    /// the read follows a confirmed write, which applies at once.
    @ObservationIgnored private var appliedWriteVersion: Int?

    private func apply(_ fresh: [MachineProfile], fromPoll: Bool, writeVersion: Int) {
        let current = machines.value
        let followsWrite = appliedWriteVersion.map { $0 != writeVersion } ?? false
        appliedWriteVersion = writeVersion
        let oldSlots = current.map { layout($0, groupNames) }
        let newSlots = layout(fresh, groupNames)
        // Only a change of section, order or membership is a move; a value
        // inside a row that stays put applies at once (section 5.0).
        let moves = oldSlots.map { $0 != newSlots } ?? false
        let voiceOver = UIAccessibility.isVoiceOverRunning
        if fromPoll, !followsWrite, moves, voiceOver || !isIdle, let current, let oldSlots {
            held = fresh
            heldForVoiceOver = voiceOver
            let byKey = Dictionary(fresh.map { (Self.rowKey($0), $0) }, uniquingKeysWith: { first, _ in first })
            machines = .loaded(current.map { old in
                let key = Self.rowKey(old)
                guard let row = byKey[key], newSlots[key] == oldSlots[key] else { return old }
                return row
            }, at: Date())
            if !voiceOver { releaseWhenIdle() }
        } else {
            held = nil
            heldForVoiceOver = false
            machines = .loaded(fresh, at: Date())
        }
    }

    private func releaseWhenIdle() {
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.held != nil, !self.heldForVoiceOver else { return }
                if self.isIdle {
                    self.showHeld()
                    return
                }
            }
        }
    }

    func showHeld() {
        guard let held else { return }
        self.held = nil
        heldForVoiceOver = false
        machines = .loaded(held, at: Date())
    }

    /// Rows a held update would move, add or remove.
    var heldCount: Int {
        guard let held, let current = machines.value else { return 0 }
        let old = layout(current, groupNames)
        let new = layout(held, groupNames)
        let keys = Set(old.keys).union(new.keys)
        let changed = keys.filter { old[$0]?.section != new[$0]?.section }.count
        return max(changed, 1)
    }

    /// True when a held update would change the row Machine detail shows for `id`.
    func holdsChange(for id: String) -> Bool {
        guard let held, let shown = machine(id: id) else { return false }
        return InventoryLookup.machine(id, in: held) != shown
    }
}
