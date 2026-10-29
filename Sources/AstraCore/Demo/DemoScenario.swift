import Foundation

/// The token preset `-AstraDemoToken <name>` puts on the demo PAT, whatever
/// the scenario, so Failing, Stale, Empty or Companion behind can be shown on
/// screens a scope gates. It overrides the token a token scenario would set.
/// A confined token is not offered: its fixtures key on the scenario.
public enum DemoToken: String, Sendable, Hashable, CaseIterable {
    case triage, `operator`, root, admin

    /// Parses "triage", "operator", "root" or "admin" ("full-admin" too).
    public init?(argument: String) {
        switch argument.lowercased() {
        case "triage", "limited": self = .triage
        case "operator": self = .operator
        case "root": self = .root
        case "admin", "full-admin", "fulladmin": self = .admin
        default: return nil
        }
    }

    public var scopes: ScopeSet {
        switch self {
        case .triage: ScopeSet(scopes: TokenPresets.triage.scopes)
        case .operator: ScopeSet(scopes: TokenPresets.operator.scopes)
        case .root: ScopeSet(scopes: TokenPresets.operatorPlusRoot.scopes)
        case .admin: ScopeSet(scopes: ["*"])
        }
    }
}

/// The demo scenarios of section 8.6, selected with
/// `-AstraDemoScenario <name>[:<path prefix>]` or Settings > Demo data.
public enum DemoScenario: Sendable, Hashable {
    case normal
    case quiet
    /// 503 for routes under the prefixes (default incidents and tasks).
    case failing(prefix: String?)
    /// The first request per route succeeds; later ones time out.
    case stale
    /// The network path is unsatisfied and every request throws `.notConnectedToInternet`.
    case offline
    /// `/api/me` answers the Triage preset.
    case limitedToken
    /// The Operator preset confined by a node allowlist (`DemoWorld.confinedNodeIDs`).
    case confinedToken
    /// `/api/me` answers the Operator plus root preset, which adds
    /// `task:run` and `terminal:open`, so the root-gated writes can be shown.
    case rootToken
    /// `/api/me` answers `*`, a full administrator, so the screens gated on
    /// `*`, `plugin:admin` or `kv:admin` (System, plugin runtime health,
    /// storage tokens) can be shown with content.
    case fullAdmin
    /// No reveal session client.
    case noSession
    /// 403 `forbidden` for a path prefix after the first load.
    case forbidden(prefix: String?)
    /// Every route serves its `emptyBody` (or `[]`).
    case empty
    /// An undecodable body for a path prefix (default the approval `?id=` route).
    case companionBehind(prefix: String?)

    public static let allCases: [DemoScenario] = [
        .normal, .quiet, .failing(prefix: nil), .stale, .offline, .limitedToken,
        .confinedToken, .rootToken, .fullAdmin, .noSession, .forbidden(prefix: nil), .empty, .companionBehind(prefix: nil),
    ]

    /// Parses a launch argument value: "failing", "failing:/api/monitors".
    public init?(argument: String) {
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        let prefix = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        switch parts.first?.lowercased() ?? "" {
        case "normal": self = .normal
        case "quiet": self = .quiet
        case "failing": self = .failing(prefix: prefix)
        case "stale": self = .stale
        case "offline": self = .offline
        case "limited", "limitedtoken", "limited-token": self = .limitedToken
        case "confined", "confinedtoken", "confined-token": self = .confinedToken
        case "root", "roottoken", "root-token": self = .rootToken
        case "admin", "fulladmin", "full-admin": self = .fullAdmin
        case "nosession", "no-session": self = .noSession
        case "forbidden": self = .forbidden(prefix: prefix)
        case "empty": self = .empty
        case "companionbehind", "companion-behind", "behind": self = .companionBehind(prefix: prefix)
        default: return nil
        }
    }

    /// The launch argument spelling, inverse of `init(argument:)`.
    public var argument: String {
        switch self {
        case .normal: "normal"
        case .quiet: "quiet"
        case .failing(let prefix): prefix.map { "failing:\($0)" } ?? "failing"
        case .stale: "stale"
        case .offline: "offline"
        case .limitedToken: "limited-token"
        case .confinedToken: "confined-token"
        case .rootToken: "root-token"
        case .fullAdmin: "full-admin"
        case .noSession: "no-session"
        case .forbidden(let prefix): prefix.map { "forbidden:\($0)" } ?? "forbidden"
        case .empty: "empty"
        case .companionBehind(let prefix): prefix.map { "companion-behind:\($0)" } ?? "companion-behind"
        }
    }

    /// The name Settings > Demo data shows.
    public var title: String {
        switch self {
        case .normal: "Normal"
        case .quiet: "Quiet"
        case .failing: "Failing"
        case .stale: "Stale"
        case .offline: "Offline"
        case .limitedToken: "Limited token"
        case .confinedToken: "Confined token"
        case .rootToken: "Root token"
        case .fullAdmin: "Full administrator"
        case .noSession: "No session"
        case .forbidden: "Forbidden"
        case .empty: "Empty"
        case .companionBehind: "Companion behind"
        }
    }
}
