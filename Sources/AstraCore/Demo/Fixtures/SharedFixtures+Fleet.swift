import Foundation

// GET /api/nodes and /api/nodes/geo, from `DemoWorld.nodes`.
extension SharedFixtures {
    static var fleetRoutes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/nodes", body: nodesBody(DemoWorld.nodes)) { request, state in
                .json(nodesBody(await currentNodes(request: request, state: state)))
            }.requiring("node:read"),
            DemoRoute(pathPattern: "/api/nodes/geo", body: geoBody(DemoWorld.nodes)) { request, state in
                .json(geoBody(await currentNodes(request: request, state: state)))
            },
        ]
    }

    /// The fleet as this session sees it: every node online in Quiet, and
    /// nodes disabled or enabled earlier in the session changed.
    static func currentNodes(request: DemoRequest, state: DemoState) async -> [DemoWorldNode] {
        let disabled = await state.members(of: "node.disabled")
        let enabled = await state.members(of: "node.enabled")
        return DemoWorld.nodes.map { node in
            var node = node
            if request.scenario == .quiet {
                node.status = "online"
                node.statusReason = ""
                node.statusSince = "-6d"
                node.lastSeen = "-12s"
                if node.agentVersion.isEmpty { node.agentVersion = "0.3.10" }
            }
            if disabled.contains(node.id) {
                node.status = "disabled"
                node.statusReason = "disabled from this iPhone"
                node.statusSince = ""
            } else if enabled.contains(node.id), node.status == "disabled" {
                node.status = "online"
                node.statusReason = ""
                node.lastSeen = "-12s"
            }
            return node
        }
    }

    static func nodesBody(_ nodes: [DemoWorldNode]) -> String {
        DemoJSON.array(nodes.map(nodeJSON)).text
    }

    static func geoBody(_ nodes: [DemoWorldNode]) -> String {
        DemoJSON.array(nodes.map(geoViewJSON)).text
    }

    private static let gib = 1_073_741_824.0

    /// Private-use AS numbers for the invented providers.
    private static let asn: [String: Double] = [
        "Northwind Cloud": 64_501, "Contoso VPS": 64_502, "Fabrikam Hosting": 64_503, "Tailspin Metal": 64_504,
    ]

    /// One `nodeView` (server.go), with the fields the console reads.
    static func nodeJSON(_ node: DemoWorldNode) -> DemoJSON {
        let reporting = node.isReporting
        let memoryTotal = Double(node.memoryGiB) * gib
        let diskTotal = Double(node.diskGiB) * gib
        return .object([
            "id": .string(node.id),
            "name": .string(node.name),
            "comment": node.role == "backup" ? "Cold storage, kept off until restores" : nil,
            "tags": .strings(node.tags),
            "role": .string(node.role),
            "wireguard_ip": "",
            "public_ip": .string(node.ipv4),
            "public_ipv6": node.ipv6.isEmpty ? nil : .string(node.ipv6),
            "internal_ip": node.region == "home" ? .string("10.20.0.\(node.ipv4.split(separator: ".").last ?? "1")") : nil,
            "agent_version": node.agentVersion.isEmpty ? nil : .string(node.agentVersion),
            "online": .bool(reporting),
            "reachability": .string(node.reachability),
            "status": .string(node.status),
            "status_since": node.statusSince.isEmpty ? nil : .time(node.statusSince),
            "status_reason": node.statusReason.isEmpty ? nil : .string(node.statusReason),
            "disabled": node.status == "disabled" ? true : nil,
            "token_last_used_at": node.lastSeen.map { .time($0) },
            "last_seen": node.lastSeen.map { .time($0) },
            "metrics": node.lastSeen == nil ? nil : .object([
                "cpu_percent": .number(node.cpuPercent),
                "load1": .number((node.cpuPercent / 100 * Double(node.cpuCores) * 100).rounded() / 100),
                "load5": .number((node.cpuPercent / 120 * Double(node.cpuCores) * 100).rounded() / 100),
                "load15": .number((node.cpuPercent / 140 * Double(node.cpuCores) * 100).rounded() / 100),
                "memory_total": .number(memoryTotal),
                "memory_used": .number((memoryTotal * node.memoryPercent / 100).rounded()),
                "disk_total": .number(diskTotal),
                "disk_used": .number((diskTotal * node.diskPercent / 100).rounded()),
                "net_rx_bytes": .number(Double(node.cpuCores) * 91_000_000_000),
                "net_tx_bytes": .number(Double(node.cpuCores) * 64_000_000_000),
                "net_rx_speed": .number(reporting ? 1_250_000 : 0),
                "net_tx_speed": .number(reporting ? 830_000 : 0),
                "uptime_seconds": .number(node.uptimeDays * 86_400),
                "collected_at": .time(node.lastSeen ?? "-12s"),
            ]),
            "host_facts": node.lastSeen == nil ? nil : .object([
                "hostname": .string(node.hostname),
                "os": node.platform == "darwin" ? "darwin" : "linux",
                "platform": .string(node.platform),
                "platform_version": .string(node.platformVersion),
                "kernel_version": node.platform == "darwin" ? "24.6.0" : "6.1.0-27",
                "arch": .string(node.arch),
                "cpu_cores": .number(Double(node.cpuCores)),
                "cpu_model": node.arch == "arm64" ? "ARM Cortex-A76" : "AMD EPYC 7B13",
                "memory_total": .number(memoryTotal),
                "swap_total": .number(gib),
                "virtualization": node.region == "home" ? "" : "kvm",
                "boot_time": .time("-\(Int(node.uptimeDays))d"),
            ]),
            // Home lab nodes have no public location: they list under "No location".
            "geo": node.region == "home" ? nil : .object([
                "country": .string(node.country),
                "region": .string(node.region),
                "city": .string(node.city),
                "lat": .number(node.lat),
                "lon": .number(node.lon),
                "provider": .string(node.provider),
                "source": "auto",
            ]),
            "group_ids": .strings(node.groupIDs),
            "created_at": "{{now-90d}}",
        ])
    }

    /// One `NodeGeoView` of `GET /api/nodes/geo`.
    static func geoViewJSON(_ node: DemoWorldNode) -> DemoJSON {
        let located = node.region != "home"
        return .object([
            "id": .string(node.id),
            "name": .string(node.name),
            "tags": .strings(node.tags),
            "role": .string(node.role),
            "online": .bool(node.isReporting),
            "status": .string(node.status),
            "status_since": node.statusSince.isEmpty ? nil : .time(node.statusSince),
            "status_reason": node.statusReason.isEmpty ? nil : .string(node.statusReason),
            "disabled": node.status == "disabled" ? true : nil,
            "public_ip": .string(node.ipv4),
            "public_ipv6": node.ipv6.isEmpty ? nil : .string(node.ipv6),
            "geo": located ? .object([
                "country": .string(node.country),
                "region": .string(node.region),
                "city": .string(node.city),
                "lat": .number(node.lat),
                "lon": .number(node.lon),
                "ip": .string(node.ipv4),
                "asn": .number(asn[node.provider] ?? 64_500),
                "as_org": .string(node.provider),
                "provider": .string(node.provider),
                "source": "auto",
                "updated_at": "{{now-2d}}",
            ]) : nil,
        ])
    }
}
