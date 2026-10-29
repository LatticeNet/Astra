import Foundation

// `GET /api/nodes/beacon?node_id=` (beacon_plan.go `beaconView`, the SDK's
// `BeaconView`). It never carries a key.

/// What a beacon plan sets (`BeaconSettings`).
public struct FleetBeaconSettings: Decodable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var port: Int
    public var bind: String
    public var endpoint: String

    public init(enabled: Bool, port: Int = 0, bind: String = "", endpoint: String = "") {
        self.enabled = enabled
        self.port = port
        self.bind = bind
        self.endpoint = endpoint
    }

    enum CodingKeys: String, CodingKey { case enabled, port, bind, endpoint }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        bind = try c.decodeIfPresent(String.self, forKey: .bind) ?? ""
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
    }
}

/// What the agent reports about its responder (`BeaconFacts`).
public struct FleetBeaconFacts: Decodable, Equatable, Hashable, Sendable {
    public var responder: Bool
    public var refusal: String
    public var state: String
    public var bind: String
    public var port: Int
    public var epoch: Int
    public var sources: Int
    public var lastAuthAt: Date?
    public var error: String

    enum CodingKeys: String, CodingKey {
        case responder, refusal, state, bind, port, epoch, sources, error
        case lastAuthAt = "last_auth_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        responder = try c.decodeIfPresent(Bool.self, forKey: .responder) ?? false
        refusal = try c.decodeIfPresent(String.self, forKey: .refusal) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        bind = try c.decodeIfPresent(String.self, forKey: .bind) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        epoch = try c.decodeIfPresent(Int.self, forKey: .epoch) ?? 0
        sources = try c.decodeIfPresent(Int.self, forKey: .sources) ?? 0
        lastAuthAt = fleetDate(try DateValue.decodeIfPresent(from: c, forKey: .lastAuthAt))
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
    }
}

/// The reachability check one source ran after a plan applied.
public struct FleetBeaconReachability: Decodable, Equatable, Hashable, Sendable {
    /// `pending`, `reachable`, `filtered` or `not_listening`.
    public var state: String
    public var source: String
    public var monitorID: String
    public var checkedAt: Date?

    public init(state: String = "", source: String = "", monitorID: String = "", checkedAt: Date? = nil) {
        self.state = state
        self.source = source
        self.monitorID = monitorID
        self.checkedAt = checkedAt
    }

    enum CodingKeys: String, CodingKey { case state, source, monitorID = "monitor_id", checkedAt = "checked_at" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        monitorID = try c.decodeIfPresent(String.self, forKey: .monitorID) ?? ""
        checkedAt = fleetDate(try DateValue.decodeIfPresent(from: c, forKey: .checkedAt))
    }
}

/// One source of a beacon: approved by the applied plan, using it now, or both.
public struct FleetBeaconSource: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var nodeID: String
    public var name: String
    public var sourceID: Int
    public var approved: Bool
    public var current: Bool
    public var reason: String

    public var id: String { nodeID }
    public var displayName: String { name.isEmpty ? nodeID : name }

    enum CodingKeys: String, CodingKey { case name, approved, current, reason, nodeID = "node_id", sourceID = "source_id" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        sourceID = try c.decodeIfPresent(Int.self, forKey: .sourceID) ?? 0
        approved = try c.decodeIfPresent(Bool.self, forKey: .approved) ?? false
        current = try c.decodeIfPresent(Bool.self, forKey: .current) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

/// Present while the beacon needs a change plan before its sources match.
public struct FleetBeaconReplan: Decodable, Equatable, Sendable {
    public var reason: String
    public var added: [String]
    public var removed: [String]
    public var pendingApprovalID: String
    public var request: BeaconPlanRequest?

    enum CodingKeys: String, CodingKey { case reason, added, removed, request, pendingApprovalID = "pending_approval_id" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        added = try c.decodeIfPresent([String].self, forKey: .added) ?? []
        removed = try c.decodeIfPresent([String].self, forKey: .removed) ?? []
        pendingApprovalID = try c.decodeIfPresent(String.self, forKey: .pendingApprovalID) ?? ""
        request = try c.decodeIfPresent(BeaconPlanRequest.self, forKey: .request)
    }
}

public struct FleetBeaconView: Decodable, Equatable, Sendable {
    public var nodeID: String
    /// `off`, `pending`, `listening`, `refused_by_node`, `not_listening` or `agent_too_old`.
    public var state: String
    /// A path reason code when the state is a problem.
    public var reason: String
    public var applied: FleetBeaconSettings?
    public var appliedApprovalID: String
    public var appliedAt: Date?
    public var epoch: Int
    public var rotatedAt: Date?
    public var lastAuthAt: Date?
    public var agent: FleetBeaconFacts?
    public var reachability: FleetBeaconReachability
    /// `netguard` or `internet`.
    public var exposure: String
    public var firewallPending: Bool
    public var sources: [FleetBeaconSource]
    public var pendingApprovalID: String
    public var suggestedPort: Int
    public var version: Int
    public var replan: FleetBeaconReplan?

    enum CodingKeys: String, CodingKey {
        case state, reason, applied, epoch, agent, reachability, exposure, sources, version, replan
        case nodeID = "node_id", appliedApprovalID = "applied_approval_id", appliedAt = "applied_at"
        case rotatedAt = "rotated_at", lastAuthAt = "last_auth_at", firewallPending = "firewall_pending"
        case pendingApprovalID = "pending_approval_id", suggestedPort = "suggested_port"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "off"
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        applied = try c.decodeIfPresent(FleetBeaconSettings.self, forKey: .applied)
        appliedApprovalID = try c.decodeIfPresent(String.self, forKey: .appliedApprovalID) ?? ""
        appliedAt = fleetDate(try DateValue.decodeIfPresent(from: c, forKey: .appliedAt))
        epoch = try c.decodeIfPresent(Int.self, forKey: .epoch) ?? 0
        rotatedAt = fleetDate(try DateValue.decodeIfPresent(from: c, forKey: .rotatedAt))
        lastAuthAt = fleetDate(try DateValue.decodeIfPresent(from: c, forKey: .lastAuthAt))
        agent = try c.decodeIfPresent(FleetBeaconFacts.self, forKey: .agent)
        reachability = try c.decodeIfPresent(FleetBeaconReachability.self, forKey: .reachability) ?? FleetBeaconReachability()
        exposure = try c.decodeIfPresent(String.self, forKey: .exposure) ?? ""
        firewallPending = try c.decodeIfPresent(Bool.self, forKey: .firewallPending) ?? false
        sources = try c.decodeIfPresent([FleetBeaconSource].self, forKey: .sources) ?? []
        pendingApprovalID = try c.decodeIfPresent(String.self, forKey: .pendingApprovalID) ?? ""
        suggestedPort = try c.decodeIfPresent(Int.self, forKey: .suggestedPort) ?? 0
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        replan = try c.decodeIfPresent(FleetBeaconReplan.self, forKey: .replan)
    }

    /// An applied plan enables the beacon.
    public var isEnabled: Bool { applied?.enabled == true }

    /// A plan on this node carries NetGuard rules, so filing and deciding it
    /// also need netguard:admin (beacon_plan.go).
    public var carriesNetGuard: Bool { exposure == "netguard" || firewallPending }

    /// The plan the Plan beacon action files: enable with the server's
    /// defaults when the beacon is off, otherwise a change that keeps the
    /// current port, bind and endpoint (or the server's own replan request).
    public var planRequest: BeaconPlanRequest {
        guard isEnabled, let applied else {
            return BeaconPlanRequest(nodeID: nodeID, action: .enable)
        }
        if let request = replan?.request, request.action == .change {
            return BeaconPlanRequest(nodeID: nodeID, action: .change, port: request.port, bind: request.bind, endpoint: request.endpoint)
        }
        return BeaconPlanRequest(
            nodeID: nodeID,
            action: .change,
            port: applied.port > 0 ? applied.port : nil,
            bind: applied.bind.isEmpty ? nil : applied.bind,
            endpoint: applied.endpoint.isEmpty ? nil : applied.endpoint
        )
    }

    public var disableRequest: BeaconPlanRequest {
        BeaconPlanRequest(nodeID: nodeID, action: .disable)
    }

    /// The state in words: "listening", "not listening: bind failed".
    public var stateWord: String {
        switch state {
        case "off": "off"
        case "pending": "pending"
        case "listening": "listening"
        case "refused_by_node": "refused by the node"
        case "not_listening": "not listening"
        case "agent_too_old": "agent too old"
        default: state.replacingOccurrences(of: "_", with: " ")
        }
    }
}

public struct FleetBeaconRotateResponse: Decodable, Equatable, Sendable {
    public var nodeID: String
    public var epoch: Int

    enum CodingKeys: String, CodingKey { case epoch, nodeID = "node_id" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        epoch = try c.decodeIfPresent(Int.self, forKey: .epoch) ?? 0
    }
}
