import Foundation
import AstraCore

public func checkPlatform() async throws {
    try await checkPlatformDecoding()
    try await checkPlatformRequestBodies()
    try checkPlatformPluginRows()
    try checkPlatformRisk()
    try checkPlatformPublishing()
    try checkPlatformShares()
    try checkPlatformStore()
    try checkPlatformSystem()
    try checkPlatformExtensionPages()
    try checkPlatformQueries()
    try await checkPlatformDemo()
}

private let platformBase = "https://lattice.example.com"

private func platformClient(_ responses: [String: (Int, Data)]) -> (LatticeClient, MockTransport) {
    let transport = MockTransport(responses: responses)
    let client = LatticeClient(baseURL: URL(string: platformBase)!, credential: LatticeCredential(bearerToken: "lat_check"), transport: transport)
    return (client, transport)
}

private func platformInstant(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

// MARK: Decoding

private func checkPlatformDecoding() async throws {
    let (client, _) = platformClient([
        "\(platformBase)/api/plugins": (200, try fixture("platform-plugins.json")),
        "\(platformBase)/api/plugins/lifecycle": (200, try fixture("platform-lifecycle.json")),
        "\(platformBase)/api/subscription-shares": (200, try fixture("platform-shares.json")),
        "\(platformBase)/api/system/health?range=24h": (200, try fixture("platform-system-health.json")),
        "\(platformBase)/api/system/series?owner=cp&series=proc.cpu&range=24h&points=400": (200, try fixture("platform-system-series.json")),
    ])

    let plugins = try await client.platformPlugins()
    try expectEqual(plugins.count, 2, "both plugins decode")
    let netguard = plugins[0]
    try expectEqual(netguard.ui?.nav.first?.scopes, ["netguard:read"], "nav scopes")
    try expectEqual(netguard.ui?.views.map(\.kind), ["sandbox", "table"], "view kinds")
    try expectEqual(netguard.ui?.views[1].source, PlatformViewSource(interface: "latticenet.netguard/firewall", method: "audit"), "view source")
    try expectEqual(netguard.uiRuntime?.mode, "sandbox", "ui runtime")
    let contract = try expectUnwrapped(netguard.interfaces.first, "typed interface")
    try expectEqual(contract.backing, "core", "backing")
    try expectEqual(contract.scopes(for: "overview"), ["netguard:read"], "a typed method's own scopes win")
    try expectEqual(contract.scopes(for: "audit"), ["netguard:admin"], "a typed method without scopes takes the interface's")
    let legacy = plugins[1]
    try expectEqual(legacy.interfaces.first?.methods.map(\.name), ["list", "get"], "bare method names decode")
    try expectEqual(legacy.interfaces.first?.scopes(for: "list"), ["kv:read"], "a bare method takes the interface scopes")
    try expect(legacy.ui == nil && legacy.status.isEmpty && !legacy.active, "an inactive plugin carries no ui")

    let lifecycle = try await client.platformLifecycle()
    try expectEqual(lifecycle.first?.runtime?.state, "armed", "runtime state")
    try expectEqual(lifecycle.first?.runtime?.startedAt, platformInstant("2026-09-02T00:00:00Z").addingTimeInterval(0.123456789), "nanosecond stamps")
    try expectEqual(lifecycle.first?.artifactSHA256, "3f9a0c21", "digest")
    try expect(lifecycle[1].updatedAt == nil, "a Go zero time reads as no date")
    try expect(lifecycle[1].runtime == nil && !lifecycle[1].available, "missing runtime and bundle")

    let shares = try await client.platformShares()
    try expectEqual(shares[0].source.identityID, "vid_1", "share identity")
    try expectEqual(shares[0].renderBudget?.refused, 14, "render budget")
    try expectEqual(shares[0].fleetFeedNow, "fleet", "fleet feed verdict")
    try expectEqual(shares[0].maskedPath, "/sub/family/…", "masked path")
    try expect(shares[1].publishesFleetCredentials && !shares[1].enabled && shares[1].expiresAt == nil, "flags and missing expiry")
    try expectEqual(shares[1].source.proxyUserID, "pu_alice", "core source")

    let health = try await client.platformSystemHealth(range: "24h")
    try expectEqual(health.process?.version, "alpha-0.4.2a151", "process version")
    try expect(health.process?.cpuPercent == nil && health.process?.rssBytes == nil, "absent readings stay absent, never zero")
    try expectEqual(health.host?.memoryFraction, 0.75, "used memory fraction")
    try expect(health.host?.diskFraction == nil, "no disk reading, no fraction")
    try expectEqual(health.http.first?.spark.p95.count, 3, "spark keeps null slots")
    try expect(health.http.first?.spark.p95[1] == nil, "a null p95 decodes as nil")
    try expectEqual(health.plugins.first?.id, "latticenet.sub-store/subscription.render", "plugin row id")
    try expectEqual(health.metricsStore?.lastWriteError, "disk full", "metrics store error")
    try expect(health.probe?.available == false && health.probe?.reason.contains("socket") == true, "probe unavailable with reason")
    try expectEqual(health.files.first?.sizeBytes, nil, "a file without a size")

    let series = try await client.platformSystemSeries(series: ["proc.cpu"], range: "24h")
    try expectEqual(series.stepSeconds, 300, "step")
    try expectEqual(series.series(named: "proc.cpu")?.avg.compactMap { $0 }, [1.5, 2.5, 3, 4], "null averages decode as nil")

    let (behind, _) = platformClient(["\(platformBase)/api/plugins": (200, json("<!doctype html>"))])
    do {
        _ = try await behind.platformPlugins()
        throw CheckFailure.failed("an HTML answer must not decode as plugins")
    } catch let error as LatticeAPIError {
        try expectEqual(error, .invalidResponse, "an undecodable list is companion behind")
    }
}

// MARK: Request bodies

private func checkPlatformRequestBodies() async throws {
    let installation = json(#"{"id":"latticenet.wireguard","name":"WireGuard","status":"active","available":true,"capabilities":[]}"#)
    let token = json(#"{"id":"stok_1","name":"ci","kind":"kv","access":"write","revoked_at":"2026-10-28T12:00:00Z","created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-28T12:00:00Z"}"#)
    let share = json(#"{"id":"share_a","slug":"family","source":{"kind":"plugin"},"enabled":true,"update_interval_hours":2}"#)
    let (client, transport) = platformClient([
        "\(platformBase)/api/plugins/lifecycle": (200, installation),
        "\(platformBase)/api/storage/bindings/delete": (200, json(#"{"ok":true}"#)),
        "\(platformBase)/api/storage/tokens/revoke": (200, token),
        "\(platformBase)/api/subscription-shares/share_a/rotate": (200, share),
        "\(platformBase)/api/subscription-shares/share_a/refresh": (200, json(#"{"fetched_at":"2026-10-28T12:00:00Z","bytes":18342,"stale":true,"error":"provider timed out"}"#)),
        "\(platformBase)/api/subscription-shares/share_a/reveal": (200, json(#"{"kind":"share","id":"share_a","slug":"family","token":"t0k","path":"/sub/family/t0k"}"#)),
        "\(platformBase)/api/subscription-shares/share_a": (204, Data()),
        "\(platformBase)/api/storage/buckets?kind=static": (200, json(#"{"buckets":[]}"#)),
        "\(platformBase)/api/storage/bindings?kind=kv": (200, json(#"{"bindings":[]}"#)),
        "\(platformBase)/api/storage/tokens?kind=static": (200, json(#"{"tokens":[]}"#)),
        "\(platformBase)/api/kv?bucket=plugin:latticenet.sub-store": (200, json("[]")),
    ])

    let activated = try await client.platformSetPluginStatus(id: "latticenet.wireguard", status: "active")
    try expectEqual(activated.status, "active", "lifecycle answer")
    var body = try bodyObject(await transport.lastBody)
    try expectEqual(body as NSDictionary, ["id": "latticenet.wireguard", "status": "active"] as NSDictionary, "lifecycle body")

    try await client.platformDeleteBinding(kind: .kv, id: "binding_status")
    body = try bodyObject(await transport.lastBody)
    try expectEqual(body as NSDictionary, ["kind": "kv", "id": "binding_status"] as NSDictionary, "binding delete body")

    let revoked = try await client.platformRevokeStorageToken(kind: .kv, tokenID: "stok_1")
    try expect(revoked.isRevoked, "the revoke answer carries revoked_at")
    body = try bodyObject(await transport.lastBody)
    try expectEqual(body as NSDictionary, ["kind": "kv", "token_id": "stok_1"] as NSDictionary, "token revoke body")

    _ = try await client.platformRotateShare(id: "share_a")
    try expectEqual(String(data: await transport.lastBody ?? Data(), encoding: .utf8), "{}", "rotate sends an empty object")
    let refresh = try await client.platformRefreshShare(id: "share_a")
    try expect(refresh.stale && refresh.error == "provider timed out" && refresh.bytes == 18_342, "refresh answer")
    try expectEqual(String(data: await transport.lastBody ?? Data(), encoding: .utf8), "{}", "refresh sends an empty object")

    let reveal = try await client.platformRevealShare(id: "share_a", grant: StepUpGrant(grant: "grant-1", expiresAt: Date().addingTimeInterval(60)))
    body = try bodyObject(await transport.lastBody)
    try expectEqual(body as NSDictionary, ["step_up_grant": "grant-1"] as NSDictionary, "reveal body carries only the grant")
    try expectEqual(reveal.fullURL(origin: URL(string: "https://console.example.com/")), "https://console.example.com/sub/family/t0k", "a reveal without url uses the console origin")

    try await client.platformDeleteShare(id: "share_a")
    let methods = await transport.methods
    try expectEqual(methods.last ?? nil, "DELETE", "share delete is a DELETE")
    let deleteBody = await transport.lastBody
    try expect(deleteBody == nil, "share delete sends no body")

    _ = try await client.platformBuckets(kind: .static)
    _ = try await client.platformBindings(kind: .kv)
    _ = try await client.platformStorageTokens(kind: .static)
    _ = try await client.platformKVKeys(bucket: "plugin:latticenet.sub-store")
    let urls = await transport.requestURLs
    try expect(urls.contains("\(platformBase)/api/storage/buckets?kind=static"), "buckets ask by kind")
    try expect(urls.contains("\(platformBase)/api/kv?bucket=plugin:latticenet.sub-store"), "a bucket name goes in the query as the server reads it")
}

// MARK: Plugins

private func checkPlatformPluginRows() throws {
    let ui = PlatformManifestUI(
        nav: [PlatformNavEntry(title: "NetGuard", route: "firewall")],
        views: [PlatformViewContribution(route: "firewall", title: "NetGuard", kind: "sandbox"), PlatformViewContribution(route: "audit", title: "Audit", kind: "table")]
    )
    let pages = PlatformPluginPages.pages(pluginID: "latticenet.netguard", ui: ui)
    try expectEqual(pages.map(\.route), ["firewall", "audit"], "nav entries first, then views no entry points at, each once")
    try expectEqual(pages.map(\.consolePath), ["/plugins/latticenet.netguard/firewall", "/plugins/latticenet.netguard/audit"], "console paths")
    try expectEqual(pages.map(\.isNative), [false, true], "only table and detail pages are native")
    try expect(PlatformPluginPages.pages(pluginID: "x", ui: nil).isEmpty, "no ui, no page")

    let lifecycleJSON = #"[{"id":"latticenet.netguard","name":"NetGuard","version":"0.1.0","status":"active","available":true,"artifact_sha256":"3f9a","runtime":{"state":"armed"},"verified_at":"2026-09-01T00:00:00Z","activated_at":"2026-09-02T00:00:00Z","installed_at":"2026-09-01T12:00:00Z"}]"#
    let lifecycle = try JSONDecoder().decode([PlatformInstallation].self, from: json(lifecycleJSON))
    let contributions = [
        PlatformPlugin(id: "latticenet.netguard", name: "NetGuard", ui: ui),
        PlatformPlugin(id: "latticenet.vpn-core", name: "vpn-core", active: true, ui: PlatformManifestUI(nav: [PlatformNavEntry(title: "Lines", route: "lines")])),
    ]
    let rows = PlatformPluginRows.merge(registered: nil, lifecycle: lifecycle, contributions: contributions)
    try expectEqual(rows.map(\.id), ["latticenet.netguard", "latticenet.vpn-core"], "one row per plugin, from whichever reads the token holds")
    try expect(rows[0].lifecycleRead && rows[0].artifactSHA256 == "3f9a", "the lifecycle read carries the digest")
    try expectEqual(rows[0].transitions.map(\.key), ["verified", "installed", "activated"], "transitions in time order")
    try expectEqual(rows[0].pages.count, 2, "pages come from the contributions read")
    try expect(!rows[1].lifecycleRead && rows[1].status == "active", "an active contribution reads as active")
    try expectEqual(rows[1].pages.first?.consolePath, "/plugins/latticenet.vpn-core/lines", "contribution page path")

    func health(_ status: String, _ runtime: String?, available: Bool? = true, read: Bool = true) -> PlatformPluginHealth {
        var row = PlatformPluginRow(id: "p", name: "p")
        row.status = status
        row.runtime = runtime.map { PlatformRuntimeStatus(state: $0) }
        row.available = available
        row.lifecycleRead = read
        return row.health
    }
    try expectEqual(health("active", "armed"), .running, "armed is running")
    try expectEqual(health("active", "failed"), .failed, "failed runtime")
    try expectEqual(health("active", "stopped"), .stopped, "stopped runtime")
    try expectEqual(health("active", "armed", available: false), .missing, "a missing bundle is red")
    try expectEqual(health("disabled", "stopped"), .disabled, "disabled is a choice")
    try expectEqual(health("installed", nil), .pending, "installed waits")
    try expectEqual(health("active", nil, available: nil, read: false), .unknown, "unread is never running")

    try expectEqual(PlatformLifecycle.next(from: "verified"), ["installed"], "verified moves to installed")
    try expectEqual(PlatformLifecycle.next(from: "installed"), ["active"], "installed moves to active")
    try expectEqual(PlatformLifecycle.next(from: "active"), ["disabled"], "active moves to disabled")
    try expectEqual(PlatformLifecycle.next(from: "disabled"), ["active"], "disabled moves to active")
    try expectEqual(PlatformLifecycle.next(from: ""), [], "unknown moves nowhere")
}

private func checkPlatformRisk() throws {
    try expectEqual(PlatformCapabilityRisk.of("kv:read"), .read, "kv:read is read risk")
    try expectEqual(PlatformCapabilityRisk.of("kv:write"), .write, "kv:write is write risk")
    try expectEqual(PlatformCapabilityRisk.of("static:write"), .host, "static:write is host risk, unlike kv:write")
    try expectEqual(PlatformCapabilityRisk.of("http:egress"), .host, "egress is host risk")
    try expectEqual(PlatformCapabilityRisk.of("made:up"), .unknown, "an unlisted capability is unknown")
    try expectEqual(PlatformCapabilityRisk.highest(["kv:read", "kv:write"]), .write, "the highest risk wins")
    try expectEqual(PlatformCapabilityRisk.highest(["made:up", "node:read"]), .read, "unknown never outranks a known risk")
    try expectEqual(PlatformCapabilityRisk.highest([]), .unknown, "no capability, unknown")
}

// MARK: Publishing

private func checkPlatformPublishing() throws {
    let now = platformInstant("2026-10-28T12:00:00Z")
    let docs = PlatformPublishingRecord(id: "b1", origin: "static", bucket: "docs", hostname: "docs.example.net")
    let flags = PlatformPublishingRecord(id: "b2", origin: "kv", bucket: "feature-flags", hostname: "cfg.example.org", pathPrefix: "/flags/", enabled: false)
    let share = PlatformPublishingRecord(id: "share_a", origin: "plugin", bucket: "share_a", anyHost: true, pathPrefix: "sub/family",
                                         expiresAt: now.addingTimeInterval(-60), reserved: true, shareID: "share_a")
    let odd = PlatformPublishingRecord(id: "w1", origin: "worker", bucket: "x", hostname: "a.example.net")
    try expectEqual(PlatformPublishing.routePath(flags), "/flags", "the path is rooted with no trailing slash")
    try expectEqual(PlatformPublishing.routeLabel(docs), "docs.example.net", "a root route is its host")
    try expectEqual(PlatformPublishing.routeLabel(flags), "cfg.example.org/flags", "host and path")
    try expectEqual(PlatformPublishing.routeLabel(share), "*/sub/family", "any host reads as *")
    try expectEqual(PlatformPublishing.originTargetLabel(share, shareSlugs: ["share_a": "family"]), "/family", "a share route names its slug")
    try expectEqual(PlatformPublishing.originTargetLabel(share, shareSlugs: [:]), "share_a", "an unknown share keeps its id")
    try expectEqual(PlatformRouteState.of(docs, now: now), .serving, "serving")
    try expectEqual(PlatformRouteState.of(flags, now: now), .disabled, "disabled")
    try expectEqual(PlatformRouteState.of(share, now: now), .expired, "expired is kept apart from disabled")
    try expectEqual(PlatformPublishing.sorted([share, odd, docs, flags]).map(\.id), ["b2", "b1", "share_a", "w1"], "kv, static, plugin, then unknown origins")
    try expectEqual(PlatformPublishingLens.share.filter([docs, flags, share]).map(\.id), ["share_a"], "the share lens shows plugin routes")
    try expectEqual(PlatformPublishingLens.all.filter([docs, odd]).count, 2, "all passes unknown origins through")
    try expectEqual(PlatformAccessMode.of(origin: "kv"), .storageToken, "kv needs a storage token")
    try expectEqual(PlatformAccessMode.of(origin: "static"), .anonymous, "static is anonymous")
    try expectEqual(PlatformAccessMode.of(origin: "plugin"), .shareToken, "plugin reads with the share token")
    try expectEqual(PlatformAccessMode.of(origin: "worker"), .unknown, "unknown origins are never called anonymous")
    try expectEqual(PlatformStorageKind.kv.adminScope, "kv:admin", "storage admin scope is kv:admin (server_storage.go)")
    try expectEqual(PlatformPublishing.storageKind(share), nil, "plugin routes have no storage kind")
}

private func checkPlatformShares() throws {
    let now = platformInstant("2026-10-28T12:00:00Z")
    func share(enabled: Bool = true, expires: TimeInterval?) -> PlatformShare {
        PlatformShare(id: "s", slug: "s", source: PlatformShareSource(kind: "plugin"), enabled: enabled, expiresAt: expires.map { now.addingTimeInterval($0) })
    }
    try expectEqual(PlatformShareState.of(share(expires: nil), now: now), .live, "no expiry is live")
    try expectEqual(PlatformShareState.of(share(expires: 8 * 86_400), now: now), .live, "eight days out is live")
    try expectEqual(PlatformShareState.of(share(expires: 7 * 86_400), now: now), .expiring, "seven days out is expiring")
    try expectEqual(PlatformShareState.of(share(expires: 0), now: now), .expired, "an expiry at now has lapsed")
    try expectEqual(PlatformShareState.of(share(enabled: false, expires: -86_400), now: now), .paused, "paused outranks expired")
    try expect(PlatformShareState.expiring.isServing && !PlatformShareState.paused.isServing, "only live and expiring serve")

    try expectEqual(PlatformRenderBudgetTone.of(nil), PlatformRenderBudgetTone.none, "no budget yet")
    try expectEqual(PlatformRenderBudgetTone.of(PlatformShareRenderBudget(remaining: 0, burst: 60, exhausted: true)), .exhausted, "exhausted")
    try expectEqual(PlatformRenderBudgetTone.of(PlatformShareRenderBudget(remaining: 50, burst: 60, refused: 1)), .warning, "any refusal warns")
    try expectEqual(PlatformRenderBudgetTone.of(PlatformShareRenderBudget(remaining: 15, burst: 60)), .warning, "a quarter left warns")
    try expectEqual(PlatformRenderBudgetTone.of(PlatformShareRenderBudget(remaining: 16, burst: 60)), .quiet, "more than a quarter is quiet")

    let plugin = PlatformShare(id: "a", slug: "a", source: PlatformShareSource(kind: "plugin", pluginID: "latticenet.sub-store", subscriptionID: "sub_1"))
    let core = PlatformShare(id: "b", slug: "b", source: PlatformShareSource(kind: "core.proxy_user", proxyUserID: "pu_1"))
    try expectEqual(PlatformShares.sourceLabel(plugin), "latticenet.sub-store · sub_1", "plugin source label")
    try expectEqual(PlatformShares.sourceLabel(core), "proxy user · pu_1", "core source label")
    try expect(PlatformShares.canRefresh(plugin) && !PlatformShares.canRefresh(core), "only a plugin source refreshes")
    try expectEqual(PlatformShares.owner(core), "pu_1", "the proxy user owns a core share")
    try expectEqual(PlatformShares.maskedURL("https://x.example.net/sub/family/abcdefghijklmnop"), "https://x.example.net/sub/family/abcd…mnop", "masked URL")
    try expectEqual(PlatformShares.maskedURL("https://x.example.net/sub/f/short"), "https://x.example.net/sub/f/short", "a short token stays")
}

// MARK: Store

private func checkPlatformStore() throws {
    func owner(_ name: String, kind: String = "kv", reserved: Bool = false) -> PlatformBucketOwner {
        PlatformBucketOwner.of(name: name, kind: kind, reserved: reserved)
    }
    try expectEqual(owner("plugin:latticenet.sub-store"), .plugin, "plugin buckets")
    try expectEqual(owner("vpnmeta/lineuuid"), .server, "line identity map")
    try expectEqual(owner("vpnmeta/lineuuid-owner"), .server, "line identity owners")
    try expectEqual(owner("agent-releases", kind: "static"), .agent, "agent releases")
    try expectEqual(owner("default"), .operator, "default bucket")
    try expectEqual(owner("vpnmeta/lineuuid", kind: "static"), .operator, "the kind is part of the rule")
    try expectEqual(owner("agent-releases", kind: "kv"), .operator, "a name alone claims no owner")
    try expectEqual(owner("vpn_users", reserved: true), .server, "reserved outranks every name rule")
    try expectEqual(owner("anything", kind: "static", reserved: true), .server, "a reserved static bucket is the server's")
    try expectEqual(PlatformBucketOwner.pluginID(PlatformBucketInventoryEntry(name: "plugin:latticenet.sub-store", kind: "kv")), "latticenet.sub-store", "plugin id")
    try expectEqual(PlatformBucketOwner.pluginID(PlatformBucketInventoryEntry(name: "default", kind: "kv")), nil, "no plugin id for others")
    try expect(!PlatformBucketOwner.contentAvailable(name: "agent-releases", kind: "static", reserved: false), "agent releases carry no bytes")
    try expect(PlatformBucketOwner.contentAvailable(name: "site", kind: "static", reserved: false), "other buckets carry bytes")

    let writer = PlatformStorageToken(id: "t", name: "ci", kind: "kv", access: "write", buckets: ["status"])
    try expect(PlatformStorageTokens.writes(writer, bucket: "status", kind: "kv"), "a write token writes its bucket")
    try expect(!PlatformStorageTokens.writes(writer, bucket: "other", kind: "kv"), "and no other")
    try expect(!PlatformStorageTokens.writes(writer, bucket: "status", kind: "static"), "nor another kind")
    try expect(PlatformStorageTokens.writes(PlatformStorageToken(id: "a", name: "", kind: "kv", access: "admin"), bucket: "x", kind: "kv"), "an empty list means every bucket")
    try expect(!PlatformStorageTokens.writes(PlatformStorageToken(id: "r", name: "", kind: "kv", access: "read"), bucket: "x", kind: "kv"), "a read token writes nothing")
    try expect(!PlatformStorageTokens.writes(PlatformStorageToken(id: "v", name: "", kind: "kv", access: "write", revokedAt: Date()), bucket: "x", kind: "kv"), "a revoked token writes nothing")
    try expectEqual(PlatformStorageTokens.bucketsLabel(PlatformStorageToken(id: "s", name: "", kind: "static", access: "read", buckets: ["*"])), "All Static buckets", "a star is every bucket")

    try expect(PlatformStoreContent.isText(contentType: "text/html; charset=utf-8"), "html is text")
    try expect(PlatformStoreContent.isText(contentType: "application/json"), "json is text")
    try expect(PlatformStoreContent.isText(contentType: "application/vnd.api+json"), "+json is text")
    try expect(PlatformStoreContent.isText(contentType: ""), "an untyped value shows as text")
    try expect(!PlatformStoreContent.isText(contentType: "image/png"), "png is binary")
    try expect(!PlatformStoreContent.isText(contentType: "application/octet-stream"), "octet-stream is binary")
}

// MARK: System

private func checkPlatformSystem() throws {
    let series = PlatformMetricSeries(name: "proc.cpu", t: [0, 300, 600, 900, 2_400, 2_700], avg: [1, 2, nil, 4, 5, .infinity])
    let segments = PlatformSystem.segments(series, stepSeconds: 300)
    try expectEqual(segments.map { $0.map(\.value) }, [[1, 2, 4], [5]], "a null drops its bucket; a gap over 2.5 steps starts a new segment; non-finite values drop")
    try expectEqual(PlatformSystem.segments(nil, stepSeconds: 300).count, 0, "no series, no segment")
    try expectEqual(PlatformSystem.latest(series), .infinity, "latest is the newest non-null value")
    try expectEqual(PlatformSystem.latest(PlatformMetricSeries(name: "x", t: [0, 1], avg: [3, nil])), 3, "a trailing null is skipped")
    try expectEqual(PlatformSystem.ranges, ["1h", "6h", "24h", "7d", "30d", "90d", "1y", "5y"], "ranges match parseMetricsWindow")
}

// MARK: Extension pages

private func checkPlatformExtensionPages() throws {
    let data = try PlatformJSONValue.parse(try fixture("platform-extension-data.json"))
    let rows = ExtensionPageModel.rows(of: data)
    try expectEqual(rows.count, 2, "a {rows} envelope yields its rows")
    try expectEqual(rows[0]["note"], .string("café 🔒 \"quoted\""), "escapes and surrogate pairs decode")
    if case .object(let pairs) = rows[0] {
        try expectEqual(pairs.map(\.0), ["id", "host", "expires_at", "chain_bytes", "alert_hook", "tags", "note"], "keys keep the order sent")
    } else {
        throw CheckFailure.failed("row is an object")
    }
    try expectEqual(ExtensionPageModel.rows(of: .array([.number(1)])).count, 1, "a bare array is the rows")
    try expectEqual(ExtensionPageModel.rows(of: .string("x")).count, 0, "a scalar has no rows")

    let view = PlatformViewContribution(route: "certificates", title: "Certificates", kind: "table", source: PlatformViewSource(interface: "c/certs", method: "list"), columns: [
        PlatformViewColumn(key: "host", label: "Host"),
        PlatformViewColumn(key: "chain_bytes", label: "Chain", render: "bytes"),
        PlatformViewColumn(key: "alert_hook", label: "Hook", render: "copy-secret"),
        PlatformViewColumn(key: "tags", label: "", render: "sparkle"),
        PlatformViewColumn(key: "expires_at", label: "Expires", render: "relative-time"),
    ])
    let now = platformInstant("2026-10-28T12:00:00Z")
    let table = ExtensionPageModel.tableRows(view: view, data: data, now: now, locale: Locale(identifier: "en_US"))
    try expectEqual(table.columns.map(\.label), ["Host", "Chain", "Hook", "tags", "Expires"], "a missing label falls back to the key")
    try expectEqual(table.columns[3].render, "", "a render outside the allow-list is plain text")
    try expectEqual(table.rows.map(\.id), ["c-1#0", "n-2#1"], "row keys use id, node_id, name or key, disambiguated by index")
    let first = table.rows[0].cells
    try expectEqual(first[1].text, ByteFormatter.bytes(4_812), "bytes render")
    try expectEqual(first[2].text, "https://••••••", "a secret keeps only its scheme")
    try expect(!first.contains { $0.text.contains("7f3a") }, "no part of a secret reaches a cell")
    try expectEqual(first[3].text, #"["a","b"]"#, "containers show as compact JSON")
    try expectEqual(first[4].text, "in 4 weeks", "relative time")
    let second = table.rows[1].cells
    try expectEqual(second[1].text, ByteFormatter.bytes(6_103), "numeric strings render as bytes")
    try expectEqual(second[2].text, "••••••", "a secret without a scheme is fully masked")
    try expectEqual(second[4].text, "", "a null shows nothing")
    try expectEqual(table.rows[0].title, "status.example.net", "the row title is the first non-secret value")

    let derived = ExtensionPageModel.columns(view: PlatformViewContribution(route: "r", title: "R", kind: "table"), rows: rows)
    try expectEqual(derived.first?.key, "id", "undeclared columns come from the first row's keys")

    let detail = PlatformViewContribution(route: "summary", title: "Summary", kind: "detail")
    let summary = try PlatformJSONValue.parse(json(#"{"targets":4,"healthy":2,"last_run":"2026-10-28T11:54:00Z","ok":true}"#))
    let cells = ExtensionPageModel.detailCells(view: detail, data: summary, now: now, locale: Locale(identifier: "en_US"))
    try expectEqual(cells.map(\.label), ["targets", "healthy", "last_run", "ok"], "detail fields keep the order sent")
    try expectEqual(cells.map(\.text), ["4", "2", "2026-10-28T11:54:00Z", "true"], "detail values as text")
    try expectEqual(ExtensionPageModel.detailCells(view: detail, data: data, now: now, locale: Locale(identifier: "en_US")).first?.text, "c-1", "a rows answer shows its first row")

    let plugin = PlatformPlugin(id: "examplelabs.cert-watch", name: "Certificate watch", ui: PlatformManifestUI(
        nav: [PlatformNavEntry(title: "Certificates", route: "certificates", scopes: ["monitor:read"]), PlatformNavEntry(title: "Raw", route: "raw", scopes: ["audit:read"])],
        views: [view, PlatformViewContribution(route: "raw", title: "Raw", kind: "markdown"), PlatformViewContribution(route: "add", title: "Add", kind: "form")]
    ), interfaces: [PlatformInterface(service: "c/certs", methods: [PlatformInterfaceMethod(name: "list", effect: "read", scopes: ["node:read"])])])
    let page = try expectUnwrapped(ExtensionPageModel.page(plugin: plugin, route: "certificates"), "table page")
    try expectEqual(page.kind, .table, "table kind")
    try expectEqual(page.requiredScopes, ["node:read"], "the source method's scopes gate the page")
    try expectEqual(page.consolePath, "/plugins/examplelabs.cert-watch/certificates", "page console path")
    try expect(page.hasSource, "table page has a source")
    let raw = try expectUnwrapped(ExtensionPageModel.page(plugin: plugin, route: "raw"), "markdown page")
    try expectEqual(raw.kind, .web, "markdown opens on the web")
    try expectEqual(raw.requiredScopes, ["audit:read"], "without a source the nav entry's scopes apply")
    try expectEqual(ExtensionPageModel.page(plugin: plugin, route: "add")?.kind, .web, "forms open on the web")
    try expect(ExtensionPageModel.page(plugin: plugin, route: "missing") == nil, "an unknown route has no page")

    for bad in ["{", #"{"a":}"#, "[1,]", #"{"a":1} x"#, #""\u12""#] {
        do {
            _ = try PlatformJSONValue.parse(json(bad))
            throw CheckFailure.failed("malformed JSON \(bad) must not parse")
        } catch let error as LatticeAPIError {
            try expectEqual(error, .invalidResponse, "malformed JSON is companion behind")
        }
    }
}

// MARK: Demo

private func checkPlatformDemo() async throws {
    let state = DemoState()
    let clock = DemoClock(pinned: "2026-10-28T12:00:00Z")!
    func client(_ identity: DemoIdentity = .pat, scenario: DemoScenario = .normal) -> LatticeClient {
        let credential = identity == .pat ? LatticeCredential(bearerToken: DemoWorld.token) : LatticeCredential(sessionCookie: "sid_demo", csrfToken: "csrf_demo")
        return LatticeClient(baseURL: DemoWorld.baseURL, credential: credential, transport: DemoTransport(identity: identity, scenario: scenario, clock: clock, state: state))
    }
    let operatorClient = client()

    let registered = try await operatorClient.platformPlugins()
    try expectEqual(registered.count, PlatformFixtures.plugins.count, "every demo plugin is registered")
    let contributions = try await operatorClient.platformContributions()
    try expect(contributions.allSatisfy { $0.active && $0.ui != nil }, "contributions list active plugins with pages only")
    do {
        _ = try await operatorClient.platformLifecycle()
        throw CheckFailure.failed("the Operator preset must not read the lifecycle")
    } catch LatticeAPIError.forbidden {}
    let rows = PlatformPluginRows.merge(registered: registered, lifecycle: nil, contributions: contributions)
    try expect(rows.allSatisfy { $0.health != .running }, "without plugin:admin no plugin is claimed running")
    let certWatch = try expectUnwrapped(registered.first { $0.id == PlatformFixtures.certWatchID }, "cert-watch")
    let table = try expectUnwrapped(ExtensionPageModel.page(plugin: certWatch, route: "certificates"), "cert-watch table page")
    let tableData = try await operatorClient.platformExtensionData(pluginID: certWatch.id, source: try expectUnwrapped(table.view.source, "source"))
    try expectEqual(ExtensionPageModel.rows(of: tableData).count, 4, "the demo table page has four certificates")
    let summaryPage = try expectUnwrapped(ExtensionPageModel.page(plugin: certWatch, route: "summary"), "summary page")
    let summary = try await operatorClient.platformExtensionData(pluginID: certWatch.id, source: try expectUnwrapped(summaryPage.view.source, "summary source"))
    try expect(!ExtensionPageModel.detailCells(view: summaryPage.view, data: summary, now: clock.anchor, locale: Locale(identifier: "en_US")).isEmpty, "the demo detail page has fields")
    do {
        _ = try await operatorClient.platformExtensionData(pluginID: PlatformFixtures.dnsProbeID, source: PlatformViewSource(interface: "examplelabs.dns-probe/resolvers", method: "list"))
        throw CheckFailure.failed("a failed runtime answers an error")
    } catch LatticeAPIError.server(let status, _, _) {
        try expectEqual(status, 502, "a failed plugin runtime is a 502")
    }

    let records = try await operatorClient.platformPublishingRecords()
    try expectEqual(records.origins, ["kv", "static", "plugin"], "the Operator preset sees every origin")
    let kvBuckets = try await operatorClient.platformBuckets(kind: .kv)
    try expect(kvBuckets.allBuckets.contains { $0.reserved }, "the demo lists a reserved bucket")
    let staticObjects = try await operatorClient.platformStaticObjects(bucket: "agent-releases")
    try expect(staticObjects.allSatisfy { !$0.hasContent }, "agent releases list without bytes")
    let keys = try await operatorClient.platformKVKeys(bucket: "status-page")
    try expect(!keys.isEmpty && keys.allSatisfy { $0.size > 0 }, "keys list with sizes, values dropped")
    let value = try await operatorClient.platformStoreValue(kind: .kv, bucket: "status-page", key: "banner")
    try expect(value?.text.hasPrefix("Scheduled maintenance") == true, "a value loads by key")
    do {
        _ = try await operatorClient.platformKVKeys(bucket: "vpn_users")
        throw CheckFailure.failed("a reserved bucket refuses its contents")
    } catch LatticeAPIError.forbidden {}
    do {
        _ = try await operatorClient.platformStorageTokens(kind: .kv)
        throw CheckFailure.failed("tokens need kv:admin, which the Operator preset lacks")
    } catch LatticeAPIError.forbidden {}
    do {
        _ = try await operatorClient.platformSystemHealth(range: "24h")
        throw CheckFailure.failed("System needs a full administrator")
    } catch LatticeAPIError.forbidden {}

    let triage = client(scenario: .limitedToken)
    let triageRecords = try await triage.platformPublishingRecords()
    try expect(triageRecords.records.isEmpty && triageRecords.origins.isEmpty, "Triage sees no origin, which is not an empty plane")

    let shares = try await operatorClient.platformShares()
    try expectEqual(shares.count, PlatformFixtures.shares.count, "every demo share lists")
    let rotated = try await operatorClient.platformRotateShare(id: "share_family")
    try expect(rotated.rotatedAt != nil, "rotate answers the share")
    do {
        _ = try await operatorClient.platformRefreshShare(id: "share_travel")
        throw CheckFailure.failed("a core share has no provider to refresh")
    } catch LatticeAPIError.server(let status, _, _) {
        try expectEqual(status, 400, "refresh of a core share is a 400")
    }
    do {
        _ = try await operatorClient.platformRevealShare(id: "share_family", grant: StepUpGrant(grant: "g", expiresAt: clock.anchor.addingTimeInterval(60)))
        throw CheckFailure.failed("the token client cannot reveal")
    } catch LatticeAPIError.forbidden(let code, _) {
        try expectEqual(code, "step_up_required", "reveals need the session")
    }
    let reveal = try await client(.session).platformRevealShare(id: "share_family", grant: StepUpGrant(grant: "g", expiresAt: clock.anchor.addingTimeInterval(60)))
    try expect(reveal.url.contains("notasecret"), "the demo reveal is an obviously fake URL")
    try await operatorClient.platformDeleteShare(id: "share_trial")
    let afterShares = try await operatorClient.platformShares()
    try expect(!afterShares.contains { $0.id == "share_trial" }, "a deleted share leaves the list")
    let afterRecords = try await operatorClient.platformPublishingRecords()
    try expect(!afterRecords.records.contains { $0.id == "share_trial" }, "and its route")
}

private func checkPlatformQueries() throws {
    var failed = PlatformPluginRow(id: "examplelabs.dns-probe", name: "DNS probe")
    failed.status = "active"
    failed.runtime = PlatformRuntimeStatus(state: "failed")
    failed.lifecycleRead = true
    failed.available = true
    failed.capabilities = ["http:egress"]
    var reader = PlatformPluginRow(id: "examplelabs.reader", name: "Reader")
    reader.status = "disabled"
    reader.capabilities = ["kv:read"]
    func plugins(_ query: String) throws -> [String] {
        guard case .success(let compiled) = LatticeQueryEngine.compile(query, provider: PlatformPluginQueryFields.self) else {
            throw CheckFailure.failed("plugin query \(query) compiles")
        }
        return LatticeQueryEngine.apply(compiled, to: [failed, reader], now: Date()).map(\.id)
    }
    try expectEqual(try plugins("health:failed"), ["examplelabs.dns-probe"], "health filter")
    try expectEqual(try plugins("risk:host"), ["examplelabs.dns-probe"], "risk filter")
    try expectEqual(try plugins("-status:disabled"), ["examplelabs.dns-probe"], "negated status")
    try expectEqual(try plugins("reader"), ["examplelabs.reader"], "bare words search the name")
    if case .success = LatticeQueryEngine.compile("helth:failed", provider: PlatformPluginQueryFields.self) {
        throw CheckFailure.failed("a misspelt field is an error, never an empty list")
    }

    let records = [
        PlatformPublishingRecord(id: "a", origin: "kv", bucket: "status-page", hostname: "status.example.net"),
        PlatformPublishingRecord(id: "b", origin: "plugin", bucket: "share_a", anyHost: true, pathPrefix: "sub/family", enabled: false, shareID: "share_a"),
    ]
    guard case .success(let compiled) = LatticeQueryEngine.compile("origin:share state:disabled", provider: PlatformRecordQueryFields.self) else {
        throw CheckFailure.failed("record query compiles")
    }
    try expectEqual(LatticeQueryEngine.apply(compiled, to: records, now: Date()).map(\.id), ["b"], "share is an alias of the plugin origin")

    let tokens = [PlatformStorageToken(id: "t1", name: "ci", kind: "kv", access: "write", buckets: ["flags"]),
                  PlatformStorageToken(id: "t2", name: "old", kind: "kv", access: "admin", revokedAt: Date())]
    guard case .success(let tokenQuery) = LatticeQueryEngine.compile("is:revoked", provider: PlatformTokenQueryFields.self) else {
        throw CheckFailure.failed("token query compiles")
    }
    try expectEqual(LatticeQueryEngine.apply(tokenQuery, to: tokens, now: Date()).map(\.id), ["t2"], "is:revoked")
}
