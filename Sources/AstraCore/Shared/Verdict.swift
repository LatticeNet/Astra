import Foundation

/// The Inbox sections the verdict line reasons about (section 4.8).
public enum InboxSection: String, Sendable, Hashable, CaseIterable {
    case approvals, incidents, nodes, tasks, upcoming, sshGuard, ddns

    /// The word used in "Not covered: DDNS, SSH Guard."
    public var title: String {
        switch self {
        case .approvals: "approvals"
        case .incidents: "incidents"
        case .nodes: "nodes"
        case .tasks: "tasks"
        case .upcoming: "renewals"
        case .sshGuard: "SSH Guard"
        case .ddns: "DDNS"
        }
    }
}

/// How much of one section the phone can vouch for.
public enum SectionCoverage: Sendable, Hashable {
    case notLoaded
    case fresh(at: Date)
    case failed(lastGoodAt: Date?)
    case stale(lastGoodAt: Date?)
    case offline(lastGoodAt: Date?)
    case denied(scope: String)
    /// Approvals the server hides from this token, by plugin display name.
    case partial(hiddenPlugins: [String], at: Date)
}

/// The worst problems, in the verdict's order of precedence.
public enum VerdictProblemKind: Int, Sendable, Hashable, Comparable, CaseIterable {
    case criticalIncident
    case sshGuardReverting
    case warningIncident
    case offlineNode
    case degradedPath
    case failedTask

    public static func < (lhs: VerdictProblemKind, rhs: VerdictProblemKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One problem summary: "Path tokyo-1 to fra-2 degraded", since a time.
public struct VerdictProblem: Sendable, Hashable {
    public var kind: VerdictProblemKind
    /// The words before "since": "fra-2 offline", "Path tokyo-1 to fra-2 degraded".
    public var summary: String
    public var since: Date?

    public init(kind: VerdictProblemKind, summary: String, since: Date?) {
        self.kind = kind
        self.summary = summary
        self.since = since
    }
}

/// Plain counts and coverage, never domain models, so the verdict is pure
/// and testable before any module exists.
public struct InboxSnapshot: Sendable, Hashable {
    public var coverage: [InboxSection: SectionCoverage]
    public var approvalsNeedingYou: Int
    public var approvalsWaiting: Int
    public var problems: [VerdictProblem]
    public var nodeCount: Int
    public var onlineCount: Int
    /// Non-nil when a node allowlist confines the token: the visible node count.
    public var confinedTo: Int?
    public var failedTasks: Int
    public var dueCount: Int
    /// The newest incident `resolved_at`, from `?state=resolved&limit=1`.
    public var newestResolvedAt: Date?

    public init(
        coverage: [InboxSection: SectionCoverage] = [:],
        approvalsNeedingYou: Int = 0,
        approvalsWaiting: Int = 0,
        problems: [VerdictProblem] = [],
        nodeCount: Int = 0,
        onlineCount: Int = 0,
        confinedTo: Int? = nil,
        failedTasks: Int = 0,
        dueCount: Int = 0,
        newestResolvedAt: Date? = nil
    ) {
        self.coverage = coverage
        self.approvalsNeedingYou = approvalsNeedingYou
        self.approvalsWaiting = approvalsWaiting
        self.problems = problems
        self.nodeCount = nodeCount
        self.onlineCount = onlineCount
        self.confinedTo = confinedTo
        self.failedTasks = failedTasks
        self.dueCount = dueCount
        self.newestResolvedAt = newestResolvedAt
    }
}

/// A count button beneath the sentence. The app maps `target` to a route.
public struct VerdictSegment: Sendable, Hashable, Identifiable {
    public enum Target: String, Sendable, Hashable {
        /// Fleet > Nodes, with `query` (`status:-online`) when some are not online.
        case nodes
        /// Activity > Approvals.
        case approvals
        /// Activity > Tasks with `status:failed`.
        case failedTasks
        /// Fleet > Machines > Upcoming.
        case upcoming
    }

    public var target: Target
    /// "33 of 35 online", "2 waiting", "1 failed task", "3 due".
    public var text: String
    public var count: Int
    public var query: String?

    public var id: Target { target }

    public init(target: Target, text: String, count: Int, query: String? = nil) {
        self.target = target
        self.text = text
        self.count = count
        self.query = query
    }
}

/// The verdict line: one sentence and its count segments.
public struct Verdict: Sendable, Hashable {
    public var sentence: String
    public var segments: [VerdictSegment]

    public init(sentence: String, segments: [VerdictSegment]) {
        self.sentence = sentence
        self.segments = segments
    }
}

/// Builds the verdict from a snapshot by the rules of section 4.8.
public enum VerdictBuilder {
    public static func verdict(for snapshot: InboxSnapshot, now: Date, mode: TimeZoneMode = .local, locale: Locale = .current) -> Verdict {
        // M0a: implement rules 1 to 5 of section 4.8 and their golden cases
        // (Triage, Operator, confined and failed-section snapshots), plus the segments.
        Verdict(sentence: "Checking the fleet.", segments: [])
    }
}
