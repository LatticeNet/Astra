import Foundation

// Pure derivations ported from the console: `pluginsModel.ts` (rows,
// health, lifecycle, pages), `publishingModel.ts` and `publishedModel.ts`
// (route and share states), `storeModel.ts` (bucket owners), and the
// server's capability risk table (`internal/plugin/plugin.go`).

// MARK: - Plugins

/// A page a plugin contributes: nav entries first, then views no nav entry points at.
public struct PlatformPluginPage: Hashable, Sendable, Identifiable {
    public var route: String
    public var title: String
    /// The view kind when a view declares the route; empty for a nav-only page.
    public var kind: String
    /// The console path, `/plugins/<id>/<route>`.
    public var consolePath: String

    public var id: String { route }

    /// Table and detail pages render natively (section 5.9); every other kind opens on the web.
    public var isNative: Bool { ExtensionPageModel.Kind(kind) != .web }
}

public enum PlatformPluginPages {
    /// The console's `pluginPages`.
    public static func pages(pluginID: String, ui: PlatformManifestUI?) -> [PlatformPluginPage] {
        guard let ui else { return [] }
        var seen = Set<String>()
        var out: [PlatformPluginPage] = []
        func add(_ route: String, _ title: String) {
            guard !route.isEmpty, seen.insert(route).inserted else { return }
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            let kind = ui.views.first { $0.route == route }?.kind ?? ""
            out.append(PlatformPluginPage(route: route, title: trimmed.isEmpty ? route : trimmed, kind: kind, consolePath: "/plugins/\(pluginID)/\(route)"))
        }
        for entry in ui.nav { add(entry.route, entry.title) }
        for view in ui.views { add(view.route, view.title) }
        return out
    }
}

/// One plugin as every reader sees it, merged from whichever reads the
/// token holds (the console's `mergePluginRows`): the lifecycle read
/// (plugin:admin) carries runtime, digest and transitions; the registered
/// read (audit:read) the manifest; the contributions read (anyone) the
/// active plugins and their pages.
public struct PlatformPluginRow: Hashable, Sendable, Identifiable {
    public struct Transition: Hashable, Sendable {
        /// "verified", "installed", "activated" or "disabled".
        public var key: String
        public var at: Date
    }

    public var id: String
    public var name: String
    public var type: String
    public var version: String
    public var publisher: String
    public var capabilities: [String]
    public var status: String
    public var runtime: PlatformRuntimeStatus?
    public var available: Bool?
    public var artifactSHA256: String
    public var transitions: [Transition]
    public var pages: [PlatformPluginPage]
    public var interfaces: [PlatformInterface]
    public var lifecycleRead: Bool

    public init(id: String, name: String) {
        self.id = id
        self.name = name.isEmpty ? id : name
        type = ""
        version = ""
        publisher = ""
        capabilities = []
        status = ""
        artifactSHA256 = ""
        transitions = []
        pages = []
        interfaces = []
        lifecycleRead = false
    }

    public var health: PlatformPluginHealth { PlatformPluginHealth.of(self) }
    public var risk: PlatformCapabilityRisk { PlatformCapabilityRisk.highest(capabilities) }
    public var nextLifecycleStates: [String] { PlatformLifecycle.next(from: status) }
}

public enum PlatformPluginRows {
    public static func merge(registered: [PlatformPlugin]?, lifecycle: [PlatformInstallation]?, contributions: [PlatformPlugin]?) -> [PlatformPluginRow] {
        var rows: [String: PlatformPluginRow] = [:]
        var order: [String] = []
        func row(_ id: String, _ name: String) -> PlatformPluginRow {
            if let existing = rows[id] { return existing }
            order.append(id)
            return PlatformPluginRow(id: id, name: name)
        }
        for install in lifecycle ?? [] {
            var current = row(install.id, install.name)
            current.name = install.name.isEmpty ? install.id : install.name
            current.type = install.type
            current.version = install.version
            current.publisher = install.publisher
            current.capabilities = install.capabilities
            current.status = install.status
            current.runtime = install.runtime
            current.available = install.available
            current.artifactSHA256 = install.artifactSHA256
            current.lifecycleRead = true
            var transitions: [PlatformPluginRow.Transition] = []
            if let at = install.verifiedAt { transitions.append(.init(key: "verified", at: at)) }
            if let at = install.installedAt { transitions.append(.init(key: "installed", at: at)) }
            if let at = install.activatedAt { transitions.append(.init(key: "activated", at: at)) }
            if let at = install.disabledAt { transitions.append(.init(key: "disabled", at: at)) }
            current.transitions = transitions.sorted { $0.at < $1.at }
            rows[install.id] = current
        }
        for source in [registered ?? [], contributions ?? []] {
            for plugin in source {
                var current = row(plugin.id, plugin.name)
                if current.type.isEmpty { current.type = plugin.type }
                if current.version.isEmpty { current.version = plugin.version }
                if current.publisher.isEmpty { current.publisher = plugin.publisher }
                if current.capabilities.isEmpty, !plugin.capabilities.isEmpty { current.capabilities = plugin.capabilities }
                if current.status.isEmpty { current.status = plugin.status.isEmpty ? (plugin.active ? "active" : "") : plugin.status }
                if current.pages.isEmpty { current.pages = PlatformPluginPages.pages(pluginID: plugin.id, ui: plugin.ui) }
                if current.interfaces.isEmpty { current.interfaces = plugin.interfaces }
                rows[plugin.id] = current
            }
        }
        return order.compactMap { rows[$0] }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// What a plugin amounts to right now (`pluginHealth`). Only an active
/// plugin whose runtime is armed answers calls; without the lifecycle read
/// an active plugin is never claimed to be running.
public enum PlatformPluginHealth: String, Sendable, Hashable, CaseIterable {
    case running, failed, stopped, missing, disabled, pending, unknown

    public static func of(_ row: PlatformPluginRow) -> PlatformPluginHealth {
        if row.lifecycleRead, row.available == false { return .missing }
        if row.status == "disabled" { return .disabled }
        if row.status == "verified" || row.status == "installed" { return .pending }
        guard row.status == "active" else { return .unknown }
        guard row.lifecycleRead, let runtime = row.runtime else { return .unknown }
        if runtime.state == "failed" { return .failed }
        if runtime.state == "armed" { return .running }
        return .stopped
    }

    /// Worst first, for grouping.
    public var rank: Int {
        switch self {
        case .failed: 0
        case .missing: 1
        case .stopped: 2
        case .pending: 3
        case .unknown: 4
        case .running: 5
        case .disabled: 6
        }
    }
}

/// The server's capability risk (`capabilityRisk` in `plugin.go`). Host
/// risk forces a trusted publisher signature.
public enum PlatformCapabilityRisk: String, Sendable, Hashable, Comparable {
    case read, write, host, unknown

    static let table: [String: PlatformCapabilityRisk] = [
        "audit:read": .read, "kv:read": .read, "monitor:read": .read, "netguard:read": .read, "netpolicy:read": .read,
        "node:read": .read, "static:read": .read, "task:read": .read, "wireguard:read": .read,
        "kv:write": .write, "log:write": .write, "notify:send": .write,
        "http:egress": .host, "http:operator-target": .host, "ddns:admin": .host, "monitor:admin": .host,
        "netguard:admin": .host, "network:apply": .host, "network:plan": .host, "netpolicy:admin": .host,
        "node:admin": .host, "static:write": .host, "subscription:serve": .host, "task:run": .host,
        "task:schedule": .host, "tunnel:admin": .host, "wireguard:admin": .host, "rpc:call": .host,
        "rpc:expose": .host, "secret:read": .host, "secret:write": .host,
    ]

    public static func of(_ capability: String) -> PlatformCapabilityRisk {
        table[capability] ?? .unknown
    }

    /// The highest known risk among a plugin's capabilities; unknown only when none is known.
    public static func highest(_ capabilities: [String]) -> PlatformCapabilityRisk {
        capabilities.map(of).filter { $0 != .unknown }.max() ?? .unknown
    }

    private var order: Int {
        switch self {
        case .unknown: 0
        case .read: 1
        case .write: 2
        case .host: 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}

public enum PlatformLifecycle {
    /// The lifecycle states a plugin can move to from where it is (`nextLifecycleStates`).
    public static func next(from status: String) -> [String] {
        switch status {
        case "verified": ["installed"]
        case "installed": ["active"]
        case "active": ["disabled"]
        case "disabled": ["active"]
        default: []
        }
    }
}

// MARK: - Publishing

/// The origin filter of Publishing (`PUBLISHING_LENSES`).
public enum PlatformPublishingLens: String, Sendable, Hashable, CaseIterable, Identifiable {
    public var id: String { rawValue }

    case all, kv, `static`, share

    public var title: String {
        switch self {
        case .all: "All"
        case .kv: "KV"
        case .static: "Static"
        case .share: "Share"
        }
    }

    /// The server origin a lens shows, or nil for the whole plane.
    public var origin: String? {
        switch self {
        case .all: nil
        case .kv: "kv"
        case .static: "static"
        case .share: "plugin"
        }
    }

    public func filter(_ records: [PlatformPublishingRecord]) -> [PlatformPublishingRecord] {
        guard let origin else { return records }
        return records.filter { $0.origin == origin }
    }
}

/// Whether a route answers right now. Expired is kept apart from disabled:
/// one was turned off on purpose, the other ran out unnoticed.
public enum PlatformRouteState: String, Sendable, Hashable {
    case serving, disabled, expired

    public static func of(_ record: PlatformPublishingRecord, now: Date) -> PlatformRouteState {
        if !record.enabled { return .disabled }
        if let expiry = record.expiresAt, expiry <= now { return .expired }
        return .serving
    }
}

/// Who may fetch a route (`accessMode`).
public enum PlatformAccessMode: String, Sendable, Hashable {
    case storageToken, anonymous, shareToken, unknown

    public static func of(origin: String) -> PlatformAccessMode {
        switch origin {
        case "kv": .storageToken
        case "static": .anonymous
        case "plugin": .shareToken
        default: .unknown
        }
    }

    public var sentence: String {
        switch self {
        case .storageToken: "Needs a storage token, even to read"
        case .anonymous: "Anyone with the URL can read it"
        case .shareToken: "Read with the token in the share URL"
        case .unknown: "Access rule not known to this app"
        }
    }
}

public enum PlatformPublishing {
    static let originOrder = ["kv", "static", "plugin"]

    /// The path a route answers on, rooted and without a trailing slash.
    public static func routePath(_ record: PlatformPublishingRecord) -> String {
        let prefix = record.pathPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return prefix.isEmpty ? "/" : "/\(prefix)"
    }

    /// "files.example.net/docs"; a route with no host answers on every host.
    public static func routeLabel(_ record: PlatformPublishingRecord, anyHost: String = "*") -> String {
        let host = record.anyHost || record.hostname.isEmpty ? anyHost : record.hostname
        let path = routePath(record)
        return path == "/" ? host : host + path
    }

    /// What the origin points at: a bucket, or for plugin routes the owning share.
    public static func originTarget(_ record: PlatformPublishingRecord) -> String {
        guard record.origin == "plugin" else { return record.bucket }
        if !record.shareID.isEmpty { return record.shareID }
        return record.bucket
    }

    /// The share's `/slug` when the share list is known, else the id.
    public static func originTargetLabel(_ record: PlatformPublishingRecord, shareSlugs: [String: String]) -> String {
        let target = originTarget(record)
        guard record.origin == "plugin" else { return target }
        return shareSlugs[target].map { "/\($0)" } ?? target
    }

    /// Origin in display order, then host, then path.
    public static func sorted(_ records: [PlatformPublishingRecord]) -> [PlatformPublishingRecord] {
        func rank(_ origin: String) -> Int { originOrder.firstIndex(of: origin) ?? originOrder.count }
        return records.sorted { a, b in
            if rank(a.origin) != rank(b.origin) { return rank(a.origin) < rank(b.origin) }
            if a.hostname != b.hostname { return a.hostname < b.hostname }
            return routePath(a) < routePath(b)
        }
    }

    /// The storage kind a kv or static route belongs to; nil for plugin routes.
    public static func storageKind(_ record: PlatformPublishingRecord) -> PlatformStorageKind? {
        PlatformStorageKind(rawValue: record.origin)
    }
}

/// A share's state (`publishedState`, without the proxy-user check, which
/// needs a read this module does not own).
public enum PlatformShareState: String, Sendable, Hashable {
    case live, expiring, paused, expired

    /// How soon an expiry is worth warning about.
    public static let expiringSoon: TimeInterval = 7 * 86_400

    public static func of(_ share: PlatformShare, now: Date) -> PlatformShareState {
        if !share.enabled { return .paused }
        if let expiry = share.expiresAt {
            if expiry <= now { return .expired }
            if expiry.timeIntervalSince(now) <= expiringSoon { return .expiring }
        }
        return .live
    }

    public var isServing: Bool { self == .live || self == .expiring }
}

/// How a share's render budget reads (`renderBudgetTone`).
public enum PlatformRenderBudgetTone: String, Sendable, Hashable {
    case none, quiet, warning, exhausted

    public static func of(_ budget: PlatformShareRenderBudget?) -> PlatformRenderBudgetTone {
        guard let budget else { return .none }
        if budget.exhausted { return .exhausted }
        if budget.refused > 0 || budget.remaining <= Swift.max(1, budget.burst / 4) { return .warning }
        return .quiet
    }
}

public enum PlatformShares {
    /// Who produces the bytes (`sourceLabel`).
    public static func sourceLabel(_ share: PlatformShare) -> String {
        let source = share.source
        if source.isPlugin {
            return "\(source.pluginID.isEmpty ? "plugin" : source.pluginID) · \(source.subscriptionID.isEmpty ? "?" : source.subscriptionID)"
        }
        return "proxy user · \(source.proxyUserID.isEmpty ? "?" : source.proxyUserID)"
    }

    /// The identity whose credentials the share publishes, if it names one.
    public static func owner(_ share: PlatformShare) -> String? {
        if !share.source.identityID.isEmpty { return share.source.identityID }
        if !share.source.proxyUserID.isEmpty { return share.source.proxyUserID }
        return nil
    }

    /// Only a plugin-sourced share has a provider to refresh (`refreshSubscriptionShare`).
    public static func canRefresh(_ share: PlatformShare) -> Bool { share.source.isPlugin }

    /// A revealed URL with its token cut to the ends (`maskedUrl`).
    public static func maskedURL(_ url: String) -> String {
        guard let slash = url.lastIndex(of: "/") else { return url }
        let token = url[url.index(after: slash)...]
        guard token.count > 10 else { return url }
        return "\(url[...slash])\(token.prefix(4))…\(token.suffix(4))"
    }
}

// MARK: - Store

/// Who writes into a bucket (`bucketOwner`). The inventory carries no owner
/// field, so this mirrors the rules the server pins writers with.
public enum PlatformBucketOwner: String, Sendable, Hashable {
    case `operator`, plugin, server, agent

    public static let agentReleasesBucket = "agent-releases"
    public static let lineMetaPrefix = "vpnmeta/"
    public static let pluginPrefix = "plugin:"

    public static func of(name: String, kind: String, reserved: Bool) -> PlatformBucketOwner {
        if reserved { return .server }
        if name.hasPrefix(pluginPrefix) { return .plugin }
        if kind == "kv", name.hasPrefix(lineMetaPrefix) { return .server }
        if kind == "static", name == agentReleasesBucket { return .agent }
        return .operator
    }

    public static func of(_ entry: PlatformBucketInventoryEntry) -> PlatformBucketOwner {
        of(name: entry.name, kind: entry.kind, reserved: entry.reserved)
    }

    /// Whether the listing carries bytes (`bucketContentAvailable`).
    public static func contentAvailable(name: String, kind: String, reserved: Bool) -> Bool {
        of(name: name, kind: kind, reserved: reserved) != .agent
    }

    /// The plugin id of a plugin-owned bucket.
    public static func pluginID(_ entry: PlatformBucketInventoryEntry) -> String? {
        of(entry) == .plugin ? String(entry.name.dropFirst(pluginPrefix.count)) : nil
    }

    /// The owner sentence the bucket screen shows.
    public var sentence: String {
        switch self {
        case .operator: "Operator bucket"
        case .plugin: "Written by a plugin"
        case .server: "Written by the server"
        case .agent: "Agent release binaries"
        }
    }
}

public enum PlatformStorageTokens {
    /// Whether a live token can write a bucket from outside the console (`tokenWritesBucket`).
    public static func writes(_ token: PlatformStorageToken, bucket: String, kind: String) -> Bool {
        guard !token.isRevoked, token.kind == kind, token.access == "write" || token.access == "admin" else { return false }
        return token.buckets.isEmpty || token.buckets.contains { $0 == "*" || $0 == bucket }
    }

    /// "All KV buckets" or the bucket list.
    public static func bucketsLabel(_ token: PlatformStorageToken) -> String {
        let kind = PlatformStorageKind(rawValue: token.kind)?.title ?? token.kind
        if token.buckets.isEmpty || token.buckets.contains("*") { return "All \(kind) buckets" }
        return token.buckets.joined(separator: ", ")
    }
}

public enum PlatformStoreContent {
    /// Whether a value can be shown as text. KV values are text; a static
    /// object is text when its type says so, or when it has no type.
    public static func isText(contentType: String) -> Bool {
        let type = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if type.isEmpty || type.hasPrefix("text/") { return true }
        let textual = ["application/json", "application/xml", "application/yaml", "application/x-yaml", "application/javascript",
                       "application/toml", "application/x-sh", "image/svg+xml"]
        return textual.contains(type) || type.hasSuffix("+json") || type.hasSuffix("+xml")
    }
}

// MARK: - System

public enum PlatformSystem {
    /// The ranges `parseMetricsWindow` accepts.
    public static let ranges = ["1h", "6h", "24h", "7d", "30d", "90d", "1y", "5y"]

    /// The control-plane series the System charts read.
    public static let chartSeries = ["host.mem_used", "host.mem_total", "host.load1", "proc.rss", "proc.heap", "proc.cpu", "host.disk_used", "host.disk_total"]

    /// One chart point.
    public struct Point: Hashable, Sendable {
        public var date: Date
        public var value: Double
    }

    /// The points of a series split into segments wherever buckets are more
    /// than 2.5 steps apart, so a chart never draws across missing data
    /// (section 4.6). Null values drop the bucket.
    public static func segments(_ series: PlatformMetricSeries?, stepSeconds: Int64) -> [[Point]] {
        guard let series else { return [] }
        var segments: [[Point]] = []
        var current: [Point] = []
        var lastT: Int64?
        let limit = Double(Swift.max(stepSeconds, 1)) * 2.5
        for (index, t) in series.t.enumerated() {
            guard index < series.avg.count, let value = series.avg[index], value.isFinite else { continue }
            if let lastT, Double(t - lastT) > limit, !current.isEmpty {
                segments.append(current)
                current = []
            }
            current.append(Point(date: Date(timeIntervalSince1970: TimeInterval(t)), value: value))
            lastT = t
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// The newest value of a series.
    public static func latest(_ series: PlatformMetricSeries?) -> Double? {
        guard let series else { return nil }
        return zip(series.t, series.avg).reversed().first { $0.1 != nil }?.1 ?? nil
    }

    /// Failures as a fraction of calls.
    public static func errorRate(_ row: PlatformSystemEventRow) -> Double {
        row.calls == 0 ? 0 : Double(row.errors) / Double(row.calls)
    }
}

// MARK: - Query fields

/// The Plugins list's query fields (section 6.14).
public enum PlatformPluginQueryFields: QueryFieldProvider {
    public typealias Row = PlatformPluginRow

    public static var fields: [LatticeQueryField<PlatformPluginRow>] {
        [
            LatticeQueryField(key: "name", type: .string, get: { .string($0.name) }),
            LatticeQueryField(key: "id", type: .string, get: { .string($0.id) }),
            LatticeQueryField(key: "publisher", type: .string, get: { $0.publisher.isEmpty ? .none : .string($0.publisher) }),
            LatticeQueryField(key: "type", type: .enumeration, values: ["system", "wasm", "worker"], get: { .string($0.type) }),
            LatticeQueryField(key: "status", aliases: ["lifecycle"], type: .enumeration, values: ["verified", "installed", "active", "disabled"], get: { .string($0.status) }),
            LatticeQueryField(key: "health", aliases: ["state"], type: .enumeration, values: PlatformPluginHealth.allCases.map(\.rawValue),
                              valueAliases: ["armed": "running", "waiting": "pending"], get: { .string($0.health.rawValue) }),
            LatticeQueryField(key: "risk", type: .enumeration, values: ["read", "write", "host", "unknown"], get: { .string($0.risk.rawValue) }),
            LatticeQueryField(key: "capability", aliases: ["cap", "capabilities"], type: .list, get: { .strings($0.capabilities) }),
            LatticeQueryField(key: "version", type: .version, get: { $0.version.isEmpty ? .none : .string($0.version) }),
        ]
    }

    public static func text(_ row: PlatformPluginRow) -> [String] {
        [row.name, row.id, row.publisher]
    }
}

/// The Publishing routes' query fields.
public enum PlatformRecordQueryFields: QueryFieldProvider {
    public typealias Row = PlatformPublishingRecord

    public static var fields: [LatticeQueryField<PlatformPublishingRecord>] {
        [
            LatticeQueryField(key: "origin", type: .enumeration, values: ["kv", "static", "plugin"], valueAliases: ["share": "plugin"], get: { .string($0.origin) }),
            LatticeQueryField(key: "host", aliases: ["hostname"], type: .string, get: { $0.anyHost ? .string("*") : .string($0.hostname) }),
            LatticeQueryField(key: "path", type: .string, get: { .string(PlatformPublishing.routePath($0)) }),
            LatticeQueryField(key: "bucket", aliases: ["target"], type: .string, get: { .string(PlatformPublishing.originTarget($0)) }),
            LatticeQueryField(key: "state", aliases: ["status"], type: .enumeration, values: ["serving", "disabled", "expired"],
                              get: { .string(PlatformRouteState.of($0, now: Date()).rawValue) }),
            LatticeQueryField(key: "reserved", type: .bool, flag: true, sortable: false, get: { .bool($0.reserved) }),
            LatticeQueryField(key: "expires", type: .time, get: { $0.expiresAt.map { .time($0) } ?? .none }),
        ]
    }

    public static func text(_ row: PlatformPublishingRecord) -> [String] {
        [row.hostname, row.pathPrefix, row.bucket, row.id]
    }
}

/// The storage tokens' query fields.
public enum PlatformTokenQueryFields: QueryFieldProvider {
    public typealias Row = PlatformStorageToken

    public static var fields: [LatticeQueryField<PlatformStorageToken>] {
        [
            LatticeQueryField(key: "name", type: .string, get: { .string($0.name) }),
            LatticeQueryField(key: "kind", type: .enumeration, values: ["kv", "static"], get: { .string($0.kind) }),
            LatticeQueryField(key: "access", type: .enumeration, values: ["read", "write", "admin"], get: { .string($0.access) }),
            LatticeQueryField(key: "bucket", aliases: ["buckets"], type: .list, get: { .strings($0.buckets) }),
            LatticeQueryField(key: "revoked", type: .bool, flag: true, sortable: false, get: { .bool($0.isRevoked) }),
            LatticeQueryField(key: "used", aliases: ["last_used"], type: .time, get: { $0.lastUsedAt.map { .time($0) } ?? .none }),
        ]
    }

    public static func text(_ row: PlatformStorageToken) -> [String] {
        [row.name, row.id] + row.buckets
    }
}

/// The shares' query fields, for Browse search.
public enum PlatformShareQueryFields: QueryFieldProvider {
    public typealias Row = PlatformShare

    public static var fields: [LatticeQueryField<PlatformShare>] {
        [
            LatticeQueryField(key: "slug", aliases: ["name"], type: .string, get: { .string($0.slug) }),
            LatticeQueryField(key: "state", aliases: ["status"], type: .enumeration, values: ["live", "expiring", "paused", "expired"],
                              get: { .string(PlatformShareState.of($0, now: Date()).rawValue) }),
            LatticeQueryField(key: "source", type: .enumeration, values: ["plugin", "core.proxy_user"], valueAliases: ["core": "core.proxy_user"], get: { .string($0.source.kind) }),
            LatticeQueryField(key: "expires", type: .time, get: { $0.expiresAt.map { .time($0) } ?? .none }),
        ]
    }

    public static func text(_ row: PlatformShare) -> [String] {
        [row.slug, row.id, row.source.subscriptionID, row.source.proxyUserID, row.source.identityID]
    }
}
