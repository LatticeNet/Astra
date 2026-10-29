import Foundation

// M7: agent update policies, releases, artifacts and mirrors (section 8.4),
// with the console's derivations from `agentUpdatesModel.ts`.

/// `model.AgentUpdatePolicy`: one node's update policy.
public struct AgentUpdatesPolicy: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var nodeID: String
    public var enabled: Bool
    public var autoPlan: Bool
    /// A version, or "latest" for the newest stable release.
    public var targetVersion: String
    public var binaryURL: String
    public var sha256: String
    public var installPath: String
    public var serviceName: String
    public var lastPlannedVersion: String
    public var lastPlannedAt: Date?
    public var lastAppliedVersion: String
    public var lastAppliedAt: Date?
    public var lastError: String
    public var lastFetch: AgentUpdatesFetch?
    public var createdAt: Date?
    public var updatedAt: Date?

    public var id: String { nodeID }

    enum CodingKeys: String, CodingKey {
        case enabled, sha256
        case nodeID = "node_id"
        case autoPlan = "auto_plan"
        case targetVersion = "target_version"
        case binaryURL = "binary_url"
        case installPath = "install_path"
        case serviceName = "service_name"
        case lastPlannedVersion = "last_planned_version"
        case lastPlannedAt = "last_planned_at"
        case lastAppliedVersion = "last_applied_version"
        case lastAppliedAt = "last_applied_at"
        case lastError = "last_error"
        case lastFetch = "last_fetch"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        autoPlan = try c.decodeIfPresent(Bool.self, forKey: .autoPlan) ?? false
        targetVersion = try c.decodeIfPresent(String.self, forKey: .targetVersion) ?? ""
        binaryURL = try c.decodeIfPresent(String.self, forKey: .binaryURL) ?? ""
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        installPath = try c.decodeIfPresent(String.self, forKey: .installPath) ?? ""
        serviceName = try c.decodeIfPresent(String.self, forKey: .serviceName) ?? ""
        lastPlannedVersion = try c.decodeIfPresent(String.self, forKey: .lastPlannedVersion) ?? ""
        lastPlannedAt = try DateValue.decodeIfPresent(from: c, forKey: .lastPlannedAt)
        lastAppliedVersion = try c.decodeIfPresent(String.self, forKey: .lastAppliedVersion) ?? ""
        lastAppliedAt = try DateValue.decodeIfPresent(from: c, forKey: .lastAppliedAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError) ?? ""
        lastFetch = try c.decodeIfPresent(AgentUpdatesFetch.self, forKey: .lastFetch)
        createdAt = try DateValue.decodeIfPresent(from: c, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: c, forKey: .updatedAt)
    }

    /// `agentPolicyState`: none (no policy), disabled, auto or manual.
    public var state: AgentUpdatesPolicyState {
        if !enabled { return .disabled }
        return autoPlan ? .auto : .manual
    }

    /// The version a plan would install: "latest" resolves to the release read.
    public func resolvedTarget(latest: String?) -> String {
        let target = targetVersion.isEmpty ? "latest" : targetVersion
        if target.lowercased() == "latest" { return latest.map(AgentUpdatesVersion.normalize) ?? "latest" }
        return AgentUpdatesVersion.normalize(target)
    }
}

public enum AgentUpdatesPolicyState: String, Sendable, Hashable, CaseIterable {
    case none, manual, auto, disabled

    public static func of(_ policy: AgentUpdatesPolicy?) -> AgentUpdatesPolicyState {
        policy?.state ?? .none
    }

    public var word: String {
        switch self {
        case .none: "no policy"
        case .manual: "manual"
        case .auto: "automatic"
        case .disabled: "policy off"
        }
    }
}

/// The parsed "lattice-agent-fetch v1" line a node's update script prints
/// (lattice-sdk `model.AgentUpdateFetch`). From the node: shown, never trusted.
public struct AgentUpdatesFetch: Decodable, Equatable, Hashable, Sendable {
    public var approvalID: String
    public var targetVersion: String
    public var at: Date?
    public var fetches: [AgentUpdatesFetchAttempt]
    public var exitCode: Int
    public var stage: String

    enum CodingKeys: String, CodingKey {
        case at, fetches, stage
        case approvalID = "approval_id"
        case targetVersion = "target_version"
        case exitCode = "exit_code"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        approvalID = try c.decodeIfPresent(String.self, forKey: .approvalID) ?? ""
        targetVersion = try c.decodeIfPresent(String.self, forKey: .targetVersion) ?? ""
        at = try DateValue.decodeIfPresent(from: c, forKey: .at)
        fetches = try c.decodeIfPresent([AgentUpdatesFetchAttempt].self, forKey: .fetches) ?? []
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode) ?? 0
        stage = try c.decodeIfPresent(String.self, forKey: .stage) ?? ""
    }

    /// `fetchReadout` outcome: installed, kept (nothing fetched) or failed.
    public var outcome: AgentUpdatesFetchOutcome {
        guard exitCode == 0, stage == "done" else { return .failed }
        return fetches.isEmpty ? .kept : .installed
    }

    /// Bytes and seconds per source kind, finished sources first.
    public var sources: [AgentUpdatesFetchSource] {
        var order: [String] = []
        var totals: [String: AgentUpdatesFetchSource] = [:]
        for attempt in fetches {
            if totals[attempt.kind] == nil {
                order.append(attempt.kind)
                totals[attempt.kind] = AgentUpdatesFetchSource(kind: attempt.kind)
            }
            totals[attempt.kind]?.add(attempt)
        }
        return order.compactMap { totals[$0] }.enumerated().sorted { lhs, rhs in
            if lhs.element.finished != rhs.element.finished { return lhs.element.finished }
            if lhs.element.bytes != rhs.element.bytes { return lhs.element.bytes > rhs.element.bytes }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

public enum AgentUpdatesFetchOutcome: String, Sendable, Hashable {
    case installed, kept, failed
}

public struct AgentUpdatesFetchAttempt: Decodable, Equatable, Hashable, Sendable {
    public var source: Int?
    public var secondPass: Bool
    /// cp, cp.gz, up, or m.<mirror id>.
    public var kind: String
    public var exitCode: Int
    public var bytes: Int
    public var seconds: Double?
    public var badChunks: Int

    enum CodingKeys: String, CodingKey {
        case source, kind, bytes, seconds
        case secondPass = "second_pass"
        case exitCode = "exit_code"
        case badChunks = "bad_chunks"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(Int.self, forKey: .source)
        secondPass = try c.decodeIfPresent(Bool.self, forKey: .secondPass) ?? false
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode) ?? 0
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds)
        badChunks = try c.decodeIfPresent(Int.self, forKey: .badChunks) ?? 0
    }
}

/// One source's share of a node's last download.
public struct AgentUpdatesFetchSource: Sendable, Hashable {
    public var kind: String
    public var bytes = 0
    public var seconds: Double? = 0
    public var fetches = 0
    public var finished = false
    public var badChunks = 0

    init(kind: String) {
        self.kind = kind
    }

    mutating func add(_ attempt: AgentUpdatesFetchAttempt) {
        bytes += max(0, attempt.bytes)
        fetches += 1
        badChunks += max(0, attempt.badChunks)
        if attempt.exitCode == 0, attempt.badChunks == 0 { finished = true }
        if let s = attempt.seconds, let total = seconds { seconds = total + s } else { seconds = nil }
    }

    /// "control plane", "control plane (gzip)", "upstream" or "mirror r2".
    public var label: String {
        switch kind {
        case "cp": "control plane"
        case "cp.gz": "control plane (gzip)"
        case "up": "upstream"
        default: kind.hasPrefix("m.") && kind.count > 2 ? "mirror \(kind.dropFirst(2))" : kind
        }
    }
}

public struct AgentUpdatesPolicyList: Decodable, Sendable {
    public var policies: [AgentUpdatesPolicy]

    enum CodingKeys: String, CodingKey { case policies }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        policies = try c.decodeIfPresent([AgentUpdatesPolicy].self, forKey: .policies) ?? []
    }
}

/// `agentReleaseInfoView`: the newest stable release and recent candidates.
public struct AgentUpdatesReleaseInfo: Decodable, Equatable, Sendable {
    public var repo: String
    public var channel: String
    public var latestTag: String
    public var latestVersion: String
    public var releaseURL: String
    /// File names from SHA256SUMS, such as "lattice-agent-linux-amd64".
    public var artifacts: [String]
    public var sha256: [String: String]
    public var candidates: [AgentUpdatesReleaseCandidate]
    public var fetchedAt: Date?

    enum CodingKeys: String, CodingKey {
        case repo, channel, artifacts, sha256, candidates
        case latestTag = "latest_tag"
        case latestVersion = "latest_version"
        case releaseURL = "release_url"
        case fetchedAt = "fetched_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        channel = try c.decodeIfPresent(String.self, forKey: .channel) ?? ""
        latestTag = try c.decodeIfPresent(String.self, forKey: .latestTag) ?? ""
        latestVersion = try c.decodeIfPresent(String.self, forKey: .latestVersion) ?? ""
        releaseURL = try c.decodeIfPresent(String.self, forKey: .releaseURL) ?? ""
        artifacts = try c.decodeIfPresent([String].self, forKey: .artifacts) ?? []
        sha256 = try c.decodeIfPresent([String: String].self, forKey: .sha256) ?? [:]
        candidates = try c.decodeIfPresent([AgentUpdatesReleaseCandidate].self, forKey: .candidates) ?? []
        fetchedAt = try DateValue.decodeIfPresent(from: c, forKey: .fetchedAt)
    }
}

public struct AgentUpdatesReleaseCandidate: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var tagName: String
    public var version: String
    /// stable, alpha, beta, rc or prerelease.
    public var channel: String
    public var prerelease: Bool
    public var latestForChannel: Bool
    public var releaseURL: String

    public var id: String { tagName.isEmpty ? version : tagName }

    enum CodingKeys: String, CodingKey {
        case version, channel, prerelease
        case tagName = "tag_name"
        case latestForChannel = "latest_for_channel"
        case releaseURL = "release_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try c.decodeIfPresent(String.self, forKey: .tagName) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        channel = try c.decodeIfPresent(String.self, forKey: .channel) ?? ""
        prerelease = try c.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        latestForChannel = try c.decodeIfPresent(Bool.self, forKey: .latestForChannel) ?? false
        releaseURL = try c.decodeIfPresent(String.self, forKey: .releaseURL) ?? ""
    }
}

/// One agent binary the control plane stores and can serve itself.
public struct AgentUpdatesArtifact: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var version: String
    public var os: String
    public var arch: String
    public var sha256: String
    public var sizeBytes: Int64
    public var storedBytes: Int64
    public var updatedAt: Date?

    public var id: String { "\(version)/\(os)/\(arch)" }
    public var platform: String { "\(os)/\(arch)" }

    enum CodingKeys: String, CodingKey {
        case version, os, arch, sha256
        case sizeBytes = "size_bytes"
        case storedBytes = "stored_bytes"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        os = try c.decodeIfPresent(String.self, forKey: .os) ?? ""
        arch = try c.decodeIfPresent(String.self, forKey: .arch) ?? ""
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
        storedBytes = try c.decodeIfPresent(Int64.self, forKey: .storedBytes) ?? 0
        updatedAt = try DateValue.decodeIfPresent(from: c, forKey: .updatedAt)
    }
}

public struct AgentUpdatesArtifactListing: Decodable, Equatable, Sendable {
    public var artifacts: [AgentUpdatesArtifact]
    public var storedBytes: Int64
    public var limitBytes: Int64
    /// False when the server has no public URL to hand nodes: plans keep
    /// using the release host and the stored binaries sit unused.
    public var servingEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case artifacts
        case storedBytes = "stored_bytes"
        case limitBytes = "limit_bytes"
        case servingEnabled = "serving_enabled"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        artifacts = try c.decodeIfPresent([AgentUpdatesArtifact].self, forKey: .artifacts) ?? []
        storedBytes = try c.decodeIfPresent(Int64.self, forKey: .storedBytes) ?? 0
        limitBytes = try c.decodeIfPresent(Int64.self, forKey: .limitBytes) ?? 0
        servingEnabled = try c.decodeIfPresent(Bool.self, forKey: .servingEnabled) ?? false
    }
}

/// One download mirror registry entry.
public struct AgentUpdatesMirror: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var preferFor: [String]
    public var global: Bool
    public var priority: Int
    public var enabled: Bool
    public var createdAt: Date?
    public var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, global, priority, enabled
        case baseURL = "base_url"
        case preferFor = "prefer_for"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        preferFor = try c.decodeIfPresent([String].self, forKey: .preferFor) ?? []
        global = try c.decodeIfPresent(Bool.self, forKey: .global) ?? false
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        createdAt = try DateValue.decodeIfPresent(from: c, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: c, forKey: .updatedAt)
    }

    public var displayName: String { name.isEmpty ? id : name }
}

/// One node's download order: "mirror:<id>", "control-plane", "upstream".
public struct AgentUpdatesMirrorOrder: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var nodeID: String
    public var name: String
    public var sources: [String]

    public var id: String { nodeID }

    enum CodingKeys: String, CodingKey {
        case name, sources
        case nodeID = "node_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
    }

    /// "r2, control plane, upstream" with mirror names where known.
    public func sentence(mirrorNames: [String: String]) -> String {
        sources.map { label in
            if label == "control-plane" { return "control plane" }
            if label.hasPrefix("mirror:") {
                let id = String(label.dropFirst("mirror:".count))
                return mirrorNames[id] ?? id
            }
            return label
        }.joined(separator: ", ")
    }
}

public struct AgentUpdatesMirrorHealth: Decodable, Equatable, Hashable, Sendable {
    public var mirror: String
    public var fetches: Int
    public var chunkFailures: Int

    enum CodingKeys: String, CodingKey {
        case mirror, fetches
        case chunkFailures = "chunk_failures"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mirror = try c.decodeIfPresent(String.self, forKey: .mirror) ?? ""
        fetches = try c.decodeIfPresent(Int.self, forKey: .fetches) ?? 0
        chunkFailures = try c.decodeIfPresent(Int.self, forKey: .chunkFailures) ?? 0
    }
}

/// `GET /api/nodes/agent-updates/mirrors`.
public struct AgentUpdatesMirrorsView: Decodable, Equatable, Sendable {
    public var mirrors: [AgentUpdatesMirror]
    public var revision: Int
    public var order: [AgentUpdatesMirrorOrder]
    /// Ids of open agent.mirrors approvals.
    public var pending: [String]
    public var health: [AgentUpdatesMirrorHealth]

    enum CodingKeys: String, CodingKey { case mirrors, revision, order, pending, health }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mirrors = try c.decodeIfPresent([AgentUpdatesMirror].self, forKey: .mirrors) ?? []
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        order = try c.decodeIfPresent([AgentUpdatesMirrorOrder].self, forKey: .order) ?? []
        pending = try c.decodeIfPresent([String].self, forKey: .pending) ?? []
        health = try c.decodeIfPresent([AgentUpdatesMirrorHealth].self, forKey: .health) ?? []
    }
}

// MARK: - Versions and standing (`agentUpdatesModel.ts`)

public enum AgentUpdatesVersion {
    /// `normalizeAgentVersion`: trims and drops a leading "v" before a digit.
    public static func normalize(_ version: String?) -> String {
        let trimmed = (version ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, first == "v" || first == "V", trimmed.dropFirst().first?.isNumber == true {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    /// `compareAgentVersion`: numeric core, then a release beats any prerelease.
    public static func compare(_ a: String, _ b: String) -> Int {
        let left = parts(normalize(a))
        let right = parts(normalize(b))
        for index in 0..<max(left.core.count, right.core.count) {
            let diff = (index < left.core.count ? left.core[index] : 0) - (index < right.core.count ? right.core[index] : 0)
            if diff != 0 { return diff < 0 ? -1 : 1 }
        }
        if left.pre == right.pre { return 0 }
        if left.pre.isEmpty { return 1 }
        if right.pre.isEmpty { return -1 }
        switch left.pre.compare(right.pre, options: [.numeric]) {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }

    private static func parts(_ version: String) -> (core: [Int], pre: String) {
        let release = version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let main: Substring
        let pre: String
        if let dash = release.firstIndex(of: "-") {
            main = release[..<dash]
            pre = String(release[release.index(after: dash)...])
        } else {
            main = Substring(release)
            pre = ""
        }
        let core = main.split(separator: ".", omittingEmptySubsequences: false).map { part -> Int in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
        return (core, pre)
    }
}

/// `AgentStanding`: the running version against the latest release.
public enum AgentUpdatesStanding: String, Sendable, Hashable, CaseIterable {
    case behind, current, ahead, unknown

    public static func of(running: String?, latest: String?) -> AgentUpdatesStanding {
        let version = AgentUpdatesVersion.normalize(running)
        let target = AgentUpdatesVersion.normalize(latest)
        guard !version.isEmpty, !target.isEmpty else { return .unknown }
        switch AgentUpdatesVersion.compare(version, target) {
        case 0: return .current
        case ..<0: return .behind
        default: return .ahead
        }
    }
}

/// One row of the Nodes view.
public struct AgentUpdatesNodeRow: Identifiable, Sendable, Hashable {
    public var nodeID: String
    public var name: String
    public var running: String
    public var standing: AgentUpdatesStanding
    public var policy: AgentUpdatesPolicy?
    public var tags: [String]
    public var role: String
    public var honesty: NodeHonesty?

    public var id: String { nodeID }

    public init(node: LatticeNode, policy: AgentUpdatesPolicy?, latest: String?) {
        nodeID = node.id
        name = node.displayName
        running = AgentUpdatesVersion.normalize(node.agentVersion)
        standing = AgentUpdatesStanding.of(running: node.agentVersion, latest: latest)
        self.policy = policy
        tags = node.tags
        role = node.role ?? ""
        honesty = node.honesty
    }

    public var policyState: AgentUpdatesPolicyState { AgentUpdatesPolicyState.of(policy) }
}

/// `bulkPlan`: behind nodes with a policy are planned, behind nodes without
/// one are skipped (a plan needs a policy).
public enum AgentUpdatesBulk {
    public static func plan(_ rows: [AgentUpdatesNodeRow]) -> (plan: [AgentUpdatesNodeRow], skipped: [AgentUpdatesNodeRow]) {
        var plan: [AgentUpdatesNodeRow] = []
        var skipped: [AgentUpdatesNodeRow] = []
        for row in rows where row.standing == .behind {
            if row.policy != nil { plan.append(row) } else { skipped.append(row) }
        }
        return (plan, skipped)
    }

    /// `versionDistribution`: each running version with its count, newest first, unreported last.
    public static func distribution(_ versions: [String?], latest: String?) -> [(version: String, count: Int, standing: AgentUpdatesStanding)] {
        var counts: [String: Int] = [:]
        for raw in versions { counts[AgentUpdatesVersion.normalize(raw), default: 0] += 1 }
        return counts.map { version, count in
            (version, count, version.isEmpty ? .unknown : AgentUpdatesStanding.of(running: version, latest: latest))
        }.sorted { a, b in
            if a.version.isEmpty { return false }
            if b.version.isEmpty { return true }
            return AgentUpdatesVersion.compare(b.version, a.version) < 0
        }
    }
}

/// A release file name read as a platform: "lattice-agent-linux-amd64" is linux/amd64.
public enum AgentUpdatesArtifactName {
    public static func platform(_ fileName: String) -> String? {
        var name = fileName
        for suffix in [".tar.gz", ".tgz", ".zip", ".gz", ".exe"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        guard name.hasPrefix("lattice-agent-") else { return nil }
        let rest = name.dropFirst("lattice-agent-".count).split(separator: "-").map(String.init)
        guard rest.count >= 2 else { return nil }
        return "\(rest[rest.count - 2])/\(rest[rest.count - 1])"
    }
}

/// The Nodes view's query fields (`agentUpdatesQuery.ts`) with the node
/// identity fields a phone needs.
public enum AgentUpdatesQueryFields: QueryFieldProvider {
    public typealias Row = AgentUpdatesNodeRow

    public static var fields: [LatticeQueryField<AgentUpdatesNodeRow>] {
        [
            LatticeQueryField(key: "standing", type: .enumeration, values: AgentUpdatesStanding.allCases.map(\.rawValue), get: { .string($0.standing.rawValue) }),
            LatticeQueryField(key: "policy", type: .enumeration, values: AgentUpdatesPolicyState.allCases.map(\.rawValue),
                              valueAliases: ["off": "disabled", "automatic": "auto"], get: { .string($0.policyState.rawValue) }),
            LatticeQueryField(key: "target", type: .string, get: { row in row.policy.map { .string($0.targetVersion.isEmpty ? "latest" : $0.targetVersion) } ?? .none }),
            LatticeQueryField(key: "planned", aliases: ["last_planned"], type: .time, get: { row in row.policy?.lastPlannedAt.map { .time($0) } ?? .none }),
            LatticeQueryField(key: "behind", type: .bool, flag: true, sortable: false, get: { .bool($0.standing == .behind) }),
            LatticeQueryField(key: "failed", aliases: ["error"], type: .bool, flag: true, sortable: false,
                              get: { .bool(!($0.policy?.lastError.isEmpty ?? true)) }),
            LatticeQueryField(key: "version", aliases: ["agent"], type: .version, get: { $0.running.isEmpty ? .none : .string($0.running) }),
            LatticeQueryField(key: "name", aliases: ["node"], type: .string, get: { .string($0.name) }),
            LatticeQueryField(key: "id", type: .string, get: { .string($0.nodeID) }),
            LatticeQueryField(key: "tag", aliases: ["tags"], type: .list, get: { .strings($0.tags) }),
            LatticeQueryField(key: "role", type: .string, get: { $0.role.isEmpty ? .none : .string($0.role) }),
        ]
    }

    public static func text(_ row: AgentUpdatesNodeRow) -> [String] {
        [row.name, row.nodeID, row.running] + row.tags
    }
}
