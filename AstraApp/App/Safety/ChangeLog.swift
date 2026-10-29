import Foundation

/// A counter per kind of data (section 8.4). `ActionRunner` bumps the kinds a
/// write declares; screens key their polling on `version(_:)` and refetch at once.
@MainActor @Observable
final class ChangeLog {
    private var versions: [ChangeKind: Int] = [:]

    func version(_ kind: ChangeKind) -> Int {
        versions[kind, default: 0]
    }

    /// The sum over several kinds, for a screen that shows more than one.
    func version(_ kinds: [ChangeKind]) -> Int {
        kinds.reduce(0) { $0 + version($1) }
    }

    func record(_ kinds: [ChangeKind]) {
        for kind in kinds { versions[kind, default: 0] += 1 }
    }

    func record(_ kind: ChangeKind) {
        record([kind])
    }

    /// Every kind at once, after sign out or a credential change.
    func recordAll() {
        record(ChangeKind.allCases)
    }
}
