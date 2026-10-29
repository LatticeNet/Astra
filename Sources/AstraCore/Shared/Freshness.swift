import Foundation

/// Whether data on screen can still be trusted (sections 4.2 and 6.11).
public enum Freshness: Sendable, Equatable {
    case fresh
    case stale(since: Date?)
    case unknown

    /// Stale when `now - loadedAt > 3 * interval` or the last attempt failed.
    public static func of<Value>(_ state: ResourceState<Value>, now: Date, interval: TimeInterval) -> Freshness {
        switch state {
        case .loaded(_, let at):
            return now.timeIntervalSince(at) > 3 * interval ? .stale(since: at) : .fresh
        case .loading(let previous, let at):
            guard previous != nil, let at else { return .unknown }
            return now.timeIntervalSince(at) > 3 * interval ? .stale(since: at) : .fresh
        case .failed(_, _, let at):
            return .stale(since: at)
        case .idle, .denied, .companionBehind:
            return .unknown
        }
    }

    public var isStale: Bool {
        if case .stale = self { return true }
        return false
    }
}
