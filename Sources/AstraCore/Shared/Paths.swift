import Foundation

/// The Monitor window shared by every segment (F-20).
public enum MonitorWindow: String, Sendable, Hashable, CaseIterable, Codable {
    case oneHour = "1h"
    case sixHours = "6h"
    case oneDay = "24h"
    case threeDays = "3d"
    case sevenDays = "7d"
    case fourteenDays = "14d"
}

/// The loss arm's evidence: shares 0 to 1, and the probes of the hour.
public struct PathLossEvidence: Codable, Equatable, Hashable, Sendable {
    public var value: Double
    public var baseline: Double
    public var trigger: Double
    public var sent: Int
    public var lost: Int
}

/// The latency arm's evidence: the 15-minute p50 and the successful runs in it.
public struct PathLatencyEvidence: Codable, Equatable, Hashable, Sendable {
    public var p50Ms: Double
    public var runs: Int
    public var baselineMs: Double
    public var triggerMs: Double

    enum CodingKeys: String, CodingKey {
        case runs
        case p50Ms = "p50_ms"
        case baselineMs = "baseline_ms"
        case triggerMs = "trigger_ms"
    }
}

/// Why and since when a path reads degraded; present only while it does.
public struct PathDegradation: Codable, Equatable, Hashable, Sendable {
    public var since: Date?
    public var evaluatedAt: Date?
    public var clearingSince: Date?
    public var loss: PathLossEvidence?
    public var latency: PathLatencyEvidence?

    enum CodingKeys: String, CodingKey {
        case since, loss, latency
        case evaluatedAt = "evaluated_at"
        case clearingSince = "clearing_since"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        since = try DateValue.decodeIfPresent(from: c, forKey: .since)
        evaluatedAt = try DateValue.decodeIfPresent(from: c, forKey: .evaluatedAt)
        clearingSince = try DateValue.decodeIfPresent(from: c, forKey: .clearingSince)
        loss = try c.decodeIfPresent(PathLossEvidence.self, forKey: .loss)
        latency = try c.decodeIfPresent(PathLatencyEvidence.self, forKey: .latency)
    }
}

public struct PathSourceView: Codable, Equatable, Hashable, Sendable {
    public var nodeID: String
    public var name: String
    public var region: String?

    enum CodingKeys: String, CodingKey {
        case name, region
        case nodeID = "node_id"
    }
}

public struct PathTargetView: Codable, Equatable, Hashable, Sendable {
    public var nodeID: String
    public var name: String
    public var region: String?
    public var country: String?

    enum CodingKeys: String, CodingKey {
        case name, region, country
        case nodeID = "node_id"
    }
}

/// The same window one period earlier.
public struct PathPrevious: Codable, Equatable, Hashable, Sendable {
    public var p50Ms: Double?
    public var loss: Double?

    enum CodingKeys: String, CodingKey {
        case loss
        case p50Ms = "p50_ms"
    }
}

/// One path cell of `GET /api/monitors/paths`. Unmeasured figures are nil, so
/// a gap reads apart from a zero.
public struct PathView: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Source node id; empty for a check the control plane runs.
    public var source: String
    /// The node the target was resolved from, when it is one.
    public var targetNode: String
    /// The resolved target as the source dials it.
    public var target: String
    public var monitorID: String
    public var checkDefinitionID: String
    public var method: String
    public var state: String
    public var reason: String
    public var degraded: PathDegradation?
    public var p50Ms: Double?
    public var p95Ms: Double?
    public var jitterMs: Double?
    public var loss: Double?
    public var samples: Int
    public var expected: Int
    public var previous: PathPrevious?
    public var lastAt: Date?
    /// Deprecated by the server (design 32 R1); key a path by its pair instead.
    public var managed: Bool

    enum CodingKeys: String, CodingKey {
        case source, target, method, state, reason, degraded, loss, samples, expected, managed
        case targetNode = "target_node"
        case monitorID = "monitor_id"
        case checkDefinitionID = "check_definition_id"
        case p50Ms = "p50_ms"
        case p95Ms = "p95_ms"
        case jitterMs = "jitter_ms"
        case previous = "prev"
        case lastAt = "last_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        targetNode = try c.decodeIfPresent(String.self, forKey: .targetNode) ?? ""
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        monitorID = try c.decodeIfPresent(String.self, forKey: .monitorID) ?? ""
        checkDefinitionID = try c.decodeIfPresent(String.self, forKey: .checkDefinitionID) ?? ""
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        degraded = try c.decodeIfPresent(PathDegradation.self, forKey: .degraded)
        p50Ms = try c.decodeIfPresent(Double.self, forKey: .p50Ms)
        p95Ms = try c.decodeIfPresent(Double.self, forKey: .p95Ms)
        jitterMs = try c.decodeIfPresent(Double.self, forKey: .jitterMs)
        loss = try c.decodeIfPresent(Double.self, forKey: .loss)
        samples = try c.decodeIfPresent(Int.self, forKey: .samples) ?? 0
        expected = try c.decodeIfPresent(Int.self, forKey: .expected) ?? 0
        previous = try c.decodeIfPresent(PathPrevious.self, forKey: .previous)
        lastAt = try DateValue.decodeIfPresent(from: c, forKey: .lastAt)
        managed = try c.decodeIfPresent(Bool.self, forKey: .managed) ?? false
    }

    /// The path's address: a node pair when the target is a node and the
    /// check is not addressed directly, else the check.
    public var address: PathAddress {
        targetNode.isEmpty
            ? .check(source: source, monitorID: monitorID)
            : .pair(source: source, targetNode: targetNode)
    }

    /// The key the app and the console use for `?path=`: the pair (or the
    /// check), whichever check definition measures it.
    public var key: String { encodePathKey(address) }

    /// Unique in the matrix. The server keeps one cell per check definition,
    /// source and target, so two definitions measuring the same pair share a
    /// key; the console's `${key}#${monitor_id}` tells them apart.
    public var id: String { "\(key)#\(monitorID)" }

    public func displayState(judgesDegraded: Bool) -> PathDisplayState {
        PathDisplayState(state: state, reason: reason, judgesDegraded: judgesDegraded)
    }
}

/// One node whose beacon sources differ from what its applied plan approved
/// (`BeaconReplan`, `monitor_paths.go` `beaconReplans`).
public struct PathBeaconReplan: Decodable, Equatable, Hashable, Sendable {
    public var nodeID: String
    public var name: String
    /// `firewall_pending` when NetGuard manages the node, else `beacon_source_pending`.
    public var reason: String
    /// Sources using the beacon that the applied plan did not approve, as node ids.
    public var added: [String]
    /// Under NetGuard, approved sources that no longer use the beacon.
    public var removed: [String]
    /// An open beacon approval that may already settle the difference.
    public var pendingApprovalID: String
    public var request: BeaconPlanRequest?

    enum CodingKeys: String, CodingKey {
        case name, reason, added, removed, request
        case nodeID = "node_id"
        case pendingApprovalID = "pending_approval_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        added = try c.decodeIfPresent([String].self, forKey: .added) ?? []
        removed = try c.decodeIfPresent([String].self, forKey: .removed) ?? []
        pendingApprovalID = try c.decodeIfPresent(String.self, forKey: .pendingApprovalID) ?? ""
        request = try c.decodeIfPresent(BeaconPlanRequest.self, forKey: .request)
    }
}

/// `GET /api/monitors/paths?window=`.
public struct PathsResponse: Decodable, Equatable, Sendable {
    public var window: String
    public var observedAt: Date?
    public var sources: [PathSourceView]
    public var targets: [PathTargetView]
    public var paths: [PathView]
    /// When the degraded evaluator last ran.
    public var degradedAt: Date?
    /// Nodes whose beacon sources drifted from the applied plan, with the
    /// request that would replan each.
    public var beaconReplans: [PathBeaconReplan]
    /// The key is absent on a server that does not judge degraded; present
    /// (even null) means `degraded` states count.
    public var judgesDegraded: Bool

    enum CodingKeys: String, CodingKey {
        case window, sources, targets, paths
        case observedAt = "observed_at"
        case degradedAt = "degraded_at"
        case beaconReplans = "beacon_replans"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        window = try c.decodeIfPresent(String.self, forKey: .window) ?? ""
        observedAt = try DateValue.decodeIfPresent(from: c, forKey: .observedAt)
        sources = try c.decodeIfPresent([PathSourceView].self, forKey: .sources) ?? []
        targets = try c.decodeIfPresent([PathTargetView].self, forKey: .targets) ?? []
        paths = try c.decodeIfPresent([PathView].self, forKey: .paths) ?? []
        degradedAt = try DateValue.decodeIfPresent(from: c, forKey: .degradedAt)
        judgesDegraded = c.contains(.degradedAt)
        beaconReplans = try c.decodeIfPresent([PathBeaconReplan].self, forKey: .beaconReplans) ?? []
    }

    /// The first path with this `?path=` key, if the response has it.
    public func path(key: String) -> PathView? {
        paths.first { $0.key == key }
    }
}

public extension LatticeClient {
    /// `GET /api/monitors/paths?window=`. A heavy payload; poll at 60 s (6.8).
    func fetchPaths(window: MonitorWindow) async throws -> PathsResponse {
        try await perform(PathsResponse.self, path: "/api/monitors/paths", query: [URLQueryItem(name: "window", value: window.rawValue)])
    }
}
