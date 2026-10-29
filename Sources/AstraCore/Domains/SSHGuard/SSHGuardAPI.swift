import Foundation

// M7 owns POST sshguard/plan, sshguard/confirm, sshguard/knock and
// sshguard/knock/reveal (section 8.4). Shared owns GET sshguard/status.

/// `GET /api/nodes/capabilities` without `node_id`: every explicit record on
/// a node the caller may read (`node:read`).
struct SSHGuardCapabilityRecordList: Decodable, Sendable {
    var capabilities: [FleetNodeCapabilityRecord]

    enum CodingKeys: String, CodingKey { case capabilities }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capabilities = try c.decodeIfPresent([FleetNodeCapabilityRecord].self, forKey: .capabilities) ?? []
    }
}

public extension LatticeClient {
    /// The explicit sshguard records by node id ("enrolled" or "excluded").
    /// The board reads them because Arm needs an explicit enrolment and the
    /// status row only says whether the gate admits the node.
    func sshGuardCapabilityRecords() async throws -> [String: String] {
        let list = try await perform(SSHGuardCapabilityRecordList.self, path: "/api/nodes/capabilities")
        var records: [String: String] = [:]
        for record in list.capabilities where record.capability == "sshguard" && !record.state.isEmpty {
            records[record.nodeID] = record.state
        }
        return records
    }
}

/// `POST /api/sshguard/plan` (`sshGuardPlanRequest`, server_sshguard.go). Every
/// field but the node is omitted unless set, so the server's verified
/// defaults stand; the arm form and the rotation build it.
public struct SSHGuardPlanRequest: Codable, Equatable, Hashable, Sendable {
    public var nodeID: String
    public var sshPort: Int?
    public var keepLegacyPort: Bool?
    public var mgmtSources: [String]?
    public var enableKnock: Bool?
    public var outOfBandFallback: Bool?
    public var confirmWindowSec: Int?
    public var acceptFindings: Bool?
    public var rotateFromSHA256: String?
    public var previousKnockPorts: [Int]?

    public init(
        nodeID: String,
        sshPort: Int? = nil,
        keepLegacyPort: Bool? = nil,
        mgmtSources: [String]? = nil,
        enableKnock: Bool? = nil,
        outOfBandFallback: Bool? = nil,
        confirmWindowSec: Int? = nil,
        acceptFindings: Bool? = nil,
        rotateFromSHA256: String? = nil,
        previousKnockPorts: [Int]? = nil
    ) {
        self.nodeID = nodeID
        self.sshPort = sshPort
        self.keepLegacyPort = keepLegacyPort
        self.mgmtSources = mgmtSources
        self.enableKnock = enableKnock
        self.outOfBandFallback = outOfBandFallback
        self.confirmWindowSec = confirmWindowSec
        self.acceptFindings = acceptFindings
        self.rotateFromSHA256 = rotateFromSHA256
        self.previousKnockPorts = previousKnockPorts
    }

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case sshPort = "ssh_port"
        case keepLegacyPort = "keep_legacy_port"
        case mgmtSources = "mgmt_sources"
        case enableKnock = "enable_knock"
        case outOfBandFallback = "out_of_band_fallback"
        case confirmWindowSec = "confirm_window_sec"
        case acceptFindings = "accept_findings"
        case rotateFromSHA256 = "rotate_from_sha256"
        case previousKnockPorts = "previous_knock_ports"
    }

    /// The same request with `accept_findings: true`, sent only after the
    /// operator ticked "Accept findings" on the findings step.
    public func accepting(_ accepted: Bool) -> SSHGuardPlanRequest {
        var copy = self
        copy.acceptFindings = accepted ? true : nil
        return copy
    }

    /// True when the request rotates the knock sequence.
    public var isRotation: Bool {
        rotateFromSHA256 != nil || previousKnockPorts != nil
    }
}

/// The arm plan answer: the filed approval and its non-blocking findings.
public struct SSHGuardPlanResponse: Decodable, Equatable, Sendable {
    public var approval: Approval
    public var findings: [PlanFinding]

    enum CodingKeys: String, CodingKey { case approval, findings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        approval = try c.decode(Approval.self, forKey: .approval)
        findings = try c.decodeIfPresent([PlanFinding].self, forKey: .findings) ?? []
    }

    public var filedApprovalIDs: [String] { [approval.id] }
}

/// The confirm answer: `{approval}`.
public struct SSHGuardConfirmResponse: Decodable, Equatable, Sendable {
    public var approval: Approval

    enum CodingKeys: String, CodingKey { case approval }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        approval = try c.decode(Approval.self, forKey: .approval)
    }
}

/// `POST /api/sshguard/knock`: whether the control plane knows this node's
/// knock sequence, without disclosing it. No second factor, works on a token.
public struct SSHGuardKnockState: Decodable, Equatable, Sendable {
    public var nodeID: String
    /// installed, installed_superseded, planned, no_knock or unknown.
    public var knowledge: String
    /// The server's own sentence; shown verbatim.
    public var note: String
    public var revealable: Bool
    public var requiresStepUp: Bool
    public var interactiveOnly: Bool
    /// The arm whose plan installed the sequence (the governing arm).
    public var approvalID: String
    public var appliedAt: Date?
    public var confirmed: Bool?
    public var planUnreadable: String
    public var portCount: Int?
    public var seqTimeoutSec: Int?
    public var openFor: String
    public var sshPort: Int?
    /// Mid-rotation: the previous sequence still opens the node.
    public var previousHonoured: Bool
    /// The node reports the knock table right now; nil from older servers.
    public var gatePresent: Bool?

    enum CodingKeys: String, CodingKey {
        case knowledge, note, revealable, confirmed
        case nodeID = "node_id"
        case requiresStepUp = "requires_step_up"
        case interactiveOnly = "interactive_only"
        case approvalID = "approval_id"
        case appliedAt = "applied_at"
        case planUnreadable = "plan_unreadable"
        case portCount = "port_count"
        case seqTimeoutSec = "seq_timeout_sec"
        case openFor = "open_for"
        case sshPort = "ssh_port"
        case previousHonoured = "previous_honoured"
        case gatePresent = "gate_present"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        knowledge = try c.decodeIfPresent(String.self, forKey: .knowledge) ?? "unknown"
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        revealable = try c.decodeIfPresent(Bool.self, forKey: .revealable) ?? false
        requiresStepUp = try c.decodeIfPresent(Bool.self, forKey: .requiresStepUp) ?? true
        interactiveOnly = try c.decodeIfPresent(Bool.self, forKey: .interactiveOnly) ?? true
        approvalID = try c.decodeIfPresent(String.self, forKey: .approvalID) ?? ""
        appliedAt = try DateValue.decodeIfPresent(from: c, forKey: .appliedAt)
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed)
        planUnreadable = try c.decodeIfPresent(String.self, forKey: .planUnreadable) ?? ""
        portCount = try c.decodeIfPresent(Int.self, forKey: .portCount)
        seqTimeoutSec = try c.decodeIfPresent(Int.self, forKey: .seqTimeoutSec)
        openFor = try c.decodeIfPresent(String.self, forKey: .openFor) ?? ""
        sshPort = try c.decodeIfPresent(Int.self, forKey: .sshPort)
        previousHonoured = try c.decodeIfPresent(Bool.self, forKey: .previousHonoured) ?? false
        gatePresent = try c.decodeIfPresent(Bool.self, forKey: .gatePresent)
    }
}

/// One way to knock and log in, as the plan renders it.
public struct SSHGuardKnockCommand: Decodable, Equatable, Hashable, Sendable {
    public struct Install: Decodable, Equatable, Hashable, Sendable {
        public var platform: String
        public var command: String
    }

    /// "knock" for the packaged client, "bash" for the form that needs nothing installed.
    public var id: String
    public var install: [Install]
    public var command: String

    enum CodingKeys: String, CodingKey { case id, install, command }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        install = try c.decodeIfPresent([Install].self, forKey: .install) ?? []
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
    }
}

/// `POST /api/sshguard/knock/reveal`: the sequence, once, to a person with a
/// fresh step-up. Never stored; only `sequenceSHA256` leaves the reveal step,
/// because a rotation names the installed sequence by it.
public struct SSHGuardKnockReveal: Decodable, Sendable {
    public var nodeID: String
    public var knowledge: String
    public var approvalID: String
    public var ports: [Int]
    public var seqTimeoutSec: Int
    public var openFor: String
    public var sshPort: Int
    public var address: String
    public var commands: [SSHGuardKnockCommand]
    public var note: String
    public var confirmed: Bool
    public var sequenceSHA256: String
    public var previousPorts: [Int]

    enum CodingKeys: String, CodingKey {
        case knowledge, ports, address, commands, note, confirmed
        case nodeID = "node_id"
        case approvalID = "approval_id"
        case seqTimeoutSec = "seq_timeout_sec"
        case openFor = "open_for"
        case sshPort = "ssh_port"
        case sequenceSHA256 = "sequence_sha256"
        case previousPorts = "previous_ports"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        knowledge = try c.decodeIfPresent(String.self, forKey: .knowledge) ?? ""
        approvalID = try c.decodeIfPresent(String.self, forKey: .approvalID) ?? ""
        ports = try c.decodeIfPresent([Int].self, forKey: .ports) ?? []
        seqTimeoutSec = try c.decodeIfPresent(Int.self, forKey: .seqTimeoutSec) ?? 0
        openFor = try c.decodeIfPresent(String.self, forKey: .openFor) ?? ""
        sshPort = try c.decodeIfPresent(Int.self, forKey: .sshPort) ?? 0
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        commands = try c.decodeIfPresent([SSHGuardKnockCommand].self, forKey: .commands) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        sequenceSHA256 = try c.decodeIfPresent(String.self, forKey: .sequenceSHA256) ?? ""
        previousPorts = try c.decodeIfPresent([Int].self, forKey: .previousPorts) ?? []
    }

    /// The value the reveal step shows and copies: the knock command when
    /// the server rendered one, else the ports in order.
    public var shownValue: String {
        let command = commands.first(where: { $0.id == "knock" })?.command ?? commands.first?.command ?? ""
        return command.isEmpty ? ports.map(String.init).joined(separator: " ") : command
    }
}

struct SSHGuardRevealBody: Encodable {
    var nodeID: String
    var stepUpGrant: String

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case stepUpGrant = "step_up_grant"
    }
}

public extension LatticeClient {
    /// Files an arm (or rotation) plan. A 409 with lint findings surfaces as
    /// `LatticeAPIError.conflict(code:message:findings:)`; resend with
    /// `accept_findings` only when the operator accepted them.
    func sshGuardPlan(_ request: SSHGuardPlanRequest) async throws -> SSHGuardPlanResponse {
        try await perform(SSHGuardPlanResponse.self, path: "/api/sshguard/plan", method: "POST", body: request)
    }

    /// Files the confirm plan, whose only effect is to cancel the automatic revert.
    func sshGuardConfirm(nodeID: String) async throws -> SSHGuardConfirmResponse {
        try await perform(SSHGuardConfirmResponse.self, path: "/api/sshguard/confirm", method: "POST", body: NodeIDBody(nodeID: nodeID))
    }

    /// Reads what the control plane knows about the node's knock sequence.
    func sshGuardKnockState(nodeID: String) async throws -> SSHGuardKnockState {
        try await perform(SSHGuardKnockState.self, path: "/api/sshguard/knock", method: "POST", body: NodeIDBody(nodeID: nodeID))
    }

    /// Reveals the knock sequence. Session clients only, with a step-up grant.
    func sshGuardRevealKnock(nodeID: String, grant: StepUpGrant) async throws -> SSHGuardKnockReveal {
        try await perform(
            SSHGuardKnockReveal.self, path: "/api/sshguard/knock/reveal", method: "POST",
            body: SSHGuardRevealBody(nodeID: nodeID, stepUpGrant: grant.grant)
        )
    }
}
