import Foundation

/// The scopes one credential holds, evaluated exactly as the server's
/// `internal/rbac` does: `*`, `<area>:*` prefix wildcards, explicit-only
/// scopes, and the `compatibleScopes` alias table (section 6.12).
public struct ScopeSet: Sendable, Hashable {
    public var scopes: [String]
    /// The nodes the credential is confined to; empty means unconfined.
    public var serverAllowlist: [String]

    public init(scopes: [String], serverAllowlist: [String] = []) {
        self.scopes = scopes
        self.serverAllowlist = serverAllowlist
    }

    public static let empty = ScopeSet(scopes: [])

    /// Scopes held only by naming them; no wildcard satisfies them.
    public static let explicitOnly: Set<String> = ["secrets:reveal"]

    /// True when a node allowlist confines this credential.
    public var isConfined: Bool {
        !serverAllowlist.isEmpty && !serverAllowlist.contains("*")
    }

    /// `rbac.Allows`: the scope, then the node allowlist when a node is named.
    public func allows(_ scope: String, nodeID: String? = nil) -> Bool {
        guard Self.scopeAllowed(scopes, scope) else { return false }
        guard let nodeID, !nodeID.isEmpty, !serverAllowlist.isEmpty else { return true }
        return serverAllowlist.contains("*") || serverAllowlist.contains(nodeID)
    }

    /// Whether every group of `requirement` is satisfied.
    public func allows(_ requirement: ScopeRequirement, nodeID: String? = nil) -> Bool {
        missing(requirement, nodeID: nodeID).isEmpty && !(requirement.unconfined && isConfined)
    }

    /// The scopes to name in "Needs ..." copy: the first alternative of every
    /// group this set does not satisfy.
    public func missing(_ requirement: ScopeRequirement, nodeID: String? = nil) -> [String] {
        requirement.groups.compactMap { group in
            group.contains { allows($0, nodeID: nodeID) } ? nil : group.first
        }
    }

    /// `rbac.scopeAllowed`.
    public static func scopeAllowed(_ scopes: [String], _ required: String) -> Bool {
        if directlyAllows(scopes, required) { return true }
        return compatibleScopes(required).contains { directlyAllows(scopes, $0) }
    }

    /// `rbac.directlyAllows`.
    public static func directlyAllows(_ scopes: [String], _ required: String) -> Bool {
        if explicitOnly.contains(required) {
            return scopes.contains(required)
        }
        for scope in scopes {
            if scope == "*" || scope == required { return true }
            if scope.hasSuffix(":*"), required.hasPrefix(String(scope.dropLast())) { return true }
        }
        return false
    }

    /// `rbac.compatibleScopes`, the only alias table. No other admin scope implies read.
    public static func compatibleScopes(_ required: String) -> [String] {
        switch required {
        case "sshguard:read": ["sshguard:admin"]
        case "proxy:read": ["vpncore:read"]
        case "proxy:admin": ["vpncore:admin"]
        case "vpncore:read", "substore:read": ["proxy:read"]
        case "vpncore:admin", "substore:admin": ["proxy:admin"]
        default: []
        }
    }
}

/// What a screen, section or intent needs: every group must be satisfied by
/// one of its alternatives, and `unconfined` asks for a token without a node
/// allowlist (measure certificate, proxy plans).
public struct ScopeRequirement: Sendable, Hashable {
    public var groups: [[String]]
    public var unconfined: Bool

    public init(groups: [[String]], unconfined: Bool = false) {
        self.groups = groups
        self.unconfined = unconfined
    }

    /// Every listed scope is needed.
    public init(_ scopes: String..., unconfined: Bool = false) {
        self.init(groups: scopes.map { [$0] }, unconfined: unconfined)
    }

    /// Any one of the listed scopes is enough.
    public static func anyOf(_ scopes: String...) -> ScopeRequirement {
        ScopeRequirement(groups: [scopes])
    }

    public static let none = ScopeRequirement(groups: [])

    /// Both requirements at once.
    public func and(_ other: ScopeRequirement) -> ScopeRequirement {
        ScopeRequirement(groups: groups + other.groups, unconfined: unconfined || other.unconfined)
    }

    /// "monitor:read and network:plan", "proxy:read or proxy:admin".
    public var summary: String {
        groups.map { $0.joined(separator: " or ") }.joined(separator: " and ")
    }
}

/// One scope's description, from the console's `lib/scopes.ts`.
public struct ScopeCatalogueEntry: Sendable, Hashable {
    public var scope: String
    public var title: String
    public var detail: String

    public init(scope: String, title: String, detail: String) {
        self.scope = scope
        self.title = title
        self.detail = detail
    }
}

/// The scope descriptions shown by ScopeSummary and TokenDetail.
public enum ScopeCatalogue {
    // M0a: implement. Port every entry of lattice-dashboard/src/lib/scopes.ts.
    public static let entries: [ScopeCatalogueEntry] = []

    public static func entry(for scope: String) -> ScopeCatalogueEntry? {
        entries.first { $0.scope == scope }
    }
}
