import Foundation

/// Demo routes for the Platform domain, owned by the Platform module (section 8.6).
///
/// Four official plugins and three from the non-official publisher the
/// trust fixture names (`example-labs`): one renders table and detail pages
/// natively, one has a failed runtime, one waits to be activated. Publishing
/// has kv, static and share routes; the store has operator, plugin, server,
/// agent and reserved buckets; System has a full health reading. Lifecycle
/// changes, binding deletes, token revokes and share rotations and deletes
/// change `DemoState`, so every list reads them back.
public enum PlatformFixtures {
    public static var routes: [DemoRoute] {
        pluginRoutes + publishingRoutes + storeRoutes + systemRoutes
    }

    // MARK: - Plugins

    /// One invented plugin.
    public struct Plugin: Sendable {
        public var id: String
        public var name: String
        public var type: String
        public var version: String
        public var publisher: String
        public var capabilities: [String]
        /// The lifecycle status before any demo write.
        public var status: String
        /// "armed", "failed", "stopped" or nil for no runtime.
        public var runtime: String?
        public var runtimeMessage = ""
        public var ui: DemoJSON?
        public var interfaces: [DemoJSON] = []
    }

    public static let certWatchID = "examplelabs.cert-watch"
    public static let dnsProbeID = "examplelabs.dns-probe"

    static func sandboxUI(_ pages: [(route: String, title: String, icon: String, scope: String)]) -> DemoJSON {
        .object([
            "nav": .array(pages.map { .object(["section": "extensions", "title": .string($0.title), "route": .string($0.route), "icon": .string($0.icon), "scopes": .strings([$0.scope])]) }),
            "views": .array(pages.map { .object(["route": .string($0.route), "title": .string($0.title), "kind": "sandbox"]) }),
        ])
    }

    static func method(_ name: String, _ effect: String, _ scopes: [String]) -> DemoJSON {
        .object(["name": .string(name), "effect": .string(effect), "scopes": .strings(scopes)])
    }

    public static let plugins: [Plugin] = [
        Plugin(id: "latticenet.vpn-core", name: "vpn-core (sing-box)", type: "system", version: "0.11.0-alpha.8", publisher: "latticenet",
               capabilities: ["node:read", "network:plan", "network:apply", "task:run"], status: "active", runtime: "armed",
               ui: sandboxUI([("lines", "Lines", "Radar", "vpncore:read"), ("users", "Users", "Users", "vpncore:read"),
                              ("profiles", "Node Profiles", "ServerCog", "vpncore:read"), ("usage", "Usage", "Gauge", "vpncore:read")]),
               interfaces: [
                   .object(["service": "latticenet.vpn-core/lines", "methods": [method("list", "read", ["vpncore:read"]), method("get", "read", ["vpncore:read"]),
                                                                              method("sync_metadata", "write", ["vpncore:admin"])], "backing": "core"]),
                   .object(["service": "latticenet.vpn-core/users", "methods": [method("list", "read", ["vpncore:read"]), method("get", "read", ["vpncore:read"])], "backing": "core"]),
               ]),
        Plugin(id: "latticenet.sub-store", name: "Sub-Store companion", type: "system", version: "0.18.0-alpha.2", publisher: "latticenet",
               capabilities: ["rpc:call", "http:egress", "http:operator-target", "kv:read", "kv:write", "subscription:serve"], status: "active", runtime: "armed",
               ui: sandboxUI([("sub-store", "Sub-Store", "Store", "substore:read")]),
               interfaces: [
                   .object(["service": "latticenet.sub-store/subscription", "methods": [method("fetch", "read", ["substore:admin"]), method("probe", "read", ["substore:read"])], "backing": "runtime"]),
               ]),
        Plugin(id: "latticenet.netguard", name: "NetGuard (nftables security groups)", type: "system", version: "0.2.0-alpha.9", publisher: "latticenet",
               capabilities: ["node:read", "network:plan", "network:apply", "task:run"], status: "active", runtime: "armed",
               ui: sandboxUI([("firewall", "Inbound firewall", "Shield", "netguard:read")]),
               interfaces: [
                   .object(["service": "latticenet.netguard/firewall", "methods": [method("overview", "read", ["netguard:read"]), method("upsert_group", "write", ["netguard:admin"])], "backing": "core"]),
               ]),
        Plugin(id: "latticenet.wireguard", name: "WireGuard (VPN networks)", type: "system", version: "0.2.0-alpha.8", publisher: "latticenet",
               capabilities: ["node:read", "network:plan", "network:apply", "task:run"], status: "disabled", runtime: "stopped",
               runtimeMessage: "operator disabled plugin",
               interfaces: [
                   .object(["service": "latticenet.wireguard/networks", "methods": [method("overview", "read", ["wireguard:read"]), method("plan", "plan", ["wireguard:admin", "network:plan"])], "backing": "core"]),
               ]),
        Plugin(id: certWatchID, name: "Certificate watch", type: "wasm", version: "1.4.2", publisher: "example-labs",
               capabilities: ["http:egress", "kv:read", "kv:write"], status: "active", runtime: "armed",
               ui: .object([
                   "nav": [
                       .object(["section": "plugins", "title": "Certificates", "route": "certificates", "icon": "Shield", "scopes": .strings(["monitor:read"])]),
                       .object(["section": "plugins", "title": "Summary", "route": "summary", "icon": "Gauge", "scopes": .strings(["monitor:read"])]),
                   ],
                   "views": [
                       .object([
                           "route": "certificates", "title": "Certificates", "kind": "table",
                           "source": .object(["interface": "examplelabs.cert-watch/certs", "method": "list"]),
                           "columns": [
                               .object(["key": "host", "label": "Host"]),
                               .object(["key": "status", "label": "Status", "render": "badge"]),
                               .object(["key": "expires_at", "label": "Expires", "render": "relative-time"]),
                               .object(["key": "issuer", "label": "Issuer"]),
                               .object(["key": "chain_bytes", "label": "Chain size", "render": "bytes"]),
                               .object(["key": "fingerprint", "label": "Fingerprint", "render": "code"]),
                               .object(["key": "alert_hook", "label": "Alert hook", "render": "copy-secret"]),
                           ],
                           "actions": [
                               .object(["label": "Recheck now", "interface": "examplelabs.cert-watch/certs", "method": "recheck"]),
                           ],
                       ]),
                       .object([
                           "route": "summary", "title": "Summary", "kind": "detail",
                           "source": .object(["interface": "examplelabs.cert-watch/certs", "method": "summary"]),
                       ]),
                       .object([
                           "route": "targets", "title": "Add target", "kind": "form",
                           "actions": [
                               .object(["label": "Add target", "interface": "examplelabs.cert-watch/certs", "method": "add_target",
                                        "form": [.object(["key": "host", "label": "Host", "kind": "text"]), .object(["key": "port", "label": "Port", "kind": "int"])]]),
                           ],
                       ]),
                   ],
               ]),
               interfaces: [
                   .object(["service": "examplelabs.cert-watch/certs", "methods": [
                       method("list", "read", ["monitor:read"]), method("summary", "read", ["monitor:read"]),
                       method("recheck", "write", ["monitor:admin"]), method("add_target", "write", ["monitor:admin"]),
                   ]]),
               ]),
        Plugin(id: dnsProbeID, name: "DNS probe", type: "wasm", version: "0.9.1", publisher: "example-labs",
               capabilities: ["http:egress", "kv:write"], status: "active", runtime: "failed",
               runtimeMessage: "wasm: out of fuel after 5000000 instructions in probe.tick",
               ui: .object([
                   "nav": [.object(["section": "plugins", "title": "Resolvers", "route": "resolvers", "icon": "Radar"])],
                   "views": [.object([
                       "route": "resolvers", "title": "Resolvers", "kind": "table",
                       "source": .object(["interface": "examplelabs.dns-probe/resolvers", "method": "list"]),
                       "columns": [.object(["key": "resolver", "label": "Resolver"]), .object(["key": "p50_ms", "label": "p50 ms"])],
                   ])],
               ]),
               interfaces: [.object(["service": "examplelabs.dns-probe/resolvers", "methods": ["list"]])]),
        Plugin(id: "examplelabs.port-audit", name: "Port audit", type: "wasm", version: "0.3.0", publisher: "example-labs",
               capabilities: ["node:read", "kv:write"], status: "installed", runtime: nil),
    ]

    static func statusKey(_ id: String) -> String { "platform.plugin.status.\(id)" }

    static func status(of plugin: Plugin, state: DemoState) async -> String {
        await state.value(for: statusKey(plugin.id)) ?? plugin.status
    }

    /// `pluginView` as `/api/plugins` writes it; the UI only while active.
    static func registeredJSON(_ plugin: Plugin, status: String) -> DemoJSON {
        .object([
            "id": .string(plugin.id), "name": .string(plugin.name), "type": .string(plugin.type), "version": .string(plugin.version),
            "publisher": .string(plugin.publisher), "capabilities": .strings(plugin.capabilities), "status": .string(status),
            "active": .bool(status == "active"), "ui": status == "active" ? plugin.ui : nil,
            "interfaces": plugin.interfaces.isEmpty ? nil : .array(plugin.interfaces),
        ])
    }

    static func contributionJSON(_ plugin: Plugin) -> DemoJSON {
        .object([
            "id": .string(plugin.id), "name": .string(plugin.name), "type": .string(plugin.type), "version": .string(plugin.version),
            "publisher": .string(plugin.publisher), "capabilities": [], "status": "active", "active": true, "ui": plugin.ui,
            "interfaces": plugin.interfaces.isEmpty ? nil : .array(plugin.interfaces),
        ])
    }

    static func installationJSON(_ plugin: Plugin, status: String) -> DemoJSON {
        let changed = status != plugin.status
        var runtimeState = plugin.runtime
        var message = plugin.runtimeMessage
        if changed {
            runtimeState = status == "active" ? "armed" : (status == "disabled" ? "stopped" : nil)
            message = status == "disabled" ? "operator disabled plugin" : ""
        }
        let runtime: DemoJSON? = runtimeState.map { state in
            .object([
                "plugin_id": .string(plugin.id), "state": .string(state), "runner": .string(plugin.type == "system" ? "core" : "wasm"),
                "message": message.isEmpty ? nil : .string(message),
                "started_at": state == "stopped" ? nil : .time(changed ? "-5s" : "-3d"),
                "stopped_at": state == "stopped" ? .time(changed ? "-5s" : "-9d") : nil,
                "updated_at": .time(state == "failed" ? "-14m" : (changed ? "-5s" : "-3d")),
            ])
        }
        return .object([
            "id": .string(plugin.id), "name": .string(plugin.name), "type": .string(plugin.type), "version": .string(plugin.version),
            "entrypoint": plugin.type == "wasm" ? "plugin.wasm" : nil, "publisher": .string(plugin.publisher),
            "capabilities": .strings(plugin.capabilities),
            "artifact_sha256": .string(digest(plugin.id)), "available": true, "status": .string(status), "runtime": runtime,
            "verified_at": .time("-40d"), "installed_at": .time("-39d"),
            "activated_at": status == "active" ? .time(changed ? "-5s" : "-21d") : (plugin.status == "disabled" ? .time("-30d") : nil),
            "disabled_at": status == "disabled" ? .time(changed ? "-5s" : "-9d") : nil,
            "created_at": .time("-40d"), "updated_at": .time(changed ? "-5s" : "-3d"),
        ])
    }

    /// A stable invented artifact digest for a plugin id.
    static func digest(_ seed: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        var out = ""
        for round in 0..<4 {
            for byte in (seed + String(round)).utf8 {
                hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
            out += String(format: "%016llx", hash)
        }
        return out
    }

    static let certificateRows: DemoJSON = [
        .object(["id": "c-1", "host": "status.example.net", "status": "ok", "expires_at": .time("+61d"), "issuer": "Example Trust R3",
                 "chain_bytes": 4_812, "fingerprint": "5f:1c:9a:2e:77:04", "alert_hook": "https://hooks.example.org/cert/7f3a9b2c"]),
        .object(["id": "c-2", "host": "docs.example.net", "status": "renew soon", "expires_at": .time("+9d"), "issuer": "Example Trust R3",
                 "chain_bytes": 4_790, "fingerprint": "a0:44:3e:91:c2:18", "alert_hook": "https://hooks.example.org/cert/7f3a9b2c"]),
        .object(["id": "c-3", "host": "files.example.org", "status": "expired", "expires_at": .time("-2d"), "issuer": "Contoso CA G2",
                 "chain_bytes": 6_103, "fingerprint": "c9:7d:01:5b:ee:3a", "alert_hook": .null]),
        .object(["id": "c-4", "host": "cfg.example.org", "status": "ok", "expires_at": .time("+180d"), "issuer": "Contoso CA G2",
                 "chain_bytes": 6_088, "fingerprint": "17:b2:84:fd:60:9e", "alert_hook": "https://hooks.example.org/cert/7f3a9b2c"]),
    ]

    static let certificateSummary: DemoJSON = .object([
        "targets": 4, "healthy": 2, "expiring_within_14d": 1, "expired": 1,
        "last_run": .time("-6m"), "next_run": .time("+54m"), "probe_region": "Frankfurt",
    ])

    static var pluginRoutes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/plugins", body: "[]") { _, state in
                var items: [DemoJSON] = []
                for plugin in plugins {
                    let current = await status(of: plugin, state: state)
                    items.append(registeredJSON(plugin, status: current))
                }
                return .json(DemoJSON.array(items).text)
            }.requiring("audit:read"),
            DemoRoute(pathPattern: "/api/plugin-contributions", body: "[]") { _, state in
                var items: [DemoJSON] = []
                for plugin in plugins where plugin.ui != nil {
                    if await status(of: plugin, state: state) == "active" { items.append(contributionJSON(plugin)) }
                }
                return .json(DemoJSON.array(items).text)
            },
            DemoRoute(pathPattern: "/api/plugins/lifecycle", body: "[]") { _, state in
                var items: [DemoJSON] = []
                for plugin in plugins {
                    let current = await status(of: plugin, state: state)
                    items.append(installationJSON(plugin, status: current))
                }
                return .json(DemoJSON.array(items).text)
            }.requiring("plugin:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/plugins/lifecycle") { request, state in
                let body = request.bodyStrings
                guard let id = body["id"], let target = body["status"], !id.isEmpty, !target.isEmpty else {
                    return .error(status: 400, code: "bad_request", message: "id and status are required")
                }
                guard let plugin = plugins.first(where: { $0.id == id }) else {
                    return .error(status: 400, code: "bad_request", message: "plugin bundle is not currently verified and loaded: \(id)")
                }
                await state.setValue(target, for: statusKey(id))
                return .json(installationJSON(plugin, status: target).text)
            }.requiring("plugin:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/plugins/call", bodyMatch: ["id": certWatchID, "method": "list"], body: certificateRows.text),
            DemoRoute(method: "POST", pathPattern: "/api/plugins/call", bodyMatch: ["id": certWatchID, "method": "summary"], body: certificateSummary.text),
            DemoRoute(method: "POST", pathPattern: "/api/plugins/call", bodyMatch: ["id": dnsProbeID], status: 502,
                      body: #"{"error":{"code":"plugin_unavailable","message":"plugin examplelabs.dns-probe runtime is not armed","request_id":"req_demo"}}"#),
        ]
    }

    // MARK: - Publishing

    public struct Binding: Sendable {
        public var id: String
        public var kind: String
        public var bucket: String
        public var hostname: String
        public var pathPrefix = ""
        public var enabled = true
        public var created: String
    }

    public static let bindings: [Binding] = [
        Binding(id: "binding_status", kind: "kv", bucket: "status-page", hostname: "status.example.net", created: "-120d"),
        Binding(id: "binding_flags", kind: "kv", bucket: "feature-flags", hostname: "cfg.example.org", pathPrefix: "flags", enabled: false, created: "-60d"),
        Binding(id: "binding_docs", kind: "static", bucket: "docs", hostname: "docs.example.net", created: "-210d"),
        Binding(id: "binding_downloads", kind: "static", bucket: "downloads", hostname: "files.example.org", pathPrefix: "dl", created: "-45d"),
    ]

    public struct Token: Sendable {
        public var id: String
        public var name: String
        public var kind: String
        public var access: String
        public var buckets: [String]
        public var lastUsed: String?
        public var revoked: String?
        public var created: String
    }

    public static let tokens: [Token] = [
        Token(id: "stok_status_writer", name: "status-page updater", kind: "kv", access: "write", buckets: ["status-page"], lastUsed: "-4m", created: "-120d"),
        Token(id: "stok_flags_ci", name: "CI feature flags", kind: "kv", access: "write", buckets: ["feature-flags"], lastUsed: "-2d", created: "-60d"),
        Token(id: "stok_kv_legacy", name: "legacy admin", kind: "kv", access: "admin", buckets: [], lastUsed: "-41d", revoked: "-30d", created: "-300d"),
        Token(id: "stok_docs_deploy", name: "docs deploy", kind: "static", access: "write", buckets: ["docs"], lastUsed: "-1h", created: "-210d"),
        Token(id: "stok_mirror_reader", name: "mirror reader", kind: "static", access: "read", buckets: ["downloads"], lastUsed: nil, created: "-45d"),
    ]

    public struct Share: Sendable {
        public var id: String
        public var slug: String
        public var pluginSubscription: String?
        public var proxyUser: String?
        public var identity: String?
        public var enabled = true
        public var expires: String?
        public var interval = 2
        public var budget: DemoJSON?
        public var created: String
        public var rotated: String?
    }

    public static let shares: [Share] = [
        Share(id: "share_family", slug: "family", pluginSubscription: "sub_family", expires: "+9d", interval: 6,
              budget: .object(["remaining": 41, "burst": 60, "per_hour": 30, "exhausted": false, "refused": 0]), created: "-200d", rotated: "-20d"),
        Share(id: "share_ops", slug: "ops-laptops", pluginSubscription: "sub_ops", identity: "vid_ops_team", expires: "+60d",
              budget: .object(["remaining": 0, "burst": 60, "per_hour": 30, "exhausted": true, "refused": 14, "last_refused_at": .time("-12m")]), created: "-90d"),
        Share(id: "share_travel", slug: "travel-kit", proxyUser: "pu_alice", created: "-150d"),
        Share(id: "share_contractor", slug: "contractor-q3", pluginSubscription: "sub_contractor", enabled: false, created: "-120d", rotated: "-70d"),
        Share(id: "share_trial", slug: "trial-october", proxyUser: "pu_trial", expires: "-3d", created: "-33d"),
    ]

    /// The URL every demo share reveals; obviously not a real token.
    public static func revealedURL(_ share: Share) -> String {
        "https://demo.lattice.invalid/sub/\(share.slug)/demo-share-token-0000-notasecret"
    }

    static let deletedBindings = "platform.bindings.deleted"
    static let revokedTokens = "platform.tokens.revoked"
    static let deletedShares = "platform.shares.deleted"
    static func rotatedKey(_ id: String) -> String { "platform.share.rotated.\(id)" }

    static func bindingJSON(_ binding: Binding) -> DemoJSON {
        .object([
            "id": .string(binding.id), "kind": .string(binding.kind), "bucket": .string(binding.bucket), "hostname": .string(binding.hostname),
            "path_prefix": binding.pathPrefix.isEmpty ? nil : .string(binding.pathPrefix), "enabled": .bool(binding.enabled),
            "created_at": .time(binding.created), "updated_at": .time("-7d"),
        ])
    }

    static func tokenJSON(_ token: Token, revokedNow: Bool) -> DemoJSON {
        .object([
            "id": .string(token.id), "name": .string(token.name), "kind": .string(token.kind), "access": .string(token.access),
            "buckets": token.buckets.isEmpty ? nil : .strings(token.buckets),
            "revoked_at": revokedNow ? .time("-2s") : token.revoked.map { .time($0) },
            "last_used_at": token.lastUsed.map { .time($0) },
            "created_at": .time(token.created), "updated_at": revokedNow ? .time("-2s") : .time(token.revoked ?? token.created),
        ])
    }

    static func shareJSON(_ share: Share, rotatedNow: Bool) -> DemoJSON {
        let source: DemoJSON = if let subscription = share.pluginSubscription {
            .object(["kind": "plugin", "plugin_id": "latticenet.sub-store", "subscription_id": .string(subscription), "identity_id": share.identity.map { .string($0) }])
        } else {
            .object(["kind": "core.proxy_user", "proxy_user_id": .string(share.proxyUser ?? "")])
        }
        return .object([
            "id": .string(share.id), "slug": .string(share.slug), "source": source,
            "default_format": share.pluginSubscription == nil ? "clash" : nil, "enabled": .bool(share.enabled),
            "created_at": .time(share.created), "updated_at": .time(rotatedNow ? "-2s" : "-7d"),
            "rotated_at": rotatedNow ? .time("-2s") : share.rotated.map { .time($0) },
            "expires_at": share.expires.map { .time($0) }, "update_interval_hours": .number(Double(share.interval)),
            "render_budget": rotatedNow ? nil : share.budget,
        ])
    }

    static func recordJSON(_ binding: Binding) -> DemoJSON {
        .object([
            "id": .string(binding.id), "origin": .string(binding.kind), "bucket": .string(binding.bucket), "hostname": .string(binding.hostname),
            "any_host": false, "path_prefix": binding.pathPrefix.isEmpty ? nil : .string(binding.pathPrefix), "enabled": .bool(binding.enabled),
            "reserved": false, "admin_scope": .string("\(binding.kind):admin"),
        ])
    }

    static func recordJSON(_ share: Share) -> DemoJSON {
        .object([
            "id": .string(share.id), "origin": "plugin", "bucket": .string(share.id), "hostname": "", "any_host": true,
            "path_prefix": .string("sub/\(share.slug)"), "enabled": .bool(share.enabled), "expires_at": share.expires.map { .time($0) },
            "reserved": true, "share_id": .string(share.id), "admin_scope": "proxy:admin",
        ])
    }

    static let identityRecord: DemoJSON = .object([
        "id": "identity:vid_alice", "origin": "plugin", "bucket": "vid_alice", "hostname": "", "any_host": true,
        "path_prefix": "sub/alice-7k2m", "enabled": true, "reserved": true, "identity_id": "vid_alice", "admin_scope": "proxy:admin",
    ])

    static func heldScopes(_ request: DemoRequest) -> ScopeSet {
        DemoTransport.scopes(for: request.identity, scenario: request.scenario)
    }

    static func shareFor(_ request: DemoRequest) -> Share? {
        guard request.segments.count >= 3 else { return nil }
        return shares.first { $0.id == request.segments[2] }
    }

    static var publishingRoutes: [DemoRoute] {
        var routes: [DemoRoute] = [
            DemoRoute(pathPattern: "/api/publishing/records", body: "", emptyBody: #"{"records":[],"origins":["kv","static","plugin"]}"#) { request, state in
                let scopes = heldScopes(request)
                let gone = await state.members(of: deletedBindings).union(await state.members(of: deletedShares))
                var records: [DemoJSON] = []
                var origins: [DemoJSON] = []
                for origin in ["kv", "static"] where scopes.allows("\(origin):read") {
                    origins.append(.string(origin))
                    records += bindings.filter { $0.kind == origin && !gone.contains($0.id) }.map(recordJSON)
                }
                if scopes.allows(ScopeRequirement("proxy:admin", unconfined: true)) {
                    origins.append("plugin")
                    records += shares.filter { !gone.contains($0.id) }.map(recordJSON)
                    records.append(identityRecord)
                }
                return .json(DemoJSON.object(["records": .array(records), "origins": .array(origins)]).text)
            },
        ]
        for kind in ["kv", "static"] {
            routes.append(DemoRoute(pathPattern: "/api/storage/bindings", query: ["kind": kind], body: "",
                                    emptyBody: #"{"bindings":[]}"#) { _, state in
                let gone = await state.members(of: deletedBindings)
                return .json(DemoJSON.object(["bindings": .array(bindings.filter { $0.kind == kind && !gone.contains($0.id) }.map(bindingJSON))]).text)
            }.requiring("\(kind):read"))
            routes.append(DemoRoute(pathPattern: "/api/storage/tokens", query: ["kind": kind], body: "",
                                    emptyBody: #"{"tokens":[]}"#) { _, state in
                let revoked = await state.members(of: revokedTokens)
                return .json(DemoJSON.object(["tokens": .array(tokens.filter { $0.kind == kind }.map { tokenJSON($0, revokedNow: revoked.contains($0.id)) })]).text)
            }.requiring("\(kind):admin"))
        }
        routes += [
            DemoRoute(method: "POST", pathPattern: "/api/storage/bindings/delete") { request, state in
                let body = request.bodyStrings
                let kind = body["kind"] ?? ""
                guard kind == "kv" || kind == "static" else { return .error(status: 400, code: "bad_request", message: "kind must be kv or static") }
                guard heldScopes(request).allows("\(kind):admin") else { return .error(status: 403, code: "forbidden", message: "missing scope \(kind):admin") }
                let gone = await state.members(of: deletedBindings)
                guard let id = body["id"], bindings.contains(where: { $0.id == id && $0.kind == kind && !gone.contains(id) }) else {
                    return .error(status: 404, code: "not_found", message: "storage binding not found")
                }
                await state.insert(id, into: deletedBindings)
                return .json(#"{"ok":true}"#)
            },
            DemoRoute(method: "POST", pathPattern: "/api/storage/tokens/revoke") { request, state in
                let body = request.bodyStrings
                let kind = body["kind"] ?? ""
                guard kind == "kv" || kind == "static" else { return .error(status: 400, code: "bad_request", message: "kind must be kv or static") }
                guard heldScopes(request).allows("\(kind):admin") else { return .error(status: 403, code: "forbidden", message: "missing scope \(kind):admin") }
                guard let id = body["token_id"], let token = tokens.first(where: { $0.id == id && $0.kind == kind }) else {
                    return .error(status: 404, code: "not_found", message: "storage token not found")
                }
                await state.insert(id, into: revokedTokens)
                return .json(tokenJSON(token, revokedNow: true).text)
            },
            DemoRoute(pathPattern: "/api/subscription-shares", body: "[]") { request, state in
                guard !heldScopes(request).isConfined else { return .error(status: 403, code: "forbidden", message: "a node-restricted principal cannot use a fleet-wide proxy endpoint") }
                let gone = await state.members(of: deletedShares)
                var items: [DemoJSON] = []
                for share in shares where !gone.contains(share.id) {
                    let rotated = await state.value(for: rotatedKey(share.id)) != nil
                    items.append(shareJSON(share, rotatedNow: rotated))
                }
                return .json(DemoJSON.array(items).text)
            }.requiring("proxy:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/subscription-shares/*/rotate") { request, state in
                guard let share = shareFor(request), !(await state.contains(share.id, in: deletedShares)) else {
                    return .error(status: 404, code: "not_found", message: "share not found")
                }
                await state.setValue("rotated", for: rotatedKey(share.id))
                return .json(shareJSON(share, rotatedNow: true).text)
            }.requiring("proxy:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/subscription-shares/*/refresh") { request, state in
                guard let share = shareFor(request), !(await state.contains(share.id, in: deletedShares)) else {
                    return .error(status: 404, code: "not_found", message: "share not found")
                }
                guard share.pluginSubscription != nil else {
                    return .error(status: 400, code: "bad_request", message: "only a plugin-sourced share has a provider to refresh")
                }
                return .json(#"{"fetched_at":"{{now}}","bytes":18342,"stale":false,"error":""}"#)
            }.requiring("proxy:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/subscription-shares/*/reveal") { request, state in
                guard let share = shareFor(request), !(await state.contains(share.id, in: deletedShares)) else {
                    return .error(status: 404, code: "not_found", message: "share not found")
                }
                guard request.identity == .session, !(request.bodyStrings["step_up_grant"] ?? "").isEmpty else {
                    return .error(status: 403, code: "step_up_required", message: "this action needs a fresh second factor")
                }
                let url = revealedURL(share)
                let path = "/sub/\(share.slug)/demo-share-token-0000-notasecret"
                return .json(DemoJSON.object(["kind": "share", "id": .string(share.id), "slug": .string(share.slug),
                                              "token": "demo-share-token-0000-notasecret", "path": .string(path), "url": .string(url)]).text)
            }.requiring("proxy:admin"),
            DemoRoute(method: "DELETE", pathPattern: "/api/subscription-shares/*") { request, state in
                guard let share = shareFor(request), !(await state.contains(share.id, in: deletedShares)) else {
                    return .error(status: 404, code: "not_found", message: "share not found")
                }
                await state.insert(share.id, into: deletedShares)
                return DemoResponse(status: 204, body: "")
            }.requiring("proxy:admin"),
        ]
        return routes
    }

    // MARK: - Store

    public struct Bucket: Sendable {
        public var name: String
        public var kind: String
        public var registered: Bool
        public var reserved = false
        public var displayName = ""
        public var description = ""
        /// KV entries as (key, value, age) or static objects as (path, content, type, size, age).
        public var entries: [DemoJSON]
    }

    static func kv(_ bucket: String, _ key: String, _ value: String, _ age: String) -> DemoJSON {
        .object(["bucket": .string(bucket), "key": .string(key), "value": .string(value), "updated_at": .time(age)])
    }

    static func object(_ bucket: String, _ path: String, _ content: String, _ type: String, size: Int? = nil, _ age: String) -> DemoJSON {
        .object(["bucket": .string(bucket), "path": .string(path), "content": .string(content), "content_type": .string(type),
                 "size": .number(Double(size ?? content.utf8.count)), "updated_at": .time(age)])
    }

    public static let buckets: [Bucket] = [
        Bucket(name: "status-page", kind: "kv", registered: true, displayName: "Status page", description: "Component states the public status page reads.", entries: [
            kv("status-page", "banner", "Scheduled maintenance on the Frankfurt relays Saturday 02:00 to 03:00 UTC.", "-2h"),
            kv("status-page", "components/api", #"{"state":"operational","latency_ms":41}"#, "-4m"),
            kv("status-page", "components/dns", #"{"state":"operational","resolvers":4}"#, "-4m"),
            kv("status-page", "components/vpn", #"{"state":"degraded","note":"Frankfurt relay at reduced capacity"}"#, "-4m"),
            kv("status-page", "incidents/current", "[]", "-1d"),
        ]),
        Bucket(name: "feature-flags", kind: "kv", registered: true, displayName: "Feature flags", entries: [
            kv("feature-flags", "beta/new-onboarding", "false", "-6d"),
            kv("feature-flags", "rollout/geo-dns", #"{"percent":25,"regions":["tokyo","frankfurt"]}"#, "-2d"),
            kv("feature-flags", "kill/legacy-sub", "true", "-30d"),
        ]),
        Bucket(name: "default", kind: "kv", registered: true, entries: [
            kv("default", "notes/oncall", "Escalate DNS issues to the Frankfurt rotation first.", "-12d"),
        ]),
        Bucket(name: "plugin:latticenet.sub-store", kind: "kv", registered: false, entries: [
            kv("plugin:latticenet.sub-store", "db/collections", #"{"count":3}"#, "-1h"),
            kv("plugin:latticenet.sub-store", "db/subs", #"{"count":7}"#, "-1h"),
            kv("plugin:latticenet.sub-store", "settings", #"{"syncPlatform":"none","defaultTimeout":8000}"#, "-9d"),
        ]),
        Bucket(name: "vpnmeta/lineuuid", kind: "kv", registered: false, entries: [
            kv("vpnmeta/lineuuid", "line_tyo_fra", "6f1d2b9e-7a1c-4f0e-9b2d-1c3e5a7f9b0d", "-14d"),
            kv("vpnmeta/lineuuid", "line_sin_ams", "0b8e4c2a-3d5f-4a6b-8c9d-2e1f0a3b4c5d", "-14d"),
        ]),
        Bucket(name: "vpn_users", kind: "kv", registered: false, reserved: true, entries: []),
        Bucket(name: "docs", kind: "static", registered: true, displayName: "Runbooks", description: "Operator runbooks served at docs.example.net.", entries: [
            object("docs", "index.html", "<!doctype html><title>Runbooks</title><h1>Runbooks</h1><ul><li><a href=\"failover.html\">Failover</a></li></ul>", "text/html; charset=utf-8", "-3d"),
            object("docs", "runbooks/failover.md", "# Failover\n\n1. Confirm the Frankfurt relays are degraded in Monitor.\n2. Publish the Amsterdam addresses from Self-host DNS.\n3. Watch the path chart recover before closing the incident.\n", "text/markdown", "-3d"),
            object("docs", "assets/logo.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 16 16\"><rect width=\"16\" height=\"16\" rx=\"3\"/></svg>", "image/svg+xml", "-40d"),
            object("docs", "assets/topology.png", "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "image/png", size: 48_211, "-40d"),
        ]),
        Bucket(name: "downloads", kind: "static", registered: true, displayName: "Downloads", entries: [
            object("downloads", "dl/client-config.yaml", "proxies: []\nrules:\n  - MATCH,DIRECT\n", "application/yaml", "-8d"),
            object("downloads", "dl/bundle.tar.gz", "H4sIAAAAAAAAA+3BAQ0AAADCoPdPbQ43oAAAAAAAAAAAAIA3A5reHScAKAAA", "application/gzip", size: 1_482_903, "-8d"),
        ]),
        Bucket(name: "agent-releases", kind: "static", registered: false, entries: [
            object("agent-releases", "lattice-agent/v0.3.5/linux-amd64", "", "application/octet-stream", size: 14_221_312, "-6d"),
            object("agent-releases", "lattice-agent/v0.3.5/linux-arm64", "", "application/octet-stream", size: 13_402_112, "-6d"),
        ]),
    ]

    static func bucketsJSON(kind: String) -> DemoJSON {
        let ofKind = buckets.filter { $0.kind == kind }
        return .object([
            "buckets": .array(ofKind.filter(\.registered).map { bucket in
                .object(["id": .string("bkt_\(bucket.name)"), "kind": .string(kind), "name": .string(bucket.name),
                         "display_name": bucket.displayName.isEmpty ? nil : .string(bucket.displayName),
                         "description": bucket.description.isEmpty ? nil : .string(bucket.description),
                         "index_document": kind == "static" ? "index.html" : nil,
                         "created_at": .time("-200d"), "updated_at": .time("-20d")])
            }),
            "inventory": .array(ofKind.map { bucket in
                .object(["name": .string(bucket.name), "kind": .string(kind), "entries": .number(Double(bucket.reserved ? 9 : bucket.entries.count)),
                         "registered": .bool(bucket.registered), "reserved": .bool(bucket.reserved)])
            }),
        ])
    }

    static var storeRoutes: [DemoRoute] {
        var routes: [DemoRoute] = []
        for kind in ["kv", "static"] {
            routes.append(DemoRoute(pathPattern: "/api/storage/buckets", query: ["kind": kind], body: bucketsJSON(kind: kind).text,
                                    emptyBody: #"{"buckets":[],"inventory":[]}"#).requiring("\(kind):read"))
        }
        for bucket in buckets {
            let path = bucket.kind == "kv" ? "/api/kv" : "/api/static"
            if bucket.reserved {
                routes.append(DemoRoute(pathPattern: path, query: ["bucket": bucket.name]) { _, _ in
                    .error(status: 403, code: "forbidden", message: "bucket is reserved for typed private state")
                })
            } else {
                routes.append(DemoRoute(pathPattern: path, query: ["bucket": bucket.name], body: DemoJSON.array(bucket.entries).text).requiring("\(bucket.kind):read"))
            }
        }
        return routes
    }

    // MARK: - System

    static func spark(_ seed: String, calls: Double, errors: Double = 0, p95: Double) -> DemoJSON {
        let points = 48
        let values = (0..<points).map { index -> Double in
            let wave = sin(Double(index) / 7 + Double(seed.utf8.count)) * 0.3 + 1
            return max(0, (calls / Double(points) * wave).rounded())
        }
        return .object([
            "step_seconds": 1_800,
            "t": .array((0..<points).map { .number(Double($0 * 1_800)) }),
            "n": .array(values.map { .number($0) }),
            "e": errors > 0 ? .array(values.map { .number(($0 * errors).rounded()) }) : nil,
            "p95": .array((0..<points).map { index in .number((p95 * (1 + sin(Double(index) / 5) * 0.2) * 1000).rounded() / 1000) }),
        ])
    }

    static func eventRow(_ name: String, plugin: String? = nil, calls: Double, errors: Double = 0, p50: Double, p95: Double, max: Double) -> DemoJSON {
        .object([
            "plugin": plugin.map { .string($0) }, "name": .string(name), "calls": .number(calls), "errors": .number((calls * errors).rounded()),
            "per_minute": .number((calls / 1_440 * 100).rounded() / 100), "p50_seconds": .number(p50), "p95_seconds": .number(p95),
            "max_seconds": .number(max), "avg_seconds": .number((p50 * 1.2 * 10_000).rounded() / 10_000),
            "spark": spark(name, calls: calls, errors: errors, p95: p95),
        ])
    }

    static let systemHealth: DemoJSON = .object([
        "observed_at": .time(), "range": "24h", "from": .time("-24h"), "to": .time(),
        "process": .object([
            "started_at": .time("-6d"), "uptime_seconds": 518_400, "version": "alpha-0.4.2a151", "commit": "d0452d6",
            "go_version": "go1.26.4", "cpus": 4, "cpu_percent": 3.8, "rss_bytes": 241_172_480, "heap_bytes": 96_468_992,
            "go_total_bytes": 158_334_976, "goroutines": 412, "gc_pause_max_seconds": 0.0042, "open_fds": 118,
        ]),
        "host": .object([
            "load1": 0.42, "load5": 0.51, "load15": 0.47, "mem_total_bytes": 8_589_934_592, "mem_available_bytes": 4_982_833_152,
            "data_dir": "/var/lib/lattice", "disk_total_bytes": 85_899_345_920, "disk_free_bytes": 52_613_349_376, "disk_used_bytes": 33_285_996_544,
        ]),
        "files": [
            .object(["label": "state", "path": "/var/lib/lattice/state.db", "size_bytes": 412_090_368, "spark": spark("state", calls: 4_800, p95: 0)]),
            .object(["label": "audit", "path": "/var/lib/lattice/audit.log", "size_bytes": 1_288_490_188, "spark": spark("audit", calls: 4_800, p95: 0)]),
            .object(["label": "metrics", "path": "/var/lib/lattice/metrics.db", "size_bytes": 2_147_483_648, "spark": spark("metrics", calls: 4_800, p95: 0)]),
            .object(["label": "logs", "path": "/var/lib/lattice/logs", "spark": spark("logs", calls: 0, p95: 0)]),
        ],
        "store": [
            eventRow("heartbeat", calls: 302_400, p50: 0.0011, p95: 0.0042, max: 0.081),
            eventRow("audit.append", calls: 18_230, p50: 0.0009, p95: 0.0031, max: 0.044),
            eventRow("plugin.kv", calls: 6_120, errors: 0.002, p50: 0.0014, p95: 0.0062, max: 0.12),
        ],
        "http": [
            eventRow("/api/agent", calls: 302_400, errors: 0.0004, p50: 0.012, p95: 0.041, max: 1.8),
            eventRow("/api/monitors", calls: 9_840, p50: 0.031, p95: 0.22, max: 2.4),
            eventRow("/api/network/approvals", calls: 2_210, errors: 0.01, p50: 0.018, p95: 0.094, max: 0.61),
            eventRow("/sub", calls: 1_450, errors: 0.03, p50: 0.084, p95: 0.61, max: 4.2),
        ],
        "plugins": [
            eventRow("subscription.render", plugin: "latticenet.sub-store", calls: 1_420, errors: 0.01, p50: 0.21, p95: 1.4, max: 6.1),
            eventRow("lines.list", plugin: "latticenet.vpn-core", calls: 3_880, p50: 0.006, p95: 0.019, max: 0.3),
            eventRow("probe.tick", plugin: dnsProbeID, calls: 288, errors: 1, p50: 2.0, p95: 2.0, max: 2.0),
        ],
        "plugin_processes": [
            .object(["plugin": "latticenet.sub-store", "processes": 1_420, "cpu_seconds": 312.4, "peak_rss_bytes": 186_646_528]),
        ],
        "metrics_store": .object([
            "path": "/var/lib/lattice/metrics.db", "size_bytes": 2_147_483_648, "series": 1_842, "max_series": 4_096,
            "max_series_per_owner": 256, "owners": 41, "refused_series": [], "refused_series_more": false,
            "refused_samples": 0, "late_samples": 12, "slots_per_series": 2_880, "tiers": [],
            "last_write": .object([:]), "last_write_at": .time("-8s"), "sample_seconds": 10,
        ]),
        "probe": .object([
            "available": true, "probe_version": "0.6.1", "engine": "sing-box", "core_version": "1.24.3",
            "uptime_s": 518_200, "inflight": 3, "max_inflight": 64, "targets": 212,
        ]),
    ])

    static let systemSeriesNames = ["host.mem_used", "host.mem_total", "host.load1", "proc.rss", "proc.heap", "proc.cpu", "host.disk_used", "host.disk_total"]

    /// Control-plane series over a range, ending at `now`, with a short gap
    /// six hours back (a restart) so charts show they never draw across one.
    static func systemSeriesBody(range: String, now: Date) -> String {
        let spans: [String: Int] = ["1h": 3_600, "6h": 21_600, "24h": 86_400, "7d": 604_800, "30d": 2_592_000, "90d": 7_776_000, "1y": 31_536_000, "5y": 157_680_000]
        let span = spans[range] ?? 86_400
        let step = max(10, span / 300)
        let end = Int(now.timeIntervalSince1970) / step * step
        var times: [Int] = []
        var time = end - span
        let gap = (end - 6 * 3_600)...(end - 6 * 3_600 + 4 * step)
        while time <= end {
            if !gap.contains(time) { times.append(time) }
            time += step
        }
        func series(_ name: String, unit: String, base: Double, swing: Double) -> DemoJSON {
            let values = times.map { t -> Double in
                let daily = sin(Double(t % 86_400) / 86_400 * 2 * .pi)
                return (Swift.max(0, base + daily * swing) * 1000).rounded() / 1000
            }
            return .object([
                "name": .string(name), "kind": "gauge", "unit": .string(unit),
                "t": .array(times.map { .number(Double($0)) }),
                "avg": .array(values.map { .number($0) }), "min": .array(values.map { .number($0) }), "max": .array(values.map { .number($0) }),
                "n": .array(times.map { _ in .number(Double(step / 10)) }),
            ])
        }
        return DemoJSON.object([
            "owner": "cp", "tier": .string(step <= 10 ? "raw" : "rollup"), "resolution_seconds": .number(Double(min(step, 600))),
            "step_seconds": .number(Double(step)), "from": .time("-\(span / 60)m"), "to": .time(), "retained_from": .time("-90d"),
            "series": [
                series("host.mem_used", unit: "bytes", base: 3_600_000_000, swing: 400_000_000),
                series("host.mem_total", unit: "bytes", base: 8_589_934_592, swing: 0),
                series("host.load1", unit: "load", base: 0.5, swing: 0.25),
                series("proc.rss", unit: "bytes", base: 236_000_000, swing: 12_000_000),
                series("proc.heap", unit: "bytes", base: 94_000_000, swing: 9_000_000),
                series("proc.cpu", unit: "percent", base: 4, swing: 2.5),
                series("host.disk_used", unit: "bytes", base: 33_000_000_000, swing: 150_000_000),
                series("host.disk_total", unit: "bytes", base: 85_899_345_920, swing: 0),
            ],
        ]).text
    }

    static var systemRoutes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/system/health", body: systemHealth.text,
                      emptyBody: #"{"observed_at":"{{now}}","range":"24h","process":{"version":"alpha-0.4.2a151","heap_bytes":0,"go_total_bytes":0,"goroutines":0},"host":{},"files":[],"store":[],"http":[],"plugins":[],"plugin_processes":[],"metrics_store":{"series":0},"probe":{"available":false,"reason":"the probe socket is not configured"}}"#)
                .requiring("*"),
            DemoRoute(pathPattern: "/api/system/series", body: "",
                      emptyBody: #"{"owner":"cp","tier":"raw","resolution_seconds":10,"step_seconds":300,"from":"{{now-24h}}","to":"{{now}}","retained_from":"{{now-90d}}","series":[]}"#) { request, _ in
                let range = request.query["range"] ?? "24h"
                guard PlatformSystem.ranges.contains(range) else {
                    return .error(status: 400, code: "bad_request", message: "range must be one of 1h, 6h, 24h, 7d, 30d, 90d, 1y, 5y")
                }
                return .json(systemSeriesBody(range: range, now: Date()))
            }.requiring("*"),
        ]
    }
}
