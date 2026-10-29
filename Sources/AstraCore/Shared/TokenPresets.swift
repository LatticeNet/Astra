import Foundation

/// How the phone serves one console action (section 3): native read, a write
/// at a tier, plan filing, a decision, a step-up reveal, or the web.
public enum ParityMode: String, Sendable, Hashable, CaseIterable {
    case native = "N"
    case nativeT1 = "N-T1"
    case nativeT2 = "N-T2"
    case nativeT3 = "N-T3"
    case nativeT4 = "N-T4"
    case nativePlan = "N-P"
    case nativeDecision = "N-D"
    case nativeStepUp = "N-S"
    case web = "W"

    public var isNative: Bool { self != .web }
}

/// One row of the parity matrix (section 3.2) as data.
public struct ParityMatrixRow: Sendable, Hashable {
    public var page: String
    public var action: String
    public var endpoint: String
    /// Every scope the row needs; a combined mode ("N-T3 + P") lists both gates' scopes.
    public var scopes: [String]
    public var modes: [ParityMode]

    public init(page: String, action: String, endpoint: String, scopes: [String], modes: [ParityMode]) {
        self.page = page
        self.action = action
        self.endpoint = endpoint
        self.scopes = scopes
        self.modes = modes
    }

    public var isNative: Bool { modes.contains { $0.isNative } }
}

/// The parity matrix rows whose scopes `TokenPresets` must cover.
public enum ParityMatrix {
    // M0a: implement. One row per section 3.2 write action (and the scoped reads of 3.1).
    public static let rows: [ParityMatrixRow] = []

    public static var nativeRows: [ParityMatrixRow] { rows.filter(\.isNative) }
}

/// A suggested token for the console's token form (F-05).
public struct TokenPreset: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var scopes: [String]
    /// A warning shown with the preset, if any.
    public var warning: String?

    public init(id: String, title: String, scopes: [String], warning: String? = nil) {
        self.id = id
        self.title = title
        self.scopes = scopes
        self.warning = warning
    }

    /// The scopes as one copyable line, comma separated.
    public var copyText: String { scopes.joined(separator: ",") }
}

/// The three presets of section 6.12, derived from the parity matrix.
public enum TokenPresets {
    /// Scopes no preset carries, and which the phone must never hold by default.
    public static let deliberatelyExcluded: Set<String> = [
        "token:admin", "user:admin", "plugin:admin", "oidc:admin", "notify:send", "secrets:reveal",
    ]

    public static let triage = TokenPreset(
        id: "triage",
        title: "Triage",
        scopes: [
            "node:read", "group:read", "inventory:read", "monitor:read", "monitor:admin",
            "audit:read", "task:read", "netpolicy:read", "geo:read", "log:read",
        ]
    )

    public static let `operator` = TokenPreset(
        id: "operator",
        title: "Operator",
        scopes: triage.scopes + [
            "network:plan", "network:apply", "node:admin", "group:admin", "sshguard:admin",
            "inventory:admin", "ddns:admin", "dns:admin", "geo:admin", "tunnel:admin",
            "netpolicy:admin", "netguard:read", "notify:admin", "proxy:read", "proxy:admin",
            "log:admin", "kv:read", "kv:write", "static:read", "static:write",
        ]
    )

    public static let operatorPlusRoot = TokenPreset(
        id: "operator-root",
        title: "Operator plus root",
        scopes: `operator`.scopes + ["task:run", "terminal:open"],
        warning: "This token can run scripts as root on every node it can see and open root shells through the API."
    )

    public static let all: [TokenPreset] = [triage, TokenPresets.operator, operatorPlusRoot]

    /// Scopes some native parity row needs that no preset or exclusion covers.
    /// A check asserts this is empty.
    public static func uncoveredScopes(rows: [ParityMatrixRow] = ParityMatrix.nativeRows) -> Set<String> {
        let covered = Set(operatorPlusRoot.scopes).union(deliberatelyExcluded)
        return Set(rows.flatMap(\.scopes)).subtracting(covered)
    }
}
