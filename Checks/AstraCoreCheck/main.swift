import Foundation
import AstraCore

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw CheckFailure.failed(message)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw CheckFailure.failed("\(message): expected \(expected), got \(actual)")
    }
}

func expectUnwrapped<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw CheckFailure.failed(message)
    }
    return value
}

func checkLatticeDecoding() throws {
    let nodesJSON = """
    [
      {
        "id": "node-b",
        "name": "Tokyo Edge",
        "tags": ["edge", "jp"],
        "role": "edge",
        "wireguard_ip": "10.8.0.2",
        "public_ip": "203.0.113.10",
        "public_ipv6": "2001:db8::10",
        "agent_version": "0.2.0",
        "online": true,
        "last_seen": "2026-06-17T02:00:00Z",
        "metrics": {
          "cpu_percent": 12.5,
          "load1": 0.42,
          "load5": 0.38,
          "load15": 0.31,
          "memory_used": 1073741824,
          "memory_total": 4294967296,
          "disk_used": 53687091200,
          "disk_total": 107374182400,
          "net_rx_bytes": 123456,
          "net_tx_bytes": 654321,
          "net_rx_speed": 2048.5,
          "net_tx_speed": 1024.25,
          "uptime_seconds": 3600,
          "collected_at": "2026-06-17T01:59:50Z"
        },
        "host_facts": {
          "hostname": "tokyo-edge",
          "os": "linux",
          "platform": "debian",
          "platform_version": "12",
          "kernel_version": "6.1.0",
          "arch": "amd64",
          "cpu_cores": 4,
          "cpu_model": "AMD EPYC",
          "memory_total": 4294967296,
          "swap_total": 1073741824,
          "virtualization": "kvm",
          "reported_at": "2026-06-17T01:58:00Z"
        },
        "geo": {
          "country": "JP",
          "city": "Tokyo",
          "lat": 35.6762,
          "lon": 139.6503
        },
        "created_at": "2026-06-16T00:00:00Z"
      },
      {
        "id": "node-a",
        "name": "Disabled Node",
        "online": true,
        "disabled": true,
        "last_seen": "2026-06-17T02:00:00Z",
        "metrics": {},
        "host_facts": {},
        "created_at": "2026-06-16T00:00:00Z"
      }
    ]
    """.data(using: .utf8)!

    let nodes = try LatticeDecoder.decodeNodes(from: nodesJSON)
    try expectEqual(nodes.map(\.id), ["node-a", "node-b"], "nodes sort by id")
    let edge = try expectUnwrapped(nodes.first(where: { $0.id == "node-b" }), "edge node")
    try expectEqual(edge.name, "Tokyo Edge", "node name")
    try expectEqual(edge.hostFacts.hostname, "tokyo-edge", "host hostname")
    try expectEqual(edge.hostFacts.cpuCores, 4, "host cpu cores")
    try expectEqual(edge.metrics.cpuPercent, 12.5, "cpu")
    try expectEqual(edge.metrics.load5, 0.38, "load5")
    try expectEqual(edge.metrics.load15, 0.31, "load15")
    try expectEqual(edge.metrics.netRxSpeed, 2048.5, "net rx speed")
    try expectEqual(edge.metrics.netTxSpeed, 1024.25, "net tx speed")
    try expectEqual(edge.memoryUsedFraction, 0.25, "memory fraction")
    try expectEqual(edge.diskUsedFraction, 0.5, "disk fraction")
    try expectEqual(edge.geo?.country, "JP", "geo country")
    let referenceDate = ISO8601DateFormatter().date(from: "2026-06-17T02:01:00Z")!
    try expect(!edge.isOffline(referenceDate: referenceDate, timeout: 180), "online node should not be offline")
    let disabled = try expectUnwrapped(nodes.first(where: { $0.id == "node-a" }), "disabled node")
    try expect(disabled.isOffline(referenceDate: referenceDate, timeout: 180), "disabled node is treated as unavailable")

    do {
        _ = try LatticeDecoder.decodeNodes(from: #"{"error":{"code":"forbidden","message":"missing node:read","request_id":"req_1"}}"#.data(using: .utf8)!)
        throw CheckFailure.failed("expected API error")
    } catch LatticeAPIError.serverError(let code, let message) {
        try expectEqual(code, "forbidden", "api error code")
        try expectEqual(message, "missing node:read (request_id: req_1)", "api error message includes request id")
    }
}

func checkLatticeURLAndRequests() throws {
    try expectEqual(
        AstraURLNormalizer.serviceURL(from: "lattice.example.com:8088")?.absoluteString,
        "https://lattice.example.com:8088",
        "service URL normalizes host and port without scheme"
    )
    try expectEqual(
        AstraURLNormalizer.serviceURL(from: " http://192.168.1.20:8088 ")?.absoluteString,
        "http://192.168.1.20:8088",
        "service URL trims and keeps explicit http scheme"
    )
    try expectEqual(
        AstraURLNormalizer.latticeDashboardURL(from: "https://lattice.example.com/api/nodes?x=1#top")?.absoluteString,
        "https://lattice.example.com",
        "dashboard URL strips API path"
    )
    try expectEqual(
        AstraURLNormalizer.latticeDashboardURL(from: "https://lattice.example.com/panel/api/nodes")?.absoluteString,
        "https://lattice.example.com/panel",
        "dashboard URL preserves reverse proxy prefix"
    )

    let bearerClient = LatticeClient(
        baseURL: URL(string: "https://lattice.example.com/panel/api")!,
        credential: LatticeCredential(bearerToken: " pat-token\n")
    )
    let bearerRequest = try bearerClient.buildRequest(path: "/api/nodes")
    try expectEqual(bearerRequest.url?.absoluteString, "https://lattice.example.com/panel/api/nodes", "nodes endpoint")
    try expectEqual(bearerRequest.value(forHTTPHeaderField: "Authorization"), "Bearer pat-token", "bearer auth header")
    try expectEqual(bearerRequest.value(forHTTPHeaderField: "Cookie"), nil, "bearer auth does not send session cookie")

    let sessionClient = LatticeClient(
        baseURL: URL(string: "https://lattice.example.com")!,
        credential: LatticeCredential(sessionCookie: "session-id", csrfToken: "csrf")
    )
    let sessionRequest = try sessionClient.buildRequest(path: "/api/nodes")
    try expectEqual(sessionRequest.url?.absoluteString, "https://lattice.example.com/api/nodes", "session endpoint")
    try expectEqual(sessionRequest.value(forHTTPHeaderField: "Cookie"), "lattice_session=session-id", "session cookie header")
    try expectEqual(sessionRequest.value(forHTTPHeaderField: "Authorization"), nil, "session auth does not send bearer")

    let loginRequest = try LatticeClient(baseURL: URL(string: "https://lattice.example.com/panel")!)
        .buildLoginRequest(username: "admin", password: "secret")
    try expectEqual(loginRequest.url?.absoluteString, "https://lattice.example.com/panel/api/login", "login endpoint")
    try expectEqual(loginRequest.httpMethod, "POST", "login method")
    try expectEqual(loginRequest.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8", "login content type")
    let body = try expectUnwrapped(loginRequest.httpBody, "login request body")
    let object = try expectUnwrapped(JSONSerialization.jsonObject(with: body) as? [String: Any], "login JSON object")
    try expectEqual(object["username"] as? String, "admin", "login username")
    try expectEqual(object["password"] as? String, "secret", "login password")
}

func checkLatticeNetworkFlow() async throws {
    let transport = RecordingTransport(responses: [
        "https://lattice.example.com/api/nodes": (
            200,
            """
            [
              {"id":"node-a","name":"A","online":true,"last_seen":"2026-06-17T02:00:00Z","metrics":{},"host_facts":{},"created_at":"2026-06-16T00:00:00Z"}
            ]
            """.data(using: .utf8)!
        ),
        "https://lattice.example.com/api/login": (
            200,
            #"{"csrf_token":"csrf-123","actor_id":"admin"}"#.data(using: .utf8)!
        ),
        "https://lattice.example.com/api/login/totp": (
            403,
            #"{"error":{"code":"forbidden","message":"missing auth:login","request_id":"req_totp"}}"#.data(using: .utf8)!
        )
    ], headers: [
        "https://lattice.example.com/api/login": [
            "Set-Cookie": "lattice_session=session-123; Path=/; HttpOnly; SameSite=Strict"
        ]
    ])

    let client = LatticeClient(
        baseURL: URL(string: "https://lattice.example.com")!,
        credential: LatticeCredential(bearerToken: "pat"),
        transport: transport
    )
    let nodes = try await client.fetchNodes()
    try expectEqual(nodes.map(\.name), ["A"], "fetch nodes")
    try expectEqual(await transport.authorizationHeaders, ["Bearer pat"], "fetch auth headers")

    let session = try await LatticeClient(
        baseURL: URL(string: "https://lattice.example.com")!,
        transport: transport
    ).login(username: "admin", password: "secret")
    try expectEqual(session.actorID, "admin", "login actor id")
    try expectEqual(session.csrfToken, "csrf-123", "login csrf")
    try expectEqual(session.sessionCookie, "session-123", "login cookie")

    do {
        _ = try await LatticeClient(
            baseURL: URL(string: "https://lattice.example.com")!,
            transport: transport
        ).loginTOTP(challengeID: "challenge", code: "000000")
        throw CheckFailure.failed("expected TOTP API error")
    } catch LatticeAPIError.serverError(let code, let message) {
        try expectEqual(code, "forbidden", "TOTP api error code")
        try expectEqual(message, "missing auth:login (request_id: req_totp)", "TOTP api error includes request id")
    }
}

func checkLatticeMonitorEngine() throws {
    let now = ISO8601DateFormatter().date(from: "2026-06-17T02:00:00Z")!
    let busyOnline = LatticeNode(
        id: "node-a",
        name: "edge",
        online: true,
        lastSeen: now,
        metrics: LatticeMetrics(cpuPercent: 95, memoryUsed: 91, memoryTotal: 100, diskUsed: 181, diskTotal: 200),
        hostFacts: LatticeHostFacts()
    )
    let staleOnline = LatticeNode(
        id: "node-b",
        name: "stale",
        online: true,
        lastSeen: now.addingTimeInterval(-600),
        metrics: LatticeMetrics(cpuPercent: 5),
        hostFacts: LatticeHostFacts()
    )
    let disabled = LatticeNode(
        id: "node-c",
        name: "disabled",
        online: true,
        disabled: true,
        lastSeen: now,
        metrics: LatticeMetrics(),
        hostFacts: LatticeHostFacts()
    )
    let config = MonitorConfiguration(
        offlineTimeout: 120,
        alertCooldown: 600,
        cpuCritical: 90,
        memoryCritical: 90,
        diskCritical: 90
    )

    var engine = MonitorEngine(configuration: config)
    let events = engine.evaluate(nodes: [busyOnline, staleOnline, disabled], now: now)
    try expectEqual(events.map(\.kind), [.cpuCritical, .memoryCritical, .diskCritical, .offline, .offline], "lattice node alerts")
    try expectEqual(events[0].id, "node-node-a.cpu", "alert id uses node id")
    try expect(events[3].body.contains("has not reported"), "stale node body")
    try expect(events[4].body.contains("disabled"), "disabled node body")

    let recovered = LatticeNode(
        id: "node-b",
        name: "stale",
        online: true,
        lastSeen: now.addingTimeInterval(601),
        metrics: LatticeMetrics(cpuPercent: 5),
        hostFacts: LatticeHostFacts()
    )
    let recovery = engine.evaluate(nodes: [busyOnline, recovered, disabled], now: now.addingTimeInterval(601))
    try expect(recovery.contains { $0.kind == .recovered && $0.nodeID == "node-b" }, "stale node recovery")
}

func checkBarkRequest() throws {
    try expectEqual(
        BarkDeviceKeyNormalizer.deviceKey(from: "https://api.day.app/device-key/Body%20Text"),
        "device-key",
        "Bark device key extracts from hosted URL"
    )
    try expectEqual(
        BarkDeviceKeyNormalizer.deviceKey(from: "http://bark.example.com:7001/device-key/"),
        "device-key",
        "Bark device key extracts from self-hosted URL"
    )
    try expectEqual(
        BarkDeviceKeyNormalizer.deviceKey(from: "https://api.day.app/push"),
        "",
        "Bark push endpoint is not mistaken for a device key"
    )

    let config = BarkConfiguration(
        serverURL: URL(string: "http://bark.roobli.org")!,
        deviceKey: "device-key",
        defaultGroup: "Lattice",
        sound: "minuet",
        icon: URL(string: "https://day.app/assets/images/avatar.jpg"),
        url: URL(string: "https://lattice.example.com"),
        level: .critical
    )
    let event = MonitorEvent(
        id: "node-node-a.cpu",
        nodeID: "node-a",
        nodeName: "edge",
        kind: .cpuCritical,
        title: "edge CPU high",
        body: "CPU 95.0%",
        date: Date(timeIntervalSince1970: 1_781_658_000)
    )

    let request = try BarkClient.buildRequest(configuration: config, event: event)
    try expectEqual(request.url?.absoluteString, "http://bark.roobli.org/push", "Bark endpoint")
    try expectEqual(request.httpMethod, "POST", "Bark method")
    try expectEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8", "Bark content type")

    let body = try expectUnwrapped(request.httpBody, "Bark request body")
    let object = try expectUnwrapped(JSONSerialization.jsonObject(with: body) as? [String: Any], "Bark JSON object")
    try expectEqual(object["device_key"] as? String, "device-key", "Bark device key")
    try expectEqual(object["title"] as? String, "edge CPU high", "Bark title")
    try expectEqual(object["body"] as? String, "CPU 95.0%", "Bark body")
    try expectEqual(object["group"] as? String, "Lattice", "Bark group")
    try expectEqual(object["sound"] as? String, "minuet", "Bark sound")
    try expectEqual(object["level"] as? String, "critical", "Bark level")
    try expectEqual(object["id"] as? String, "node-node-a.cpu", "Bark id")
    try expectEqual(object["url"] as? String, "https://lattice.example.com", "Bark click URL")
    try expectEqual(ByteFormatter.speed(2048.5), "2.0 KB/s", "fractional byte speed rounds for display")
}

func checkBarkNetworkFlow() async throws {
    let transport = RecordingTransport(responses: [
        "http://bark.roobli.org/push": (200, #"{"code": 200}"#.data(using: .utf8)!)
    ])
    let client = BarkClient(transport: transport)
    let event = MonitorEvent(
        id: "node-node-a.cpu",
        nodeID: "node-a",
        nodeName: "edge",
        kind: .cpuCritical,
        title: "edge CPU high",
        body: "CPU 95.0%",
        date: Date(timeIntervalSince1970: 1_781_658_000)
    )

    try await client.send(
        configuration: BarkConfiguration(
            serverURL: URL(string: "http://bark.roobli.org")!,
            deviceKey: "device-key"
        ),
        event: event
    )

    try expectEqual(await transport.requestURLs, ["http://bark.roobli.org/push"], "Bark send endpoint")

    let codeFailureTransport = RecordingTransport(responses: [
        "http://bark.roobli.org/push": (200, #"{"code": 400, "message": "bad key"}"#.data(using: .utf8)!)
    ])
    do {
        try await BarkClient(transport: codeFailureTransport).send(
            configuration: BarkConfiguration(
                serverURL: URL(string: "http://bark.roobli.org")!,
                deviceKey: "device-key"
            ),
            event: event
        )
        throw CheckFailure.failed("expected Bark response code failure")
    } catch BarkError.serverCode(let code, let message) {
        try expectEqual(code, 400, "Bark response code failure")
        try expectEqual(message, "bad key", "Bark response message failure")
    }
}

func bodyObject(_ data: Data?) throws -> [String: Any] {
    let body = try expectUnwrapped(data, "request body present")
    return try expectUnwrapped(JSONSerialization.jsonObject(with: body) as? [String: Any], "request body JSON object")
}

func checkLatticeAPIClient() async throws {
    let base = URL(string: "https://lattice.example.com")!
    let transport = RecordingTransport(responses: [
        "https://lattice.example.com/api/me": (
            200,
            #"{"actor_id":"admin","username":"admin","token_id":"tok1","scopes":["node:read","node:admin","*"],"csrf_token":"c","totp_enabled":true}"#.data(using: .utf8)!
        ),
        "https://lattice.example.com/api/machines": (
            200,
            """
            [
              {"id":"m1","node_id":"node-a","node_name":"Edge","label":"Tokyo box","online":true,
               "host_facts":{"hostname":"edge"},"vendor":"Vultr","region":"nrt","has_console_url":true,
               "has_detail_url":false,"price_cents":600,"currency":"usd","renewal_cycle":"monthly",
               "cycle_days":0,"next_renewal":"2026-06-20T00:00:00Z","days_until_renewal":3,"auto_roll":true,
               "remind_days_before":[7,1],"reminders_enabled":true,"created_at":"2026-01-01T00:00:00Z"}
            ]
            """.data(using: .utf8)!
        ),
        "https://lattice.example.com/api/monitors": (200, #"{"id":"mon1","name":"api","type":"http","target":"https://x","enabled":true}"#.data(using: .utf8)!),
        "https://lattice.example.com/api/nodes/disable?node_id=node-a": (200, #"{"ok":true,"disabled":true}"#.data(using: .utf8)!),
        "https://lattice.example.com/api/nodes/rotate-token?node_id=node-a": (200, #"{"node_id":"node-a","token":"tok.secret"}"#.data(using: .utf8)!),
        "https://lattice.example.com/api/audit?limit=200&offset=0&decision=deny": (
            200,
            #"{"events":[{"id":"a1","at":"2026-06-17T02:00:00Z","actor_id":"admin","action":"node.disable","decision":"deny","reason":"missing scope"}],"total":1,"limit":200,"offset":0}"#.data(using: .utf8)!
        ),
        "https://lattice.example.com/api/notify/rules": (200, #"{"rules":[{"id":"r1","name":"down","event_types":["monitor.down"],"channel_ids":["c1"],"enabled":true}]}"#.data(using: .utf8)!),
        "https://lattice.example.com/api/logs/query?source_id=s1&limit=200": (
            200,
            #"{"lines":[{"source_id":"s1","node_id":"node-a","seq":42,"at":"2026-06-17T02:00:00Z","line":"hello"}],"truncated":true,"next_before_seq":41}"#.data(using: .utf8)!
        )
    ])

    let session = LatticeClient(baseURL: base, credential: LatticeCredential(sessionCookie: "sid", csrfToken: "csrf-token"), transport: transport)

    let me = try await session.fetchIdentity()
    try expectEqual(me.actorID, "admin", "me actor id")
    try expect(me.totpEnabled, "me totp enabled")
    try expect(me.hasScope("node:read"), "me has explicit scope")
    try expect(me.hasScope("inventory:read"), "me has wildcard scope via *")

    let machines = try await session.listMachines()
    let machine = try expectUnwrapped(machines.first, "machine decoded")
    try expectEqual(machine.nodeName, "Edge", "machine node name from view")
    try expect(machine.hasConsoleURL, "machine has console url flag")
    try expect(!machine.hasDetailURL, "machine has no detail url flag")
    try expectEqual(machine.serverDaysUntilRenewal, 3, "machine server days until renewal")
    let monthly = try expectUnwrapped(machine.monthlyCost, "machine monthly cost")
    try expect(abs(monthly - 6.0) < 0.001, "monthly cost of a $6/mo box")
    try expectEqual(machine.hostFacts.hostname, "edge", "machine host facts")

    try await session.createMonitor(name: "api", type: .http, target: "https://x", intervalSec: 60, timeoutSec: 10, assignAll: true, nodeIDs: [])
    let monitorBody = try await bodyObject(transport.bodies.last ?? nil)
    try expectEqual(Set(monitorBody.keys), ["name", "type", "target", "interval_sec", "timeout_sec", "assign_all", "node_ids"], "monitor create sends exactly the server fields")
    try expectEqual(monitorBody["type"] as? String, "http", "monitor type field")
    try expectEqual(await transport.methods.last ?? nil, "POST", "monitor create is POST")
    try expectEqual(await transport.csrfHeaders.last ?? nil, "csrf-token", "monitor create carries CSRF header")

    try await session.setNodeDisabled(nodeID: "node-a", disabled: true)
    let disableBody = try await bodyObject(transport.bodies.last ?? nil)
    try expectEqual(disableBody["node_id"] as? String, "node-a", "disable node id body")
    try expectEqual(disableBody["disabled"] as? Bool, true, "disable flag body")

    let rotate = try await session.rotateNodeToken(nodeID: "node-a")
    try expectEqual(rotate.token, "tok.secret", "rotate returns one-time token")

    let audit = try await session.fetchAudit(limit: 200, decision: "deny")
    try expectEqual(audit.total, 1, "audit total")
    try expect(audit.events.first?.isDeny ?? false, "audit deny decision parsed")

    let rules = try await session.listNotifyRules()
    try expectEqual(rules.map(\.id), ["r1"], "notify rules unwrapped from envelope")

    let logs = try await session.queryLogs(sourceID: "s1", limit: 200)
    try expectEqual(logs.lines.first?.line, "hello", "log line text")
    try expectEqual(logs.nextBeforeSeq, 41, "log pagination cursor")
    try expect(logs.truncated, "log truncated flag")
}

func checkLatticeAnalytics() throws {
    let now = ISO8601DateFormatter().date(from: "2026-06-17T02:00:00Z")!
    let healthy = LatticeNode(id: "n1", name: "h", online: true, lastSeen: now, metrics: LatticeMetrics(cpuPercent: 20, memoryUsed: 20, memoryTotal: 100), hostFacts: LatticeHostFacts())
    let hot = LatticeNode(id: "n2", name: "hot", online: true, lastSeen: now, metrics: LatticeMetrics(cpuPercent: 95, memoryUsed: 50, memoryTotal: 100), hostFacts: LatticeHostFacts())
    let down = LatticeNode(id: "n3", name: "down", online: false, lastSeen: now.addingTimeInterval(-9999), metrics: LatticeMetrics(), hostFacts: LatticeHostFacts())
    let config = MonitorConfiguration(offlineTimeout: 180, alertCooldown: 600, cpuCritical: 90, memoryCritical: 90, diskCritical: 90)

    let summary = FleetSummary(nodes: [healthy, hot, down], configuration: config, now: now)
    try expectEqual(summary.total, 3, "fleet total")
    try expectEqual(summary.online, 2, "fleet online")
    try expectEqual(summary.offline, 1, "fleet offline")
    try expectEqual(summary.critical, 2, "fleet critical counts hot cpu + offline")
    try expect(abs(summary.averageCPU - 57.5) < 0.001, "fleet average cpu over online nodes")

    var history = MetricsHistory(capacity: 2)
    history.record(nodes: [healthy, hot], at: now)
    history.record(nodes: [healthy, hot], at: now.addingTimeInterval(30))
    history.record(nodes: [healthy], at: now.addingTimeInterval(60))
    try expectEqual(history.samples(for: "n1").count, 2, "history respects capacity")
    try expectEqual(history.samples(for: "n2").count, 0, "history prunes missing nodes")
    try expectEqual(history.samples(for: "n1").last?.cpu, 20, "history records latest cpu")

    let machines = [
        MachineProfile(id: "m1", priceCents: 1200, currency: "USD", renewalCycleRaw: "annual", cycleDays: 0, nextRenewal: now.addingTimeInterval(5 * 86_400)),
        MachineProfile(id: "m2", priceCents: 500, currency: "USD", renewalCycleRaw: "monthly", cycleDays: 0, nextRenewal: now.addingTimeInterval(-2 * 86_400)),
        MachineProfile(id: "m3", priceCents: 0, currency: "USD", renewalCycleRaw: "monthly")
    ]
    let inventory = InventorySummary(machines: machines, window: 14, now: now)
    try expectEqual(inventory.machineCount, 3, "inventory machine count")
    let usd = try expectUnwrapped(inventory.monthlyCostByCurrency["USD"], "USD monthly cost")
    try expect(abs(usd - (12.0 * 30 / 365 + 5.0)) < 0.01, "monthly cost normalizes annual + monthly")
    try expectEqual(inventory.dueSoon.map(\.id), ["m1"], "renewal due soon within window")
    try expectEqual(inventory.overdue.map(\.id), ["m2"], "overdue renewal")

    let results = [
        MonitorResult(monitorID: "x", nodeID: "n1", at: now, success: true, latencyMs: 100),
        MonitorResult(monitorID: "x", nodeID: "n1", at: now.addingTimeInterval(60), success: false, latencyMs: 0, error: "timeout"),
        MonitorResult(monitorID: "x", nodeID: "n1", at: now.addingTimeInterval(120), success: true, latencyMs: 200)
    ]
    let stats = MonitorStats(results: results)
    try expectEqual(stats.successCount, 2, "monitor success count")
    try expect(abs((stats.uptimeFraction ?? 0) - 2.0 / 3.0) < 0.001, "monitor uptime fraction")
    try expect(abs((stats.averageLatencyMs ?? 0) - 150) < 0.001, "monitor average latency over successes")
    try expectEqual(stats.lastResult?.latencyMs, 200, "monitor last result by time")

    try expectEqual(UptimeFormatter.string(seconds: 90_061), "1d 1h", "uptime formats days+hours")
    try expectEqual(RelativeDateFormatter.shortDuration(3_600), "1h", "relative duration hours")
    try expectEqual(RelativeDateFormatter.string(from: now.addingTimeInterval(-120), now: now), "2m ago", "relative date ago")
}

func checkLatticeNetwork() async throws {
    // SHA-256 plan hash (known vectors) — used for the approve TOCTOU defense.
    try expectEqual(PlanHasher.sha256Hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "sha256 of empty string")
    try expectEqual(PlanHasher.sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 of abc")

    let base = URL(string: "https://lattice.example.com")!
    let transport = RecordingTransport(responses: [
        "https://lattice.example.com/api/netpolicy": (
            200,
            """
            {"policies":[
              {"id":"node-a","target_node_id":"node-a","target_node_name":"Edge","enabled":true,
               "rules":[{"id":"r1","action":"allow","direction":"egress","protocol":"tcp","ports":[443],
                         "remote":{"kind":"cidr","cidr":"10.0.0.0/8"},"comment":"https"},
                        {"id":"r2","action":"deny","direction":"ingress","protocol":"any",
                         "remote":{"kind":"any"},"disabled":true}],
               "last_plan_sha":"abc","updated_at":"2026-06-17T02:00:00Z"}
            ]}
            """.data(using: .utf8)!
        ),
        "https://lattice.example.com/api/netpolicy/graph": (
            200,
            """
            {"nodes":[{"id":"node-a","name":"Edge","online":true},{"id":"node-b","name":"Core","online":false}],
             "edges":[{"from":"node-a","to":"node-b","action":"allow","protocol":"tcp","ports":[22],"direction":"egress","rule_id":"r1"}],
             "externals":[{"target_node_id":"node-a","action":"deny","remote":"0.0.0.0/0","protocol":"any","direction":"ingress","rule_id":"r2"}]}
            """.data(using: .utf8)!
        ),
        "https://lattice.example.com/api/network/nft/inputs": (
            200,
            #"{"inputs":[{"id":"node-a","node_id":"node-a","node_name":"Edge","interface_name":"eth0","wireguard_cidr":"10.8.0.0/24","public_tcp":[443,80],"wireguard_udp":[51820],"updated_at":"2026-06-17T02:00:00Z"}]}"#.data(using: .utf8)!
        ),
        "https://lattice.example.com/api/tunnels": (
            200,
            #"[{"id":"t1","name":"web","node_id":"node-a","tunnel_id":"cf-123","ingress":[{"hostname":"app.example.com","service":"http://localhost:8088"}],"created_at":"2026-06-17T00:00:00Z"}]"#.data(using: .utf8)!
        ),
        "https://lattice.example.com/api/network/approvals": (
            200,
            """
            [
              {"id":"ap1","node_id":"node-a","plugin":"nftpolicy","action":"apply nft",
               "plan":"table inet lattice_guard {}","status":"pending","actor_id":"admin",
               "created_at":"2026-06-17T02:00:00Z"},
              {"id":"ap-stale","node_id":"node-a","plugin":"agentupdate","action":"agent.update",
               "plan":"target_version: 0.2.7","status":"pending","actor_id":"admin",
               "reason":"agent update policy changed since this approval was planned; re-plan before approving",
               "stale":true,"stale_code":"agent_update_policy_changed",
               "created_at":"2026-06-17T02:01:00Z"}
            ]
            """.data(using: .utf8)!
        ),
        "https://lattice.example.com/api/network/approvals/approve": (
            200,
            #"{"id":"ap1","node_id":"node-a","plugin":"nftpolicy","action":"apply nft","plan":"table inet lattice_guard {}","status":"approved","actor_id":"admin","approved_by":"admin"}"#.data(using: .utf8)!
        )
    ])

    let client = LatticeClient(baseURL: base, credential: LatticeCredential(sessionCookie: "sid", csrfToken: "csrf-token"), transport: transport)

    let policies = try await client.listNetPolicies()
    let policy = try expectUnwrapped(policies.first, "policy decoded from envelope")
    try expectEqual(policy.targetNodeName, "Edge", "policy node name")
    try expectEqual(policy.rules.count, 2, "policy rule count")
    try expectEqual(policy.activeRules.count, 1, "policy active (non-disabled) rules")
    let rule = try expectUnwrapped(policy.rules.first, "first rule")
    try expect(rule.isAllow, "rule allow")
    try expectEqual(rule.proto, "tcp", "rule protocol via 'protocol' key")
    try expectEqual(rule.remote.displayText, "10.0.0.0/8", "rule remote cidr display")
    try expectEqual(policy.rules[1].remote.displayText, "any", "deny rule remote any")

    let graph = try await client.netPolicyGraph()
    try expectEqual(graph.nodes.count, 2, "graph nodes")
    try expectEqual(graph.edges.first?.ruleID, "r1", "graph edge rule id")
    try expectEqual(graph.externals.first?.remote, "0.0.0.0/0", "graph external remote")
    try expect(!(graph.externals.first?.isAllow ?? true), "graph external deny")

    let inputs = try await client.listNFTInputs()
    let nft = try expectUnwrapped(inputs.first, "nft inputs decoded from envelope")
    try expectEqual(nft.interfaceName, "eth0", "nft interface")
    try expectEqual(NFTInputs.portList(nft.publicTCP), "443, 80", "nft public tcp list")

    let tunnels = try await client.listTunnels()
    try expectEqual(tunnels.first?.ingress.first?.hostname, "app.example.com", "tunnel ingress hostname")

    let approvals = try await client.listApprovals()
    let approval = try expectUnwrapped(approvals.first, "approval decoded")
    try expect(approval.isPending, "approval pending")
    try expect(approval.isApprovable, "fresh pending approval is approvable")
    let expectedHash = PlanHasher.sha256Hex("table inet lattice_guard {}")
    try expectEqual(approval.planHash, expectedHash, "approval plan hash computed")
    let staleApproval = try expectUnwrapped(approvals.first(where: { $0.id == "ap-stale" }), "stale approval decoded")
    try expect(staleApproval.isPending, "stale approval can remain pending until server cleanup")
    try expect(staleApproval.isStale, "stale approval exposes structured stale flag")
    try expect(!staleApproval.isApprovable, "stale approval is not approvable")
    try expectEqual(staleApproval.staleCode, "agent_update_policy_changed", "stale code decoded")
    try expect(staleApproval.reason.contains("re-plan"), "stale reason decoded")

    let approved = try await client.approveApproval(approvalID: approval.id, queueApply: true, planSHA256: approval.planHash)
    try expectEqual(approved.status, "approved", "approve returns approved status")
    let approveBody = try await bodyObject(transport.bodies.last ?? nil)
    try expectEqual(Set(approveBody.keys), ["approval_id", "queue_apply", "plan_sha256"], "approve sends exactly the server fields")
    try expectEqual(approveBody["approval_id"] as? String, "ap1", "approve approval_id")
    try expectEqual(approveBody["queue_apply"] as? Bool, true, "approve queue_apply")
    try expectEqual(approveBody["plan_sha256"] as? String, expectedHash, "approve plan_sha256 matches plan hash")
    try expectEqual(await transport.csrfHeaders.last ?? nil, "csrf-token", "approve carries CSRF header")
}

actor RecordingTransport: HTTPTransport {
    private var responses: [String: [(Int, Data)]]
    private var headers: [String: [String: String]]
    private(set) var requestURLs: [String] = []
    private(set) var authorizationHeaders: [String?] = []
    private(set) var cookieHeaders: [String?] = []
    private(set) var csrfHeaders: [String?] = []
    private(set) var methods: [String?] = []
    private(set) var bodies: [Data?] = []
    private(set) var lastBody: Data?

    init(responses: [String: (Int, Data)], headers: [String: [String: String]] = [:]) {
        self.responses = responses.mapValues { [$0] }
        self.headers = headers
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try expectUnwrapped(request.url, "request URL")
        requestURLs.append(url.absoluteString)
        authorizationHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
        cookieHeaders.append(request.value(forHTTPHeaderField: "Cookie"))
        csrfHeaders.append(request.value(forHTTPHeaderField: "X-Lattice-CSRF"))
        methods.append(request.httpMethod)
        bodies.append(request.httpBody)
        lastBody = request.httpBody

        guard var availableResponses = responses[url.absoluteString], !availableResponses.isEmpty else {
            throw CheckFailure.failed("missing mock response for \(url.absoluteString)")
        }
        let response = availableResponses.removeFirst()
        responses[url.absoluteString] = availableResponses
        let http = HTTPURLResponse(
            url: url,
            statusCode: response.0,
            httpVersion: "HTTP/1.1",
            headerFields: headers[url.absoluteString]
        )!
        return (response.1, http)
    }
}

do {
    try checkLatticeDecoding()
    try checkLatticeURLAndRequests()
    try await checkLatticeNetworkFlow()
    try checkLatticeMonitorEngine()
    try checkBarkRequest()
    try await checkBarkNetworkFlow()
    try await checkLatticeAPIClient()
    try checkLatticeAnalytics()
    try await checkLatticeNetwork()
    print("AstraCoreCheck passed")
} catch {
    fputs("AstraCoreCheck failed: \(error)\n", stderr)
    exit(1)
}
