import Foundation

// Deep links (section 2.5): every `lattice://` object link, the console HTTPS
// routes the app opens natively, and the "Open on web" builders. The enums
// below are shared with the app's route types so `?view=` parses here.

/// NodeDetail's three views, matching the console's `?view=`.
public enum NodeDetailTab: String, Codable, Sendable, CaseIterable {
    case overview, activity, settings
}

/// Fleet's scope segments.
public enum FleetScope: String, Codable, Sendable, CaseIterable {
    case nodes, groups, map, machines
}

/// Monitor's segments.
public enum MonitorSegment: String, Codable, Sendable, CaseIterable {
    case overview, paths, checks, incidents
}

/// Activity's scope segments.
public enum ActivityScope: String, Codable, Sendable, CaseIterable {
    case tasks, audit, approvals, sent
}

/// The Approvals scope's search scopes, matching the console's `view=`.
public enum ApprovalsScope: String, Codable, Sendable, CaseIterable {
    case needs, history, stuck
}

/// Every destination a `lattice://` link names. App links round-trip exactly:
/// `LatticeDeepLink(url: link.customURL!) == link`.
public enum LatticeDeepLink: Hashable, Sendable {
    case inbox
    case approval(id: String)
    case node(id: String, view: NodeDetailTab? = nil)
    /// `lattice://monitors/{id}`, kept from v2; opens CheckDetail like `check`.
    case monitor(id: String)
    case check(id: String)
    case definition(id: String)
    /// `key` from `encodePathKey`.
    case path(key: String)
    /// A derived id `pending:<key>` is percent-encoded in the link.
    case incident(id: String)
    case maintenanceWindow(id: String)
    case task(id: String)
    case taskNode(taskID: String, nodeID: String)
    case auditEvent(id: String)
    case trace(correlationID: String)
    case machine(id: String)
    case upcoming
    case group(id: String)
    case policy(id: String)
    case dnsDeployment(id: String)
    case ddnsProfile(id: String)
    case geoRoute(id: String)
    case tunnel(id: String)
    case sshGuardNode(nodeID: String)
    case agentUpdateNode(nodeID: String)
    case plugin(id: String)
    case share(id: String)
    case notifyChannel(id: String)
    case notifyDelivery(id: String)
    case webhook(id: String)
    case token(id: String)
    case user(id: String)
    case terminalSession(id: String)
    case vpnUser(id: String)
    case connection(id: String)
    case settingsConnection
    case fleet(scope: FleetScope?, query: String?)
    /// `view` is the Paths view: problems, all or chains.
    case monitoring(segment: MonitorSegment?, view: String?, query: String?)
    case activity(scope: ActivityScope?, view: ApprovalsScope?, query: String?)

    public static let scheme = "lattice"

    /// Parses a `lattice://` link, or a console HTTPS route when its host and
    /// port equal `console`'s. Any other URL is nil (it opens in the browser).
    public init?(url: URL, console: URL? = nil) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let scheme = components.scheme?.lowercased() ?? ""
        let query = Self.queryValues(components)
        if scheme == Self.scheme {
            var segments: [String] = []
            if let host = components.percentEncodedHost, !host.isEmpty {
                segments.append(host.removingPercentEncoding ?? host)
            }
            segments += Self.pathSegments(components.percentEncodedPath)
            self.init(appSegments: segments, query: query)
        } else if scheme == "https" || scheme == "http" {
            guard let console, Self.sameOrigin(url, console) else { return nil }
            var segments = Self.pathSegments(components.percentEncodedPath)
            let base = Self.pathSegments(URLComponents(url: console, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "")
            if !base.isEmpty, segments.starts(with: base) {
                segments.removeFirst(base.count)
            }
            self.init(consoleSegments: segments, query: query)
        } else {
            return nil
        }
    }

    private init?(appSegments s: [String], query q: [String: String]) {
        guard let first = s.first?.lowercased() else { return nil }
        let id = s.count > 1 ? s[1] : ""
        func one(_ make: (String) -> LatticeDeepLink) -> LatticeDeepLink? {
            s.count == 2 && !id.isEmpty ? make(id) : nil
        }
        let link: LatticeDeepLink?
        switch first {
        case "inbox": link = s.count == 1 ? .inbox : nil
        case "approvals": link = one { .approval(id: $0) }
        case "nodes": link = one { .node(id: $0, view: q["view"].flatMap(NodeDetailTab.init(rawValue:))) }
        case "monitors": link = one { .monitor(id: $0) }
        case "checks": link = one { .check(id: $0) }
        case "definitions": link = one { .definition(id: $0) }
        case "paths": link = one { .path(key: $0) }
        case "incidents": link = one { .incident(id: $0) }
        case "maintenance": link = one { .maintenanceWindow(id: $0) }
        case "tasks":
            if s.count == 4, s[2] == "nodes", !id.isEmpty, !s[3].isEmpty {
                link = .taskNode(taskID: id, nodeID: s[3])
            } else {
                link = one { .task(id: $0) }
            }
        case "audit": link = one { .auditEvent(id: $0) }
        case "trace": link = one { .trace(correlationID: $0) }
        case "machines": link = one { .machine(id: $0) }
        case "upcoming": link = s.count == 1 ? .upcoming : nil
        case "groups": link = one { .group(id: $0) }
        case "policies": link = one { .policy(id: $0) }
        case "dns": link = one { .dnsDeployment(id: $0) }
        case "ddns": link = one { .ddnsProfile(id: $0) }
        case "geo-routes": link = one { .geoRoute(id: $0) }
        case "tunnels": link = one { .tunnel(id: $0) }
        case "ssh-guard": link = one { .sshGuardNode(nodeID: $0) }
        case "agent-updates": link = one { .agentUpdateNode(nodeID: $0) }
        case "plugins": link = one { .plugin(id: $0) }
        case "shares": link = one { .share(id: $0) }
        case "webhooks": link = one { .webhook(id: $0) }
        case "tokens": link = one { .token(id: $0) }
        case "users": link = one { .user(id: $0) }
        case "terminal": link = one { .terminalSession(id: $0) }
        case "notify", "vpn", "evidence", "settings":
            link = Self.nested(first, s.dropFirst().map { $0 })
        case "fleet":
            link = s.count == 1 ? .fleet(scope: q["scope"].flatMap(FleetScope.init(rawValue:)), query: q["q"]) : nil
        case "monitor":
            link = s.count == 1
                ? .monitoring(segment: q["segment"].flatMap(MonitorSegment.init(rawValue:)), view: q["view"], query: q["q"])
                : nil
        case "activity":
            link = s.count == 1
                ? .activity(
                    scope: q["scope"].flatMap(ActivityScope.init(rawValue:)),
                    view: q["view"].flatMap(ApprovalsScope.init(rawValue:)),
                    query: q["q"]
                )
                : nil
        default: link = nil
        }
        guard let link else { return nil }
        self = link
    }

    private static func nested(_ first: String, _ rest: [String]) -> LatticeDeepLink? {
        switch (first, rest.count, rest.first) {
        case ("notify", 2, "channels"): return rest[1].isEmpty ? nil : .notifyChannel(id: rest[1])
        case ("notify", 2, "deliveries"): return rest[1].isEmpty ? nil : .notifyDelivery(id: rest[1])
        case ("vpn", 2, "users"): return rest[1].isEmpty ? nil : .vpnUser(id: rest[1])
        case ("evidence", 2, "connections"): return rest[1].isEmpty ? nil : .connection(id: rest[1])
        case ("settings", 1, "connection"): return .settingsConnection
        default: return nil
        }
    }

    /// The console HTTPS routes section 2.5 lists; everything else is nil.
    private init?(consoleSegments s: [String], query q: [String: String]) {
        let path = s.joined(separator: "/")
        let open = q["open"].flatMap { $0.isEmpty ? nil : $0 }
        let link: LatticeDeepLink?
        switch path {
        case "approvals": link = open.map { .approval(id: $0) }
        case "monitoring":
            if q["view"] == "topology", let key = q["path"], !key.isEmpty {
                link = .path(key: key)
            } else if q["view"] == "checks" {
                link = open.map { .check(id: $0) }
            } else {
                link = nil
            }
        case "tasks": link = open.map { .task(id: $0) }
        case "audit": link = open.map { .auditEvent(id: $0) }
        case "inventory": link = q["machine"].flatMap { $0.isEmpty ? nil : .machine(id: $0) }
        case "node-groups": link = open.map { .group(id: $0) }
        case "network/ssh-guard": link = q["node_id"].flatMap { $0.isEmpty ? nil : .sshGuardNode(nodeID: $0) }
        case "platform/plugins": link = open.map { .plugin(id: $0) }
        default:
            if s.count == 2, s[0] == "monitoring", !s[1].isEmpty {
                link = .check(id: s[1])
            } else if s.count == 2, s[0] == "nodes", !s[1].isEmpty {
                link = .node(id: s[1], view: q["view"].flatMap(NodeDetailTab.init(rawValue:)))
            } else {
                link = nil
            }
        }
        guard let link else { return nil }
        self = link
    }

    /// The `lattice://` link for this destination.
    public var customURL: URL? {
        let (segments, query) = parts
        var text = "\(Self.scheme)://" + segments.map(Self.encodeSegment).joined(separator: "/")
        let items = query.filter { $0.value?.isEmpty == false }
        if !items.isEmpty {
            var components = URLComponents()
            components.queryItems = items
            text += "?" + (components.percentEncodedQuery ?? "")
        }
        return URL(string: text)
    }

    private var parts: ([String], [URLQueryItem]) {
        switch self {
        case .inbox: (["inbox"], [])
        case .approval(let id): (["approvals", id], [])
        case .node(let id, let view): (["nodes", id], [URLQueryItem(name: "view", value: view?.rawValue)])
        case .monitor(let id): (["monitors", id], [])
        case .check(let id): (["checks", id], [])
        case .definition(let id): (["definitions", id], [])
        case .path(let key): (["paths", key], [])
        case .incident(let id): (["incidents", id], [])
        case .maintenanceWindow(let id): (["maintenance", id], [])
        case .task(let id): (["tasks", id], [])
        case .taskNode(let taskID, let nodeID): (["tasks", taskID, "nodes", nodeID], [])
        case .auditEvent(let id): (["audit", id], [])
        case .trace(let id): (["trace", id], [])
        case .machine(let id): (["machines", id], [])
        case .upcoming: (["upcoming"], [])
        case .group(let id): (["groups", id], [])
        case .policy(let id): (["policies", id], [])
        case .dnsDeployment(let id): (["dns", id], [])
        case .ddnsProfile(let id): (["ddns", id], [])
        case .geoRoute(let id): (["geo-routes", id], [])
        case .tunnel(let id): (["tunnels", id], [])
        case .sshGuardNode(let id): (["ssh-guard", id], [])
        case .agentUpdateNode(let id): (["agent-updates", id], [])
        case .plugin(let id): (["plugins", id], [])
        case .share(let id): (["shares", id], [])
        case .notifyChannel(let id): (["notify", "channels", id], [])
        case .notifyDelivery(let id): (["notify", "deliveries", id], [])
        case .webhook(let id): (["webhooks", id], [])
        case .token(let id): (["tokens", id], [])
        case .user(let id): (["users", id], [])
        case .terminalSession(let id): (["terminal", id], [])
        case .vpnUser(let id): (["vpn", "users", id], [])
        case .connection(let id): (["evidence", "connections", id], [])
        case .settingsConnection: (["settings", "connection"], [])
        case .fleet(let scope, let query):
            (["fleet"], [URLQueryItem(name: "scope", value: scope?.rawValue), URLQueryItem(name: "q", value: query)])
        case .monitoring(let segment, let view, let query):
            (["monitor"], [
                URLQueryItem(name: "segment", value: segment?.rawValue),
                URLQueryItem(name: "view", value: view),
                URLQueryItem(name: "q", value: query),
            ])
        case .activity(let scope, let view, let query):
            (["activity"], [
                URLQueryItem(name: "scope", value: scope?.rawValue),
                URLQueryItem(name: "view", value: view?.rawValue),
                URLQueryItem(name: "q", value: query),
            ])
        }
    }

    // MARK: Helpers

    /// Path characters left unescaped: RFC 3986 `pchar` without `%`, so
    /// `pending:`, `~`, `@` and `_` stay readable and `/`, `?`, `#` and spaces are escaped.
    private static let segmentAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$&'()*+,;=:@"
    )

    static func encodeSegment(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? segment
    }

    static func pathSegments(_ percentEncodedPath: String) -> [String] {
        percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map {
            String($0).removingPercentEncoding ?? String($0)
        }
    }

    static func queryValues(_ components: URLComponents) -> [String: String] {
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where values[item.name] == nil {
            values[item.name] = item.value ?? ""
        }
        return values
    }

    static func sameOrigin(_ url: URL, _ console: URL) -> Bool {
        guard let host = url.host?.lowercased(), host == console.host?.lowercased() else { return false }
        return effectivePort(url) == effectivePort(console)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

/// A console route for "Open on web" (sections 2.5 and 6.15). Builders take
/// explicit inputs because several routes need data an id cannot supply.
public struct LatticeConsolePath: Hashable, Sendable {
    /// The route path, starting with "/".
    public var path: String
    public var query: [URLQueryItem]

    public init(path: String, query: [URLQueryItem] = []) {
        self.path = path.hasPrefix("/") ? path : "/" + path
        self.query = query
    }

    private init(_ path: String, _ pairs: KeyValuePairs<String, String?>) {
        self.init(path: path, query: pairs.compactMap { name, value in
            value.flatMap { $0.isEmpty ? nil : URLQueryItem(name: name, value: $0) }
        })
    }

    /// The absolute URL under the console URL (Settings > Connection).
    public func url(console: URL) -> URL {
        var base = console.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var components = URLComponents(string: base + path)
        if !query.isEmpty { components?.queryItems = query }
        return components?.url ?? console
    }

    // MARK: Builders, one per row of section 2.5

    public static let inbox = LatticeConsolePath(path: "/")
    public static func approval(id: String) -> Self { Self("/approvals", ["open": id]) }
    public static func approvals(view: ApprovalsScope? = nil) -> Self { Self("/approvals", ["view": view?.rawValue]) }
    public static func node(id: String, view: NodeDetailTab? = nil) -> Self {
        Self("/nodes/\(LatticeDeepLink.encodeSegment(id))", ["view": view?.rawValue])
    }
    public static let nodes = LatticeConsolePath(path: "/nodes")
    public static func check(id: String) -> Self { Self("/monitoring", ["view": "checks", "open": id]) }
    /// Lossy: the console opens a definition through the checks layer.
    public static func definition(id: String) -> Self { check(id: id) }
    public static func path(key: String) -> Self { Self("/monitoring", ["view": "topology", "path": key]) }
    /// The console reads no incident id; this lands on a filtered list.
    public static func incident(id: String, query: String) -> Self {
        Self("/monitoring", ["view": "incidents", "state": "all", "q": query])
    }
    public static let maintenance = LatticeConsolePath("/monitoring", ["view": "incidents", "state": "all"])
    public static func monitoring(view: String? = nil) -> Self { Self("/monitoring", ["view": view]) }
    public static func task(id: String) -> Self { Self("/tasks", ["open": id]) }
    /// Lossy: the node is dropped.
    public static func taskNode(taskID: String, nodeID: String) -> Self { task(id: taskID) }
    public static let tasks = LatticeConsolePath(path: "/tasks")
    public static func auditEvent(id: String) -> Self { Self("/audit", ["open": id]) }
    public static func trace(correlationID: String) -> Self { Self("/audit", ["view": "all", "q": "trace:\(correlationID)"]) }
    public static func audit(view: String? = nil) -> Self { Self("/audit", ["view": view]) }
    public static func machine(id: String) -> Self { Self("/inventory", ["machine": id]) }
    public static let inventory = LatticeConsolePath(path: "/inventory")
    public static let upcoming = LatticeConsolePath(path: "/upcoming")
    public static func group(id: String) -> Self { Self("/node-groups", ["open": id]) }
    public static let nodeGroups = LatticeConsolePath(path: "/node-groups")
    public static let map = LatticeConsolePath(path: "/map")
    public static func policy(id: String) -> Self { Self("/network/outbound", ["policy": id]) }
    public static func dnsDeployment(id: String) -> Self { Self("/network/dns", ["open": id]) }
    public static func ddnsProfile(id: String) -> Self { Self("/network/ddns", ["open": id]) }
    public static func geoRoute(id: String) -> Self { Self("/network/geo-routing", ["open": id]) }
    public static func tunnel(id: String) -> Self { Self("/network/tunnels", ["open": id]) }
    public static func sshGuardNode(nodeID: String) -> Self { Self("/network/ssh-guard", ["node_id": nodeID]) }
    /// The console filters agent updates by node name, not id.
    public static func agentUpdates(nodeName: String) -> Self {
        Self("/platform/agent-updates", ["view": "nodes", "q": nodeName])
    }
    public static func plugin(id: String) -> Self { Self("/platform/plugins", ["open": id]) }
    public static func share(id: String) -> Self {
        Self("/platform/publishing", ["view": "routes", "origin": "share", "open": id])
    }
    public static func notifyChannel(id: String) -> Self { Self("/platform/notifications", ["view": "routing", "channel": id]) }
    public static func notifyDelivery(id: String) -> Self { Self("/platform/notifications", ["view": "sent", "open": id]) }
    public static func webhook(id: String) -> Self { Self("/platform/webhooks", ["open": id]) }
    /// The console reads no `open` here; lands on the list.
    public static let tokens = LatticeConsolePath("/settings/access", ["view": "tokens"])
    /// The console reads no `open` here; lands on the list.
    public static let users = LatticeConsolePath("/settings/access", ["view": "users"])
    public static func terminalSession(id: String) -> Self { Self("/terminal", ["session_id": id]) }
    public static let vpnUsers = LatticeConsolePath(path: "/plugins/latticenet.vpn-core/users")
    public static func connection(id: String) -> Self {
        Self("/platform/evidence", ["view": "explore", "lens": "connections", "conn": id])
    }
    /// Lossy stand-in for Settings > Connection.
    public static let settingsSecurity = LatticeConsolePath(path: "/settings/security")

    // MARK: Legacy v2 helpers, removed with the v2 views (M0b)

    public static func approvals(_ id: String, dashboard: URL) -> URL { approval(id: id).url(console: dashboard) }
    public static func nodes(_ id: String, dashboard: URL) -> URL { node(id: id).url(console: dashboard) }
    public static func monitors(_ id: String, dashboard: URL) -> URL { check(id: id).url(console: dashboard) }
}
