import Foundation

/// Custom URL scheme destinations. Universal Links wait for a signed build.
public enum LatticeDeepLink: Equatable, Sendable {
    case approval(id: String)
    case node(id: String)
    case monitor(id: String)

    public static let scheme = "lattice"

    public init?(url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == Self.scheme {
            self.init(customURL: url)
            return
        }
        if scheme == "https" || scheme == "http" {
            self.init(httpsURL: url)
            return
        }
        return nil
    }

    private init?(customURL url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        var hostAndPath: [String] = []
        if let host = url.host, !host.isEmpty {
            hostAndPath.append(host)
        }
        hostAndPath.append(contentsOf: parts)
        self.init(components: hostAndPath)
    }

    private init?(httpsURL url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        self.init(components: parts)
    }

    private init?(components: [String]) {
        guard components.count >= 2 else { return nil }
        let resource = components[0].lowercased()
        let id = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        switch resource {
        case "approvals": self = .approval(id: id)
        case "nodes": self = .node(id: id)
        case "monitors": self = .monitor(id: id)
        default: return nil
        }
    }

    public var customURL: URL? {
        switch self {
        case .approval(let id): URL(string: "\(Self.scheme)://approvals/\(id)")
        case .node(let id): URL(string: "\(Self.scheme)://nodes/\(id)")
        case .monitor(let id): URL(string: "\(Self.scheme)://monitors/\(id)")
        }
    }
}

public enum LatticeConsolePath {
    public static func approvals(_ id: String, dashboard: URL) -> URL {
        join(dashboard, "approvals/\(id)")
    }

    public static func nodes(_ id: String, dashboard: URL) -> URL {
        join(dashboard, "nodes/\(id)")
    }

    public static func monitors(_ id: String, dashboard: URL) -> URL {
        join(dashboard, "monitors/\(id)")
    }

    public static func join(_ dashboard: URL, _ path: String) -> URL {
        var base = dashboard.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        let suffix = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: "\(base)/\(suffix)") ?? dashboard
    }
}
