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
}

/// The invented fleet every fixture uses (section 8.6): IPv4 from the
/// documentation ranges, IPv6 from 2001:db8::/32, hosts under example.net
/// and example.org, tokens like `lat_demo_0001.notasecret`. No real names,
/// addresses, hostnames or tokens.
public enum DemoWorld {
    // M0a: implement the 35 nodes in all five honesty states.
    public static let nodes: [DemoWorldNode] = []

    public static let baseURL = URL(string: "https://demo.lattice.invalid")!
    public static let token = "lat_demo_0001.notasecret"
}
