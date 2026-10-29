import Foundation

public struct SSHGuardPosture: Codable, Equatable, Hashable, Sendable {
    public var state: String
    public var keyAccess: Bool
    public var keyEvidence: String
    public var reason: String

    public init(state: String = "unknown", keyAccess: Bool = false, keyEvidence: String = "", reason: String = "") {
        self.state = state
        self.keyAccess = keyAccess
        self.keyEvidence = keyEvidence
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case state, reason
        case keyAccess = "key_access"
        case keyEvidence = "key_evidence"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "unknown"
        keyAccess = try c.decodeIfPresent(Bool.self, forKey: .keyAccess) ?? false
        keyEvidence = try c.decodeIfPresent(String.self, forKey: .keyEvidence) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

public struct SSHGuardSSHDFacts: Codable, Equatable, Hashable, Sendable {
    public var passwordAuthentication: Bool
    public var pubkeyAuthentication: Bool
    public var permitRootLogin: String
    public var ports: [Int]
    public var observedAt: Date?

    enum CodingKeys: String, CodingKey {
        case passwordAuthentication = "password_authentication"
        case pubkeyAuthentication = "pubkey_authentication"
        case permitRootLogin = "permit_root_login"
        case ports
        case observedAt = "observed_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        passwordAuthentication = try c.decodeIfPresent(Bool.self, forKey: .passwordAuthentication) ?? false
        pubkeyAuthentication = try c.decodeIfPresent(Bool.self, forKey: .pubkeyAuthentication) ?? false
        permitRootLogin = try c.decodeIfPresent(String.self, forKey: .permitRootLogin) ?? ""
        ports = try c.decodeIfPresent([Int].self, forKey: .ports) ?? []
        observedAt = try DateValue.decodeIfPresent(from: c, forKey: .observedAt)
    }
}

public struct SSHGuardKnockView: Codable, Equatable, Hashable, Sendable {
    public var knowledge: String
    public var revealable: Bool
    public var requiresStepUp: Bool
    public var interactiveOnly: Bool
    public var note: String
    public var approvalID: String
    public var confirmed: Bool?

    enum CodingKeys: String, CodingKey {
        case knowledge, revealable, note, confirmed
        case requiresStepUp = "requires_step_up"
        case interactiveOnly = "interactive_only"
        case approvalID = "approval_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        knowledge = try c.decodeIfPresent(String.self, forKey: .knowledge) ?? ""
        revealable = try c.decodeIfPresent(Bool.self, forKey: .revealable) ?? false
        requiresStepUp = try c.decodeIfPresent(Bool.self, forKey: .requiresStepUp) ?? false
        interactiveOnly = try c.decodeIfPresent(Bool.self, forKey: .interactiveOnly) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        approvalID = try c.decodeIfPresent(String.self, forKey: .approvalID) ?? ""
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed)
    }
}

public struct SSHGuardNodeStatus: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var nodeID: String
    public var nodeName: String
    public var enrolled: Bool
    public var posture: SSHGuardPosture
    public var sshd: SSHGuardSSHDFacts?
    public var sshdNote: String
    public var knockGate: Bool
    public var stage: String
    public var stageIsHistory: Bool
    public var revertArmed: Bool
    public var revertDeadline: Date?
    public var actionableApprovalID: String
    public var knock: SSHGuardKnockView?

    public var id: String { nodeID }

    enum CodingKeys: String, CodingKey {
        case enrolled, posture, sshd, stage, knock
        case nodeID = "node_id"
        case nodeName = "node_name"
        case sshdNote = "sshd_note"
        case knockGate = "knock_gate"
        case stageIsHistory = "stage_is_history"
        case revertArmed = "revert_armed"
        case revertDeadline = "revert_deadline"
        case actionableApprovalID = "actionable_approval_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        nodeName = try c.decodeIfPresent(String.self, forKey: .nodeName) ?? ""
        enrolled = try c.decodeIfPresent(Bool.self, forKey: .enrolled) ?? false
        posture = try c.decodeIfPresent(SSHGuardPosture.self, forKey: .posture) ?? SSHGuardPosture()
        sshd = try c.decodeIfPresent(SSHGuardSSHDFacts.self, forKey: .sshd)
        sshdNote = try c.decodeIfPresent(String.self, forKey: .sshdNote) ?? ""
        knockGate = try c.decodeIfPresent(Bool.self, forKey: .knockGate) ?? false
        stage = try c.decodeIfPresent(String.self, forKey: .stage) ?? ""
        stageIsHistory = try c.decodeIfPresent(Bool.self, forKey: .stageIsHistory) ?? false
        revertArmed = try c.decodeIfPresent(Bool.self, forKey: .revertArmed) ?? false
        revertDeadline = try DateValue.decodeIfPresent(from: c, forKey: .revertDeadline)
        actionableApprovalID = try c.decodeIfPresent(String.self, forKey: .actionableApprovalID) ?? ""
        knock = try c.decodeIfPresent(SSHGuardKnockView.self, forKey: .knock)
    }
}

public struct SSHGuardStatusResponse: Decodable, Sendable {
    public var ok: Bool
    public var node: SSHGuardNodeStatus?
    public var nodes: [SSHGuardNodeStatus]

    enum CodingKeys: String, CodingKey { case ok, node, nodes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        node = try c.decodeIfPresent(SSHGuardNodeStatus.self, forKey: .node)
        nodes = try c.decodeIfPresent([SSHGuardNodeStatus].self, forKey: .nodes) ?? []
    }
}

public extension LatticeClient {
    /// `GET /api/sshguard/status?node_id=` (read posture; knock reveal stays web).
    func fetchSSHGuardStatus(nodeID: String) async throws -> SSHGuardNodeStatus {
        let data = try await performData(
            path: "/api/sshguard/status",
            query: [URLQueryItem(name: "node_id", value: nodeID)]
        )
        let response = try JSONDecoder().decode(SSHGuardStatusResponse.self, from: data)
        if let node = response.node { return node }
        if let node = response.nodes.first(where: { $0.nodeID == nodeID }) { return node }
        throw LatticeAPIError.invalidResponse
    }
}

/// The stage the board shows: the server's `stage`, plus `reverted` once an
/// armed node's revert deadline has passed (`sshGuardBoardModel.ts`).
public enum SSHGuardBoardStage: String, Sendable, Hashable, CaseIterable {
    case idle
    case armPending = "arm_pending"
    case armApproved = "arm_approved"
    case armFailed = "arm_failed"
    case awaitingConfirm = "awaiting_confirm"
    case confirmPending = "confirm_pending"
    case confirmApproved = "confirm_approved"
    case confirmed
    case hardened
    case reverted
    case inForce = "in_force"

    /// Unknown server words read as idle, which is not a healthy state.
    public init(serverValue: String) {
        self = SSHGuardBoardStage(rawValue: serverValue) ?? .idle
    }
}

/// Whether the node is enrolled in SSH Guard by capability.
public enum SSHGuardScopeState: String, Sendable, Hashable, CaseIterable {
    case enrolled, excluded, undecided
}

/// Ports of the console's board derivations over the server's `stage`.
public enum SSHGuardBoard {
    /// `boardStage`: the server stage, or `reverted` when the revert window passed.
    public static func boardStage(_ status: SSHGuardNodeStatus, now: Date) -> SSHGuardBoardStage {
        if revertWindowPassed(status, now: now) { return .reverted }
        return SSHGuardBoardStage(serverValue: status.stage)
    }

    /// `coverageBucket`: the one coverage chip a node counts under. Exclusion
    /// wins only while nothing is live on the box. A stage-only call cannot
    /// know the deadline; use `coverage(for:scope:now:)` for the countdown.
    public static func coverageBucket(_ stage: SSHGuardBoardStage, scope: SSHGuardScopeState, deadline: Date? = nil) -> SSHGuardCoverage {
        switch stage {
        case .confirmed, .hardened, .inForce:
            return .confirmed
        case .idle, .armFailed, .reverted:
            if scope == .excluded { return .excluded }
            return stage == .idle ? .open : .failed
        case .armPending, .armApproved:
            return .armPending
        case .awaitingConfirm, .confirmPending, .confirmApproved:
            return .reverting(deadline: deadline)
        }
    }

    /// The coverage of one status row, with the revert deadline while the timer runs.
    public static func coverage(for status: SSHGuardNodeStatus, scope: SSHGuardScopeState, now: Date) -> SSHGuardCoverage {
        let running = status.revertArmed && !revertWindowPassed(status, now: now)
        return coverageBucket(boardStage(status, now: now), scope: scope, deadline: running ? revertDeadline(status) : nil)
    }

    /// `revertingNodes`: nodes whose revert timer is still running.
    public static func revertingNodes(_ statuses: [SSHGuardNodeStatus], now: Date) -> [SSHGuardNodeStatus] {
        statuses.filter { $0.revertArmed && !revertWindowPassed($0, now: now) }
    }

    /// `revertDeadline`: when the node reverts unless confirmed. The server
    /// sends it as `revert_deadline` while the timer is armed.
    public static func revertDeadline(_ status: SSHGuardNodeStatus) -> Date? {
        status.revertArmed ? status.revertDeadline : nil
    }

    public static func revertWindowPassed(_ status: SSHGuardNodeStatus, now: Date) -> Bool {
        guard let deadline = revertDeadline(status) else { return false }
        return deadline <= now
    }
}

public extension SSHGuardNodeStatus {
    var postureState: SSHGuardPostureState {
        SSHGuardPostureState(serverValue: posture.state)
    }
}

public extension LatticeClient {
    /// `GET /api/sshguard/status`: every node the caller holds `sshguard:read`
    /// and `network:plan` on. Others are skipped silently, with no hidden count.
    func fetchSSHGuardStatus() async throws -> [SSHGuardNodeStatus] {
        try await perform(SSHGuardStatusResponse.self, path: "/api/sshguard/status").nodes
    }
}
