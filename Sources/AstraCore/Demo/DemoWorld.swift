import Foundation

/// One invented node of the demo fleet.
public struct DemoWorldNode: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var region: String
    public var country: String
    public var provider: String
    public var ipv4: String
    public var ipv6: String
    public var tags: [String]
    /// The honesty word the server sends: online, degraded, offline, never_reported, disabled.
    public var status: String = "online"
    public var statusReason: String = ""
    /// A `DemoClock` offset for `status_since` (`-3h`); empty for none.
    public var statusSince: String = ""
    /// A `DemoClock` offset for `last_seen`; nil when the node never reported.
    public var lastSeen: String? = "-12s"
    public var role: String = "edge"
    public var city: String = ""
    public var lat: Double = 0
    public var lon: Double = 0
    public var agentVersion: String = "0.3.10"
    public var platform: String = "debian"
    public var platformVersion: String = "12"
    public var arch: String = "amd64"
    public var cpuCores: Int = 2
    public var memoryGiB: Int = 4
    public var diskGiB: Int = 80
    public var cpuPercent: Double = 7
    public var memoryPercent: Double = 38
    public var diskPercent: Double = 41
    public var uptimeDays: Double = 21
    public var groupIDs: [String] = []

    public init(id: String, name: String, region: String, country: String, provider: String, ipv4: String, ipv6: String, tags: [String] = []) {
        self.id = id
        self.name = name
        self.region = region
        self.country = country
        self.provider = provider
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.tags = tags
    }

    /// Whether the agent reports now: online and degraded do.
    public var isReporting: Bool { status == "online" || status == "degraded" }

    /// The server's reachability word.
    public var reachability: String {
        switch status {
        case "online", "degraded": "online"
        case "never_reported": "never"
        default: lastSeen == nil ? "never" : "offline"
        }
    }

    public var hostname: String { "\(name).example.net" }
}

/// One invented node group.
public struct DemoWorldGroup: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// The selector the console shows, or nil for a static group.
    public var selector: String?
    public var nodeIDs: [String]

    public init(id: String, name: String, selector: String?, nodeIDs: [String]) {
        self.id = id
        self.name = name
        self.selector = selector
        self.nodeIDs = nodeIDs
    }
}

/// The invented fleet every fixture uses (section 8.6): IPv4 from the
/// documentation ranges, IPv6 from 2001:db8::/32, hosts under example.net
/// and example.org, tokens like `lat_demo_0001.notasecret`. No real names,
/// addresses, hostnames or tokens.
///
/// 35 nodes across ten regions: 25 online, 3 degraded, 3 offline, 2 that
/// never reported and 2 disabled.
public enum DemoWorld {
    public static let baseURL = URL(string: "https://demo.lattice.invalid")!
    public static let token = "lat_demo_0001.notasecret"
    /// The operator the demo session and token belong to.
    public static let actorID = "u-demo-ops"
    public static let username = "ops"

    private struct Region {
        var code: String
        var city: String
        var country: String
        var lat: Double
        var lon: Double
        var provider: String
        var v4: String
        var v6: String
    }

    private static let regions: [String: Region] = [
        "tyo": Region(code: "tyo", city: "Tokyo", country: "JP", lat: 35.68, lon: 139.69, provider: "Northwind Cloud", v4: "203.0.113", v6: "2001:db8:10"),
        "sin": Region(code: "sin", city: "Singapore", country: "SG", lat: 1.35, lon: 103.82, provider: "Northwind Cloud", v4: "203.0.113", v6: "2001:db8:11"),
        "hkg": Region(code: "hkg", city: "Hong Kong", country: "HK", lat: 22.32, lon: 114.17, provider: "Contoso VPS", v4: "203.0.113", v6: "2001:db8:12"),
        "fra": Region(code: "fra", city: "Frankfurt", country: "DE", lat: 50.11, lon: 8.68, provider: "Fabrikam Hosting", v4: "198.51.100", v6: "2001:db8:20"),
        "ams": Region(code: "ams", city: "Amsterdam", country: "NL", lat: 52.37, lon: 4.90, provider: "Fabrikam Hosting", v4: "198.51.100", v6: "2001:db8:21"),
        "lon": Region(code: "lon", city: "London", country: "GB", lat: 51.51, lon: -0.13, provider: "Tailspin Metal", v4: "198.51.100", v6: "2001:db8:22"),
        "iad": Region(code: "iad", city: "Ashburn", country: "US", lat: 39.04, lon: -77.49, provider: "Contoso VPS", v4: "192.0.2", v6: "2001:db8:30"),
        "sjc": Region(code: "sjc", city: "San Jose", country: "US", lat: 37.34, lon: -121.89, provider: "Tailspin Metal", v4: "192.0.2", v6: "2001:db8:31"),
        "syd": Region(code: "syd", city: "Sydney", country: "AU", lat: -33.87, lon: 151.21, provider: "Northwind Cloud", v4: "192.0.2", v6: "2001:db8:32"),
        "home": Region(code: "home", city: "Zurich", country: "CH", lat: 47.37, lon: 8.54, provider: "home", v4: "192.0.2", v6: ""),
    ]

    /// Builds one node; `host` is the last octet and the IPv6 suffix.
    private static func make(_ name: String, _ region: String, host: Int, role: String, tags: [String] = [], configure: (inout DemoWorldNode) -> Void = { _ in }) -> DemoWorldNode {
        let place = regions[region]!
        var node = DemoWorldNode(
            id: "n-\(name)",
            name: name,
            region: place.code,
            country: place.country,
            provider: place.provider,
            ipv4: "\(place.v4).\(host)",
            ipv6: place.v6.isEmpty ? "" : "\(place.v6)::\(host)",
            tags: tags
        )
        node.role = role
        node.city = place.city
        // Spread nodes of one city a little so map pins do not stack.
        node.lat = place.lat + Double(host % 5) * 0.02
        node.lon = place.lon + Double(host % 3) * 0.02
        // Varied but fixed load, so lists do not show one number for every node.
        node.cpuPercent = Double(3 + (host * 37) % 31)
        node.memoryPercent = Double(22 + (host * 53) % 41)
        configure(&node)
        if node.status == "online", node.statusReason.isEmpty, let lastSeen = node.lastSeen {
            node.statusReason = onlineReason(lastSeen: lastSeen)
        }
        return node
    }

    public static let nodes: [DemoWorldNode] = [
        make("edge-tyo-1", "tyo", host: 11, role: "edge", tags: ["edge", "asia"]),
        make("edge-tyo-2", "tyo", host: 12, role: "edge", tags: ["edge", "asia", "sshguard"]),
        make("edge-tyo-3", "tyo", host: 13, role: "edge", tags: ["edge", "asia"]) {
            $0.status = "degraded"
            $0.statusReason = "Reporting, but the work loop has been in step metrics for 14 min and has not completed a cycle for 14 min."
            $0.statusSince = "-14m"
            $0.cpuPercent = 96
        },
        make("relay-tyo-1", "tyo", host: 14, role: "relay", tags: ["relay", "asia"]) { $0.cpuCores = 4; $0.memoryGiB = 8 },
        make("dns-tyo-1", "tyo", host: 15, role: "dns", tags: ["dns"]),
        make("edge-sin-1", "sin", host: 21, role: "edge", tags: ["edge", "asia"]) { $0.agentVersion = "0.3.9" },
        make("edge-sin-2", "sin", host: 22, role: "edge", tags: ["edge", "asia"]) { $0.agentVersion = "0.3.9" },
        make("probe-sin-3", "sin", host: 23, role: "probe", tags: ["probe"]) {
            $0.status = "never_reported"
            $0.lastSeen = nil
            $0.agentVersion = ""
            $0.statusSince = "-2d"
            $0.statusReason = "No report has arrived since enrollment at {{now-2d}}."
        },
        make("relay-hkg-1", "hkg", host: 31, role: "relay", tags: ["relay", "asia"]) { $0.cpuCores = 4; $0.memoryGiB = 8 },
        make("edge-hkg-2", "hkg", host: 32, role: "edge", tags: ["edge", "asia"]) {
            $0.status = "degraded"
            // A full disk alone is load, not degraded; the server proves sing-box restarting.
            $0.statusReason = "Reporting, but sing-box has been restarting since {{now-3h}} (unit activating/auto-restart, 41 restarts)."
            $0.statusSince = "-3h"
            $0.diskPercent = 94
        },
        make("relay-fra-1", "fra", host: 41, role: "relay", tags: ["relay", "europe"]) { $0.cpuCores = 4; $0.memoryGiB = 16 },
        make("relay-fra-2", "fra", host: 42, role: "relay", tags: ["relay", "europe"]) {
            $0.status = "offline"
            $0.statusReason = offlineReason(lastSeen: "-3h")
            $0.statusSince = "-3h"
            $0.lastSeen = "-3h"
        },
        make("edge-fra-3", "fra", host: 43, role: "edge", tags: ["edge", "europe"]),
        make("dns-fra-1", "fra", host: 44, role: "dns", tags: ["dns"]),
        make("build-fra-4", "fra", host: 45, role: "build", tags: ["build"]) {
            $0.status = "never_reported"
            $0.lastSeen = nil
            $0.agentVersion = ""
            $0.statusSince = "-6h"
            $0.statusReason = "No report has arrived since enrollment at {{now-6h}}."
        },
        make("edge-ams-1", "ams", host: 51, role: "edge", tags: ["edge", "europe"]) { $0.agentVersion = "0.3.9" },
        make("edge-ams-2", "ams", host: 52, role: "edge", tags: ["edge", "europe"]),
        make("probe-ams-3", "ams", host: 53, role: "probe", tags: ["probe"]),
        make("backup-ams-4", "ams", host: 54, role: "backup", tags: ["backup"]) {
            $0.status = "disabled"
            $0.statusReason = "Disabled by an operator at {{now-9d}}; the agent token is refused until the node is enabled again."
            $0.statusSince = "-9d"
            $0.lastSeen = "-9d"
            $0.diskGiB = 2000
        },
        make("edge-lon-1", "lon", host: 61, role: "edge", tags: ["edge", "europe"]) { $0.agentVersion = "0.3.9" },
        make("core-lon-1", "lon", host: 62, role: "core", tags: ["core"]) { $0.cpuCores = 8; $0.memoryGiB = 32 },
        make("edge-iad-1", "iad", host: 71, role: "edge", tags: ["edge", "us"]),
        make("edge-iad-2", "iad", host: 72, role: "edge", tags: ["edge", "us"]) {
            $0.status = "disabled"
            $0.statusReason = "Disabled by an operator at {{now-2d}}; the agent token is refused until the node is enabled again."
            $0.statusSince = "-2d"
            $0.lastSeen = "-2d"
        },
        make("relay-iad-3", "iad", host: 73, role: "relay", tags: ["relay", "us"]),
        make("dns-iad-1", "iad", host: 74, role: "dns", tags: ["dns"]),
        make("edge-sjc-1", "sjc", host: 81, role: "edge", tags: ["edge", "us"]),
        make("edge-sjc-2", "sjc", host: 82, role: "edge", tags: ["edge", "us"]) {
            $0.status = "offline"
            $0.statusReason = offlineReason(lastSeen: "-25m")
            $0.statusSince = "-25m"
            $0.lastSeen = "-25m"
        },
        make("core-sjc-1", "sjc", host: 83, role: "core", tags: ["core"]) { $0.cpuCores = 8; $0.memoryGiB = 32 },
        make("edge-syd-1", "syd", host: 91, role: "edge", tags: ["edge", "oceania"]),
        make("relay-syd-2", "syd", host: 92, role: "relay", tags: ["relay", "oceania"]) {
            $0.status = "degraded"
            $0.statusReason = "Reporting, but the guard reality snapshot was collected at {{now-1840m}} and is older than 30h0m0s while the agent keeps reporting."
            $0.statusSince = "-40m"
        },
        make("home-nas", "home", host: 201, role: "storage", tags: ["home"]) { $0.diskGiB = 8000; $0.arch = "amd64" },
        make("home-router", "home", host: 202, role: "router", tags: ["home"]) { $0.platform = "openwrt"; $0.platformVersion = "23.05"; $0.arch = "arm64" },
        make("studio-mac", "home", host: 203, role: "workstation", tags: ["home"]) {
            $0.platform = "darwin"
            $0.platformVersion = "15.6"
            $0.arch = "arm64"
            $0.cpuCores = 12
            $0.memoryGiB = 36
        },
        make("lab-pi-1", "home", host: 204, role: "lab", tags: ["home", "lab"]) { $0.arch = "arm64"; $0.platform = "raspbian" },
        make("lab-pi-2", "home", host: 205, role: "lab", tags: ["home", "lab"]) {
            $0.arch = "arm64"
            $0.platform = "raspbian"
            $0.status = "offline"
            $0.statusReason = offlineReason(lastSeen: "-6d")
            $0.statusSince = "-6d"
            $0.lastSeen = "-6d"
            $0.agentVersion = "0.3.7"
        },
    ].map(withGroups)

    public static let groups: [DemoWorldGroup] = [
        DemoWorldGroup(id: "g-asia-edge", name: "Asia edge", selector: "tag:edge AND tag:asia", nodeIDs: []),
        DemoWorldGroup(id: "g-europe-relays", name: "Europe relays", selector: "tag:europe", nodeIDs: []),
        DemoWorldGroup(id: "g-dns", name: "DNS nodes", selector: "role:dns", nodeIDs: []),
        DemoWorldGroup(id: "g-us-edge", name: "US edge", selector: "tag:us", nodeIDs: []),
        DemoWorldGroup(id: "g-home-lab", name: "Home lab", selector: nil, nodeIDs: []),
    ].map { group in
        var group = group
        group.nodeIDs = nodes.filter { $0.groupIDs.contains(group.id) }.map(\.id)
        return group
    }

    private static func groupIDs(for node: DemoWorldNode) -> [String] {
        var ids: [String] = []
        if node.tags.contains("edge") && node.tags.contains("asia") { ids.append("g-asia-edge") }
        if node.tags.contains("europe") { ids.append("g-europe-relays") }
        if node.role == "dns" { ids.append("g-dns") }
        if node.tags.contains("us") { ids.append("g-us-edge") }
        if node.tags.contains("home") { ids.append("g-home-lab") }
        return ids
    }

    private static func withGroups(_ node: DemoWorldNode) -> DemoWorldNode {
        var node = node
        node.groupIDs = groupIDs(for: node)
        return node
    }

    /// The node allowlist of the Confined token scenario: the 12 nodes in
    /// Asia and Oceania.
    public static var confinedNodeIDs: [String] {
        nodes.filter { ["tyo", "sin", "hkg", "syd"].contains($0.region) }.map(\.id)
    }

    /// The server's reason for a reporting node (deriveNodeStatus, node_status.go).
    public static func onlineReason(lastSeen: String) -> String {
        "Reporting; last report at {{now\(lastSeen)}}."
    }

    /// The server's reason for a silent node, with its 90 s offline threshold.
    static func offlineReason(lastSeen: String) -> String {
        "No report since {{now\(lastSeen)}}; the control plane stops trusting a node after 1m30s of silence."
    }

    /// The node with this name; fixtures name nodes, never invent ids.
    public static func node(_ name: String) -> DemoWorldNode {
        guard let node = nodes.first(where: { $0.name == name }) else {
            preconditionFailure("DemoWorld has no node named \(name)")
        }
        return node
    }

    public static func node(id: String) -> DemoWorldNode? {
        nodes.first { $0.id == id }
    }
}
