import Foundation

/// Demo routes for the Networking domain, owned by the Networking module
/// (section 8.6): outbound policy, self-host DNS, DDNS writes, geo routing,
/// tunnels and the inbound firewall, every list in every state its screens
/// show. Session state keys are prefixed `networking.`.
public enum NetworkingFixtures {
    public static var routes: [DemoRoute] {
        policyRoutes + dnsRoutes + ddnsRoutes + geoRoutes + tunnelRoutes + guardRoutes
    }

    static func id(_ name: String) -> String { DemoWorld.node(name).id }

    // MARK: - Outbound policy

    struct Rule {
        var id: String
        var action = "allow"
        var direction = "egress"
        var proto = "tcp"
        var ports: [Int] = []
        var remote: DemoJSON = .object(["kind": "any"])
        var comment = ""
        var disabled = false

        var json: DemoJSON {
            .object([
                "id": .string(id),
                "comment": comment.isEmpty ? nil : .string(comment),
                "action": .string(action),
                "direction": .string(direction),
                "protocol": .string(proto),
                "ports": ports.isEmpty ? nil : .array(ports.map { .number(Double($0)) }),
                "remote": remote,
                "disabled": disabled ? true : nil,
            ])
        }
    }

    static func groupRemote(_ groupID: String) -> DemoJSON { .object(["kind": "group", "group_id": .string(groupID)]) }
    static func cidrRemote(_ cidr: String) -> DemoJSON { .object(["kind": "cidr", "cidr": .string(cidr)]) }
    static func domainRemote(_ domain: String) -> DemoJSON { .object(["kind": "domain", "domain": .string(domain)]) }

    struct GroupPolicy {
        var id: String
        var name: String
        var groups: [String] = []
        var nodes: [String] = []
        var all = false
        var exclude: [String] = []
        var rules: [Rule]
        var enabled = true
        var priority: Int
        var version = 3
        var updated = "-6d"

        /// The node ids the target resolves to now.
        var targetNodeIDs: [String] {
            var ids: [String] = all ? DemoWorld.nodes.map(\.id) : []
            for group in groups { ids += DemoWorld.groups.first { $0.id == group }?.nodeIDs ?? [] }
            ids += nodes.map { NetworkingFixtures.id($0) }
            let excluded = Set(exclude.map { NetworkingFixtures.id($0) })
            var seen = Set<String>()
            return ids.filter { !excluded.contains($0) && seen.insert($0).inserted }
        }

        var label: String {
            if !name.isEmpty { return name }
            if all { return "Whole fleet" }
            if let group = groups.first { return DemoWorld.groups.first { $0.id == group }?.name ?? group }
            return nodes.joined(separator: ", ")
        }
    }

    static let groupPolicies: [GroupPolicy] = [
        GroupPolicy(id: "gnp_d01", name: "Fleet baseline", all: true, exclude: ["lab-pi-1", "lab-pi-2"], rules: [
            Rule(id: "r_001", ports: [80, 443], comment: "package mirrors and the control plane"),
            Rule(id: "r_002", proto: "udp", ports: [123], comment: "time"),
            Rule(id: "r_003", proto: "udp", ports: [53], remote: groupRemote("g-dns"), comment: "resolvers"),
        ], priority: 100, version: 7, updated: "-12d"),
        GroupPolicy(id: "gnp_d02", name: "Asia edge egress", groups: ["g-asia-edge"], rules: [
            Rule(id: "r_001", ports: [443], remote: domainRemote("api.example.org"), comment: "origin API"),
            Rule(id: "r_002", action: "deny", proto: "any", remote: groupRemote("g-home-lab"), comment: "never reach the home lab"),
            Rule(id: "r_003", action: "deny", proto: "any", remote: cidrRemote("10.0.0.0/8")),
        ], priority: 20, updated: "-3d"),
        GroupPolicy(id: "gnp_d03", name: "Europe relay mesh", groups: ["g-europe-relays"], rules: [
            Rule(id: "r_001", ports: [7443], remote: groupRemote("g-asia-edge"), comment: "relay hops to Asia"),
            Rule(id: "r_002", ports: [22], remote: groupRemote("g-europe-relays"), comment: "rsync between relays"),
            Rule(id: "r_003", direction: "ingress", ports: [7443], remote: groupRemote("g-asia-edge")),
        ], priority: 30, updated: "-9d"),
        GroupPolicy(id: "gnp_d04", name: "", nodes: ["build-fra-4"], rules: [
            Rule(id: "r_001", ports: [443], remote: domainRemote("registry.example.org")),
        ], enabled: false, priority: 50, version: 1, updated: "-20d"),
    ]

    static func groupPolicyJSON(_ policy: GroupPolicy, request: DemoRequest) -> DemoJSON {
        let confined = request.scenario == .confinedToken && request.identity == .pat
        let allow = Set(DemoWorld.confinedNodeIDs)
        let targets = policy.targetNodeIDs.filter { !confined || allow.contains($0) }
        let hidden = confined ? (policy.nodes + policy.exclude).map { id($0) }.filter { !allow.contains($0) }.count : 0
        let groupName = policy.groups.count == 1 ? DemoWorld.groups.first { $0.id == policy.groups[0] }?.name : nil
        return .object([
            "id": .string(policy.id),
            "name": policy.name.isEmpty ? nil : .string(policy.name),
            "scope_group_id": .string(policy.groups.count == 1 && policy.nodes.isEmpty && !policy.all ? policy.groups[0] : ""),
            "scope": .object([
                "nodes": policy.nodes.isEmpty ? nil : .strings(policy.nodes.map { id($0) }),
                "groups": policy.groups.isEmpty ? nil : .strings(policy.groups),
                "all": policy.all ? true : nil,
                "exclude": policy.exclude.isEmpty ? nil : .strings(policy.exclude.map { id($0) }),
            ]),
            "rules": .array(policy.rules.map(\.json)),
            "enabled": .bool(policy.enabled),
            "priority": .number(Double(policy.priority)),
            "version": .number(Double(policy.version)),
            "created_at": "{{now-60d}}",
            "updated_at": .time(policy.updated),
            "scope_group_name": groupName.map(DemoJSON.string),
            "group_rule_count": .number(Double(policy.rules.filter { $0.remote.text.contains("\"group\"") }.count)),
            "target": .object([
                "nodes": policy.nodes.isEmpty ? nil : .strings(policy.nodes.map { id($0) }),
                "groups": policy.groups.isEmpty ? nil : .strings(policy.groups),
                "all": policy.all ? true : nil,
                "exclude": policy.exclude.isEmpty ? nil : .strings(policy.exclude.map { id($0) }),
            ]),
            "target_node_ids": .strings(targets),
            "label": .string(policy.label),
            "hidden_target_nodes": hidden > 0 ? .number(Double(hidden)) : nil,
        ])
    }

    /// One node's document as `GET /api/netpolicy` lists it.
    struct NodeDoc {
        var node: String
        var derived: Bool
        var rules: [Rule]
        var enabled = true
        var planned: String? = "-3d"
        var applied: String? = "-3d"
        var error = ""
        var updated = "-3d"
    }

    static let derivedRules = [
        Rule(id: "gnp_d01.r_001", ports: [80, 443]),
        Rule(id: "gnp_d01.r_002", proto: "udp", ports: [123]),
        Rule(id: "gnp_d01.r_003.n-dns-tyo-1", proto: "udp", ports: [53], remote: .object(["kind": "node", "node_id": .string("n-dns-tyo-1")])),
    ]

    static let nodeDocs: [NodeDoc] = [
        NodeDoc(node: "edge-tyo-1", derived: true, rules: derivedRules),
        NodeDoc(node: "edge-tyo-2", derived: true, rules: derivedRules),
        NodeDoc(node: "edge-tyo-3", derived: true, rules: derivedRules),
        NodeDoc(node: "edge-sin-1", derived: true, rules: derivedRules),
        NodeDoc(node: "edge-sin-2", derived: true, rules: derivedRules, applied: "-4d", updated: "-1h"),
        NodeDoc(node: "edge-hkg-2", derived: true, rules: derivedRules, applied: nil,
                error: "nft: table inet lattice_egress: Could not process rule: No such file or directory", updated: "-2h"),
        NodeDoc(node: "relay-fra-1", derived: true, rules: derivedRules, planned: "-9d", applied: "-9d", updated: "-9d"),
        NodeDoc(node: "edge-ams-2", derived: true, rules: derivedRules, planned: "-9d", applied: "-9d", updated: "-9d"),
        NodeDoc(node: "lab-pi-1", derived: true, rules: derivedRules, planned: "-30d", applied: "-30d", updated: "-30d"),
        NodeDoc(node: "core-lon-1", derived: false, rules: [
            Rule(id: "r_001", ports: [5432], remote: .object(["kind": "node", "node_id": .string("n-core-sjc-1")]), comment: "database replica"),
            Rule(id: "r_002", ports: [443]),
            Rule(id: "r_003", action: "deny", proto: "any", remote: cidrRemote("0.0.0.0/0"), comment: "everything else"),
        ], planned: "-40d", applied: "-40d", updated: "-40d"),
        NodeDoc(node: "home-router", derived: false, rules: [
            Rule(id: "r_001", proto: "udp", ports: [51820], comment: "wireguard"),
        ], enabled: false, planned: nil, applied: nil, updated: "-70d"),
    ]

    static func nodeDocJSON(_ doc: NodeDoc, convertedTo policy: String? = nil) -> DemoJSON {
        let node = DemoWorld.node(doc.node)
        let derived = doc.derived || policy != nil
        return .object([
            "id": .string(node.id),
            "target_node_id": .string(node.id),
            "target_node_name": .string(node.name),
            "rules": .array(doc.rules.map(\.json)),
            "enabled": .bool(doc.enabled),
            "group_derived": derived ? true : nil,
            "last_plan_sha": doc.planned == nil ? nil : .string(PlanHasher.sha256Hex(nftPlan(node: node.name))),
            "last_applied_at": doc.applied.map { .time($0) } ?? "0001-01-01T00:00:00Z",
            "last_error": doc.error.isEmpty ? nil : .string(doc.error),
            "updated_at": policy == nil ? .time(doc.updated) : .time(),
        ])
    }

    static func confinedFilter(_ request: DemoRequest, _ nodeID: String) -> Bool {
        guard request.scenario == .confinedToken, request.identity == .pat else { return true }
        return DemoWorld.confinedNodeIDs.contains(nodeID)
    }

    static var policyRoutes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/netpolicy", body: netPolicyBody(request: nil, converted: [:]), emptyBody: #"{"policies":[]}"#) { request, state in
                var converted: [String: String] = [:]
                for node in await state.members(of: "networking.converted") {
                    converted[node] = await state.value(for: "networking.converted.\(node)") ?? ""
                }
                return .json(netPolicyBody(request: request, converted: converted))
            }.requiring("netpolicy:read"),
            DemoRoute(pathPattern: "/api/group-policies", body: groupPoliciesBody(request: DemoRequest(identity: .pat, method: "GET", path: "/api/group-policies"), extra: []), emptyBody: #"{"policies":[]}"#) { request, state in
                let extra = await state.members(of: "networking.converted").sorted().compactMap { node -> GroupPolicy? in
                    guard let world = DemoWorld.node(id: node), let doc = nodeDocs.first(where: { $0.node == world.name }) else { return nil }
                    return GroupPolicy(id: "gnp_conv_\(world.name)", name: "", nodes: [world.name], rules: doc.rules, enabled: doc.enabled, priority: 0, version: 1, updated: "")
                }
                return .json(groupPoliciesBody(request: request, extra: extra))
            }.requiring("netpolicy:read"),
            DemoRoute(pathPattern: "/api/netpolicy/matrix", body: matrixBody(direction: "egress"), emptyBody: #"{"direction":"egress","groups":[],"cells":[],"external":[],"exclusions":[]}"#).requiring("netpolicy:read"),
            DemoRoute(pathPattern: "/api/netpolicy/matrix", query: ["direction": "ingress"], body: matrixBody(direction: "ingress"),
                      emptyBody: #"{"direction":"ingress","groups":[],"cells":[],"external":[],"exclusions":[]}"#).requiring("netpolicy:read"),
            DemoRoute(method: "POST", pathPattern: "/api/group-policies/plan") { request, state in
                await planGroupPolicies(state: state)
            }.requiring("netpolicy:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/netpolicy/plan") { request, state in
                let nodeID = request.bodyStrings["node_id"] ?? request.bodyStrings["target_node_id"] ?? ""
                guard let node = DemoWorld.node(id: nodeID), nodeDocs.contains(where: { $0.node == node.name }) else {
                    return .error(status: 404, code: "not_found", message: "netpolicy not found")
                }
                let approval = await file(plugin: "nftpolicy", action: "apply-ruleset", node: node.name, plan: nftPlan(node: node.name), state: state)
                return .json(SharedFixtures.approvalJSON(approval, includePlan: true).text)
            }.requiring("netpolicy:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/netpolicy/convert") { request, state in
                await convert(request, state: state)
            }.requiring("netpolicy:admin"),
        ]
    }

    static func netPolicyBody(request: DemoRequest?, converted: [String: String]) -> String {
        let docs = nodeDocs.filter { doc in request.map { confinedFilter($0, id(doc.node)) } ?? true }
        return DemoJSON.object([("policies", .array(docs.map { nodeDocJSON($0, convertedTo: converted[id($0.node)]) }))]).text
    }

    static func groupPoliciesBody(request: DemoRequest, extra: [GroupPolicy]) -> String {
        DemoJSON.object([("policies", .array((groupPolicies + extra).map { groupPolicyJSON($0, request: request) }))]).text
    }

    static func matrixGroups() -> DemoJSON {
        .array(DemoWorld.groups.map { group in
            .object(["id": .string(group.id), "name": .string(group.name), "slug": .string(group.id.replacingOccurrences(of: "g-", with: "")), "color": "sky"])
        })
    }

    static func cell(_ from: String, _ to: String, _ action: String, _ protocols: [String], _ ports: [Int], count: Int = 1, mixed: Bool = false) -> DemoJSON {
        .object([
            "from": .string(from),
            "to": .string(to),
            "action": .string(action),
            "protocols": protocols.isEmpty ? nil : .strings(protocols),
            "ports": ports.isEmpty ? nil : .array(ports.map { .number(Double($0)) }),
            "rule_count": .number(Double(count)),
            "mixed": .bool(mixed),
        ])
    }

    static func matrixBody(direction: String) -> String {
        if direction == "ingress" {
            return DemoJSON.object([
                ("direction", "ingress"),
                ("groups", matrixGroups()),
                ("cells", [cell("g-europe-relays", "g-asia-edge", "allow", ["tcp"], [7443])]),
                ("external", []),
                ("exclusions", []),
            ]).text
        }
        let labPi = DemoWorld.node("lab-pi-1")
        let labPi2 = DemoWorld.node("lab-pi-2")
        return DemoJSON.object([
            ("direction", "egress"),
            ("groups", matrixGroups()),
            ("cells", [
                cell("g-asia-edge", "g-home-lab", "deny", ["any"], []),
                cell("g-europe-relays", "g-asia-edge", "allow", ["tcp"], [7443]),
                cell("g-europe-relays", "g-europe-relays", "allow", ["tcp"], [22]),
            ]),
            ("external", [
                .object(["from": "g-asia-edge", "rule_count": 2]),
            ]),
            ("exclusions", []),
            ("fleet", .object([
                "cells": [cell("", "g-dns", "allow", ["udp"], [53])],
                "external": 2,
                "exclusions": [
                    .object([
                        "policy_id": "gnp_d01",
                        "label": "Fleet baseline",
                        "nodes": [
                            .object(["id": .string(labPi.id), "name": .string(labPi.name)]),
                            .object(["id": .string(labPi2.id), "name": .string(labPi2.name)]),
                        ],
                    ]),
                ],
            ])),
        ]).text
    }

    /// Plans every covered node: manual documents conflict, a derived
    /// document whose node no policy covers any more is orphaned.
    static func planGroupPolicies(state: DemoState) async -> DemoResponse {
        let covered = Set(groupPolicies.filter(\.enabled).flatMap(\.targetNodeIDs))
        let converted = await state.members(of: "networking.converted")
        let manual = Set(nodeDocs.filter { !$0.derived && !$0.rules.isEmpty }.map { id($0.node) }).subtracting(converted)
        var affected: [DemoJSON] = []
        var conflicts: [DemoJSON] = []
        for node in DemoWorld.nodes where covered.contains(node.id) {
            if manual.contains(node.id) {
                conflicts.append(.object([
                    "node_id": .string(node.id),
                    "reason": "node has a manually-authored network policy; resolve before applying group policy",
                ]))
                continue
            }
            let plan = nftPlan(node: node.name)
            let approval = await file(plugin: "nftpolicy", action: "apply-ruleset", node: node.name, plan: plan, state: state)
            affected.append(.object(["node_id": .string(node.id), "approval_id": .string(approval.id), "plan_sha": .string(approval.planSHA256)]))
        }
        let orphaned = nodeDocs.filter { $0.derived && !covered.contains(id($0.node)) }.map { id($0.node) }
        let dnsGroup = DemoWorld.groups.first { $0.id == "g-dns" }
        return .json(DemoJSON.object([
            ("affected", .array(affected)),
            ("conflicts", .array(conflicts)),
            ("orphaned", .strings(orphaned)),
            ("selector_impacts", [
                .object([
                    "group_id": "g-dns",
                    "group_name": .string(dnsGroup?.name ?? "DNS nodes"),
                    "uses": ["remote"],
                    "policy_ids": ["gnp_d01"],
                    "selector": .object(["match_roles": ["dns"]]),
                    "explicit_member_ids": [],
                    "selector_member_ids": .strings(dnsGroup?.nodeIDs ?? []),
                    "resolved_member_ids": .strings(dnsGroup?.nodeIDs ?? []),
                ]),
            ]),
        ]).text)
    }

    static func convert(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        let body = request.bodyStrings
        guard let nodeID = body["target_node_id"], let node = DemoWorld.node(id: nodeID),
              let doc = nodeDocs.first(where: { $0.node == node.name }) else {
            return .error(status: 404, code: "not_found", message: "node has no outbound policy to convert")
        }
        let alreadyConverted = await state.contains(nodeID, in: "networking.converted")
        if doc.derived || alreadyConverted {
            return .error(status: 409, code: "conflict", message: "the policy on node \(node.name) is already built from outbound policies; edit those instead")
        }
        let name = body["name"] ?? ""
        await state.insert(nodeID, into: "networking.converted")
        await state.setValue(name, for: "networking.converted.\(nodeID)")
        var policy = GroupPolicy(id: "gnp_conv_\(node.name)", name: name, nodes: [node.name], rules: doc.rules, enabled: doc.enabled,
                                 priority: Int(body["priority"] ?? "") ?? 0, version: 1, updated: "")
        policy.updated = ""
        var approval: DemoJSON = .null
        if doc.enabled {
            let filed = await file(plugin: "nftpolicy", action: "apply-ruleset", node: node.name, plan: nftPlan(node: node.name), state: state)
            approval = SharedFixtures.approvalJSON(filed, includePlan: true)
        }
        return .json(DemoJSON.object([("group_policy", groupPolicyJSON(policy, request: request)), ("approval", approval)]).text)
    }

    /// Records a filed plan the way Shared does, so Review reads it back by id.
    static func file(plugin: String, action: String, node: String, plan: String, state: DemoState) async -> DemoApproval {
        let id = "approval_filed\(await state.recordHit("filed.approval"))"
        let approval = DemoApproval(id: id, plugin: plugin, action: action, node: node, status: "pending",
                                    plan: plan, planSHA256: PlanHasher.sha256Hex(plan), createdAt: "", updatedAt: "")
        await SharedFixtures.recordFiled(approval, state: state)
        return approval
    }

    static func nftPlan(node name: String) -> String {
        """
        # outbound policy for \(name), compiled from Fleet baseline and the policies that target its groups
        table inet lattice_egress {
          chain output {
            type filter hook output priority 0; policy accept;
            ct state established,related accept
            tcp dport { 80, 443 } accept comment "gnp_d01.r_001"
            udp dport 123 accept comment "gnp_d01.r_002"
            ip daddr 203.0.113.15 udp dport 53 accept comment "gnp_d01.r_003"
          }
        }
        """
    }

    // MARK: - Self-host DNS

    struct Deployment {
        var id: String
        var name: String
        var node: String
        var engine = "coredns"
        var exposure = "mesh"
        var hostname = ""
        var allowedClients: [String] = []
        var zones: DemoJSON = []
        var listeners: [(String, Int, String)] = []
        var publish = false
        var lastIPv6Override: String?
        var status = "running"
        var applied: String? = "-2d"
        var error = ""
        var publishError = ""
        var published: String? = nil
        var disabled = false
        var drift: DemoJSON?
        var certChecks: [DemoJSON] = []
        var certExpiry: DemoJSON?
    }

    static let forwardZone: DemoJSON = .object(["suffix": ".", "mode": "forward", "upstreams": ["1.1.1.1", "9.9.9.9"]])
    static let internalZone: DemoJSON = .object([
        "suffix": "lattice.internal",
        "mode": "static",
        "records": [
            .object(["name": "grafana", "type": "A", "value": "10.66.0.12", "ttl": 300]),
            .object(["name": "registry", "type": "A", "value": "10.66.0.20"]),
            .object(["name": "nas", "type": "AAAA", "value": "2001:db8:ff::201"]),
        ],
    ])

    static let deployments: [Deployment] = [
        Deployment(id: "dns_d01", name: "mesh resolver tyo", node: "dns-tyo-1", zones: [forwardZone, internalZone]),
        Deployment(id: "dns_d02", name: "public resolver fra", node: "dns-fra-1", exposure: "public", hostname: "dns-fra.example.org",
                   allowedClients: ["198.51.100.0/24", "2001:db8:20::/48"], zones: [forwardZone], publish: true,
                   lastIPv6Override: "2001:db8:20::99", applied: "-6d", published: "-6d"),
        Deployment(id: "dns_d03", name: "doh iad", node: "dns-iad-1", engine: "external", hostname: "doh.example.net",
                   listeners: [("tcp", 53, "systemd-resolve"), ("udp", 53, "systemd-resolve"), ("tcp", 853, "dnsproxy"), ("tcp", 8443, "dnsproxy")],
                   status: "observed", applied: nil,
                   drift: .object([
                       "status": "drift",
                       "findings": ["udp/53 is held by systemd-resolve, not dnsproxy as recorded."],
                       "reality_collected_at": "{{now-14m}}",
                   ]),
                   certChecks: [.object([
                       "monitor_id": "mon_doh_853", "name": "doh iad certificate (doh.example.net:853)", "target": "doh.example.net:853",
                       "threshold_days": 21, "enabled": true, "cert_not_after": "{{now+9d}}", "measured_at": "{{now-2h}}",
                   ])],
                   certExpiry: .object(["not_after": "{{now+9d}}", "source": "measured", "monitor_id": "mon_doh_853"])),
        Deployment(id: "dns_d04", name: "sjc failover", node: "edge-sjc-2", exposure: "public", hostname: "edge-sjc.example.org",
                   allowedClients: ["192.0.2.0/24"], zones: [forwardZone], publish: true, status: "failed", applied: "-25m",
                   error: "coredns: listen tcp 0.0.0.0:53: bind: address already in use",
                   publishError: "cloudflare: HTTP 403: [{\"code\":10000,\"message\":\"Authentication error\"}]", published: "-1d"),
        Deployment(id: "dns_d05", name: "lab resolver", node: "lab-pi-1", zones: [forwardZone], status: "disabled", applied: "-30d", disabled: true),
    ]

    static func deploymentJSON(_ dep: Deployment, published: Bool, measured: Bool) -> DemoJSON {
        let node = DemoWorld.node(dep.node)
        var checks = dep.certChecks
        if measured {
            checks.append(.object([
                "monitor_id": "mon_doh_8443", "name": .string("\(dep.name) certificate (\(dep.hostname):8443)"), "target": .string("\(dep.hostname):8443"),
                "threshold_days": 14, "enabled": true,
            ]))
        }
        let lastV6 = published ? node.ipv6 : (dep.lastIPv6Override ?? node.ipv6)
        return .object([
            "id": .string(dep.id),
            "name": .string(dep.name),
            "node_id": .string(node.id),
            "node_name": .string(node.name),
            "engine": .string(dep.engine),
            "listen_port": dep.engine == "external" ? 0 : 53,
            "enable_udp": .bool(dep.engine != "external"),
            "enable_tcp": .bool(dep.engine != "external"),
            "exposure": .string(dep.exposure),
            "zones": dep.zones,
            "allowed_clients": dep.allowedClients.isEmpty ? nil : .strings(dep.allowedClients),
            "listeners": dep.listeners.isEmpty ? nil : .array(dep.listeners.map { .object(["protocol": .string($0.0), "port": .number(Double($0.1)), "process": .string($0.2)]) }),
            "drift": dep.drift,
            "cert_checks": checks.isEmpty ? nil : .array(checks),
            "cert_expiry": dep.certExpiry,
            "hostname": dep.hostname.isEmpty ? nil : .string(dep.hostname),
            "publish_ipv4": .bool(dep.publish),
            "publish_ipv6": .bool(dep.publish && !node.ipv6.isEmpty),
            "record_ttl": dep.publish ? 120 : nil,
            "has_credential": .bool(dep.publish),
            "status": .string(dep.status),
            "engine_version": dep.engine == "external" ? nil : "1.11.3",
            "last_ipv4": dep.publish ? .string(node.ipv4) : nil,
            "last_ipv6": dep.publish && !lastV6.isEmpty ? .string(lastV6) : nil,
            "last_applied_at": dep.applied.map { .time($0) } ?? "0001-01-01T00:00:00Z",
            "last_error": dep.error.isEmpty ? nil : .string(dep.error),
            "last_published_at": published ? .time() : (dep.published.map { .time($0) } ?? "0001-01-01T00:00:00Z"),
            "last_publish_error": dep.publishError.isEmpty || published ? nil : .string(dep.publishError),
            "disabled": dep.disabled ? true : nil,
            "created_at": "{{now-90d}}",
            "updated_at": "{{now-6d}}",
        ])
    }

    static func deploymentsBody(published: Set<String>, measured: Set<String>, request: DemoRequest?) -> String {
        let rows = deployments.filter { dep in request.map { confinedFilter($0, id(dep.node)) } ?? true }
        return DemoJSON.object([("deployments", .array(rows.map { deploymentJSON($0, published: published.contains($0.id), measured: measured.contains($0.id)) }))]).text
    }

    static var dnsRoutes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/dns/deployments", body: deploymentsBody(published: [], measured: [], request: nil), emptyBody: #"{"deployments":[]}"#) { request, state in
                .json(deploymentsBody(published: await state.members(of: "networking.dns.published"), measured: await state.members(of: "networking.dns.measured"), request: request))
            }.requiring("dns:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/dns/plan") { request, state in
                await planDNS(request, state: state)
            }.requiring("dns:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/dns/publish") { request, state in
                guard let dep = deployments.first(where: { $0.id == request.bodyStrings["id"] }) else {
                    return .error(status: 404, code: "not_found", message: "dns deployment not found")
                }
                if dep.engine == "external" {
                    return .error(status: 400, code: "bad_request", message: "an external DNS engine is observed only: Lattice never plans or publishes it")
                }
                if dep.disabled { return .error(status: 400, code: "bad_request", message: "dns deployment is disabled") }
                await state.insert(dep.id, into: "networking.dns.published")
                let node = DemoWorld.node(dep.node)
                return .json(DemoJSON.object([
                    ("ok", true),
                    ("ipv4", .string(node.ipv4)),
                    ("ipv6", .string(node.ipv6)),
                    ("deployment", deploymentJSON(dep, published: true, measured: false)),
                ]).text)
            }.requiring("dns:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/dns/measure-cert") { request, state in
                if request.scenario == .confinedToken {
                    return .error(status: 403, code: "capability_denied", message: "measuring a certificate creates server-evaluated tls checks, which takes monitor:admin on a token with no node allowlist")
                }
                guard let dep = deployments.first(where: { $0.id == request.bodyStrings["id"] }) else {
                    return .error(status: 404, code: "not_found", message: "dns deployment not found")
                }
                guard dep.engine == "external" else {
                    return .error(status: 400, code: "bad_request", message: "\(dep.name) is a CoreDNS deployment, which serves no DoT or DoH: only an external engine's certificate is measured")
                }
                await state.insert(dep.id, into: "networking.dns.measured")
                return .json(DemoJSON.object([
                    ("deployment", deploymentJSON(dep, published: false, measured: true)),
                    ("created", ["mon_doh_8443"]),
                    ("linked", []),
                ]).text)
            }.requiring("dns:admin"),
        ]
    }

    static func planDNS(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        guard let dep = deployments.first(where: { $0.id == request.bodyStrings["id"] }) else {
            return .error(status: 404, code: "not_found", message: "dns deployment not found")
        }
        if dep.engine == "external" {
            return .error(status: 400, code: "bad_request", message: "an external DNS engine is observed only: Lattice never plans or publishes it")
        }
        let accepted = request.bodyStrings["accept_lockout_risk"] == "1" || request.bodyStrings["accept_lockout_risk"] == "true"
        let blocking: [DemoJSON] = dep.exposure == "public" ? [
            .object([
                "code": "lockout_listener",
                "severity": "block",
                "message": .string("The plan drops inbound tcp/22 on \(dep.node), and the node reports sshd listening there: committing it cuts off SSH."),
            ]),
        ] : []
        let warnings: [DemoJSON] = dep.exposure == "public" ? [
            .object(["code": "public_resolver", "severity": "warn", "message": "The resolver answers on a public address; only the allowed client networks get answers."]),
        ] : []
        if !blocking.isEmpty && !accepted {
            return DemoResponse(status: 409, body: DemoJSON.object([("error", "plan blocked by lint findings"), ("findings", .array(warnings + blocking))]).text)
        }
        let approval = await file(plugin: "selfdns", action: "apply-config", node: dep.node, plan: dnsPlan(dep), state: state)
        return .json(DemoJSON.object([("approval", SharedFixtures.approvalJSON(approval, includePlan: true)), ("findings", .array(warnings + blocking))]).text)
    }

    static func dnsPlan(_ dep: Deployment) -> String {
        """
        # self-host DNS \(dep.name) on \(dep.node)
        # Corefile
        . {
            bind 0.0.0.0
            acl {
        \(dep.allowedClients.map { "        allow net \($0)" }.joined(separator: "\n"))
                block
            }
            forward . 1.1.1.1 9.9.9.9
            cache 300
            errors
        }
        # lattice_guard input chain
        table inet lattice_guard {
          chain input {
            type filter hook input priority 0; policy drop;
            ct state established,related accept
            iifname "lo" accept
            udp dport 53 accept
            tcp dport 53 accept
          }
        }
        """
    }

    // MARK: - DDNS writes

    static var ddnsRoutes: [DemoRoute] {
        [
            DemoRoute(method: "POST", pathPattern: "/api/ddns/run") { request, state in
                guard let profileID = request.bodyStrings["id"], let profile = SharedFixtures.ddnsProfiles.first(where: { $0.text.contains("\"\(profileID)\"") }) else {
                    return .error(status: 404, code: "not_found", message: "ddns profile not found")
                }
                if profileID == "ddns_d02" {
                    return .error(status: 502, code: "upstream_error", message: "cloudflare: HTTP 403: [{\"code\":10000,\"message\":\"Authentication error\"}]")
                }
                await state.insert(profileID, into: "networking.ddns.ran")
                return .json(ranProfile(profile, id: profileID))
            }.requiring("ddns:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/ddns/delete") { request, state in
                guard let profileID = request.bodyStrings["id"] else { return .error(status: 400, code: "bad_request", message: "id is required") }
                await state.insert(profileID, into: "networking.ddns.deleted")
                return .json(#"{"ok":true}"#)
            }.requiring("ddns:admin"),
        ]
    }

    /// The profile after a run: the node's current address, run now, no error.
    static func ranProfile(_ profile: DemoJSON, id: String) -> String {
        guard case .object(var pairs) = profile else { return profile.text }
        let nodeID = pairs.first { $0.0 == "node_id" }.flatMap { if case .string(let value) = $0.1 { value } else { nil } } ?? ""
        let node = DemoWorld.node(id: nodeID)
        pairs.removeAll { $0.0 == "last_error" }
        for index in pairs.indices {
            switch pairs[index].0 {
            case "last_run_at", "updated_at": pairs[index].1 = .time()
            case "last_ipv4": pairs[index].1 = .string(node?.ipv4 ?? "")
            default: break
            }
        }
        return DemoJSON.object(pairs).text
    }

    // MARK: - Geo-Routing

    static let geoRoutings: [DemoJSON] = [
        .object([
            "id": "geo_g01", "name": "dns apex", "hostname": "dns.example.org",
            "node_ids": .strings(["edge-tyo-1", "relay-fra-1", "edge-iad-1", "edge-syd-1"].map { id($0) }),
            "dns_node_ids": .strings(["dns-tyo-1", "dns-fra-1"].map { id($0) }),
            "ttl": 60, "strategy": "geoip", "geoip_db_path": "/var/lib/GeoIP/GeoLite2-City.mmdb",
            "publish_ns": true, "ddns_profile_id": "ddns_d01",
            "last_rendered_sha": .string(PlanHasher.sha256Hex(geoConfig(host: "dns.example.org"))),
            "status": "applied", "last_applied_at": "{{now-5d}}", "last_delegated_at": "{{now-5d}}",
            "created_at": "{{now-80d}}", "updated_at": "{{now-5d}}",
        ]),
        .object([
            "id": "geo_g02", "name": "status mirror", "hostname": "status.example.net",
            "node_ids": .strings(["edge-ams-2", "edge-lon-1"].map { id($0) }),
            "dns_node_ids": .strings(["dns-fra-1"].map { id($0) }),
            "strategy": "all-healthy", "status": "pending",
            "last_applied_at": "0001-01-01T00:00:00Z", "last_delegated_at": "0001-01-01T00:00:00Z",
            "created_at": "{{now-2d}}", "updated_at": "{{now-2d}}",
        ]),
        .object([
            "id": "geo_g03", "name": "cdn edge", "hostname": "cdn.example.org",
            "node_ids": .strings(["edge-sjc-1", "edge-iad-1"].map { id($0) }),
            "dns_node_ids": .strings(["dns-iad-1"].map { id($0) }),
            "ttl": 30, "strategy": "geoip", "status": "failed",
            "last_applied_at": "{{now-12d}}",
            "last_error": "dns-iad-1: geoip database /var/lib/GeoIP/GeoLite2-City.mmdb not found",
            "created_at": "{{now-40d}}", "updated_at": "{{now-1d}}",
        ]),
    ]

    static func geoConfig(host: String) -> String {
        """
        \(host) {
            geoip /var/lib/GeoIP/GeoLite2-City.mmdb
            template IN A {
                match ".*"
                answer "{{ .Name }} 60 IN A {{ geoip_nearest }}"
            }
            log
        }
        """
    }

    static var geoRoutes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/geo-routing", body: geoBody(deleted: []), emptyBody: #"{"geo_routings":[]}"#) { _, state in
                .json(geoBody(deleted: await state.members(of: "networking.geo.deleted")))
            }.requiring("geo:read"),
            DemoRoute(method: "POST", pathPattern: "/api/geo-routing/plan") { request, _ in
                guard let routingID = request.bodyStrings["id"], let routing = geoRoutings.first(where: { $0.text.contains("\"\(routingID)\"") }) else {
                    return .error(status: 404, code: "not_found", message: "geo routing not found")
                }
                let host = routing.text.range(of: #""hostname":"([^"]+)""#, options: .regularExpression).map { String(routing.text[$0].dropFirst(12).dropLast()) } ?? ""
                let config = geoConfig(host: host)
                return .json(DemoJSON.object([
                    ("geo_routing_id", .string(routingID)),
                    ("hostname", .string(host)),
                    ("strategy", routingID == "geo_g02" ? "all-healthy" : "geoip"),
                    ("config", .string(config)),
                    ("sha256", .string(PlanHasher.sha256Hex(config))),
                    ("warnings", routingID == "geo_g03" ? ["dns-iad-1 has no GeoIP database at the configured path; it answers with every healthy node instead."] : []),
                    ("continent_choice", routingID == "geo_g02" ? .object([]) : .object([
                        "AS": .string(id("edge-tyo-1")), "EU": .string(id("relay-fra-1")), "NA": .string(id("edge-iad-1")), "OC": .string(id("edge-syd-1")),
                    ])),
                ]).text)
            }.requiring("geo:read"),
            DemoRoute(method: "POST", pathPattern: "/api/geo-routing/delete") { request, state in
                guard let routingID = request.bodyStrings["id"] else { return .error(status: 400, code: "bad_request", message: "id is required") }
                await state.insert(routingID, into: "networking.geo.deleted")
                return .json(#"{"ok":true}"#)
            }.requiring("geo:admin"),
        ]
    }

    static func geoBody(deleted: Set<String>) -> String {
        DemoJSON.object([("geo_routings", .array(geoRoutings.filter { routing in !deleted.contains { routing.text.contains("\"\($0)\"") } }))]).text
    }

    // MARK: - Tunnels

    static let tunnels: [DemoJSON] = [
        tunnel("tunnel_t01", "grafana", node: "core-lon-1", tunnelID: "6f1c2a90-3d4b-4e8f-9a21-0c7d5e3b8a14", ingress: [
            ("grafana.example.org", "http://localhost:3000", ""),
            ("metrics.example.org", "http://localhost:9090", "/api/.*"),
        ], created: "-50d"),
        tunnel("tunnel_t02", "home nas", node: "home-nas", tunnelID: "0b8e7d61-52c9-4a3f-8e10-7fd2c4a9b356", ingress: [
            ("nas.example.net", "https://localhost:5001", ""),
            ("photos.example.net", "http://localhost:2342", ""),
        ], created: "-120d"),
        tunnel("tunnel_t03", "build cache", node: "build-fra-4", tunnelID: "c3d9a1f4-7e26-4b58-91ad-2e6f0b8c7d45", ingress: [
            ("cache.example.org", "http://localhost:8080", ""),
        ], created: "-6h"),
    ]

    static func tunnel(_ tunnelID: String, _ name: String, node: String, tunnelID cfID: String, ingress: [(String, String, String)], created: String) -> DemoJSON {
        .object([
            "id": .string(tunnelID),
            "name": .string(name),
            "node_id": .string(id(node)),
            "tunnel_id": .string(cfID),
            "credentials_file": .string("/etc/cloudflared/\(cfID).json"),
            "ingress": .array(ingress.map { .object(["hostname": .string($0.0), "service": .string($0.1), "path": $0.2.isEmpty ? nil : .string($0.2)]) }),
            "created_at": .time(created),
            "updated_at": .time(created),
        ])
    }

    static var tunnelRoutes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/tunnels", body: DemoJSON.array(tunnels).text) { request, state in
                let deleted = await state.members(of: "networking.tunnel.deleted")
                let rows = tunnels.filter { tunnel in !deleted.contains { tunnel.text.contains("\"\($0)\"") } }
                    .filter { tunnel in DemoWorld.nodes.contains { node in tunnel.text.contains("\"\(node.id)\"") && confinedFilter(request, node.id) } }
                return .json(DemoJSON.array(rows).text)
            }.requiring("tunnel:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/tunnels/plan") { request, state in
                guard let tunnelID = request.bodyStrings["id"], let tunnel = tunnels.first(where: { $0.text.contains("\"\(tunnelID)\"") }),
                      let node = DemoWorld.nodes.first(where: { tunnel.text.contains("\"\($0.id)\"") }) else {
                    return .error(status: 404, code: "not_found", message: "tunnel profile not found")
                }
                let approval = await file(plugin: "cftunnel", action: "apply-config", node: node.name, plan: tunnelConfig(tunnel), state: state)
                return .json(SharedFixtures.approvalJSON(approval, includePlan: true).text)
            }.requiring("tunnel:admin"),
            DemoRoute(method: "POST", pathPattern: "/api/tunnels/delete") { request, state in
                guard let tunnelID = request.bodyStrings["id"] else { return .error(status: 400, code: "bad_request", message: "id is required") }
                await state.insert(tunnelID, into: "networking.tunnel.deleted")
                return .json(#"{"ok":true}"#)
            }.requiring("tunnel:admin"),
        ]
    }

    static func tunnelConfig(_ tunnel: DemoJSON) -> String {
        guard let profile = try? JSONDecoder().decode(TunnelProfile.self, from: Data(tunnel.text.utf8)) else { return "" }
        let rules = profile.ingress.map { rule in
            "  - hostname: \(rule.hostname)\n" + (rule.path.isEmpty ? "" : "    path: \(rule.path)\n") + "    service: \(rule.service)"
        }.joined(separator: "\n")
        return """
        tunnel: \(profile.tunnelID)
        credentials-file: \(profile.credentialsFile)
        ingress:
        \(rules)
          - service: http_status:404
        """
    }

    // MARK: - Inbound firewall

    static func guardRule(_ ruleID: String, _ proto: String, _ ports: [Int], remote: DemoJSON, comment: String = "") -> DemoJSON {
        .object([
            "id": .string(ruleID),
            "comment": comment.isEmpty ? nil : .string(comment),
            "action": "allow",
            "direction": "ingress",
            "protocol": .string(proto),
            "ports": ports.isEmpty ? nil : .array(ports.map { .object(["from": .number(Double($0)), "to": .number(Double($0))]) }),
            "remote": remote,
        ])
    }

    static func zoneRemote(_ zoneID: String) -> DemoJSON { .object(["kind": "zone", "zone_id": .string(zoneID)]) }

    static func securityGroup(_ groupID: String, _ name: String, _ rules: [DemoJSON], source: String = "stored", node: String? = nil, description: String = "") -> DemoJSON {
        .object([
            "id": .string(groupID),
            "name": .string(name),
            "description": description.isEmpty ? nil : .string(description),
            "rules": .array(rules),
            "version": 4,
            "created_at": "{{now-45d}}",
            "updated_at": "{{now-8d}}",
            "source": .string(source),
            "node_id": node.map { .string(id($0)) },
        ])
    }

    static let sshAdmin = securityGroup("sg_ssh_admin", "SSH from admin", [
        guardRule("r1", "tcp", [22], remote: cidrRemote("198.51.100.0/24"), comment: "office"),
        guardRule("r2", "tcp", [22], remote: zoneRemote("wireguard"), comment: "mesh"),
    ], description: "Operator SSH from the office network and the mesh")
    static let publicWeb = securityGroup("sg_web", "Public web", [
        guardRule("r1", "tcp", [80, 443], remote: .object(["kind": "any"])),
        guardRule("r2", "udp", [443], remote: .object(["kind": "any"]), comment: "HTTP/3"),
    ])
    static let dnsService = securityGroup("sg_dns", "DNS service", [
        guardRule("r1", "udp", [53], remote: zoneRemote("wireguard")),
        guardRule("r2", "tcp", [53], remote: zoneRemote("wireguard")),
        guardRule("r3", "tcp", [853], remote: .object(["kind": "any"]), comment: "DNS over TLS"),
    ])
    static let routerLegacy = securityGroup("legacy:n-home-router", "home-router baseline", [
        guardRule("r1", "tcp", [22], remote: cidrRemote("192.0.2.0/24")),
        guardRule("r2", "udp", [51820], remote: .object(["kind": "any"]), comment: "wireguard"),
    ], source: "legacy", node: "home-router")

    static func zone(_ zoneID: String, _ name: String, builtin: Bool = false, interfaces: [String] = [], cidrs: [String] = []) -> DemoJSON {
        .object([
            "id": .string(zoneID),
            "name": .string(name),
            "builtin": builtin ? true : nil,
            "interfaces": interfaces.isEmpty ? nil : .strings(interfaces),
            "cidrs": cidrs.isEmpty ? nil : .strings(cidrs),
            "created_at": builtin ? "0001-01-01T00:00:00Z" : "{{now-45d}}",
            "updated_at": builtin ? "0001-01-01T00:00:00Z" : "{{now-45d}}",
        ])
    }

    static let zones: [DemoJSON] = [
        zone("office", "office", cidrs: ["198.51.100.0/24", "2001:db8:22::/48"]),
        zone("public", "public", builtin: true),
        zone("loopback", "loopback", builtin: true, interfaces: ["lo"]),
        zone("wireguard", "wireguard", builtin: true),
        zone("tailscale", "tailscale", builtin: true),
    ]

    struct GuardNode {
        var node: String
        var groups: [DemoJSON]
        var derived: [DemoJSON] = []
        var managed = true
        var applied: String? = "-1d"
        var error = ""
        var source = "stored"
    }

    static let guardNodes: [GuardNode] = [
        GuardNode(node: "edge-tyo-1", groups: [sshAdmin, publicWeb]),
        GuardNode(node: "edge-tyo-2", groups: [sshAdmin, publicWeb], applied: nil),
        GuardNode(node: "dns-tyo-1", groups: [sshAdmin], derived: [dnsService]),
        GuardNode(node: "dns-fra-1", groups: [sshAdmin], derived: [dnsService], applied: "-3d", error: "nft: Error: Could not process rule: Device or resource busy"),
        GuardNode(node: "relay-fra-1", groups: [sshAdmin], managed: false, applied: nil),
        GuardNode(node: "home-router", groups: [routerLegacy], managed: false, applied: nil, source: "legacy"),
    ]

    static func guardNodeJSON(_ entry: GuardNode) -> DemoJSON {
        let node = DemoWorld.node(entry.node)
        let groupIDs: [String] = entry.groups.compactMap { group in
            guard case .object(let pairs) = group, case .string(let value)? = pairs.first(where: { $0.0 == "id" })?.1 else { return nil }
            return value
        }
        let derived: [DemoJSON] = entry.derived.map { group in
            guard case .object(var pairs) = group else { return group }
            pairs.append(("via_node_group", .object(["id": "g-dns", "name": "DNS nodes"])))
            if !entry.managed { pairs.append(("inactive", true)) }
            return .object(pairs)
        }
        return .object([
            "node_id": .string(node.id),
            "node_name": .string(node.name),
            "source": .string(entry.source),
            "binding": .object([
                "node_id": .string(node.id),
                "group_ids": .strings(groupIDs),
                "zone_ids": ["office"],
                "managed": .bool(entry.managed),
                "version": 6,
                "last_plan_sha": entry.managed ? .string(PlanHasher.sha256Hex("netguard \(node.name)")) : nil,
                "last_applied_at": entry.applied.map { .time($0) } ?? "0001-01-01T00:00:00Z",
                "last_error": entry.error.isEmpty ? nil : .string(entry.error),
                "applied_table_sha": entry.applied == nil ? nil : .string(PlanHasher.sha256Hex("netguard \(node.name)")),
                "created_at": "{{now-45d}}",
                "updated_at": "{{now-1d}}",
            ]),
            "groups": .array(entry.groups),
            "derived_groups": .array(derived),
            "zones": [zones[0]],
        ])
    }

    static func nodeGroupBindingsBody() -> String {
        func member(_ name: String, active: Bool) -> DemoJSON {
            .object([
                "node_id": .string(id(name)),
                "node_name": .string(name),
                "state": active ? "active" : "inactive",
                "reason": active ? nil : "group binding inactive: node not managed",
            ])
        }
        let asia = DemoWorld.groups.first { $0.id == "g-asia-edge" }?.nodeIDs.compactMap { DemoWorld.node(id: $0)?.name } ?? []
        return DemoJSON.object([
            ("bindings", [
                .object([
                    "group_id": "g-dns", "security_group_ids": ["sg_dns"], "version": 2,
                    "created_at": "{{now-30d}}", "updated_at": "{{now-30d}}", "group_name": "DNS nodes",
                    "members": [member("dns-tyo-1", active: true), member("dns-fra-1", active: true), member("dns-iad-1", active: false)],
                ]),
                .object([
                    "group_id": "g-asia-edge", "security_group_ids": ["sg_web"], "version": 1,
                    "created_at": "{{now-10d}}", "updated_at": "{{now-10d}}", "group_name": "Asia edge",
                    "members": .array(asia.map { member($0, active: ["edge-tyo-1", "edge-tyo-2"].contains($0)) }),
                ]),
            ]),
            ("node_groups", .array(DemoWorld.groups.map { .object(["id": .string($0.id), "name": .string($0.name), "members": .strings($0.nodeIDs)]) })),
        ]).text
    }

    /// Global NetGuard objects need an unconfined credential.
    static func refusedWhenConfined(_ request: DemoRequest) -> DemoResponse? {
        guard request.scenario == .confinedToken, request.identity == .pat else { return nil }
        return .error(status: 403, code: "capability_denied", message: "forbidden")
    }

    static var guardRoutes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/netguard/groups", body: DemoJSON.object([("groups", .array([sshAdmin, publicWeb, dnsService, routerLegacy]))]).text,
                      emptyBody: #"{"groups":[]}"#) { request, _ in
                refusedWhenConfined(request) ?? .json(DemoJSON.object([("groups", .array([sshAdmin, publicWeb, dnsService, routerLegacy]))]).text)
            }.requiring("netguard:read"),
            DemoRoute(pathPattern: "/api/netguard/zones", body: DemoJSON.object([("zones", .array(zones))]).text, emptyBody: #"{"zones":[]}"#) { request, _ in
                refusedWhenConfined(request) ?? .json(DemoJSON.object([("zones", .array(zones))]).text)
            }.requiring("netguard:read"),
            DemoRoute(pathPattern: "/api/netguard/nodes", body: DemoJSON.object([("nodes", .array(guardNodes.map(guardNodeJSON)))]).text, emptyBody: #"{"nodes":[]}"#) { request, _ in
                .json(DemoJSON.object([("nodes", .array(guardNodes.filter { confinedFilter(request, id($0.node)) }.map(guardNodeJSON)))]).text)
            }.requiring("netguard:read"),
            DemoRoute(pathPattern: "/api/netguard/node-group-bindings", body: nodeGroupBindingsBody(), emptyBody: #"{"bindings":[],"node_groups":[]}"#) { request, _ in
                if let refused = refusedWhenConfined(request) { return refused }
                let scopes = DemoTransport.scopes(for: request.identity, scenario: request.scenario)
                guard scopes.allows("group:read") else { return .error(status: 403, code: "forbidden", message: "missing scope group:read") }
                return .json(nodeGroupBindingsBody())
            }.requiring("netguard:read"),
        ]
    }
}
