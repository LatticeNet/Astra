import Foundation

/// Demo routes for the VPN domain, owned by the VPN module (section 8.6).
///
/// Bodies follow `server_vpncore.go` and its views: `users.list` and
/// `users.get` answer `vpnUserUsageView` rows, `lines.list` the node-grouped
/// `Line` read model, and the link routes `identityLinkStatusView` and
/// `linkRevealView`. The identities cover every state the screens show:
/// alice expiring with an active link that leaves one line out, bob over his
/// quota (placeholder), carol active with no link, dave expired with a
/// paused link, erin bound to no line, frank turned off, grace active with a
/// link that serves nothing, and heidi suspended by an operator. The lines
/// carry M3's chain uuids (edge-tyo-1 to relay-hkg-1 to relay-fra-1,
/// edge-sin-1 to relay-fra-2, edge-iad-1 to edge-sjc-1) and one line in each
/// line state. Rotating and revoking a link are recorded in DemoState.
public enum VPNFixtures {
    public static let rotatedSet = "vpn.link.rotated"
    public static let revokedSet = "vpn.link.revoked"
    public static let missingUserID = "vu_gone"

    public static var routes: [DemoRoute] {
        [
            DemoRoute(method: "POST", pathPattern: "/api/plugins/call", bodyMatch: ["service": VPNService.users, "method": "list"],
                      body: usersListBody) { request, state in
                if case .empty = request.scenario { return .json(#"{"users":[],"count":0}"#) }
                return .json(await usersList(state: state))
            }.requiring(VPNIntents.readScope),
            DemoRoute(method: "POST", pathPattern: "/api/plugins/call", bodyMatch: ["service": VPNService.users, "method": "get"]) { request, state in
                await userGet(request, state: state)
            }.requiring(VPNIntents.readScope),
            DemoRoute(method: "POST", pathPattern: "/api/plugins/call", bodyMatch: ["service": VPNService.lines, "method": "list"],
                      body: linesListBody) { request, _ in
                if case .empty = request.scenario { return .json(#"{"groups":[],"count":0}"#) }
                return .json(linesListBody)
            }.requiring(VPNIntents.readScope),
            DemoRoute(pathPattern: "/api/proxy/users", body: proxyUsersBody, emptyBody: #"{"users":[]}"#).requiring("proxy:read"),
            DemoRoute(pathPattern: "/api/vpn/users/*/link", body: linkStatusBody(users[0], rotated: false, revoked: false),
                      emptyBody: notIssuedBody(identity: "vu_none")) { request, state in
                await linkStatus(request, state: state)
            }.requiring(VPNIntents.linkScope),
            DemoRoute(method: "POST", pathPattern: "/api/vpn/users/*/link/rotate") { request, state in
                await rotate(request, state: state)
            }.requiring(VPNIntents.linkScope),
            DemoRoute(method: "DELETE", pathPattern: "/api/vpn/users/*/link") { request, state in
                await revoke(request, state: state)
            }.requiring(VPNIntents.linkScope),
            DemoRoute(method: "POST", pathPattern: "/api/vpn/users/*/link/reveal") { request, state in
                await revealLink(request, state: state)
            }.requiring(VPNIntents.linkScope),
            DemoRoute(method: "POST", pathPattern: "/api/proxy/users/reveal-credentials") { request, _ in
                revealCredentials(request)
            }.requiring(VPNIntents.credentialsScope),
        ]
    }

    // MARK: Lines

    /// The stable handle of demo line `n`.
    public static func lineHash(_ n: Int) -> String {
        String(format: "line_7a1c0e52%016d", n)
    }

    /// The uuid M3's chain fixtures use for line `n`.
    public static func lineUUID(_ n: Int) -> String {
        String(format: "7a1c0e52-0000-4000-8000-%012d", n)
    }

    public struct Line: Sendable {
        public var n: Int
        public var node: String
        public var name: String
        public var type: String
        public var security: String = "reality"
        public var transport: String = "tcp"
        public var port: Int = 443
        /// Lines in a chain carry M3's uuid.
        public var chained = false
        public var relaysTo: Int?
        public var outbound: String = "direct"
        public var users: Int? = 3
        public var status: String = "ok"
        public var lastError: String = ""
        public var service: String = "running"
        public var serviceNote: String = ""
        public var managed = true
        public var domain: String = ""

        public var hash: String { VPNFixtures.lineHash(n) }
        public var nodeID: String { DemoWorld.node(node).id }
    }

    public static let lines: [Line] = [
        Line(n: 1, node: "edge-tyo-1", name: "tyo-reality", type: "vless", chained: true, relaysTo: 2, users: 6),
        Line(n: 8, node: "edge-tyo-1", name: "tyo-hy2", type: "hysteria2", security: "tls", transport: "udp", port: 8443, users: 4, domain: "hy.example.net"),
        Line(n: 2, node: "relay-hkg-1", name: "hk-in", type: "vless", port: 8443, chained: true, relaysTo: 3, users: 3),
        Line(n: 3, node: "relay-fra-1", name: "fra-exit", type: "vless", chained: true, users: 5),
        Line(n: 4, node: "edge-sin-1", name: "sin-reality", type: "vless", chained: true, relaysTo: 5, users: 4),
        Line(n: 5, node: "relay-fra-2", name: "fra2-exit", type: "vless", chained: true, users: 2, service: "down",
             serviceNote: "sing-box exited: listen tcp :443: bind: address already in use"),
        Line(n: 6, node: "edge-iad-1", name: "iad-ws", type: "vless", security: "tls", transport: "ws", chained: true, relaysTo: 7, users: 3,
             status: "pending", domain: "iad.example.net"),
        Line(n: 7, node: "edge-sjc-1", name: "sjc-exit", type: "vless", chained: true, users: 3),
        Line(n: 9, node: "edge-ams-1", name: "ams-trojan", type: "trojan", security: "tls", users: 2, status: "error",
             lastError: "config check failed: unknown field \"tls.reality.short_id\"", domain: "ams.example.net"),
        Line(n: 10, node: "edge-lon-1", name: "lon-ss", type: "shadowsocks", security: "none", port: 8388, users: nil, service: "", managed: false),
        Line(n: 11, node: "edge-syd-1", name: "syd-tuic", type: "tuic", security: "tls", transport: "udp", port: 8443, users: 1,
             service: "restarting", serviceNote: "restarted 4 times in the last 10 minutes"),
        Line(n: 12, node: "edge-hkg-2", name: "hkg2-vmess", type: "vmess", security: "tls", transport: "ws", users: 2, status: "stale",
             domain: "hkg.example.net"),
        Line(n: 13, node: "edge-tyo-2", name: "tyo2-anytls", type: "anytls", security: "tls", port: 9443, users: 1, service: "",
             serviceNote: "no process holds :9443; the probe could not tell which service should"),
    ]

    public static func line(_ n: Int) -> Line {
        guard let line = lines.first(where: { $0.n == n }) else { preconditionFailure("no demo line \(n)") }
        return line
    }

    static func lineJSON(_ line: Line) -> DemoJSON {
        let node = DemoWorld.node(line.node)
        let target = line.relaysTo.map(VPNFixtures.line)
        let outboundRef = target.map { "\($0.node)/\($0.name)" } ?? line.outbound
        return .object([
            "id": .string(line.hash),
            "line_hash_id": .string(line.hash),
            "node_id": .string(node.id),
            "line_uuid": line.chained ? .string(lineUUID(line.n)) : nil,
            "downstream_line_uuid": target.map { .string(lineUUID($0.n)) },
            "core": "sing-box",
            "source": .string(line.managed ? "managed" : "discovered"),
            "managed": .bool(line.managed),
            "name": .string(line.name),
            "tag": .string(line.name),
            "named_users": line.users.map { .number(Double($0)) },
            "type": .string(line.type),
            "transport": .string(line.transport),
            "security": .string(line.security),
            "listen_host": "::",
            "listen_port": .number(Double(line.port)),
            "public_host": .string(node.hostname),
            "domain": line.domain.isEmpty ? nil : .string(line.domain),
            "outbound_ref": .string(outboundRef),
            "outbound_server": target.map { .string(DemoWorld.node($0.node).hostname) },
            "outbound_port": target.map { .number(Double($0.port)) },
            "jump_edges": target.map { .strings([$0.hash]) },
            "declared_jump_edges": target.map { .strings([$0.hash]) },
            "user_count": .number(Double(line.users ?? 0)),
            "user_known": .bool(line.users != nil),
            "status": .string(line.status),
            "last_error": line.lastError.isEmpty ? nil : .string(line.lastError),
            "service_state": line.service.isEmpty ? nil : .string(line.service),
            "service_checked_at": line.service.isEmpty && line.serviceNote.isEmpty ? nil : .time("-2m"),
            "service_note": line.serviceNote.isEmpty ? nil : .string(line.serviceNote),
        ])
    }

    static let linesListBody: String = {
        var order: [String] = []
        var byNode: [String: [Line]] = [:]
        for line in lines {
            if byNode[line.node] == nil { order.append(line.node) }
            byNode[line.node, default: []].append(line)
        }
        let groups: [DemoJSON] = order.map { name in
            let node = DemoWorld.node(name)
            return .object(["node_id": .string(node.id), "node_name": .string(node.name), "lines": .array(byNode[name]!.map(lineJSON))])
        }
        return DemoJSON.object(["groups": .array(groups), "count": .number(Double(lines.count))]).text
    }()

    // MARK: Identities

    public struct Binding: Sendable {
        public var line: Int
        public var enabled = true
        public var credential = "current"
    }

    public struct LinkLine: Sendable {
        public var line: Int
        public var reason: String = ""
        public var fix: String = ""
        public var detail: String = ""
    }

    public struct User: Sendable {
        public var id: String
        public var email: String
        public var name: String
        public var group: String = ""
        public var comment: String = ""
        public var enabled = true
        public var protocols: [String] = ["vless"]
        public var bindings: [Binding] = []
        public var quotaGiB: Double = 0
        public var monthly = false
        /// A time token offset ("+5d"); nil for no expiry.
        public var expires: String?
        public var usedGiB: Double = 0
        public var last7dMiB: [Double] = []
        public var lastSeen: String? = "-25m"
        public var policy: String = "active"
        public var policyReason: String = ""
        public var suspendedBy: String = ""
        public var migrated = false
        public var created: String = "-120d"
        /// nil for no link; otherwise its slug.
        public var slug: String?
        public var linkEnabled = true
        public var linkIntervalHours = 12
        public var linkRotated: String?
        /// nodes, placeholder or decoy, with its reason.
        public var answer: String = "nodes"
        public var answerReason: String = "active"
        public var placeholder: String = ""
        public var included: [LinkLine] = []
        public var excluded: [LinkLine] = []
        /// The last fetch: offset, client class and answer.
        public var fetch: (at: String, ua: String, answer: String)?
    }

    public static let users: [User] = [
        User(id: "vu_alice", email: "alice@example.org", name: "Alice", group: "family", comment: "Phone and laptop",
             protocols: ["vless", "hysteria2", "anytls"],
             bindings: [Binding(line: 1), Binding(line: 8), Binding(line: 13, credential: "stale")],
             quotaGiB: 100, monthly: true, expires: "+5d", usedGiB: 38.2, last7dMiB: [910, 1_420, 760, 2_210, 1_880, 640, 1_130],
             slug: "u-k3m9q2x7ab", linkRotated: "-20d",
             included: [LinkLine(line: 1), LinkLine(line: 8)],
             excluded: [LinkLine(line: 13, reason: "rotation_not_applied", fix: "plan_update")],
             fetch: ("-3h", "shadowrocket", "nodes")),
        User(id: "vu_bob", email: "bob@example.org", name: "Bob", group: "family", bindings: [Binding(line: 3)],
             quotaGiB: 50, usedGiB: 53.7, last7dMiB: [2_900, 3_400, 4_100, 2_200, 3_800, 5_100, 4_400], lastSeen: "-6m",
             policy: "over_quota", policyReason: "quota", slug: "u-p8w2n5c4td", linkIntervalHours: 6,
             answer: "placeholder", answerReason: "quota", placeholder: "Quota used up",
             included: [LinkLine(line: 3)], fetch: ("-40m", "clashmeta", "placeholder")),
        User(id: "vu_carol", email: "carol@example.net", name: "Carol", group: "team", protocols: ["vless", "trojan"],
             bindings: [Binding(line: 4), Binding(line: 5)], usedGiB: 12.4, last7dMiB: [320, 410, 0, 560, 380, 290, 450]),
        User(id: "vu_dave", email: "dave@example.net", name: "Dave", group: "team", bindings: [Binding(line: 6)],
             expires: "-3d", usedGiB: 4.1, last7dMiB: [120, 90, 0, 0, 0, 0, 0], lastSeen: "-3d",
             policy: "expired", policyReason: "expiry", slug: "u-z6r1h9m3qe", linkEnabled: false,
             answer: "decoy", answerReason: "link_disabled", included: [LinkLine(line: 6)]),
        User(id: "vu_erin", email: "erin@example.org", name: "Erin", group: "guests", usedGiB: 0, lastSeen: nil,
             created: "-2d", slug: "u-b4t7y2k8wn", answer: "placeholder", answerReason: "no_lines", placeholder: "No lines assigned yet"),
        User(id: "vu_frank", email: "frank@example.org", name: "Frank", group: "guests", enabled: false,
             bindings: [Binding(line: 7, enabled: false, credential: "none")], usedGiB: 0.8, lastSeen: "-41d",
             policy: "disabled", policyReason: "disabled", suspendedBy: DemoWorld.actorID),
        User(id: "vu_grace", email: "grace@example.org", name: "Grace", group: "team", protocols: ["vless", "vmess"],
             bindings: [Binding(line: 7, credential: "none"), Binding(line: 12, credential: "current")],
             quotaGiB: 200, monthly: true, usedGiB: 9.6, last7dMiB: [800, 1_100, 950, 1_300, 0, 0, 0], lastSeen: "-2d",
             slug: "u-g2c5v8x1rm", answer: "decoy", answerReason: "transient_empty",
             excluded: [LinkLine(line: 7, reason: "credential_not_applied", fix: "plan_add"),
                        LinkLine(line: 12, reason: "template_lossy", fix: "wait_for_template", detail: "dropped: alpn, fp")],
             fetch: ("-30h", "singbox", "decoy")),
        User(id: "vu_heidi", email: "heidi@example.org", name: "Heidi", group: "team", comment: "Paused while travelling",
             protocols: ["trojan"], bindings: [Binding(line: 9)], usedGiB: 21.3, last7dMiB: [0, 0, 0, 0, 0, 0, 0], lastSeen: "-9d",
             policy: "disabled", policyReason: "operator", suspendedBy: DemoWorld.actorID, migrated: true, created: "-400d",
             slug: "u-h7q3d6w9pf", answer: "placeholder", answerReason: "operator", placeholder: "Account suspended"),
    ]

    public static func user(_ id: String) -> User? {
        users.first { $0.id == id }
    }

    private static let gib = 1_073_741_824.0

    private static func bytes(_ gib: Double) -> DemoJSON {
        .number((gib * Self.gib).rounded())
    }

    static func linkSummaryJSON(_ user: User, rotated: Bool) -> DemoJSON? {
        guard let slug = user.slug else { return nil }
        return .object([
            "slug": .string(slug),
            "enabled": .bool(user.linkEnabled),
            "issued_at": .time("-90d"),
            "rotated_at": rotated ? .time("") : user.linkRotated.map { .time($0) },
            "update_interval_hours": .number(Double(user.linkIntervalHours)),
        ])
    }

    static func userView(_ user: User, usage: Bool, rotated: Bool = false, revoked: Bool = false) -> DemoJSON {
        let credentials: [DemoJSON] = user.protocols.map { proto in
            .object([
                "protocol": .string(proto),
                "flow": proto == "vless" ? "xtls-rprx-vision" : nil,
                "method": proto == "shadowsocks" ? "2022-blake3-aes-128-gcm" : nil,
                "has_secret": true,
            ])
        }
        let bindings: [DemoJSON] = user.bindings.map { binding in
            .object([
                "line_hash_id": .string(lineHash(binding.line)),
                "enabled": .bool(binding.enabled),
                "credential": usage ? .string(binding.credential) : nil,
            ])
        }
        var pairs: [(String, DemoJSON)] = [
            ("id", .string(user.id)),
            ("email", .string(user.email)),
            ("name", .string(user.name)),
            ("enabled", .bool(user.enabled)),
            ("credentials", .array(credentials)),
            ("bindings", .array(bindings)),
        ]
        if user.quotaGiB > 0 { pairs.append(("quota_bytes", bytes(user.quotaGiB))) }
        if user.monthly {
            pairs.append(("quota_period", "monthly"))
            pairs.append(("quota_reset_day", 1))
        }
        if let expires = user.expires { pairs.append(("expires_at", .time(expires))) }
        if !user.group.isEmpty { pairs.append(("group", .string(user.group))) }
        if !user.comment.isEmpty { pairs.append(("comment", .string(user.comment))) }
        pairs.append(("migrated", .bool(user.migrated)))
        if !revoked, let link = linkSummaryJSON(user, rotated: rotated) { pairs.append(("link", link)) }
        pairs.append(("created_at", .time(user.created)))
        pairs.append(("updated_at", .time("-4d")))
        guard usage else { return .object(pairs) }
        pairs.append(("used_total_bytes", bytes(user.usedGiB * (user.monthly ? 2.6 : 1))))
        pairs.append(("used_total_from", .time("-400d")))
        if user.created == "-400d" { pairs.append(("used_total_truncated", true)) }
        pairs.append(("used_period_bytes", bytes(user.usedGiB)))
        if user.monthly {
            pairs.append(("period_start", .time("-28d")))
            pairs.append(("period_end", .time("+3d")))
        }
        let days = user.last7dMiB.isEmpty ? Array(repeating: 0.0, count: 7) : user.last7dMiB
        pairs.append(("last_7d", .array(days.map { .number(($0 * 1_048_576).rounded()) })))
        if let seen = user.lastSeen { pairs.append(("last_seen_at", .time(seen))) }
        pairs.append(("allocated_nodes", .array(allocated(user))))
        pairs.append(("policy", policy(user)))
        return .object(pairs)
    }

    private static func allocated(_ user: User) -> [DemoJSON] {
        var byNode: [String: [Binding]] = [:]
        var order: [String] = []
        for binding in user.bindings where binding.enabled {
            let node = line(binding.line).node
            if byNode[node] == nil { order.append(node) }
            byNode[node, default: []].append(binding)
        }
        let share = user.usedGiB / Double(max(1, user.bindings.filter(\.enabled).count))
        return order.map { name in
            let node = DemoWorld.node(name)
            let rows: [DemoJSON] = byNode[name]!.map { binding in
                let item = line(binding.line)
                return .object([
                    "line_hash_id": .string(item.hash),
                    "tag": .string(item.name),
                    "role": .string(item.relaysTo == nil ? "exit" : "entry"),
                    "allocation": "binding",
                    "period_uplink": bytes(share * 0.08),
                    "period_downlink": bytes(share * 0.92),
                    "last_seen_at": user.lastSeen.map { .time($0) },
                    "counted": true,
                ])
            }
            return .object([
                "node_id": .string(node.id),
                "node_name": .string(node.name),
                "collector_state": .string(name == "edge-tyo-2" ? "stats_off" : "ok"),
                "lines": .array(rows),
            ])
        }
    }

    private static func policy(_ user: User) -> DemoJSON {
        var pairs: [(String, DemoJSON)] = [("status", .string(user.policy))]
        if !user.policyReason.isEmpty { pairs.append(("reason", .string(user.policyReason))) }
        if !user.suspendedBy.isEmpty {
            pairs.append(("suspended_by", .string(user.suspendedBy)))
            pairs.append(("suspended_since", .time("-9d")))
        }
        if user.quotaGiB > 0 {
            var quota: [(String, DemoJSON)] = [
                ("limit_bytes", bytes(user.quotaGiB)),
                ("used_bytes", bytes(user.usedGiB)),
                ("proof_bytes", bytes(user.usedGiB * 0.97)),
            ]
            if user.usedGiB >= user.quotaGiB { quota.append(("evidence", "proof")) }
            quota.append(("period", .string(user.monthly ? "monthly" : "lifetime")))
            if user.monthly {
                quota.append(("period_start", .time("-28d")))
                quota.append(("period_end", .time("+3d")))
            }
            pairs.append(("quota", .object(quota)))
        }
        return .object(pairs)
    }

    static let usersListBody: String = DemoJSON.object([
        "users": .array(users.map { userView($0, usage: true) }),
        "count": .number(Double(users.count)),
    ]).text

    /// The list as it stands after the demo's rotations and revocations:
    /// a revoked link drops out of the summary, as the server's list does.
    private static func usersList(state: DemoState) async -> String {
        var rows: [DemoJSON] = []
        for user in users { rows.append(await recordedView(user, state: state)) }
        return DemoJSON.object(["users": .array(rows), "count": .number(Double(users.count))]).text
    }

    private static func recordedView(_ user: User, state: DemoState) async -> DemoJSON {
        userView(user, usage: true, rotated: await state.contains(user.id, in: rotatedSet), revoked: await state.contains(user.id, in: revokedSet))
    }

    private static func userGet(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        let payload = request.bodyObject()?["payload"] as? [String: Any]
        let id = payload?["id"] as? String ?? ""
        guard let user = user(id) else {
            // The gateway hides the service's "not found" text behind the
            // generic 502 message (`apiErrorMessage`), as the server does.
            return .error(status: 502, code: "bad_gateway", message: "upstream service error")
        }
        return .json(DemoJSON.object(["user": await recordedView(user, state: state)]).text)
    }

    /// The legacy proxy users the identities were derived from, as
    /// `/api/proxy/users` lists them.
    static let proxyUsersBody: String = {
        let rows: [DemoJSON] = users.prefix(4).map { user in
            .object([
                "id": .string(String(user.id.dropFirst(3))),
                "name": .string(user.email),
                "enabled": .bool(user.enabled),
                "has_uuid": true,
                "has_password": .bool(user.protocols.contains("trojan")),
                "traffic_limit_bytes": user.quotaGiB > 0 ? bytes(user.quotaGiB) : nil,
                "expires_at": user.expires.map { .time($0) },
                "used_bytes": bytes(user.usedGiB),
                "last_seen_at": user.lastSeen.map { .time($0) },
                "status": .string(user.policy == "disabled" ? "disabled" : user.policy),
                "created_at": .time(user.created),
                "updated_at": .time("-4d"),
            ])
        }
        return DemoJSON.object(["users": .array(rows)]).text
    }()

    // MARK: Identity link

    private static func linkLineJSON(_ entry: LinkLine) -> DemoJSON {
        let item = line(entry.line)
        return .object([
            "line_hash_id": .string(item.hash),
            "node_id": .string(item.nodeID),
            "node_name": .string(item.node),
            "line_name": .string(item.name),
            "protocol": .string(item.type),
            "reason": entry.reason.isEmpty ? nil : .string(entry.reason),
            "fix": entry.fix.isEmpty ? nil : .string(entry.fix),
            "detail": entry.detail.isEmpty ? nil : .string(entry.detail),
        ])
    }

    private static let formats: DemoJSON = .object([
        "native": .strings(["URI", "V2Ray"]),
        "converted": .strings(["ClashMeta", "Clash", "Stash", "sing-box", "Surge", "SurgeMac", "Loon", "QX", "Shadowrocket", "Egern", "Surfboard", "JSON"]),
        "convert_available": true,
    ])

    static func notIssuedBody(identity: String) -> String {
        DemoJSON.object([
            "identity_id": .string(identity),
            "issued": false,
            "answer": "decoy",
            "answer_reason": "not_issued",
            "included": [],
            "excluded": [],
            "formats": formats,
        ]).text
    }

    static func linkStatusBody(_ user: User, rotated: Bool, revoked: Bool) -> String {
        guard !revoked, let summary = linkSummaryJSON(user, rotated: rotated) else { return notIssuedBody(identity: user.id) }
        let total = user.quotaGiB > 0 ? max(user.quotaGiB, user.usedGiB) : 0
        let used = user.answer == "placeholder" && total > 0 ? total : user.usedGiB
        var userinfo = "upload=\(Int((used * 0.08 * gib).rounded())); download=\(Int((used * 0.92 * gib).rounded()))"
        if total > 0 { userinfo += "; total=\(Int((total * gib).rounded()))" }
        // A fetch after a rotation could only come from a client given the
        // new link, which nobody has yet.
        let fetch: DemoJSON? = rotated ? nil : user.fetch.map { fetch in
            .object(["at": .time(fetch.at), "ua_class": .string(fetch.ua), "answer": .string(fetch.answer)])
        }
        return DemoJSON.object([
            "identity_id": .string(user.id),
            "issued": true,
            "link": summary,
            "answer": .string(user.answer),
            "answer_reason": .string(user.answerReason),
            "placeholder": user.placeholder.isEmpty ? nil : .string(user.placeholder),
            "subscription_userinfo": user.answer == "decoy" ? nil : .string(userinfo),
            "included": .array(user.included.map(linkLineJSON)),
            "excluded": .array(user.excluded.map(linkLineJSON)),
            "formats": formats,
            "last_fetch": fetch,
        ]).text
    }

    private static func userID(_ request: DemoRequest) -> String {
        request.segments.count > 3 ? request.segments[3] : ""
    }

    private static let notFound = DemoResponse.error(status: 404, code: "not_found", message: "vpn user not found")
    private static let notIssued = DemoResponse.error(status: 404, code: "link_not_issued", message: "this identity has no link; issue one first")

    private static func linkStatus(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        let id = userID(request)
        guard let user = user(id) else { return notFound }
        return .json(linkStatusBody(user, rotated: await state.contains(id, in: rotatedSet), revoked: await state.contains(id, in: revokedSet)))
    }

    private static func rotate(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        let id = userID(request)
        guard let user = user(id) else { return notFound }
        guard user.slug != nil, !(await state.contains(id, in: revokedSet)) else { return notIssued }
        await state.insert(id, into: rotatedSet)
        return .json(linkStatusBody(user, rotated: true, revoked: false))
    }

    private static func revoke(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        let id = userID(request)
        guard let user = user(id) else { return notFound }
        guard user.slug != nil, !(await state.contains(id, in: revokedSet)) else {
            return .error(status: 404, code: "link_not_issued", message: "this identity has no link")
        }
        await state.insert(id, into: revokedSet)
        return .json(notIssuedBody(identity: id))
    }

    private static func revealLink(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        let id = userID(request)
        guard let user = user(id) else { return notFound }
        guard let slug = user.slug, !(await state.contains(id, in: revokedSet)) else { return notIssued }
        guard request.bodyStrings["step_up_grant"]?.isEmpty == false else {
            return .error(status: 403, code: "step_up_required", message: "step-up required")
        }
        let generation = await state.contains(id, in: rotatedSet) ? "r1" : "r0"
        let token = "demo-\(generation)-\(id.dropFirst(3))-link-not-a-secret"
        return .json(DemoJSON.object([
            "kind": "identity",
            "id": .string(id),
            "slug": .string(slug),
            "token": .string(token),
            "path": .string("/sub/\(slug)/\(token)"),
            "url": .string("\(DemoWorld.baseURL.absoluteString)/sub/\(slug)/\(token)"),
        ]).text)
    }

    private static func revealCredentials(_ request: DemoRequest) -> DemoResponse {
        let id = request.bodyStrings["id"] ?? ""
        guard request.bodyStrings["step_up_grant"]?.isEmpty == false else {
            return .error(status: 403, code: "step_up_required", message: "step-up required")
        }
        guard let user = user(id) else { return .error(status: 404, code: "not_found", message: "vpn user not found") }
        let secrets: [DemoJSON] = user.protocols.enumerated().map { index, proto in
            let usesUUID = ["vless", "vmess", "tuic"].contains(proto)
            return .object([
                "protocol": .string(proto),
                "uuid": usesUUID ? .string(String(format: "00000000-demo-4000-8000-%012d", index + 1)) : nil,
                "password": usesUUID && proto != "tuic" ? nil : .string("demo-\(proto)-password-not-a-secret"),
                "flow": proto == "vless" ? "xtls-rprx-vision" : nil,
            ])
        }
        return .json(DemoJSON.object([
            "ok": true,
            "user": userView(user, usage: false),
            "credentials": .array(secrets),
        ]).text)
    }
}
