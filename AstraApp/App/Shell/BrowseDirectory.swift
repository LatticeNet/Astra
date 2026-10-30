import SwiftUI

/// Where a directory row or search result goes. Rows that switch tabs or open
/// the Settings sheet look different from push rows (section 2.4).
enum DirectoryTarget: Hashable, Sendable {
    case push(AppRoute)
    case tab(AppTab, scope: String?, query: String? = nil)
    /// A page that lives in another tab's stack, opened there (2.4).
    case open(AppRoute, in: AppTab, scope: String?)
    case settings([SettingsRoute])
    case web(LatticeConsolePath)
    /// A palette action that presents Review; it never decides anything itself.
    case review(ReviewTarget)
}

/// One page of the Browse directory.
struct DirectoryEntry: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let target: DirectoryTarget
    /// The read requirement from the server's route wrappers (section 8.9).
    var requirement: ScopeRequirement = .none
    /// On the session client (Security needs a signed-in session).
    var needsSession = false
}

struct DirectorySection: Identifiable, Sendable {
    let title: String
    let entries: [DirectoryEntry]
    var id: String { title }
}

/// Every directory row (F-22), mirroring the console sidebar. Pages the token
/// cannot read move to a collapsed group, never out of sight.
enum BrowseDirectory {
    static let sections: [DirectorySection] = [
        DirectorySection(title: "Fleet", entries: [
            DirectoryEntry(id: "nodes", title: "Nodes", symbol: "server.rack", target: .tab(.fleet, scope: "nodes"), requirement: ScopeRequirement("node:read")),
            DirectoryEntry(id: "groups", title: "Groups", symbol: "square.stack.3d.up", target: .tab(.fleet, scope: "groups"), requirement: ScopeRequirement("group:read")),
            DirectoryEntry(id: "map", title: "Map", symbol: "map", target: .tab(.fleet, scope: "map"), requirement: ScopeRequirement("node:read")),
            DirectoryEntry(id: "machines", title: "Machines", symbol: "shippingbox", target: .tab(.fleet, scope: "machines"), requirement: ScopeRequirement("inventory:read")),
            DirectoryEntry(id: "upcoming", title: "Upcoming", symbol: "calendar", target: .open(.inventory(.upcoming), in: .fleet, scope: "machines"), requirement: InventoryStore.upcomingRequirement),
            DirectoryEntry(id: "monitoring", title: "Monitoring", symbol: "waveform.path.ecg", target: .tab(.monitor, scope: "overview"), requirement: ScopeRequirement("monitor:read")),
        ]),
        DirectorySection(title: "VPN", entries: [
            DirectoryEntry(id: "vpn.users", title: "Users", symbol: "person.2", target: .push(.vpn(.users)), requirement: .anyOf("proxy:read", "vpncore:read")),
            DirectoryEntry(id: "vpn.lines", title: "Lines", symbol: "point.3.connected.trianglepath.dotted", target: .push(.vpn(.lines)), requirement: .anyOf("proxy:read", "vpncore:read")),
            DirectoryEntry(id: "vpn.profiles", title: "Node profiles", symbol: "slider.horizontal.3", target: .web(LatticeConsolePath(path: "/plugins/latticenet.vpn-core/profiles"))),
            DirectoryEntry(id: "vpn.usage", title: "Usage", symbol: "chart.bar", target: .web(LatticeConsolePath(path: "/plugins/latticenet.vpn-core/usage"))),
            DirectoryEntry(id: "substore", title: "Sub-Store", symbol: "tray.2", target: .web(LatticeConsolePath(path: "/plugins/latticenet.sub-store/sub-store"))),
        ]),
        DirectorySection(title: "Operations", entries: [
            DirectoryEntry(id: "approvals", title: "Approvals", symbol: "checkmark.seal", target: .tab(.activity, scope: "approvals"), requirement: ScopeRequirement("network:plan")),
            DirectoryEntry(id: "tasks", title: "Tasks", symbol: "terminal", target: .tab(.activity, scope: "tasks"), requirement: ScopeRequirement("task:read")),
            DirectoryEntry(id: "terminal", title: "Terminal", symbol: "apple.terminal", target: .push(.terminal(.sessions(nodeID: nil))), requirement: ScopeRequirement("terminal:open")),
            DirectoryEntry(id: "audit", title: "Audit", symbol: "list.bullet.rectangle", target: .tab(.activity, scope: "audit"), requirement: ScopeRequirement("audit:read")),
        ]),
        DirectorySection(title: "Networking", entries: [
            DirectoryEntry(id: "firewall", title: "Inbound firewall", symbol: "shield.lefthalf.filled", target: .push(.networking(.inboundFirewall(nodeID: nil))), requirement: ScopeRequirement("netguard:read")),
            DirectoryEntry(id: "outbound", title: "Outbound policy", symbol: "arrow.up.forward.circle", target: .push(.networking(.outboundPolicy)), requirement: ScopeRequirement("netpolicy:read")),
            DirectoryEntry(id: "wireguard", title: "WireGuard mesh", symbol: "network", target: .web(LatticeConsolePath(path: "/plugins/latticenet.wireguard/networks"))),
            DirectoryEntry(id: "dns", title: "Self-host DNS", symbol: "globe", target: .push(.networking(.dns)), requirement: ScopeRequirement("dns:admin")),
            DirectoryEntry(id: "ddns", title: "DDNS", symbol: "arrow.triangle.2.circlepath.circle", target: .push(.networking(.ddns)), requirement: ScopeRequirement("ddns:admin")),
            DirectoryEntry(id: "geo", title: "Geo-Routing", symbol: "globe.asia.australia", target: .push(.networking(.geoRouting)), requirement: ScopeRequirement("geo:read")),
            DirectoryEntry(id: "tunnels", title: "Tunnels", symbol: "point.topleft.down.to.point.bottomright.curvepath", target: .push(.networking(.tunnels)), requirement: ScopeRequirement("tunnel:admin")),
            DirectoryEntry(id: "sshguard", title: "SSH Guard", symbol: "lock.shield", target: .push(.sshGuard(.board(posture: nil, coverage: nil))), requirement: ScopeRequirement("sshguard:read", "network:plan")),
        ]),
        DirectorySection(title: "Platform", entries: [
            DirectoryEntry(id: "plugins", title: "Plugins", symbol: "puzzlepiece.extension", target: .push(.platform(.plugins)), requirement: ScopeRequirement("audit:read")),
            DirectoryEntry(id: "extensions", title: "Extensions", symbol: "square.on.square", target: .push(.platform(.extensions))),
            DirectoryEntry(id: "publishing", title: "Publishing", symbol: "paperplane", target: .push(.platform(.publishing(view: nil))), requirement: .anyOf("kv:read", "static:read", "proxy:admin")),
            DirectoryEntry(id: "store", title: "Store", symbol: "cylinder.split.1x2", target: .push(.platform(.store)), requirement: .anyOf("kv:read", "static:read")),
            DirectoryEntry(id: "evidence", title: "Evidence", symbol: "doc.text.magnifyingglass", target: .push(.evidence(.overview)), requirement: ScopeRequirement("log:read")),
            DirectoryEntry(id: "notifications", title: "Notifications", symbol: "bell", target: .push(.notify(.notifications(view: nil))), requirement: ScopeRequirement("notify:admin")),
            DirectoryEntry(id: "webhooks", title: "Webhooks", symbol: "arrow.down.forward.and.arrow.up.backward", target: .push(.notify(.webhooks)), requirement: ScopeRequirement("notify:admin")),
            DirectoryEntry(id: "agentupdates", title: "Agent Updates", symbol: "arrow.down.circle", target: .push(.sshGuard(.agentUpdates(view: nil, nodeID: nil))), requirement: ScopeRequirement("node:admin")),
            DirectoryEntry(id: "system", title: "System", symbol: "cpu", target: .push(.platform(.system)), requirement: ScopeRequirement("*")),
        ]),
        DirectorySection(title: "Settings", entries: [
            DirectoryEntry(id: "security", title: "Security & 2FA", symbol: "lock", target: .settings([.account(.security)]), needsSession: true),
            DirectoryEntry(id: "access", title: "Access", symbol: "person.badge.key", target: .settings([.account(.access(view: nil))]), requirement: .anyOf("user:admin", "token:admin", "oidc:admin")),
            DirectoryEntry(id: "gates", title: "Capability Gates", symbol: "checklist", target: .push(.fleet(.capabilityGates)), requirement: ScopeRequirement("node:read")),
            DirectoryEntry(id: "about", title: "About", symbol: "info.circle", target: .settings([.page(.about)])),
        ]),
    ]

    static var allEntries: [DirectoryEntry] { sections.flatMap(\.entries) }

    static func entry(id: String) -> DirectoryEntry? {
        allEntries.first { $0.id == id }
    }
}

/// Browse's recently opened pages: up to six ids in `UserDefaults` (not secret).
enum BrowseRecents {
    private static let key = "browse.recent.pages"
    static let limit = 6

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ id: String) {
        var ids = load().filter { $0 != id }
        ids.insert(id, at: 0)
        UserDefaults.standard.set(Array(ids.prefix(limit)), forKey: key)
    }
}
