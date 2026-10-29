import Foundation

/// Demo routes for the Notify domain, owned by the Notify module (section 8.6).
///
/// The channels and rules agree with the Shared deliveries (`ch_bark`,
/// `ch_mail`, `rule_incidents`). The Sent log asks the outbox for 500 rows
/// and a delivery opened by link asks for 200; those two queries are served
/// here with the Shared rows plus richer ones (several attempts, a retry, a
/// fallback, quiet hours, a folded no-route row), filtered by the server's
/// own names. Every notify read is refused to a node-confined token, as the
/// server's `refuseConfinedNotifyRead` does.
public enum NotifyFixtures {
    public static var routes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/notify/channels", body: channelsBody([]), emptyBody: "[]") { request, state in
                if let refusal = confinedRefusal(request) { return refusal }
                return .json(channelsBody(await state.members(of: deletedChannelsSet)))
            }.requiring(admin),
            DemoRoute(pathPattern: "/api/notify/rules", body: rulesBody, emptyBody: #"{"rules":[]}"#) { request, _ in
                confinedRefusal(request) ?? .json(rulesBody)
            }.requiring(admin),
            DemoRoute(pathPattern: "/api/notify/catalogue", body: catalogueBody, emptyBody: #"{"categories":[],"types":[],"patterns":[],"webhook_types":[]}"#) { request, _ in
                confinedRefusal(request) ?? .json(catalogueBody)
            }.requiring(admin),
            DemoRoute(pathPattern: "/api/notify/witness", body: witnessBody, emptyBody: witnessEmptyBody) { request, _ in
                confinedRefusal(request) ?? .json(witnessBody)
            }.requiring(admin),
            DemoRoute(pathPattern: "/api/notify/webhooks", body: webhooksBody([]), emptyBody: #"{"webhooks":[]}"#) { request, state in
                if let refusal = confinedRefusal(request) { return refusal }
                return .json(webhooksBody(await state.members(of: deletedWebhooksSet)))
            }.requiring(admin),
            DemoRoute(pathPattern: "/api/notify/webhooks/deliveries", body: #"{"deliveries":[]}"#, emptyBody: #"{"deliveries":[]}"#) { request, state in
                if let refusal = confinedRefusal(request) { return refusal }
                let id = request.query["id"] ?? ""
                guard !id.isEmpty else { return .error(status: 400, code: "bad_request", message: "id is required") }
                guard webhooks.contains(where: { $0.id == id }), !(await state.contains(id, in: deletedWebhooksSet)) else {
                    return .error(status: 404, code: "not_found", message: "webhook not found")
                }
                return .json(DemoJSON.object([("deliveries", .array(webhookDeliveries(id)))]).text)
            }.requiring(admin),
            // The outbox at the two depths the app reads it (Sent log and open by link).
            deliveriesRoute(limit: NotifySentFilters.limit),
            deliveriesRoute(limit: 200),
            // Writes.
            DemoRoute(method: "POST", pathPattern: "/api/notify/channels/test") { request, state in
                await testChannel(request, state: state)
            }.requiring(admin),
            DemoRoute(method: "POST", pathPattern: "/api/notify/channels/delete") { request, state in
                if let refusal = confinedRefusal(request) { return refusal }
                guard let id = request.bodyStrings["id"], !id.isEmpty else { return .error(status: 400, code: "bad_request", message: "id is required") }
                await state.insert(id, into: deletedChannelsSet)
                return .json(#"{"ok":true}"#)
            }.requiring(admin),
            DemoRoute(method: "POST", pathPattern: "/api/notify/webhooks/test") { request, state in
                await testWebhook(request, state: state)
            }.requiring(admin),
            DemoRoute(method: "POST", pathPattern: "/api/notify/webhooks/delete") { request, state in
                if let refusal = confinedRefusal(request) { return refusal }
                let id = request.bodyStrings["id"] ?? ""
                guard webhooks.contains(where: { $0.id == id }), !(await state.contains(id, in: deletedWebhooksSet)) else {
                    return .error(status: 404, code: "not_found", message: "webhook not found")
                }
                await state.insert(id, into: deletedWebhooksSet)
                return .json(#"{"ok":true}"#)
            }.requiring(admin),
            DemoRoute(method: "POST", pathPattern: "/api/notify/witness/plan") { request, state in
                await planWitness(request, state: state)
            }.requiring(admin),
            // The witness plan already waiting on probe-ams-3, readable by id for Review.
            DemoRoute(pathPattern: "/api/network/approvals", query: ["id": pendingWitness.id], body: pendingWitnessBody, emptyBody: pendingWitnessBody),
        ]
    }

    static let admin = "notify:admin"
    static let deletedChannelsSet = "notify.channels.deleted"
    static let deletedWebhooksSet = "notify.webhooks.deleted"

    /// The server refuses the notify read and write surface to a token with
    /// a server allowlist (`refuseConfinedNotifyRead`, `refuseConfinedFleetWrite`).
    static func confinedRefusal(_ request: DemoRequest) -> DemoResponse? {
        guard DemoTransport.scopes(for: request.identity, scenario: request.scenario).isConfined else { return nil }
        return .error(status: 403, code: "capability_denied", message: "notification history is fleet-wide with no node to confine it to; it requires a token without a server allowlist restriction")
    }

    // MARK: Channels

    public struct Channel: Sendable {
        public var id: String
        public var name: String
        public var kind: String
        public var keys: [String]
        public var enabled: Bool
        public var fallback: String
        public var health: DemoJSON
    }

    static let critical: [String] = ["node.offline", "service.down", "ssh.compromise_suspected", "notify.channel_failing"]

    public static let channels: [Channel] = [
        Channel(id: "ch_bark", name: "Phone (Bark)", kind: "bark", keys: ["base_url", "group", "key", "level"], enabled: true, fallback: "ch_tg", health: .object([
            "state": "ok", "last_attempt_at": .time("-20m"), "last_ok_at": .time("-20m"), "last_failure_at": .time("-9d"),
            "last_failure_kind": "timeout", "consecutive_failures": 0,
        ])),
        Channel(id: "ch_mail", name: "Ops mail", kind: "webhook", keys: ["url"], enabled: true, fallback: "", health: .object([
            "state": "failing", "last_attempt_at": .time("-14m"), "last_ok_at": .time("-1d"), "last_failure_at": .time("-14m"),
            "last_failure_kind": "upstream_5xx", "last_status_code": 503, "consecutive_failures": 6, "failing_since": .time("-175m"),
            "last_fallback_at": .time("-175m"), "last_fallback_channel_id": "ch_tg", "fallbacks": 2,
        ])),
        Channel(id: "ch_tg", name: "Team chat", kind: "telegram", keys: ["chat_id", "token"], enabled: true, fallback: "", health: .object([
            "state": "degraded", "last_attempt_at": .time("-44m"), "last_ok_at": .time("-2h"), "last_failure_at": .time("-44m"),
            "last_failure_kind": "rate_limited", "last_status_code": 429, "consecutive_failures": 2,
        ])),
        Channel(id: "ch_discord", name: "Status room", kind: "discord", keys: ["webhook_url"], enabled: false, fallback: "", health: .object([
            "state": "unknown", "consecutive_failures": 0,
        ])),
    ]

    static func channelJSON(_ channel: Channel) -> DemoJSON {
        .object([
            "id": .string(channel.id),
            "name": .string(channel.name),
            "kind": .string(channel.kind),
            "config_keys": .strings(channel.keys),
            "enabled": .bool(channel.enabled),
            "created_at": .time("-90d"),
            "updated_at": .time("-12d"),
            "health": channel.health,
            "fallback_channel_id": channel.fallback.isEmpty ? nil : .string(channel.fallback),
            "critical_event_types": .strings(critical),
        ])
    }

    static func channelsBody(_ deleted: Set<String>) -> String {
        DemoJSON.array(channels.filter { !deleted.contains($0.id) }.map(channelJSON)).text
    }

    // MARK: Rules

    public struct Rule: Sendable {
        public var id: String
        public var name: String
        public var events: [String]
        public var channels: [String]
        public var enabled: Bool
        public var fallback: String = ""
        public var quiet: (String, String, String)?
        public var escalationOff = false
        public var escalateAfter = 30
        public var level = "critical"
        public var title = ""
        public var body = ""
    }

    public static let rules: [Rule] = [
        Rule(id: "rule_incidents", name: "Incidents to the phone",
             events: ["node.offline", "node.online", "service.down", "service.recovered", "monitor.down", "monitor.recovered", "path.degraded", "path.recovered", "incident.open", "incident.resolved"],
             channels: ["ch_bark"], enabled: true, fallback: "ch_mail", quiet: ("23:00", "07:00", "Europe/Zurich")),
        Rule(id: "rule_ops", name: "Agents and SSH to team chat",
             events: ["agent.stalled", "agent.recovered", "ssh.login", "ssh.compromise_suspected", "cert.renewed"],
             channels: ["ch_tg"], enabled: true, escalateAfter: 15, level: "timeSensitive",
             title: "[Lattice] {{title}}", body: "{{body}}\nNode: {{node}}"),
        Rule(id: "rule_backups", name: "Backups to ops mail", events: ["backup.finished", "notify.channel_failing", "notify.channel_ok"],
             channels: ["ch_mail", "ch_tg"], enabled: true, escalationOff: true),
        Rule(id: "rule_plugins", name: "Plugin chatter", events: ["plugin.health"], channels: ["ch_discord"], enabled: false, escalationOff: true),
    ]

    static var rulesBody: String {
        DemoJSON.object([("rules", .array(rules.map { rule in
            DemoJSON.object([
                "id": .string(rule.id),
                "name": .string(rule.name),
                "event_types": .strings(rule.events),
                "channel_ids": .strings(rule.channels),
                "title_template": rule.title.isEmpty ? nil : .string(rule.title),
                "body_template": rule.body.isEmpty ? nil : .string(rule.body),
                "enabled": .bool(rule.enabled),
                "created_at": .time("-80d"),
                "updated_at": .time("-5d"),
                "fallback_channel_id": rule.fallback.isEmpty ? nil : .string(rule.fallback),
                "escalation_off": .bool(rule.escalationOff),
                "escalate_after_minutes": .number(Double(rule.escalateAfter)),
                "escalation_bark_level": .string(rule.level),
                "quiet_hours": rule.quiet.map { .object(["start": .string($0.0), "end": .string($0.1), "time_zone": .string($0.2)]) } ?? .null,
            ])
        }))]).text
    }

    // MARK: Catalogue (the server's table, notify_catalogue.go)

    static var catalogueBody: String {
        let categories: [(String, String)] = [
            ("nodes", "Nodes"), ("services", "Services"), ("monitors", "Monitors"), ("agents", "Agents"), ("ssh", "SSH"),
            ("auth", "Sign-in"), ("quota", "Quota"), ("inventory", "Inventory"), ("notify", "Notifications"),
            ("plugins", "Plugins"), ("webhooks", "Webhooks"), ("general", "General"),
        ]
        let types: [(String, String, String, Bool, String, String)] = [
            ("node.offline", "nodes", "critical", false, "server-off", "Node offline"),
            ("node.online", "nodes", "info", true, "server", "Node back online"),
            ("service.down", "services", "critical", false, "power-off", "Proxy core down"),
            ("service.recovered", "services", "info", true, "power", "Proxy core recovered"),
            ("monitor.down", "monitors", "warning", false, "activity", "Monitor failing"),
            ("monitor.recovered", "monitors", "info", true, "heart-pulse", "Monitor recovered"),
            ("path.degraded", "monitors", "warning", false, "trending-down", "Path degraded"),
            ("path.recovered", "monitors", "info", true, "trending-up", "Path recovered"),
            ("agent.stalled", "agents", "warning", false, "hourglass", "Agent loop stalled"),
            ("agent.recovered", "agents", "info", true, "bot", "Agent loop recovered"),
            ("agent.mirror_first_plan", "agents", "notice", false, "cloud-download", "Agent mirror in an update plan for the first time"),
            ("ssh.login", "ssh", "notice", false, "key-round", "SSH login"),
            ("ssh.compromise_suspected", "ssh", "critical", false, "shield-alert", "SSH login after repeated failures"),
            ("auth.2fa_limit", "auth", "warning", false, "lock-keyhole", "Two-factor attempt limit reached"),
            ("proxy.quota", "quota", "notice", false, "gauge", "Proxy user quota"),
            ("proxy.expiry", "quota", "notice", false, "calendar-clock", "Proxy user expiry"),
            ("inventory.renewal", "inventory", "notice", false, "receipt", "Server renewal due"),
            ("notify.channel_failing", "notify", "warning", false, "bell-off", "Notification channel failing"),
            ("notify.channel_ok", "notify", "info", true, "bell-ring", "Notification channel recovered"),
            ("notify.test", "notify", "info", false, "flask-conical", "Channel test"),
            ("generic", "general", "info", false, "bell", "Notification"),
        ]
        func entry(_ type: String, _ category: String, _ severity: String, _ recovery: Bool, _ icon: String, _ description: String) -> DemoJSON {
            .object(["type": .string(type), "category": .string(category), "severity": .string(severity), "recovery": .bool(recovery), "icon": .string(icon), "description": .string(description)])
        }
        let webhookTypes = webhooks.filter { !$0.event.hasPrefix("cert.") }.map(\.event).sorted()
        return DemoJSON.object([
            ("categories", .array(categories.map { .object(["id": .string($0.0), "label": .string($0.1)]) })),
            ("types", .array(types.map { entry($0.0, $0.1, $0.2, $0.3, $0.4, $0.5) })),
            ("patterns", [.object([
                ("pattern", "plugin.<id>.message"), ("type", "plugin.<id>.message"), ("category", "plugins"), ("severity", "info"),
                ("recovery", false), ("icon", "puzzle"), ("description", "Plugin message"),
            ])]),
            ("webhook_types", .array((webhookTypes + ["cert.renewed"]).sorted().map { entry($0, "webhooks", "info", false, "webhook", "Inbound webhook event") })),
        ]).text
    }

    // MARK: Witness

    static let pendingWitness: DemoApproval = {
        let plan = witnessRemovePlan(node: DemoWorld.node("probe-ams-3"))
        return DemoApproval(id: "approval_nw01", plugin: "controlplane-witness", action: "witness-remove:v1", node: "probe-ams-3", status: "pending",
                            plan: plan, planSHA256: PlanHasher.sha256Hex(plan), createdAt: "-40m", updatedAt: "-40m")
    }()

    static var pendingWitnessBody: String { DemoJSON.object([("approval", SharedFixtures.approvalJSON(pendingWitness, includePlan: true))]).text }

    static let healthURL = "https://lattice.example.net/readyz"

    static var witnessBody: String {
        let home = DemoWorld.node("home-nas")
        let sin = DemoWorld.node("probe-sin-3")
        let ams = DemoWorld.node("probe-ams-3")
        let studio = DemoWorld.node("studio-mac")
        func approval(_ id: String, action: String, status: String, at: String, reason: String? = nil, channel: Bool = true) -> DemoJSON {
            .object([
                "approval_id": .string(id), "action": .string(action), "status": .string(status), "reason": reason.map(DemoJSON.string),
                "config_sha256": channel ? "4b1f0c2e9a7d3c5b8e6f1a2d4c7b9e0f3a5d8c1b6e9f2a4d7c0b3e5f8a1d4c7b" : nil,
                "channel_id": channel ? "ch_bark" : nil, "channel_name": channel ? "Phone (Bark)" : nil,
                "key_sha256_prefix": channel ? "9c41e07a" : nil,
                "created_at": .time(at), "updated_at": .time(at), "health_url": channel ? .string(healthURL) : nil,
            ])
        }
        let nodes: [DemoJSON] = [
            .object([
                "node_id": .string(home.id), "node_name": .string(home.name), "capable": true,
                "configured": approval("approval_nw00", action: "configure", status: "applied", at: "-12d"),
                "report": .object([
                    "version": 1, "config_sha256": "4b1f0c2e9a7d3c5b8e6f1a2d4c7b9e0f3a5d8c1b6e9f2a4d7c0b3e5f8a1d4c7b",
                    "started_at": .time("-12d"), "phase": "watching", "health_url": .string(healthURL), "reference_count": 3,
                    "interval_seconds": 30, "hold_seconds": 180, "last_check_at": .time("-18s"), "last_check_ok": true,
                    "last_ok_at": .time("-18s"), "alerted": false, "last_push_at": .time("-2d"), "last_push_kind": "recovery",
                    "last_push_ok": true, "pushes": 2, "relayed_at": .time("-15s"),
                ]),
                "reported_at": .time("-15s"), "report_fresh": true, "check_stale": false, "config_matches": true,
            ]),
            .object([
                "node_id": .string(sin.id), "node_name": .string(sin.name), "capable": true,
                "configured": approval("approval_nw02", action: "configure", status: "applied", at: "-6d"),
                "report": .object([
                    "version": 1, "config_sha256": "4b1f0c2e9a7d3c5b8e6f1a2d4c7b9e0f3a5d8c1b6e9f2a4d7c0b3e5f8a1d4c7b",
                    "started_at": .time("-6d"), "phase": "failing", "health_url": .string(healthURL), "reference_count": 3,
                    "interval_seconds": 30, "hold_seconds": 180, "last_check_at": .time("-25s"), "last_check_ok": false,
                    "last_check_detail": "http 503", "last_ok_at": .time("-80s"), "failing_since": .time("-75s"),
                    "consecutive_failures": 2, "alerted": false, "last_push_ok": false, "pushes": 0, "relayed_at": .time("-20s"),
                ]),
                "reported_at": .time("-20s"), "report_fresh": true, "check_stale": false, "config_matches": true,
            ]),
            .object([
                "node_id": .string(ams.id), "node_name": .string(ams.name), "capable": true,
                "configured": approval("approval_nw03", action: "configure", status: "applied", at: "-20d"),
                "pending": approval(pendingWitness.id, action: "remove", status: "pending", at: "-40m", channel: false),
                "report": .object([
                    "version": 1, "config_sha256": "4b1f0c2e9a7d3c5b8e6f1a2d4c7b9e0f3a5d8c1b6e9f2a4d7c0b3e5f8a1d4c7b",
                    "started_at": .time("-20d"), "phase": "watching", "health_url": .string(healthURL), "reference_count": 3,
                    "interval_seconds": 30, "hold_seconds": 180, "last_check_at": .time("-9s"), "last_check_ok": true,
                    "last_ok_at": .time("-9s"), "alerted": false, "last_push_ok": false, "pushes": 0, "relayed_at": .time("-6s"),
                ]),
                "reported_at": .time("-6s"), "report_fresh": true, "check_stale": false, "config_matches": true,
            ]),
        ]
        return DemoJSON.object([
            ("health_url", .string(healthURL)),
            ("nodes", .array(nodes)),
            ("capable_nodes", .array([home, ams, sin, studio].sorted { $0.name < $1.name }.map { node in
                .object(["node_id": .string(node.id), "node_name": .string(node.name), "online": .bool(node.isReporting)])
            })),
            ("defaults", witnessDefaults),
        ]).text
    }

    static let witnessDefaults: DemoJSON = .object([
        "reference_urls": ["https://www.example.com/", "https://example.org/", "https://www.example.net/"],
        "interval_seconds": 30, "hold_seconds": 180, "recover_seconds": 60, "bark_level": "critical",
        "bark_levels": ["active", "timeSensitive", "passive", "critical"],
        "key_file": "/etc/lattice-witness/bark.key", "config_file": "/etc/lattice-witness/config.json", "unit": "lattice-witness.service",
    ])

    static var witnessEmptyBody: String {
        DemoJSON.object([("nodes", []), ("capable_nodes", []), ("defaults", witnessDefaults), ("health_url", .string(healthURL))]).text
    }

    static func witnessRemovePlan(node: DemoWorldNode) -> String {
        """
        Control-plane witness: remove from \(node.name) (\(node.id))

        Afterwards nothing outside the control plane watches it from this node.

        Steps on the node:
        1. Stop and disable lattice-witness.service if it exists.
        2. Remove /etc/systemd/system/lattice-witness.service and daemon-reload.
        3. Remove /etc/lattice-witness (config and device key) and /usr/local/lib/lattice-witness.
        4. Remove /var/lib/lattice-witness, so the agent stops relaying a witness status.

        """
    }

    static func witnessConfigurePlan(node: DemoWorldNode, channel: Channel, barkURL: String) -> String {
        """
        Control-plane witness: configure on \(node.name) (\(node.id))

        The witness is `lattice-agent -witness`, its own process under
        lattice-witness.service on this node. Every 30 s it asks:
          \(healthURL)
        After 180 s of failures while a reference URL still answers, it pushes one
        Bark message (level critical) through the bark-server at \(barkURL),
        then one recovery once the control plane has answered for 60 s.
        When the control plane and every reference fail together, the node's own
        network is down and it pushes nothing. References:
          https://www.example.com/
          https://example.org/
          https://www.example.net/
        It holds no node token, sends no fleet data, and reads nothing but its config
        and the key file. The agent relays its status file on the heartbeat.

        channel_id: \(channel.id)
        device_key_channel: \(channel.name) (\(channel.kind))
        key_sha256_prefix: 9c41e07a
        device_key_file: /etc/lattice-witness/bark.key (0600, root)

        """
    }

    static func planWitness(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        if let refusal = confinedRefusal(request) { return refusal }
        let body = request.bodyStrings
        guard let nodeID = body["node_id"], let node = DemoWorld.node(id: nodeID) else {
            return .error(status: 404, code: "not_found", message: "node not found")
        }
        let remove = body["remove"] == "1" || body["remove"] == "true"
        let plan: String
        if remove {
            plan = witnessRemovePlan(node: node)
        } else {
            guard ["home-nas", "probe-sin-3", "probe-ams-3", "studio-mac"].contains(node.name) else {
                return .error(status: 409, code: "conflict", message: "\(node.name) has not advertised control-plane-witness-v1; update its agent to a release with witness mode and let it heartbeat first")
            }
            guard let channel = channels.first(where: { $0.id == body["channel_id"] }), channel.kind == "bark" else {
                return .error(status: 400, code: "bad_request", message: "channel_id must name a stored Bark channel; its device key is what the witness pushes to")
            }
            let barkURL = body["bark_url"] ?? ""
            guard NotifyWitness.isLoopbackBaseURL(barkURL) else {
                return .error(status: 400, code: "bad_request", message: "bark_url must be the bark-server on the node's loopback address")
            }
            plan = witnessConfigurePlan(node: node, channel: channel, barkURL: barkURL)
        }
        let id = "approval_filed\(await state.recordHit("filed.approval"))"
        let approval = DemoApproval(id: id, plugin: "controlplane-witness", action: remove ? "witness-remove:v1" : "witness-configure:v1",
                                    node: node.name, status: "pending", plan: plan, planSHA256: PlanHasher.sha256Hex(plan), createdAt: "", updatedAt: "")
        await SharedFixtures.recordFiled(approval, state: state)
        return .json(DemoJSON.object([("approval", SharedFixtures.approvalJSON(approval, includePlan: true))]).text)
    }

    // MARK: Channel test

    static func testChannel(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        if let refusal = confinedRefusal(request) { return refusal }
        let id = request.bodyStrings["id"] ?? ""
        guard let channel = channels.first(where: { $0.id == id }), !(await state.contains(id, in: deletedChannelsSet)) else {
            return .error(status: 404, code: "not_found", message: "notification channel not found")
        }
        let failing = channel.id == "ch_mail"
        let attempt: DemoJSON = .object([
            "at": .time(), "ok": .bool(!failing), "kind": failing ? "upstream_5xx" : nil,
            "status": failing ? 503 : nil, "duration_ms": failing ? 1_840 : 380,
        ])
        let delivery: DemoJSON = .object([
            "id": .string("nd_test_\(channel.id)"), "event_id": "evt_test", "event_type": "notify.test", "source": "operator",
            "channel_id": .string(channel.id), "channel_name": .string(channel.name), "channel_kind": .string(channel.kind),
            "role": "test", "outcome": failing ? "failed" : "sent", "reason": failing ? "upstream status 503 after 1 attempts" : nil,
            "attempts": [attempt], "title": "Lattice test",
            "body": .string("Test message for the \(channel.kind) channel \"\(channel.name)\", sent from Notifications. If you can read this, the channel works."),
            "created_at": .time(), "settled_at": .time(),
            "category": "notify", "severity": "info", "recovery": false, "icon": "flask-conical",
        ])
        return .json(DemoJSON.object([("ok", .bool(!failing)), ("delivery", delivery), ("health", channel.health)]).text)
    }

    // MARK: Webhooks

    public struct Webhook: Sendable {
        public var id: String
        public var name: String
        public var event: String
        public var enabled: Bool
        public var lastUsed: String?
        public var title: String
        public var body: String
    }

    public static let webhooks: [Webhook] = [
        Webhook(id: "wh_backup", name: "Nightly backup", event: "backup.finished", enabled: true, lastUsed: "-7h",
                title: "Backup of {{data.host}} finished", body: "{{data.detail}}"),
        Webhook(id: "wh_ups", name: "UPS on battery", event: "ups.on_battery", enabled: true, lastUsed: "-3d",
                title: "UPS {{data.unit}} is on battery", body: "Runtime left: {{data.runtime}}"),
        Webhook(id: "wh_cert", name: "Certificate renewal", event: "cert.renewed", enabled: true, lastUsed: "-2d",
                title: "Renewed {{data.domain}}", body: ""),
        Webhook(id: "wh_ci", name: "CI deploy", event: "deploy.finished", enabled: false, lastUsed: nil,
                title: "Deployed {{data.service}}", body: "{{data.commit}}"),
    ]

    static func webhookJSON(_ hook: Webhook) -> DemoJSON {
        .object([
            "id": .string(hook.id), "name": .string(hook.name), "event_type": .string(hook.event),
            "title_template": .string(hook.title), "body_template": .string(hook.body), "enabled": .bool(hook.enabled),
            "path": .string("/api/hooks/\(hook.id)"), "last_used_at": hook.lastUsed.map(DemoJSON.time),
            "created_at": .time("-40d"), "updated_at": .time("-9d"),
        ])
    }

    static func webhooksBody(_ deleted: Set<String>) -> String {
        DemoJSON.object([("webhooks", .array(webhooks.filter { !deleted.contains($0.id) }.map(webhookJSON)))]).text
    }

    static func webhookAttempt(_ id: String, hook: String, outcome: String, at: String, channels: Int, delivered: Int, reason: String? = nil, test: Bool = false, fields: Int = 2) -> DemoJSON {
        .object([
            "id": .string(id), "webhook_id": .string(hook), "event_type": .string(webhooks.first { $0.id == hook }?.event ?? ""),
            "outcome": .string(outcome), "reason": reason.map(DemoJSON.string),
            "title": outcome == "rejected" ? nil : .string(attemptTitles[hook] ?? "Webhook event"),
            "source_ip": test ? "127.0.0.1" : "192.0.2.31", "fields": .number(Double(fields)), "bytes": 96,
            "channels": .number(Double(channels)), "delivered": .number(Double(delivered)), "test": test ? true : nil,
            "created_at": .time(at),
        ])
    }

    static let attemptTitles = [
        "wh_backup": "Backup of nas.example.net finished", "wh_ups": "UPS rack-a is on battery",
        "wh_cert": "Renewed api.example.org", "wh_ci": "Deployed status-page",
    ]

    static func webhookDeliveries(_ id: String) -> [DemoJSON] {
        switch id {
        case "wh_backup":
            [
                webhookAttempt("whd_01", hook: id, outcome: "accepted", at: "-7h", channels: 2, delivered: 1),
                webhookAttempt("whd_02", hook: id, outcome: "accepted", at: "-31h", channels: 2, delivered: 2),
                webhookAttempt("whd_03", hook: id, outcome: "failed", at: "-55h", channels: 2, delivered: 0, reason: "every channel send failed"),
                webhookAttempt("whd_04", hook: id, outcome: "rejected", at: "-3d", channels: 0, delivered: 0, reason: "authentication failed", fields: 0),
            ]
        case "wh_ups":
            [
                webhookAttempt("whd_05", hook: id, outcome: "no_route", at: "-3d", channels: 0, delivered: 0, reason: "no enabled rule and channel matched the event"),
                webhookAttempt("whd_06", hook: id, outcome: "no_route", at: "-4d", channels: 0, delivered: 0, reason: "no enabled rule and channel matched the event", test: true, fields: 0),
            ]
        case "wh_cert":
            [webhookAttempt("whd_07", hook: id, outcome: "accepted", at: "-2d", channels: 1, delivered: 1, fields: 1)]
        default:
            []
        }
    }

    static func testWebhook(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        if let refusal = confinedRefusal(request) { return refusal }
        let id = request.bodyStrings["id"] ?? ""
        guard let hook = webhooks.first(where: { $0.id == id }), !(await state.contains(id, in: deletedWebhooksSet)) else {
            return .error(status: 404, code: "not_found", message: "webhook not found")
        }
        let routed = !hook.enabled ? false : rules.contains { $0.enabled && $0.events.contains(hook.event) }
        if !hook.enabled {
            return .json(webhookAttempt("whd_test", hook: id, outcome: "rejected", at: "", channels: 0, delivered: 0, reason: "webhook disabled", test: true, fields: 0).text)
        }
        let channelCount = rules.filter { $0.enabled && $0.events.contains(hook.event) }.flatMap(\.channels).count
        return .json(webhookAttempt("whd_test", hook: id, outcome: routed ? "accepted" : "no_route", at: "", channels: routed ? channelCount : 0, delivered: 0,
                                    reason: routed ? nil : "no enabled rule and channel matched the event", test: true, fields: 0).text)
    }

    // MARK: Deliveries

    /// The richer outbox rows, newest first by offset.
    static let deliveries: [DemoJSON] = [
        delivery("dlv_n01", event: "evt_n01", type: "notify.channel_failing", severity: "warning", category: "notify",
                 channel: ("ch_bark", "Phone (Bark)", "bark"), rule: ("rule_backups", "Backups to ops mail"), role: "fallback", fallbackFor: "ch_mail",
                 outcome: "sent", at: "-170m", title: "Channel Ops mail is failing",
                 body: "Ops mail has failed 3 deliveries in a row since the last success (upstream status 503).",
                 attempts: [attempt("-170m", ok: true, status: 200, ms: 402)]),
        delivery("dlv_n02", event: "inc_d03", type: "monitor.down", severity: "warning", category: "monitors",
                 channel: ("ch_mail", "Ops mail", "webhook"), rule: ("rule_incidents", "Incidents to the phone"), role: "fallback", fallbackFor: "ch_bark",
                 outcome: "failed", at: "-22m", title: "tls-api.example.org check failing",
                 body: "HTTPS check tls-api on core-lon-1 failed 3 times: certificate expires in 2 days.",
                 attempts: [attempt("-22m", ok: false, kind: "timeout", ms: 10_000), attempt("-21m", ok: false, kind: "upstream_5xx", status: 502, ms: 640),
                            attempt("-19m", ok: false, kind: "upstream_5xx", status: 503, ms: 702)],
                 reason: "upstream status 503 after 3 attempts", incidents: ["inc_d03"]),
        delivery("dlv_n03", event: "inc_d02", type: "path.degraded", severity: "warning", category: "monitors",
                 channel: ("ch_tg", "Team chat", "telegram"), rule: ("rule_ops", "Agents and SSH to team chat"), role: "primary",
                 outcome: "planned", at: "-44m", title: "Path edge-tyo-1 to relay-fra-1 degraded",
                 body: "Loss 6.2% over the last 5 minutes (trigger 2%).",
                 attempts: [attempt("-44m", ok: false, kind: "rate_limited", status: 429, ms: 210), attempt("-43m", ok: false, kind: "rate_limited", status: 429, ms: 198)],
                 reason: "upstream status 429 after 2 attempts, retrying", incidents: ["inc_d02"], next: "+40s"),
        delivery("dlv_n04", event: "inc_d04", type: "monitor.down", severity: "warning", category: "monitors",
                 channel: ("ch_bark", "Phone (Bark)", "bark"), rule: ("rule_incidents", "Incidents to the phone"), role: "primary",
                 outcome: "planned", at: "-3h", title: "edge-hkg-2 disk above 90%", body: "/var is 93% full.",
                 attempts: [], incidents: ["inc_d04"], held: "+5h"),
        delivery("dlv_n05", event: "evt_n05", type: "ups.on_battery", severity: "info", category: "webhooks", source: ("webhook", "wh_ups"),
                 channel: nil, rule: nil, role: "", outcome: "no_route", at: "-3d", title: "UPS rack-a is on battery",
                 body: "Runtime left: 41 min", attempts: [], reason: "no enabled rule routes this event type", repeats: 3),
        delivery("dlv_n06", event: "evt_n06", type: "ssh.login", severity: "notice", category: "ssh",
                 channel: ("ch_tg", "Team chat", "telegram"), rule: ("rule_ops", "Agents and SSH to team chat"), role: "primary",
                 outcome: "sent", at: "-5h", title: "SSH login on build-fra-4", body: "ops from 198.51.100.77 with publickey.",
                 attempts: [attempt("-5h", ok: true, status: 200, ms: 512)]),
        delivery("dlv_n07", event: "evt_n07", type: "backup.finished", severity: "info", category: "webhooks", source: ("webhook", "wh_backup"),
                 channel: ("ch_tg", "Team chat", "telegram"), rule: ("rule_backups", "Backups to ops mail"), role: "primary",
                 outcome: "sent", at: "-7h", title: "Backup of nas.example.net finished", body: "412 GB in 38 min, 0 errors.",
                 attempts: [attempt("-7h", ok: true, status: 200, ms: 288)]),
        delivery("dlv_n08", event: "evt_n08", type: "notify.test", severity: "info", category: "notify", source: ("operator", ""),
                 channel: ("ch_bark", "Phone (Bark)", "bark"), rule: nil, role: "test", outcome: "sent", at: "-1d",
                 title: "Lattice test", body: "Test message for the bark channel \"Phone (Bark)\", sent from Notifications. If you can read this, the channel works.",
                 attempts: [attempt("-1d", ok: true, status: 200, ms: 371)]),
        delivery("dlv_n09", event: "evt_n09", type: "agent.recovered", severity: "info", category: "agents",
                 channel: ("ch_tg", "Team chat", "telegram"), rule: ("rule_ops", "Agents and SSH to team chat"), role: "primary",
                 outcome: "planned", at: "-8s", title: "edge-tyo-3 agent loop recovered", body: "The agent loop on edge-tyo-3 reports again.",
                 attempts: []),
    ]

    static func attempt(_ at: String, ok: Bool, kind: String = "", status: Int? = nil, ms: Int) -> DemoJSON {
        .object(["at": .time(at), "ok": .bool(ok), "kind": kind.isEmpty ? nil : .string(kind), "status": status.map { .number(Double($0)) }, "duration_ms": .number(Double(ms))])
    }

    static func delivery(_ id: String, event: String, type: String, severity: String, category: String, source: (String, String) = ("server", ""),
                         channel: (String, String, String)?, rule: (String, String)?, role: String, fallbackFor: String = "",
                         outcome: String, at: String, title: String, body: String, attempts: [DemoJSON], reason: String = "",
                         incidents: [String] = [], next: String? = nil, held: String? = nil, repeats: Int = 0) -> DemoJSON {
        let settled = outcome == "sent" || outcome == "failed" || outcome == "no_route"
        return .object([
            "id": .string(id), "event_id": .string(event), "event_type": .string(type),
            "source": .string(source.0), "source_id": source.1.isEmpty ? nil : .string(source.1),
            "rule_id": rule.map { .string($0.0) }, "rule_name": rule.map { .string($0.1) },
            "channel_id": channel.map { .string($0.0) }, "channel_name": channel.map { .string($0.1) }, "channel_kind": channel.map { .string($0.2) },
            "role": role.isEmpty ? nil : .string(role), "fallback_for": fallbackFor.isEmpty ? nil : .string(fallbackFor),
            "outcome": .string(outcome), "reason": reason.isEmpty ? nil : .string(reason),
            "attempts": attempts.isEmpty ? nil : .array(attempts), "next_attempt_at": next.map(DemoJSON.time),
            "title": .string(title), "body": .string(body),
            "created_at": .time(at), "settled_at": settled ? .time(at) : nil,
            "repeats": repeats > 0 ? .number(Double(repeats)) : nil, "last_seen_at": repeats > 0 ? .time("-50m") : nil,
            "held_until": held.map(DemoJSON.time), "incident_ids": incidents.isEmpty ? nil : .strings(incidents),
            "category": .string(category), "severity": .string(severity), "recovery": false,
        ])
    }

    /// The Shared rows and these, newest first.
    static var allDeliveries: [DemoJSON] {
        (SharedFixtures.deliveries + deliveries).sorted { offsetSeconds($0) > offsetSeconds($1) }
    }

    /// The created_at token as seconds from now ("{{now-3h}}" is -10800).
    static func offsetSeconds(_ row: DemoJSON) -> Int {
        guard case .object(let pairs) = row, case .string(let token)? = pairs.first(where: { $0.0 == "created_at" })?.1,
              let match = token.firstMatch(of: /\{\{now([+-])(\d+)([smhd])\}\}/) else { return 0 }
        let unit = ["s": 1, "m": 60, "h": 3_600, "d": 86_400][String(match.3)] ?? 1
        return (match.1 == "-" ? -1 : 1) * (Int(match.2) ?? 0) * unit
    }

    static func deliveriesRoute(limit: Int) -> DemoRoute {
        DemoRoute(pathPattern: "/api/notify/deliveries", query: ["limit": String(limit)], body: outboxBody(allDeliveries),
                  emptyBody: SharedFixtures.deliveriesBody([])) { request, _ in
            if let refusal = confinedRefusal(request) { return refusal }
            var rows = allDeliveries
            for name in ["channel_id", "event_type", "event_id", "source", "source_id"] {
                guard let wanted = request.query[name], !wanted.isEmpty else { continue }
                rows = rows.filter { field($0, name) == wanted }
            }
            if let outcome = request.query["outcome"], !outcome.isEmpty {
                rows = rows.filter { field($0, "outcome") == outcome }
            }
            return .json(outboxBody(Array(rows.prefix(limit))))
        }.requiring(admin)
    }

    /// `stored` is the whole outbox, as the server counts it, not the page.
    static func outboxBody(_ rows: [DemoJSON]) -> String {
        DemoJSON.object([
            ("deliveries", .array(rows)),
            ("stored", .number(Double(allDeliveries.count))),
            ("durable", true),
            ("max", 2_000),
            ("floor", 200),
        ]).text
    }

    static func field(_ row: DemoJSON, _ name: String) -> String? {
        guard case .object(let pairs) = row, case .string(let value)? = pairs.first(where: { $0.0 == name })?.1 else { return nil }
        return value
    }
}
