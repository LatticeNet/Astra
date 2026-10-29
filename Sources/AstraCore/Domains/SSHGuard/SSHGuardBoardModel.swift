import Foundation

/// One node on the SSH Guard board, with everything a row, a filter, a
/// section and a query read from it. Built from the Shared status row and,
/// when known, the node from `/api/nodes`.
public struct SSHGuardBoardRow: Identifiable, Sendable, Hashable {
    public var status: SSHGuardNodeStatus
    public var name: String
    public var tags: [String]
    public var role: String
    public var region: String
    public var stage: SSHGuardBoardStage
    public var coverage: SSHGuardCoverage
    public var posture: SSHGuardPostureState
    public var scope: SSHGuardScopeState
    public var knock: String

    public var id: String { status.nodeID }

    /// `record` is the node's explicit sshguard capability state ("enrolled",
    /// "excluded"), or nil when it has none or it could not be read.
    public init(status: SSHGuardNodeStatus, node: LatticeNode?, now: Date, record: String? = nil) {
        self.status = status
        name = node?.displayName ?? (status.nodeName.isEmpty ? status.nodeID : status.nodeName)
        tags = node?.tags ?? []
        role = node?.role ?? ""
        region = node?.geo?.region ?? ""
        stage = SSHGuardBoard.boardStage(status, now: now)
        scope = Self.scope(record: record)
        coverage = SSHGuardBoard.coverage(for: status, scope: scope, now: now)
        posture = status.postureState
        knock = status.knock?.knowledge.isEmpty == false ? status.knock!.knowledge : "unknown"
    }

    /// `scopeOf` on the console: scope is an operator's explicit decision.
    /// The status row's `enrolled` is the gate's answer (true for every
    /// undecided node while the gate is off, false for an undecided node once
    /// it is on), so it never stands in for one.
    public static func scope(record: String?) -> SSHGuardScopeState {
        switch record {
        case "enrolled": .enrolled
        case "excluded": .excluded
        default: .undecided
        }
    }

    /// Whether the capability gate lets SSH Guard plan for the node now.
    public var admitted: Bool { status.enrolled }

    public var isReverting: Bool {
        if case .reverting = coverage { return true }
        return false
    }

    /// The revert deadline while the timer runs.
    public var deadline: Date? {
        if case .reverting(let deadline) = coverage { return deadline }
        return nil
    }

    /// The board may offer Arm: nothing live on the box and an explicit
    /// enrolment, as on the console (`isArmable`).
    public var isArmable: Bool {
        scope == .enrolled && admitted && [.idle, .armFailed, .reverted].contains(stage)
    }

    public var sshdPorts: [Int] { status.sshd?.ports ?? [] }
}

/// The board's sections, in the order an operator works them.
public enum SSHGuardBoardSection: String, Sendable, Hashable, CaseIterable, Identifiable {
    case confirmNeeded, passwordOpen, partial, unknown, secured, excluded

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .confirmNeeded: "Confirm needed"
        case .passwordOpen: "Password login open"
        case .partial: "Partial"
        case .unknown: "Not reported"
        case .secured: "Secured"
        case .excluded: "Excluded"
        }
    }

    public static func of(_ row: SSHGuardBoardRow) -> SSHGuardBoardSection {
        if row.isReverting { return .confirmNeeded }
        if row.coverage == .excluded { return .excluded }
        switch row.posture {
        case .passwordOpen: return .passwordOpen
        case .partial: return .partial
        case .unknown: return .unknown
        case .secured: return .secured
        }
    }
}

/// The posture filter of the toolbar menu (section 5.8).
public enum SSHGuardPostureFilter: String, Sendable, Hashable, CaseIterable {
    case all, passwordOpen = "password_open", partial, unknown, secured

    public var title: String {
        switch self {
        case .all: "All"
        case .passwordOpen: "Password login open"
        case .partial: "Partial"
        case .unknown: "Unknown"
        case .secured: "Secured"
        }
    }

    public func matches(_ row: SSHGuardBoardRow) -> Bool {
        self == .all || row.posture.rawValue == rawValue
    }

    public init(title: String) {
        self = Self.allCases.first { $0.title == title } ?? .all
    }
}

/// The coverage filter of the toolbar menu.
public enum SSHGuardCoverageFilter: String, Sendable, Hashable, CaseIterable {
    case all, reverting, armPending, open, failed, confirmed, excluded

    public var title: String {
        switch self {
        case .all: "All"
        case .reverting: "Reverting"
        case .armPending: "Arm pending"
        case .open: "Not armed"
        case .failed: "Failed"
        case .confirmed: "Confirmed"
        case .excluded: "Excluded"
        }
    }

    public func matches(_ row: SSHGuardBoardRow) -> Bool {
        self == .all || row.coverage.filterName == rawValue
    }

    public init(title: String) {
        self = Self.allCases.first { $0.title == title } ?? .all
    }
}

/// What a board row offers on its swipe, and what Confirm does.
public enum SSHGuardBoardAction: Sendable, Hashable {
    /// The revert timer runs: open the confirm approval when there is one, else file it.
    case confirm(SSHGuardConfirmTarget)
    case arm
    case none

    public static func primary(for row: SSHGuardBoardRow) -> SSHGuardBoardAction {
        if row.isReverting { return .confirm(SSHGuardConfirmTarget.of(row.status)) }
        if row.isArmable { return .arm }
        return .none
    }
}

/// Confirm opens the approval the server names instead of filing a
/// duplicate (section 3.2): `actionable_approval_id` on a confirm stage is
/// the confirm plan already waiting.
public enum SSHGuardConfirmTarget: Sendable, Hashable {
    case review(approvalID: String)
    case file

    static let confirmStages: Set<String> = ["confirm_pending", "confirm_approved"]

    public static func of(_ status: SSHGuardNodeStatus) -> SSHGuardConfirmTarget {
        if !status.actionableApprovalID.isEmpty, confirmStages.contains(status.stage) {
            return .review(approvalID: status.actionableApprovalID)
        }
        return .file
    }
}

/// Groups and orders the board: every section in its order, rows within it
/// by urgency (soonest deadline, then stage), then name.
public enum SSHGuardBoardLayout {
    static let stageRank: [SSHGuardBoardStage: Int] = [
        .awaitingConfirm: 0, .confirmPending: 1, .confirmApproved: 2, .armApproved: 3, .armPending: 4,
        .armFailed: 5, .reverted: 6, .idle: 7, .confirmed: 8, .hardened: 9, .inForce: 10,
    ]

    public static func sections(_ rows: [SSHGuardBoardRow]) -> [(section: SSHGuardBoardSection, rows: [SSHGuardBoardRow])] {
        let grouped = Dictionary(grouping: rows, by: SSHGuardBoardSection.of)
        return SSHGuardBoardSection.allCases.compactMap { section in
            guard let members = grouped[section], !members.isEmpty else { return nil }
            return (section, members.sorted(by: areInIncreasingOrder))
        }
    }

    public static func areInIncreasingOrder(_ a: SSHGuardBoardRow, _ b: SSHGuardBoardRow) -> Bool {
        switch (a.deadline, b.deadline) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        let ra = stageRank[a.stage] ?? 99
        let rb = stageRank[b.stage] ?? 99
        if ra != rb { return ra < rb }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// The board's query fields (`sshGuardQuery.ts`) plus the node identity
/// fields a phone needs: name, tag, role and region.
public enum SSHGuardBoardQueryFields: QueryFieldProvider {
    public typealias Row = SSHGuardBoardRow

    public static let postures = ["password_open", "partial", "unknown", "secured"]
    public static let states = ["reverting", "armPending", "failed", "open", "excluded", "confirmed"]
    public static let stages = ["awaitingConfirm", "confirmPending", "confirmApproved", "armApproved", "armPending", "armFailed", "reverted", "idle", "confirmed"]
    public static let knocks = ["installed", "installed_superseded", "planned", "no_knock", "unknown"]

    /// The console's stage names, where hardened and in force read as confirmed.
    public static func consoleStage(_ stage: SSHGuardBoardStage) -> String {
        switch stage {
        case .idle: "idle"
        case .armPending: "armPending"
        case .armApproved: "armApproved"
        case .armFailed: "armFailed"
        case .awaitingConfirm: "awaitingConfirm"
        case .confirmPending: "confirmPending"
        case .confirmApproved: "confirmApproved"
        case .confirmed, .hardened, .inForce: "confirmed"
        case .reverted: "reverted"
        }
    }

    public static var fields: [LatticeQueryField<SSHGuardBoardRow>] {
        [
            LatticeQueryField(key: "posture", type: .enumeration, values: postures,
                              valueAliases: ["password": "password_open", "password-open": "password_open", "secure": "secured", "not_reported": "unknown", "not-reported": "unknown"],
                              get: { .string($0.posture.rawValue) }),
            LatticeQueryField(key: "state", aliases: ["coverage"], type: .enumeration, values: states,
                              valueAliases: ["pending": "armPending", "arm-pending": "armPending", "not-armed": "open", "notarmed": "open"],
                              get: { .string($0.coverage.filterName) }),
            LatticeQueryField(key: "stage", type: .enumeration, values: stages, get: { .string(consoleStage($0.stage)) }),
            LatticeQueryField(key: "scope", type: .enumeration, values: ["enrolled", "undecided", "excluded"], get: { .string($0.scope.rawValue) }),
            LatticeQueryField(key: "port", aliases: ["ports", "sshd"], type: .number,
                              get: { $0.sshdPorts.isEmpty ? .none : .numbers($0.sshdPorts.map(Double.init)) }),
            LatticeQueryField(key: "password", type: .bool, flag: true, sortable: false,
                              get: { row in row.status.sshd.map { .bool($0.passwordAuthentication) } ?? .none }),
            LatticeQueryField(key: "knock", type: .enumeration, values: knocks,
                              valueAliases: ["none": "no_knock", "no-knock": "no_knock", "superseded": "installed_superseded"],
                              get: { .string($0.knock) }),
            LatticeQueryField(key: "observed", aliases: ["snapshot"], type: .time,
                              get: { row in row.status.realityCollectedAt.map { .time($0) } ?? .none }),
            LatticeQueryField(key: "gate", aliases: ["gated"], type: .bool, flag: true, sortable: false, get: { .bool($0.status.knockGate) }),
            LatticeQueryField(key: "reverting", type: .bool, flag: true, sortable: false, get: { .bool($0.isReverting) }),
            LatticeQueryField(key: "armable", type: .bool, flag: true, sortable: false, get: { .bool($0.isArmable) }),
            LatticeQueryField(key: "name", aliases: ["node"], type: .string, get: { .string($0.name) }),
            LatticeQueryField(key: "id", type: .string, get: { .string($0.id) }),
            LatticeQueryField(key: "tag", aliases: ["tags"], type: .list, get: { .strings($0.tags) }),
            LatticeQueryField(key: "role", type: .string, get: { $0.role.isEmpty ? .none : .string($0.role) }),
            LatticeQueryField(key: "region", type: .string, get: { $0.region.isEmpty ? .none : .string($0.region) }),
        ]
    }

    public static func text(_ row: SSHGuardBoardRow) -> [String] {
        [row.name, row.id] + row.tags
    }
}
