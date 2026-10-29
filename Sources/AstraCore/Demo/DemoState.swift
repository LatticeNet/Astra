import Foundation

/// In-memory overrides for one demo session: acknowledged incidents,
/// disabled nodes, decided approvals, filed plans. Keys are free-form so each
/// module's routes can keep their own state without editing this file.
public actor DemoState {
    private var values: [String: String] = [:]
    private var sets: [String: Set<String>] = [:]
    private var hits: [String: Int] = [:]

    public init() {}

    public func value(for key: String) -> String? {
        values[key]
    }

    public func setValue(_ value: String?, for key: String) {
        values[key] = value
    }

    public func insert(_ member: String, into set: String) {
        sets[set, default: []].insert(member)
    }

    public func remove(_ member: String, from set: String) {
        sets[set]?.remove(member)
    }

    public func contains(_ member: String, in set: String) -> Bool {
        sets[set]?.contains(member) ?? false
    }

    public func members(of set: String) -> Set<String> {
        sets[set] ?? []
    }

    /// Counts requests per key and returns the new count (1 for the first).
    public func recordHit(_ key: String) -> Int {
        hits[key, default: 0] += 1
        return hits[key] ?? 0
    }

    public func reset() {
        values = [:]
        sets = [:]
        hits = [:]
    }
}
