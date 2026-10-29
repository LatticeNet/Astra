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
    /// Human-pending approvals this token can decide now (not stale).
    public var approvalsNeedingYou: Int
    /// Every pending approval visible to this token, the console's
    /// "Approvals waiting"; the count button shows it.
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
        Verdict(sentence: sentence(for: snapshot, now: now, mode: mode, locale: locale), segments: segments(for: snapshot))
    }

    // MARK: Sentence

    private static func sentence(for snapshot: InboxSnapshot, now: Date, mode: TimeZoneMode, locale: Locale) -> String {
        let coverage = InboxSection.allCases.map { (section: $0, coverage: snapshot.coverage[$0] ?? .notLoaded) }
        let readable = coverage.filter { !$0.coverage.isDenied }

        // Rule 2 comes before rule 1 once anything has failed: a failure is
        // known, so the line never waits on the sections still loading.
        let broken = readable.filter(\.coverage.isBroken)
        if !broken.isEmpty {
            return cannotConfirm(snapshot, broken: broken.map(\.section), all: coverage.map(\.coverage), now: now, mode: mode, locale: locale)
        }

        // Rule 1: nothing to vouch for until every readable section has loaded.
        if readable.isEmpty || readable.contains(where: { $0.coverage == .notLoaded }) {
            return "Checking the fleet."
        }

        // Rule 5: denied and partial sections qualify the sentence instead of blocking it.
        let denied = coverage.filter(\.coverage.isDenied).map(\.section.title)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let hidden = coverage.flatMap(\.coverage.hiddenPlugins)
        var qualifiers: [String] = []
        if !denied.isEmpty { qualifiers.append("Not covered: \(denied.joined(separator: ", ")).") }
        if !hidden.isEmpty { qualifiers.append("Hidden from this token: \(listed(hidden)) approvals.") }
        let limited = !denied.isEmpty || snapshot.confinedTo != nil

        var lead: [String] = []
        if snapshot.approvalsNeedingYou > 0 {
            lead.append(needYou(snapshot.approvalsNeedingYou))
        }
        if let worst = worstProblem(snapshot.problems) {
            // Rule 3: something is wrong.
            lead.append(problemSentence(worst, now: now, mode: mode, locale: locale))
        } else if lead.isEmpty {
            // Rule 4: nothing is wrong.
            if limited {
                lead.append("Quiet for what this token can see.")
            } else if let resolved = snapshot.newestResolvedAt {
                lead.append("Quiet since \(since(resolved, now: now, mode: mode, locale: locale)).")
            } else {
                lead.append("Quiet. Nothing needs you.")
            }
        }
        return (lead + qualifiers).joined(separator: " ")
    }

    /// Rule 2: never say quiet when a section failed, went stale or is offline.
    private static func cannotConfirm(_ snapshot: InboxSnapshot, broken: [InboxSection], all: [SectionCoverage], now: Date, mode: TimeZoneMode, locale: Locale) -> String {
        let approvals = snapshot.coverage[.approvals] ?? .notLoaded
        if approvals.isCurrent, snapshot.approvalsNeedingYou > 0 {
            let rest = broken.filter { $0 != .approvals }.map(\.title)
            return "\(needYou(snapshot.approvalsNeedingYou)) Cannot confirm the rest: \(listed(rest)) did not load."
        }
        let offline = all.compactMap { coverage -> Date?? in
            if case .offline(let lastGood) = coverage { return .some(lastGood) }
            return nil
        }
        if !offline.isEmpty {
            if let latest = offline.compactMap({ $0 }).max() {
                return "Cannot confirm. Offline since \(since(latest, now: now, mode: mode, locale: locale))."
            }
            return "Cannot confirm. Offline."
        }
        // The oldest successful refresh among the sections that have one.
        if let oldest = all.compactMap(\.lastGoodAt).min() {
            return "Cannot confirm. Last good refresh \(TimeDisplay.duration(now.timeIntervalSince(oldest), locale: locale)) ago."
        }
        return "Cannot confirm: \(listed(broken.map(\.title))) did not load."
    }

    /// Worst kind first; among equals, the one that has lasted longest.
    private static func worstProblem(_ problems: [VerdictProblem]) -> VerdictProblem? {
        problems.min { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return (lhs.since ?? .distantFuture) < (rhs.since ?? .distantFuture)
        }
    }

    /// The summary as the caller wrote it: a node name keeps its case ("fra-2 offline").
    private static func problemSentence(_ problem: VerdictProblem, now: Date, mode: TimeZoneMode, locale: Locale) -> String {
        guard let since = problem.since else { return "\(problem.summary)." }
        return "\(problem.summary) since \(self.since(since, now: now, mode: mode, locale: locale))."
    }

    private static func needYou(_ count: Int) -> String {
        count == 1 ? "1 needs you." : "\(count) need you."
    }

    /// A clock time today, a date and time otherwise.
    private static func since(_ date: Date, now: Date, mode: TimeZoneMode, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = mode.timeZone
        return calendar.isDate(date, inSameDayAs: now)
            ? TimeDisplay.clock(date, mode: mode, locale: locale)
            : TimeDisplay.dateTime(date, mode: mode, locale: locale)
    }

    /// "incidents", "incidents and tasks", "incidents, tasks and DDNS".
    static func listed(_ words: [String]) -> String {
        switch words.count {
        case 0: ""
        case 1: words[0]
        default: words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1]
        }
    }

    // MARK: Segments

    private static func segments(for snapshot: InboxSnapshot) -> [VerdictSegment] {
        var segments: [VerdictSegment] = []
        if snapshot.coverage[.nodes]?.hasData == true {
            let visible = snapshot.confinedTo == nil ? "" : " visible nodes"
            segments.append(VerdictSegment(
                target: .nodes,
                text: "\(snapshot.onlineCount) of \(snapshot.nodeCount)\(visible) online",
                count: snapshot.nodeCount,
                query: snapshot.onlineCount < snapshot.nodeCount ? "-status:online" : nil
            ))
        }
        if snapshot.coverage[.approvals]?.hasData == true {
            let waiting = max(snapshot.approvalsWaiting, snapshot.approvalsNeedingYou)
            segments.append(VerdictSegment(target: .approvals, text: "\(waiting) waiting", count: waiting))
        }
        if snapshot.coverage[.tasks]?.hasData == true {
            let noun = snapshot.failedTasks == 1 ? "failed task" : "failed tasks"
            segments.append(VerdictSegment(target: .failedTasks, text: "\(snapshot.failedTasks) \(noun)", count: snapshot.failedTasks, query: "status:failed"))
        }
        if snapshot.coverage[.upcoming]?.hasData == true {
            segments.append(VerdictSegment(target: .upcoming, text: "\(snapshot.dueCount) due", count: snapshot.dueCount))
        }
        return segments
    }
}

extension SectionCoverage {
    var isDenied: Bool {
        if case .denied = self { return true }
        return false
    }

    /// Failed, stale or offline: rule 2.
    var isBroken: Bool {
        switch self {
        case .failed, .stale, .offline: true
        default: false
        }
    }

    /// Fresh, or partial (fresh with plugins hidden).
    var isCurrent: Bool {
        switch self {
        case .fresh, .partial: true
        default: false
        }
    }

    /// Something was read at some point, so its counts can be shown.
    var hasData: Bool {
        switch self {
        case .fresh, .partial: true
        case .failed(let lastGood), .stale(let lastGood), .offline(let lastGood): lastGood != nil
        case .notLoaded, .denied: false
        }
    }

    var lastGoodAt: Date? {
        switch self {
        case .fresh(let at), .partial(_, let at): at
        case .failed(let lastGood), .stale(let lastGood), .offline(let lastGood): lastGood
        case .notLoaded, .denied: nil
        }
    }

    var hiddenPlugins: [String] {
        if case .partial(let plugins, _) = self { return plugins }
        return []
    }
}
