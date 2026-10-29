import Foundation

/// The one shape every data-backed screen binds to (sections 5.0 and 8.3).
public enum ResourceState<Value: Sendable>: Sendable {
    case idle
    case loading(previous: Value?, previousAt: Date?)
    case loaded(Value, at: Date)
    case failed(LatticeAPIError, last: Value?, lastAt: Date?)
    case denied(scope: String)
    case companionBehind(surface: String)

    /// The newest value this state still carries, if any.
    public var value: Value? {
        switch self {
        case .loading(let previous, _): previous
        case .loaded(let value, _): value
        case .failed(_, let last, _): last
        case .idle, .denied, .companionBehind: nil
        }
    }

    /// When `value` was loaded.
    public var loadedAt: Date? {
        switch self {
        case .loading(_, let at): at
        case .loaded(_, let at): at
        case .failed(_, _, let at): at
        case .idle, .denied, .companionBehind: nil
        }
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// The loading state that keeps whatever this state had.
    public var reloading: ResourceState<Value> {
        .loading(previous: value, previousAt: loadedAt)
    }

    /// The state after `error`, keeping the last good value. A 403 drops the
    /// value so nothing stale looks current (6.7), and an undecodable body
    /// reads as companion behind for `surface`.
    public func failing(_ error: LatticeAPIError, surface: String) -> ResourceState<Value> {
        switch error {
        case .forbidden(_, let scope):
            .denied(scope: scope ?? "")
        case .invalidResponse:
            .companionBehind(surface: surface)
        default:
            .failed(error, last: value, lastAt: loadedAt)
        }
    }
}
