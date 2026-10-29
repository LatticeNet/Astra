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
    /// The resource group's label ("Nodes", "SSH Guard").
    public var title: String
    /// What the scope grants, from the holder's point of view.
    public var detail: String
    /// The resource group's id (`node`, `sshguard`).
    public var group: String
    /// Set when the scope departs from the plain read and admin pair.
    public var note: String?
    /// Set for scopes that are dangerous out of proportion to their name.
    public var sensitive: Bool

    public init(scope: String, title: String, detail: String) {
        self.init(scope: scope, title: title, detail: detail, group: "")
    }

    public init(scope: String, title: String, detail: String, group: String, note: String? = nil, sensitive: Bool = false) {
        self.scope = scope
        self.title = title
        self.detail = detail
        self.group = group
        self.note = note
        self.sensitive = sensitive
    }
}

/// The scope descriptions shown by ScopeSummary and TokenDetail, in the
/// console's group order (`SCOPE_GROUPS`). The server's `rbac.KnownScopes`
/// stays authoritative; this list only explains scopes.
public enum ScopeCatalogue {
    public static let entries: [ScopeCatalogueEntry] = [
        ScopeCatalogueEntry(scope: "node:read", title: "Nodes", detail: "List nodes and read their status, addresses and duplicate report.", group: "node"),
        ScopeCatalogueEntry(scope: "node:admin", title: "Nodes", detail: "Enroll, rename, disable, rotate tokens for and delete nodes.", group: "node", note: "Also appends a node into a group at enroll time, which group:admin otherwise governs.", sensitive: true),
        ScopeCatalogueEntry(scope: "inventory:read", title: "Nodes", detail: "Read the machine inventory: vendor, cost, renewal dates.", group: "node"),
        ScopeCatalogueEntry(scope: "inventory:admin", title: "Nodes", detail: "Edit machines and vendors, run renewal reminders, reveal purchase links.", group: "node"),
        ScopeCatalogueEntry(scope: "network:plan", title: "Network planning", detail: "Compile a plan and file it for review. Nothing reaches a node.", group: "network", note: "A verb, not a resource. It crosses every network resource rather than naming one."),
        ScopeCatalogueEntry(scope: "network:apply", title: "Network planning", detail: "Approve a reviewed plan and queue it onto the node.", group: "network", note: "This is the scope that changes a live server. network:plan alone cannot.", sensitive: true),
        ScopeCatalogueEntry(scope: "netpolicy:read", title: "Network policy", detail: "Read policies, the reachability matrix and the policy graph.", group: "netpolicy"),
        ScopeCatalogueEntry(scope: "netpolicy:admin", title: "Network policy", detail: "Author node and group policies, and plan them.", group: "netpolicy"),
        ScopeCatalogueEntry(scope: "netguard:read", title: "NetGuard firewall", detail: "Read zones, groups, bindings and the compiled review for a node.", group: "netguard"),
        ScopeCatalogueEntry(scope: "netguard:admin", title: "NetGuard firewall", detail: "Edit zones and groups, adopt nodes, and plan a node's firewall.", group: "netguard", note: "Zones and groups are fleet-wide, so these actions require an unrestricted node allowlist.", sensitive: true),
        ScopeCatalogueEntry(scope: "sshguard:read", title: "SSH Guard", detail: "Read SSH Guard plans and the approvals they produce.", group: "sshguard", note: "The arm plan contains the knock sequence in clear, which is a credential drawn per node. Reading it is reading that."),
        ScopeCatalogueEntry(scope: "sshguard:admin", title: "SSH Guard", detail: "Author an SSH Guard plan for a node and decide it.", group: "sshguard", note: "Pair with network:plan, which the endpoint requires as well. A wrong profile takes a node off the network for its operator, which is why the change arms an automatic revert that a second approval has to cancel.", sensitive: true),
        ScopeCatalogueEntry(scope: "wireguard:read", title: "WireGuard mesh", detail: "Read each node's mesh address, public key and endpoint.", group: "wireguard"),
        ScopeCatalogueEntry(scope: "wireguard:admin", title: "WireGuard mesh", detail: "Plan a node's mesh configuration.", group: "wireguard", note: "Planning also requires wireguard:read on every other member, because the config names them all."),
        ScopeCatalogueEntry(scope: "proxy:read", title: "Proxy and lines", detail: "Read inbounds, profiles, VPN users and usage.", group: "proxy"),
        ScopeCatalogueEntry(scope: "proxy:admin", title: "Proxy and lines", detail: "Edit inbounds and users, reveal credentials, and manage subscription shares.", group: "proxy", note: "Reveals plaintext credentials and share tokens. Requires an unrestricted node allowlist.", sensitive: true),
        ScopeCatalogueEntry(scope: "vpncore:read", title: "Proxy and lines", detail: "Read through the vpn-core plugin. Interchangeable with proxy:read.", group: "proxy"),
        ScopeCatalogueEntry(scope: "vpncore:admin", title: "Proxy and lines", detail: "Administer through the vpn-core plugin. Interchangeable with proxy:admin.", group: "proxy"),
        ScopeCatalogueEntry(scope: "substore:read", title: "Proxy and lines", detail: "Read sub-store subscriptions and shares.", group: "proxy", note: "A proxy:read grant satisfies this too, during the migration. The reverse does not hold."),
        ScopeCatalogueEntry(scope: "substore:admin", title: "Proxy and lines", detail: "Administer sub-store subscriptions, scripts and shares.", group: "proxy", sensitive: true),
        ScopeCatalogueEntry(scope: "vpn:probe", title: "Proxy and lines", detail: "Test a pasted outbound through the control plane's probe: whether it connects, its latency, its exit and UDP.", group: "proxy", note: "Its own domain: no proxy, vpncore or substore grant implies it, only *, vpn:* or vpn:probe itself. A test changes nothing but spends the control plane's bandwidth, so it requires an unrestricted node allowlist."),
        ScopeCatalogueEntry(scope: "ddns:admin", title: "DNS and routing", detail: "Manage dynamic DNS profiles, including their provider credentials, and run them.", group: "dns", note: "No ddns:read exists, so seeing the profile list requires the scope that can change it.", sensitive: true),
        ScopeCatalogueEntry(scope: "dns:admin", title: "DNS and routing", detail: "Manage self-hosted DNS deployments, plan and publish zones.", group: "dns", note: "No dns:read exists, so seeing deployments requires the scope that can publish them."),
        ScopeCatalogueEntry(scope: "geo:read", title: "DNS and routing", detail: "Read geo-routing records and plan one.", group: "dns"),
        ScopeCatalogueEntry(scope: "geo:admin", title: "DNS and routing", detail: "Create, edit and delete geo-routing records.", group: "dns"),
        ScopeCatalogueEntry(scope: "tunnel:admin", title: "DNS and routing", detail: "Manage Cloudflare tunnel profiles and plan them.", group: "dns", note: "No tunnel:read exists."),
        ScopeCatalogueEntry(scope: "task:read", title: "Operations", detail: "Read task history and results.", group: "ops"),
        ScopeCatalogueEntry(scope: "task:run", title: "Operations", detail: "Queue, cancel and rerun tasks on a node.", group: "ops", note: "Tasks execute a script on the node. Treat this as close to shell access.", sensitive: true),
        ScopeCatalogueEntry(scope: "terminal:open", title: "Operations", detail: "Open an interactive terminal session on a node.", group: "ops", note: "This is shell access. There is no read-only variant.", sensitive: true),
        ScopeCatalogueEntry(scope: "monitor:read", title: "Operations", detail: "Read monitors and their results.", group: "ops"),
        ScopeCatalogueEntry(scope: "monitor:admin", title: "Operations", detail: "Create, edit and delete monitors.", group: "ops"),
        ScopeCatalogueEntry(scope: "log:read", title: "Operations", detail: "Query logs and log statistics.", group: "ops"),
        ScopeCatalogueEntry(scope: "log:write", title: "Operations", detail: "Ship log lines into the server.", group: "ops"),
        ScopeCatalogueEntry(scope: "log:admin", title: "Operations", detail: "Manage log sources, including deleting them.", group: "ops", note: "Three levels here (read, write, admin) where most resources have two."),
        ScopeCatalogueEntry(scope: "notify:send", title: "Operations", detail: "Send a test notification through a channel config supplied inline. Dispatch only.", group: "ops", note: "Before the 2026-09 split this scope also governed channels and rules; that management is now notify:admin, and older send-only tokens lost it."),
        ScopeCatalogueEntry(scope: "notify:admin", title: "Operations", detail: "Manage notification channels, rules and inbound webhooks, including reading their config and delivery history.", group: "ops", note: "Channels route fleet-wide security telemetry outward, so these objects have no node dimension and writes require an unrestricted node allowlist. Does not grant dispatch.", sensitive: true),
        ScopeCatalogueEntry(scope: "kv:read", title: "Storage", detail: "Read key-value entries.", group: "storage"),
        ScopeCatalogueEntry(scope: "kv:write", title: "Storage", detail: "Write and delete key-value entries.", group: "storage"),
        ScopeCatalogueEntry(scope: "kv:admin", title: "Storage", detail: "Manage buckets, bindings and storage tokens.", group: "storage", note: "Three levels here (read, write, admin) where most resources have two."),
        ScopeCatalogueEntry(scope: "static:read", title: "Storage", detail: "Read static objects.", group: "storage"),
        ScopeCatalogueEntry(scope: "static:write", title: "Storage", detail: "Upload and delete static objects.", group: "storage"),
        ScopeCatalogueEntry(scope: "static:admin", title: "Storage", detail: "Manage static buckets, bindings and storage tokens.", group: "storage"),
        ScopeCatalogueEntry(scope: "user:admin", title: "Platform and access", detail: "Create, edit and delete operator accounts and their scopes.", group: "platform", note: "A user account carries no node allowlist, so this requires an unrestricted one. No user:read exists.", sensitive: true),
        ScopeCatalogueEntry(scope: "token:admin", title: "Platform and access", detail: "Create, revoke and delete API tokens.", group: "platform", note: "A token may only be issued with scopes and an allowlist the issuer already holds. No token:read exists.", sensitive: true),
        ScopeCatalogueEntry(scope: "oidc:admin", title: "Platform and access", detail: "Configure SSO providers.", group: "platform", note: "No oidc:read exists.", sensitive: true),
        ScopeCatalogueEntry(scope: "group:read", title: "Platform and access", detail: "Read groups and preview a selector against the fleet.", group: "platform"),
        ScopeCatalogueEntry(scope: "group:admin", title: "Platform and access", detail: "Create groups and move nodes in and out of them.", group: "platform", note: "Membership drives group policy, so this changes which firewall applies to a node."),
        ScopeCatalogueEntry(scope: "plugin:admin", title: "Platform and access", detail: "Install, enable, disable and invoke plugins.", group: "platform", sensitive: true),
        ScopeCatalogueEntry(scope: "plugin:verify", title: "Platform and access", detail: "Verify a plugin bundle's signature without installing it.", group: "platform"),
        ScopeCatalogueEntry(scope: "audit:read", title: "Platform and access", detail: "Read the audit log, verify its chain, and list installed plugins.", group: "platform", note: "There is no audit:admin, by design: the log is append-only. It also gates the plugin listing, which belongs with plugin."),
    ]

    public static func entry(for scope: String) -> ScopeCatalogueEntry? {
        entries.first { $0.scope == scope }
    }
}
