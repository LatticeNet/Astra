import Foundation

/// Demo routes for the AgentUpdates domain, owned by the AgentUpdates module (section 8.6).
///
/// The latest release is 0.3.10. Behind it: edge-sin-1, edge-sin-2,
/// edge-ams-1 and edge-lon-1 on 0.3.9 and lab-pi-2 on 0.3.7. Shared files a
/// plan for any node with an id nothing can read back, so the behind nodes
/// get their own plan routes (a distinct `bodyMatch`): the three with an open
/// plan answer it, as the server does; edge-lon-1 files `approval_au_<id>`;
/// lab-pi-2's policy is off, which the server refuses.
public enum AgentUpdatesFixtures {
    public static var routes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/nodes/agent-updates", body: policiesBody(scopes: nil), emptyBody: #"{"policies":[]}"#) { request, _ in
                .json(policiesBody(scopes: request.scopes))
            }.requiring("node:read"),
            DemoRoute(pathPattern: "/api/nodes/agent-updates/releases", body: release.text, emptyBody: release.text).requiring("node:read"),
            DemoRoute(pathPattern: "/api/nodes/agent-updates/artifacts", body: artifacts.text,
                      emptyBody: #"{"artifacts":[],"stored_bytes":0,"limit_bytes":536870912,"serving_enabled":true}"#).requiring("node:read"),
            DemoRoute(pathPattern: "/api/nodes/agent-updates/mirrors", body: mirrorsBody(scopes: nil),
                      emptyBody: #"{"mirrors":[],"revision":0,"order":[],"pending":[],"health":[]}"#) { request, _ in
                .json(mirrorsBody(scopes: request.scopes))
            }.requiring("node:read"),
        ] + planRoutes
    }

    public static let latest = "0.3.10"

    // MARK: Policies

    private struct Policy {
        var node: String
        var enabled = true
        var auto = false
        var target = "latest"
        var lastPlanned: String?
        var lastPlannedAt: String?
        var lastApplied: String?
        var lastAppliedAt: String?
        var error: String?
        var fetch: DemoJSON?
    }

    private static let policies: [Policy] = [
        Policy(node: "edge-tyo-1", auto: true, lastPlanned: "0.3.10", lastPlannedAt: "-1d", lastApplied: "0.3.10", lastAppliedAt: "-23h", fetch: fetch(approval: "approval_d0901", sources: [("cp", 0, 11_812_352, 2.4)])),
        Policy(node: "edge-tyo-2", auto: true, lastPlanned: "0.3.10", lastPlannedAt: "-1d", lastApplied: "0.3.10", lastAppliedAt: "-23h"),
        Policy(node: "relay-tyo-1", auto: true, lastPlanned: "0.3.10", lastPlannedAt: "-1d", lastApplied: "0.3.10", lastAppliedAt: "-22h",
               fetch: fetch(approval: "approval_au_relay_tyo_1", sources: [("m.r2-apac", 0, 11_812_352, 1.1)])),
        Policy(node: "edge-sin-1", lastPlanned: "0.3.10", lastPlannedAt: "-2h",
               fetch: fetch(approval: "approval_d0906", sources: [("m.r2-apac", 28, 4_194_304, 30), ("cp", 0, 7_618_048, 6.2)])),
        Policy(node: "edge-sin-2", lastPlanned: "0.3.10", lastPlannedAt: "-2h"),
        Policy(node: "edge-ams-1", lastPlanned: "0.3.10", lastPlannedAt: "-2h"),
        Policy(node: "edge-lon-1", lastPlanned: "0.3.9", lastPlannedAt: "-3d",
               error: "agent update policy changed since this approval was planned; re-plan before approving"),
        Policy(node: "relay-fra-1", auto: true, lastPlanned: "0.3.10", lastPlannedAt: "-1d", lastApplied: "0.3.10", lastAppliedAt: "-1d"),
        Policy(node: "relay-fra-2", lastPlanned: "0.3.10", lastPlannedAt: "-4h", error: "Waiting for relay-fra-2, offline; the update is dispatched when the agent reports again."),
        Policy(node: "core-lon-1", target: "0.3.10", lastPlanned: "0.3.10", lastPlannedAt: "-6d", lastApplied: "0.3.10", lastAppliedAt: "-6d"),
        Policy(node: "home-nas", target: "0.3.10", lastPlanned: "0.3.10", lastPlannedAt: "-5d", lastApplied: "0.3.10", lastAppliedAt: "-5d",
               fetch: fetch(approval: "approval_au_home_nas", sources: [("up", 22, 0, 0.4), ("cp.gz", 0, 4_980_736, 3.0)])),
        Policy(node: "lab-pi-2", enabled: false, target: "0.3.10", lastPlanned: "0.3.10", lastPlannedAt: "-8d",
               error: "the node went offline before the update task reported"),
    ]

    private static func fetch(approval: String, sources: [(kind: String, exit: Int, bytes: Int, seconds: Double)]) -> DemoJSON {
        let attempts: [DemoJSON] = sources.enumerated().map { index, source in
            .object([
                "source": .number(Double(index + 1)),
                "kind": .string(source.kind),
                "exit_code": .number(Double(source.exit)),
                "bytes": .number(Double(source.bytes)),
                "seconds": .number(source.seconds),
            ])
        }
        let failed = sources.allSatisfy { $0.exit != 0 }
        return .object([
            "approval_id": .string(approval),
            "target_version": "0.3.10",
            "at": "{{now-23h}}",
            "fetches": .array(attempts),
            "exit_code": failed ? 22 : 0,
            "stage": failed ? "fetch" : "done",
        ])
    }

    private static func policyJSON(_ policy: Policy) -> DemoJSON {
        let node = DemoWorld.node(policy.node)
        return .object([
            "node_id": .string(node.id),
            "enabled": .bool(policy.enabled),
            "auto_plan": .bool(policy.auto),
            "target_version": .string(policy.target),
            "binary_url": "",
            "sha256": "",
            "install_path": "/usr/local/bin/lattice-agent",
            "service_name": "lattice-agent",
            "last_planned_version": policy.lastPlanned.map(DemoJSON.string),
            "last_planned_at": policy.lastPlannedAt.map { .time($0) },
            "last_applied_version": policy.lastApplied.map(DemoJSON.string),
            "last_applied_at": policy.lastAppliedAt.map { .time($0) },
            "last_error": policy.error.map(DemoJSON.string),
            "last_fetch": policy.fetch,
            "created_at": "{{now-60d}}",
            "updated_at": .time(policy.lastPlannedAt ?? "-30d"),
        ])
    }

    static func policiesBody(scopes: ScopeSet?) -> String {
        let visible = policies.filter { scopes?.allows("node:read", nodeID: DemoWorld.node($0.node).id) ?? true }
        return DemoJSON.object([("policies", .array(visible.map(policyJSON)))]).text
    }

    // MARK: Release, artifacts, mirrors

    static let release: DemoJSON = .object([
        "repo": "LatticeNet/lattice-node-agent",
        "channel": "stable",
        "latest_tag": "v0.3.10",
        "latest_version": "0.3.10",
        "release_url": "https://github.com/LatticeNet/lattice-node-agent/releases/tag/v0.3.10",
        "artifacts": .strings(releaseDigests.map(\.file)),
        "sha256": .object(releaseDigests.map { ($0.file, DemoJSON.string($0.sha)) }),
        "candidates": .array([
            candidate("v0.4.0-alpha.3", "0.4.0-alpha.3", channel: "alpha", prerelease: true, latest: true),
            candidate("v0.4.0-alpha.2", "0.4.0-alpha.2", channel: "alpha", prerelease: true, latest: false),
            candidate("v0.3.10", "0.3.10", channel: "stable", prerelease: false, latest: true),
            candidate("v0.3.9", "0.3.9", channel: "stable", prerelease: false, latest: false),
            candidate("v0.3.8", "0.3.8", channel: "stable", prerelease: false, latest: false),
        ]),
        "fetched_at": "{{now-7m}}",
    ])

    static let releaseDigests: [(file: String, sha: String)] = [
        ("lattice-agent-darwin-arm64", "c1d4e7a0b3f6c9d2e5a8b1c4d7e0f3a6b9c2d5e8f1a4b7c0d3e6f9a2b5c8d1e4"),
        ("lattice-agent-linux-amd64", "9f2c4e6a8b0d2f4a6c8e0b2d4f6a8c0e2b4d6f8a0c2e4b6d8f0a2c4e6b8d0f2a"),
        ("lattice-agent-linux-arm64", "5d0e3b7c9a41f2e8b6c3d9a0f1e2b4c6d8e0a2c4e6f8a0b2d4f6a8c0e2b4d6f8"),
        ("lattice-agent-linux-armv7", "e8b1c4d7e0f3a6b9c2d5e8f1a4b7c0d3e6f9a2b5c8d1e4f7a0b3c6d9e2f5a8b1"),
    ]

    private static func candidate(_ tag: String, _ version: String, channel: String, prerelease: Bool, latest: Bool) -> DemoJSON {
        .object([
            "tag_name": .string(tag),
            "version": .string(version),
            "channel": .string(channel),
            "prerelease": .bool(prerelease),
            "latest_for_channel": .bool(latest),
            "release_url": .string("https://github.com/LatticeNet/lattice-node-agent/releases/tag/\(tag)"),
        ])
    }

    static let artifacts: DemoJSON = .object([
        "artifacts": .array([
            artifact("0.3.10", "linux", "amd64", sha: releaseDigests[1].sha, size: 11_812_352, age: "-6d"),
            artifact("0.3.10", "linux", "arm64", sha: releaseDigests[2].sha, size: 11_010_048, age: "-6d"),
            artifact("0.3.10", "darwin", "arm64", sha: releaseDigests[0].sha, size: 11_403_264, age: "-6d"),
            artifact("0.3.9", "linux", "amd64", sha: "7a3e9c1b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a5c7e9b1d3f5a7c9e1b3d5f7a9c", size: 11_677_184, age: "-30d"),
        ]),
        "stored_bytes": 45_902_848,
        "limit_bytes": 536_870_912,
        "serving_enabled": true,
    ])

    private static func artifact(_ version: String, _ os: String, _ arch: String, sha: String, size: Int, age: String) -> DemoJSON {
        .object([
            "version": .string(version),
            "os": .string(os),
            "arch": .string(arch),
            "sha256": .string(sha),
            "size_bytes": .number(Double(size)),
            "stored_bytes": .number(Double(size)),
            "updated_at": .time(age),
        ])
    }

    private static let mirrorEntries: [DemoJSON] = [
        .object([
            "id": "r2-apac",
            "name": "Object store, Asia Pacific",
            "base_url": "https://agents-apac.example.org/lattice",
            "prefer_for": .strings(["g-asia-edge", DemoWorld.node("relay-tyo-1").id]),
            "global": false,
            "priority": 10,
            "enabled": true,
            "created_at": "{{now-40d}}",
            "updated_at": "{{now-12d}}",
        ]),
        .object([
            "id": "eu-mirror",
            "name": "Frankfurt mirror",
            "base_url": "https://mirror-fra.example.net/agents",
            "global": true,
            "priority": 20,
            "enabled": true,
            "created_at": "{{now-40d}}",
            "updated_at": "{{now-40d}}",
        ]),
        .object([
            "id": "lab-cache",
            "name": "Home lab cache",
            "base_url": "https://cache.example.net/lattice",
            "prefer_for": .strings(["g-home-lab"]),
            "priority": 30,
            "enabled": false,
            "created_at": "{{now-9d}}",
            "updated_at": "{{now-2d}}",
        ]),
    ]

    static func mirrorsBody(scopes: ScopeSet?) -> String {
        let order: [DemoJSON] = DemoWorld.nodes.filter { scopes?.allows("node:read", nodeID: $0.id) ?? true }.map { node in
            var sources: [String] = []
            if node.groupIDs.contains("g-asia-edge") || node.name == "relay-tyo-1" { sources.append("mirror:r2-apac") }
            sources.append("control-plane")
            sources.append("mirror:eu-mirror")
            sources.append("upstream")
            return .object(["node_id": .string(node.id), "name": .string(node.name), "sources": .strings(sources)])
        }
        return DemoJSON.object([
            ("mirrors", .array(mirrorEntries)),
            ("revision", 7),
            ("order", .array(order)),
            ("pending", []),
            ("health", .array([
                .object(["mirror": "r2-apac", "fetches": 6, "chunk_failures": 1]),
                .object(["mirror": "eu-mirror", "fetches": 2, "chunk_failures": 0]),
                .object(["mirror": "lab-cache", "fetches": 0, "chunk_failures": 0]),
            ])),
        ]).text
    }

    // MARK: Plan filing for the behind nodes

    static let existingPlans = ["edge-sin-1": "approval_d1002", "edge-sin-2": "approval_d1003", "edge-ams-1": "approval_d1004"]

    static var planRoutes: [DemoRoute] {
        var routes: [DemoRoute] = existingPlans.sorted { $0.key < $1.key }.map { name, approvalID in
            DemoRoute(method: "POST", pathPattern: "/api/nodes/agent-updates/plan", bodyMatch: ["node_id": DemoWorld.node(name).id]) { request, state in
                guard let approval = SharedFixtures.approvals.first(where: { $0.id == approvalID }) else {
                    return .error(status: 500, code: "internal", message: "missing fixture")
                }
                let current = await SharedFixtures.current(approval, state: state, scenario: request.scenario)
                return .json(SharedFixtures.approvalJSON(current, includePlan: true).text)
            }
        }
        let lon = DemoWorld.node("edge-lon-1")
        routes.append(DemoRoute(method: "POST", pathPattern: "/api/nodes/agent-updates/plan", bodyMatch: ["node_id": lon.id]) { _, state in
            let id = "approval_au_\(lon.id)"
            await state.insert(id, into: "agentupdates.filed")
            await state.setValue(nil, for: "approval.status.\(id)")
            return .json(SharedFixtures.approvalJSON(lonApproval, includePlan: true).text)
        })
        routes.append(DemoRoute(pathPattern: "/api/network/approvals", query: ["id": "approval_au_\(lon.id)"]) { request, state in
            guard await state.contains("approval_au_\(lon.id)", in: "agentupdates.filed") else {
                return .error(status: 404, code: "not_found", message: "approval not found")
            }
            let current = await SharedFixtures.current(lonApproval, state: state, scenario: request.scenario)
            return .json(DemoJSON.object([("approval", SharedFixtures.approvalJSON(current, includePlan: true))]).text)
        })
        routes.append(DemoRoute(method: "POST", pathPattern: "/api/nodes/agent-updates/plan", bodyMatch: ["node_id": DemoWorld.node("lab-pi-2").id]) { _, _ in
            .error(status: 400, code: "bad_request", message: "agent update policy is not enabled for this node")
        })
        return routes
    }

    static var lonApproval: DemoApproval {
        let plan = DemoPlans.agentUpdate(node: "edge-lon-1", arch: "amd64")
        return DemoApproval(id: "approval_au_\(DemoWorld.node("edge-lon-1").id)", plugin: "agentupdate", action: "update-agent", node: "edge-lon-1",
                            status: "pending", plan: plan, planSHA256: PlanHasher.sha256Hex(plan), createdAt: "-1m", updatedAt: "-1m")
    }
}
