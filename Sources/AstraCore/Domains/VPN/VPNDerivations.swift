import Foundation

// Pure derivations ported from the vpn-core console UI
// (lattice-plugin-vpn-core/ui/src): `usersModel.ts` (identity state, expiry,
// summary), `usageModel.ts` (quotaState), `identityLinkModel.ts` (what a
// link serves and why), `lineGroups.ts`, `vpnModel.ts` and `fleetRows.ts`
// (line state, role and target). The wording is the console's where it has
// any, so the phone and the console say the same thing.

// MARK: Expiry

/// `expiryOf`: none, expired, within 30 days, or later.
public enum VPNExpiry: Sendable, Hashable {
    case none
    case expired(Date)
    case soon(Date)
    case later(Date)

    public static let expiringWithinDays = 30

    public static func of(_ expiresAt: Date?, now: Date) -> VPNExpiry {
        guard let at = expiresAt else { return .none }
        let seconds = at.timeIntervalSince(now)
        if seconds <= 0 { return .expired(at) }
        if seconds <= Double(expiringWithinDays) * 86_400 { return .soon(at) }
        return .later(at)
    }

    public var date: Date? {
        switch self {
        case .none: nil
        case .expired(let at), .soon(let at), .later(let at): at
        }
    }

    /// `expiryRelative`: "in 20 days", "within a day", "3 days ago". Whole
    /// days, rounded toward the event.
    public func relative(now: Date) -> String {
        guard let at = date else { return "" }
        let seconds = at.timeIntervalSince(now)
        let days = Int((abs(seconds) / 86_400).rounded(.down))
        if seconds > 0 {
            if days < 1 { return "within a day" }
            return "in \(days) \(days == 1 ? "day" : "days")"
        }
        if days < 1 { return "less than a day ago" }
        return "\(days) \(days == 1 ? "day" : "days") ago"
    }
}

// MARK: Quota

/// `quotaState`: used against a quota, with the tone the console gives it.
public struct VPNQuota: Sendable, Hashable {
    public enum Tone: Sendable, Hashable { case none, healthy, warning, over }

    public var hasQuota: Bool
    public var usedBytes: Int64
    public var quotaBytes: Int64
    /// 0 to 100, rounded, capped at 100.
    public var percent: Int
    public var over: Bool
    public var remainingBytes: Int64
    public var tone: Tone

    public static func of(used: Int64, quota: Int64) -> VPNQuota {
        let used = max(0, used)
        let quota = max(0, quota)
        guard quota > 0 else {
            return VPNQuota(hasQuota: false, usedBytes: used, quotaBytes: 0, percent: 0, over: false, remainingBytes: 0, tone: .none)
        }
        let percent = min(100, Int((Double(used) / Double(quota) * 100).rounded()))
        let over = used >= quota
        return VPNQuota(hasQuota: true, usedBytes: used, quotaBytes: quota, percent: percent, over: over,
                        remainingBytes: max(0, quota - used), tone: over ? .over : (percent >= 80 ? .warning : .healthy))
    }

    /// 0 to 1, for a bar.
    public var fraction: Double { hasQuota ? min(1, Double(usedBytes) / Double(quotaBytes)) : 0 }
}

// MARK: Identity state

/// `identityState`: one word for where an identity stands, worst first.
/// Disabled is deliberate, so it ranks below active.
public enum VPNIdentityState: String, Sendable, Hashable, CaseIterable {
    case expired
    case overQuota = "over_quota"
    case expiring
    case unbound
    case active
    case disabled

    /// `STATE_ORDER`.
    public static let order: [VPNIdentityState] = [.expired, .overQuota, .expiring, .unbound, .active, .disabled]

    public var label: String {
        switch self {
        case .expired: "expired"
        case .overQuota: "over quota"
        case .expiring: "expiring"
        case .unbound: "no line"
        case .active: "active"
        case .disabled: "disabled"
        }
    }

    /// Higher is worse.
    public var rank: Int {
        switch self {
        case .expired: 5
        case .overQuota: 4
        case .expiring: 3
        case .unbound: 2
        case .active: 1
        case .disabled: 0
        }
    }

    public var isProblem: Bool {
        switch self {
        case .expired, .overQuota, .expiring, .unbound: true
        case .active, .disabled: false
        }
    }
}

public enum VPNIdentity {
    /// `isBound`: at least one enabled binding, so the credential is placed somewhere.
    public static func isBound(_ user: VPNUser) -> Bool {
        user.bindings.contains(where: \.enabled)
    }

    /// The period figure the console compares with the quota.
    public static func periodBytes(_ user: VPNUser) -> Int64 {
        user.usage?.usedPeriodBytes ?? 0
    }

    public static func quota(_ user: VPNUser) -> VPNQuota {
        VPNQuota.of(used: periodBytes(user), quota: user.quotaBytes)
    }

    /// Out of service by the operator's hand: turned off, or suspended by
    /// an operator while still enabled (the server's policy says so; the
    /// console reads only `enabled`).
    public static func isSwitchedOff(_ user: VPNUser) -> Bool {
        if !user.enabled { return true }
        if user.source == .legacyProxyUser { return user.legacyStatus == "disabled" }
        return user.policy?.status == "disabled" && user.policy?.reason == "operator"
    }

    /// `identityConditions`: every condition an identity is in, worst first.
    /// A disabled identity is only disabled. A legacy proxy user has no
    /// bindings, so it is never reported as bound to no line; the server's
    /// status word decides expiry and quota for it.
    public static func conditions(_ user: VPNUser, now: Date) -> [VPNIdentityState] {
        if isSwitchedOff(user) { return [.disabled] }
        let expiry = VPNExpiry.of(user.expiresAt, now: now)
        var out: [VPNIdentityState] = []
        if case .expired = expiry { out.append(.expired) } else if user.legacyStatus == "expired" { out.append(.expired) }
        if quota(user).over || user.legacyStatus == "over_quota" { out.append(.overQuota) }
        if case .soon = expiry { out.append(.expiring) }
        if user.source == .vpnCore, !isBound(user) { out.append(.unbound) }
        return out.isEmpty ? [.active] : out
    }

    /// The worst condition: what a row sorts and groups by.
    public static func state(_ user: VPNUser, now: Date) -> VPNIdentityState {
        conditions(user, now: now)[0]
    }

    /// Why a problem state holds, as a sentence for the row's reason line.
    public static func reason(_ user: VPNUser, state: VPNIdentityState, now: Date) -> String? {
        switch state {
        case .expired:
            let when = VPNExpiry.of(user.expiresAt, now: now).relative(now: now)
            return when.isEmpty ? "Expired." : "Expired \(when)."
        case .overQuota:
            let quota = quota(user)
            return "\(VPNBytes.text(quota.usedBytes)) of \(VPNBytes.text(quota.quotaBytes)) used."
        case .expiring:
            return "Expires \(VPNExpiry.of(user.expiresAt, now: now).relative(now: now))."
        case .unbound:
            return "Bound to no line, so it signs in nowhere Lattice manages."
        case .active:
            return nil
        case .disabled:
            if user.enabled, user.policy?.reason == "operator" { return "Suspended by an operator." }
            return nil
        }
    }

    /// The word a disabled row shows: an operator suspension reads as suspended.
    public static func word(_ user: VPNUser, state: VPNIdentityState) -> String {
        if state == .disabled, user.enabled, user.policy?.reason == "operator" { return "suspended" }
        return state.label
    }

    /// Identities ordered for a list: worst state first, then by email.
    public static func ordered(_ users: [VPNUser], now: Date) -> [VPNUser] {
        users.map { ($0, state($0, now: now).rank) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.displayName.localizedStandardCompare(rhs.0.displayName) == .orderedAscending
            }
            .map(\.0)
    }
}

/// `usersSummary`: identities per condition, worst first. An identity in two
/// conditions counts in both, as the console's attention list does.
public struct VPNUsersSummary: Sendable, Hashable {
    public var total: Int
    public var enabled: Int
    public var counts: [(state: VPNIdentityState, count: Int)]

    public static func of(_ users: [VPNUser], now: Date) -> VPNUsersSummary {
        var tally: [VPNIdentityState: Int] = [:]
        for user in users {
            for state in VPNIdentity.conditions(user, now: now) { tally[state, default: 0] += 1 }
        }
        let counts = VPNIdentityState.order.compactMap { state in tally[state].map { (state, $0) } }
        return VPNUsersSummary(total: users.count, enabled: users.filter { !VPNIdentity.isSwitchedOff($0) }.count, counts: counts)
    }

    public static func == (lhs: VPNUsersSummary, rhs: VPNUsersSummary) -> Bool {
        lhs.total == rhs.total && lhs.enabled == rhs.enabled
            && lhs.counts.map(\.state) == rhs.counts.map(\.state) && lhs.counts.map(\.count) == rhs.counts.map(\.count)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(total)
        hasher.combine(enabled)
        for entry in counts {
            hasher.combine(entry.state)
            hasher.combine(entry.count)
        }
    }

    /// "12 identities. 1 expired, 2 expiring." Only the problems are named.
    public var sentence: String { sentence(stale: false) }

    /// Stale or offline data stops claiming health (section 5.0): the
    /// "None needs attention" clause gives way to when the data is from.
    /// `asOf` is that time as shown; nil when it is not known.
    public func sentence(stale: Bool, asOf: String? = nil) -> String {
        let head = total == 1 ? "1 identity." : "\(total) identities."
        let problems = counts.filter { $0.state.isProblem }.map { "\($0.count) \($0.state == .unbound ? "bound to no line" : $0.state.label)" }
        let when = asOf.map { "As of \($0)." } ?? "Not refreshed."
        if problems.isEmpty { return stale ? "\(head) \(when)" : "\(head) None needs attention." }
        return "\(head) \(problems.joined(separator: ", "))." + (stale ? " \(when)" : "")
    }
}

/// Bytes the way the vpn-core console writes them (`formatBytes`): binary
/// units named as such, no decimal from 100 up.
public enum VPNBytes {
    public static func text(_ value: Int64) -> String {
        let bytes = max(0, value)
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KiB", "MiB", "GiB", "TiB"]
        var amount = Double(bytes)
        var unit = -1
        repeat {
            amount /= 1024
            unit += 1
        } while amount >= 1024 && unit < units.count - 1
        return String(format: amount >= 100 ? "%.0f %@" : "%.1f %@", amount, units[unit])
    }
}

/// The credential state a binding reports (`lineBindingCredentialState`).
public enum VPNBindingCredential {
    public static func words(_ state: String) -> String? {
        switch state {
        case "current": "the node holds this identity's credential"
        case "stale": "the node still holds an older credential"
        case "none": "no applied plan put the credential on the node"
        case "unknown": "whether the node holds it is not known"
        default: nil
        }
    }
}

// MARK: Identity link

/// What a link serves now, the one sentence at the top of its section
/// (`linkHeadline`). The route facts decide before the identity's own state.
public struct VPNLinkHeadline: Sendable, Hashable {
    public enum Key: String, Sendable, Hashable { case none, active, placeholder, empty, paused, expired }
    public enum Tone: Sendable, Hashable { case healthy, warning, error, neutral }

    public var key: Key
    public var tone: Tone
    public var title: String
    public var detail: String

    public static func of(_ status: VPNLinkStatus, expiryText: (Date) -> String) -> VPNLinkHeadline {
        if !status.issued || status.answerReason == "not_issued" {
            return VPNLinkHeadline(key: .none, tone: .neutral, title: "No link",
                                   detail: "This identity has no subscription link. Issue one on the web to hand it to a client.")
        }
        if status.answerReason == "link_disabled" {
            return VPNLinkHeadline(key: .paused, tone: .warning, title: "Paused",
                                   detail: "The link answers like an unknown URL until it is resumed on the web. Clients keep the servers they already have.")
        }
        if status.answerReason == "link_expired" {
            let when = status.link?.expiresAt.map { " on \(expiryText($0))" } ?? ""
            return VPNLinkHeadline(key: .expired, tone: .error, title: "Link expired",
                                   detail: "The link expired\(when) and answers like an unknown URL. Rotating keeps the expiry, so the new URL would be expired too; remove the expiry on the web (Rotate and remove expiry) to serve again.")
        }
        let placeholder = status.placeholder.isEmpty ? "one placeholder entry" : "one entry named \"\(status.placeholder)\""
        if status.answer == "placeholder" {
            let why = switch status.answerReason {
            case "disabled": "The identity is turned off"
            case "operator": "The identity is suspended"
            case "expiry": "The identity has expired"
            case "quota": "The identity is over its quota"
            case "no_lines": "The identity is bound to no line"
            default: "The identity is not in service"
            }
            let back = switch status.answerReason {
            case "disabled": " Turning the identity on serves its lines again."
            case "operator": " It serves its lines again when the suspension is lifted."
            case "expiry": " Moving or clearing its expiry serves its lines again."
            case "quota": " Raising the quota serves its lines again, as does the next quota reset."
            case "no_lines": " Binding a line serves it."
            default: ""
            }
            return VPNLinkHeadline(key: .placeholder, tone: .warning, title: "Serving a placeholder",
                                   detail: "\(why), so a client gets \(placeholder) and no servers, with its quota shown as used up.\(back)")
        }
        if status.answer == "decoy" {
            return VPNLinkHeadline(key: .empty, tone: .error, title: "Serving nothing",
                                   detail: "Every bound line is left out right now (\(plural(status.excluded.count, "line", "lines")), below), so a fetch gets an empty answer and the client keeps its last list.")
        }
        let served = status.included.count
        let left = status.excluded.count
        return VPNLinkHeadline(
            key: .active, tone: left > 0 ? .warning : .healthy, title: "Active",
            detail: left > 0
                ? "Serves \(plural(served, "line", "lines")); \(plural(left, "bound line is", "bound lines are")) left out, each with the reason below."
                : "Serves \(plural(served, "line", "lines")), every line this identity is bound to."
        )
    }

    static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }
}

public enum VPNLinkWords {
    /// Why a rotation alone will not make the link serve: the server keeps
    /// the pause and the expiry across a rotation (`rotateIdentityLink`
    /// replaces only the token). Nil when the rotated link will serve.
    public static func rotateCaveat(_ link: VPNLinkSummary?, now: Date) -> String? {
        guard let link else { return nil }
        if !link.enabled { return pausedRotateCaveat }
        if let expires = link.expiresAt, expires <= now { return expiredRotateCaveat }
        return nil
    }

    public static let pausedRotateCaveat = "The new link stays paused. Resume it on the web before it serves."
    public static let expiredRotateCaveat = "The new link stays expired. Remove the expiry on the web before it serves."

    /// `linkAnswers`: issued, on, and not expired.
    public static func answers(_ status: VPNLinkStatus) -> Bool {
        status.issued && (status.link?.enabled ?? false)
            && !["not_issued", "link_disabled", "link_expired"].contains(status.answerReason)
    }

    /// `servedHeading`: present tense only while a fetch gets the lines.
    public static func servedHeading(_ status: VPNLinkStatus) -> String {
        let lines = VPNLinkHeadline.plural(status.included.count, "line", "lines")
        if answers(status), status.answer == "nodes" { return "Serves \(lines)" }
        let when = if !status.issued { "once a link is issued" }
            else if status.answerReason == "link_disabled" { "once the link is resumed" }
            else if status.answerReason == "link_expired" { "once the link's expiry is removed" }
            else if status.answer == "placeholder" { "once the identity is back in service" }
            else { "once it answers with servers again" }
        return "Would serve \(lines) \(when)"
    }

    /// `leftOutHeading`.
    public static func leftOutHeading(_ status: VPNLinkStatus) -> String {
        let lines = VPNLinkHeadline.plural(status.excluded.count, "bound line", "bound lines")
        return answers(status) && status.answer != "placeholder" ? "Leaves out \(lines)" : "Would leave out \(lines)"
    }

    private static let reasons: [String: String] = [
        "binding_disabled": "the binding is turned off",
        "line_unknown": "no node reports this line now",
        "managed_line_unsupported": "managed lines are not served in identity links yet",
        "protocol_unsupported": "its protocol cannot carry a credential per identity",
        "credential_not_applied": "this identity's credential was never applied on the line",
        "rotation_not_applied": "the line still has this identity's old credential",
        "credential_unknown": "the line's user id is not known yet",
        "parked_on_line": "the identity is parked (suspended) on this line",
        "no_client_template": "no client template has been read for this line",
        "template_lossy": "the client template would drop parameters",
        "template_unusable": "the client template cannot be used",
        "service_down": "the line's service is down on its node",
    ]

    /// `excludedReason`: why a bound line is left out, as a clause.
    public static func excludedReason(_ line: VPNLinkLine) -> String {
        let reason = reasons[line.reason] ?? (line.reason.isEmpty ? "left out" : line.reason.replacingOccurrences(of: "_", with: " "))
        return line.detail.isEmpty ? reason : "\(reason) (\(line.detail))"
    }

    /// `linkFix`: the way back in. The two plan fixes are filed on the web.
    public static func fix(_ line: VPNLinkLine) -> String? {
        if line.reason == "binding_disabled", line.fix.isEmpty { return "turn the binding on, on the web" }
        switch line.fix {
        case "plan_add": return "queue an add plan on the web"
        case "plan_update": return "queue an update plan on the web"
        case "wait_for_discovery": return "waits for the node to report the line"
        case "wait_for_template": return "waits for the next discovery to read a template"
        case "wait_for_line_uuid": return "waits for discovery to report the line's user id"
        case "resume": return "comes back when the identity is resumed"
        case "check_line_service": return "check the service on its node"
        default: return nil
        }
    }

    /// `lineTitle`: "relay-hkg-1 / hk-reality".
    public static func lineTitle(_ line: VPNLinkLine) -> String {
        let node = line.nodeName.isEmpty ? line.nodeID : line.nodeName
        let name = line.lineName.isEmpty ? line.lineHashID : line.lineName
        return node.isEmpty ? name : "\(node) / \(name)"
    }

    private static let families: [String: String] = [
        "clashmeta": "mihomo (Clash Verge, FlClash)",
        "clash": "Clash",
        "stash": "Stash",
        "singbox": "sing-box",
        "shadowrocket": "Shadowrocket",
        "surge": "Surge",
        "quantumultx": "Quantumult X",
        "egern": "Egern",
        "loon": "Loon",
        "other": "an unrecognised client",
    ]

    /// `clientFamily`.
    public static func clientFamily(_ uaClass: String) -> String {
        families[uaClass] ?? families["other"]!
    }

    /// `fetchLine`: when the link was last fetched, by what, and what it got.
    /// Fresh means within twice the refresh the link advertises.
    public struct Fetch: Sendable, Hashable {
        public enum Freshness: Sendable, Hashable { case fresh, stale, never }
        public var freshness: Freshness
        public var healthy: Bool
        public var text: String
    }

    public static func fetch(_ status: VPNLinkStatus, now: Date, age: (TimeInterval) -> String) -> Fetch {
        guard let fetch = status.lastFetch else {
            return Fetch(freshness: .never, healthy: false,
                         text: status.issued ? "Not fetched since the server last started" : "Never fetched")
        }
        let elapsed = max(0, now.timeIntervalSince(fetch.at))
        let hours = status.link?.updateIntervalHours ?? 2
        let interval = Double(hours) * 3_600
        let freshness: Fetch.Freshness = elapsed <= interval * 2 ? .fresh : .stale
        let got = switch fetch.answer {
        case "nodes": "got the servers"
        case "placeholder": "got the placeholder"
        case "decoy": "got nothing"
        default: "got an answer"
        }
        return Fetch(freshness: freshness, healthy: freshness == .fresh && fetch.answer == "nodes",
                     text: "Fetched \(age(elapsed)) ago by \(clientFamily(fetch.uaClass)), \(got)"
                        + (freshness == .stale ? ". Overdue: clients refresh every \(hours == 1 ? "hour" : "\(hours) hours")" : ""))
    }

    /// `userinfoText`: the Subscription-Userinfo header in words, what the
    /// client's quota bar shows. A placeholder reports the quota as used up.
    public static func userinfo(_ header: String, answer: String, day: (Date) -> String) -> String {
        guard !header.isEmpty else { return "" }
        var fields: [String: Double] = [:]
        for part in header.split(separator: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pieces.count == 2 { fields[pieces[0]] = Double(pieces[1]) }
        }
        let used = (fields["upload"] ?? 0) + (fields["download"] ?? 0)
        let total = fields["total"] ?? 0
        let expire = fields["expire"] ?? 0
        var out = total > 0 ? "\(gib(used)) of \(gib(total))" : "\(gib(used)) used, no limit"
        if answer == "placeholder" { out += ", shown as used up" }
        if expire > 0 { out += ", expires \(day(Date(timeIntervalSince1970: expire)))" }
        return out
    }

    private static func gib(_ value: Double) -> String {
        let gib = value / 1_073_741_824
        if gib >= 1 { return gib >= 100 ? String(format: "%.0f GiB", gib) : String(format: "%.1f GiB", gib) }
        return String(format: "%.1f MiB", value / 1_048_576)
    }

    /// `linkBadge`: the link as a list row shows it, or nil when none is issued.
    public enum Badge: String, Sendable, Hashable { case link, paused, expired }

    public static func badge(_ summary: VPNLinkSummary?, now: Date) -> Badge? {
        guard let summary else { return nil }
        if !summary.enabled { return .paused }
        if let at = summary.expiresAt, at <= now { return .expired }
        return .link
    }

    /// `linkPathHint`: the path with no token, what a list may show.
    public static func pathHint(_ slug: String) -> String {
        "/sub/\(slug)/…"
    }
}

// MARK: Lines

/// `lineStateOf`: config and service together. A dead service outranks a
/// clean config; an unreported service keeps the config verdict.
public enum VPNLineState: String, Sendable, Hashable, CaseIterable {
    case down
    case configError = "config error"
    case restarting
    case pending
    case stale
    case running
    case unproven
    case configOK = "config ok"

    public static func of(_ line: VPNLine) -> VPNLineState {
        let service = line.serviceState.trimmingCharacters(in: .whitespaces)
        if service == "down" { return .down }
        if line.status == "error" || !line.lastError.isEmpty { return .configError }
        if service == "restarting" { return .restarting }
        if line.status == "pending" { return .pending }
        if line.status == "stale" { return .stale }
        if service == "running" { return .running }
        if !line.serviceNote.isEmpty { return .unproven }
        return .configOK
    }

    public var label: String { rawValue }

    /// Higher is worse.
    public var rank: Int {
        switch self {
        case .down: 6
        case .configError: 5
        case .restarting: 4
        case .pending, .stale: 3
        case .unproven, .configOK: 1
        case .running: 0
        }
    }

    public var isProblem: Bool { rank >= 3 }
}

/// `lineRole`: relay when it forwards, exit when it has an outbound,
/// orphan when the node reported neither.
public enum VPNLineRole: String, Sendable, Hashable {
    case relay, exit, orphan

    public static func of(_ line: VPNLine) -> VPNLineRole {
        if !line.jumpEdges.isEmpty || isRelayCandidate(line) { return .relay }
        if line.outboundRef.trimmingCharacters(in: .whitespaces).isEmpty,
           line.outboundServer.trimmingCharacters(in: .whitespaces).isEmpty { return .orphan }
        return .exit
    }

    /// `isRelayCandidate`: an outbound that names a server and port.
    public static func isRelayCandidate(_ line: VPNLine) -> Bool {
        let ref = line.outboundRef.trimmingCharacters(in: .whitespaces).lowercased()
        if ref.isEmpty || ref == "direct" { return false }
        return !line.outboundServer.trimmingCharacters(in: .whitespaces).isEmpty && line.outboundPort > 0
    }
}

/// `lineTarget`: where a line's traffic goes next.
public enum VPNLineTarget: Sendable, Hashable {
    /// Another fleet node; `more` counts further resolved nodes.
    case node(id: String, name: String, more: Int)
    /// `host:port` outside the fleet.
    case offFleet(String)
    case direct
    case none

    public static func of(_ line: VPNLine, in groups: [VPNLineGroup]) -> VPNLineTarget {
        var byHash: [String: VPNLineGroup] = [:]
        for group in groups {
            for item in group.lines where byHash[item.lineHashID] == nil { byHash[item.lineHashID] = group }
        }
        let resolved = line.jumpEdges.compactMap { byHash[$0] }
        if let first = resolved.first {
            return .node(id: first.nodeID, name: first.nodeName.isEmpty ? first.nodeID : first.nodeName,
                         more: Set(resolved.map(\.nodeID)).count - 1)
        }
        if VPNLineRole.isRelayCandidate(line) {
            return .offFleet("\(line.outboundServer.trimmingCharacters(in: .whitespaces)):\(line.outboundPort)")
        }
        return VPNLineRole.of(line) == .orphan ? .none : .direct
    }

    /// "relays to relay-hkg-1", "exits directly", "relays to 198.51.100.7:443".
    public var sentence: String {
        switch self {
        case .node(_, let name, let more): more > 0 ? "relays to \(name) and \(more) more" : "relays to \(name)"
        case .offFleet(let endpoint): "relays to \(endpoint), outside the fleet"
        case .direct: "exits directly"
        case .none: "no outbound reported"
        }
    }
}

public enum VPNLineFormat {
    /// `formatHostPort`: "[2001:db8::1]:443", "edge.example.net:443", or "".
    public static func hostPort(_ host: String, _ port: Int) -> String {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return "" }
        guard port > 0 else { return host }
        let shown = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(shown):\(port)"
    }

    /// Where the outside reaches the line: the public port when it differs.
    public static func endpoint(_ line: VPNLine) -> String {
        hostPort(line.publicHost, line.publicPort > 0 ? line.publicPort : line.listenPort)
    }

    /// "vless · reality · tcp", the shape a row's detail line names.
    public static func shape(_ line: VPNLine) -> String {
        [line.type, line.security, line.transport].filter { !$0.isEmpty && $0 != "none" }.joined(separator: " · ")
    }

    /// "12 users", "users not inspected yet".
    public static func users(_ line: VPNLine) -> String {
        guard line.userKnown else { return "users not inspected yet" }
        return line.userCount == 1 ? "1 user" : "\(line.userCount) users"
    }
}

/// A line with its node, for flat lists and lookups.
public struct VPNLineEntry: Sendable, Hashable, Identifiable {
    public var line: VPNLine
    public var nodeID: String
    public var nodeName: String

    public var id: String { line.lineHashID }

    /// Every line, worst state first, then by node and name.
    public static func flatten(_ groups: [VPNLineGroup]) -> [VPNLineEntry] {
        groups.flatMap { group in
            group.lines.map { VPNLineEntry(line: $0, nodeID: group.nodeID, nodeName: group.nodeName.isEmpty ? group.nodeID : group.nodeName) }
        }
        .sorted { lhs, rhs in
            let left = VPNLineState.of(lhs.line).rank, right = VPNLineState.of(rhs.line).rank
            if left != right { return left > right }
            if lhs.nodeName != rhs.nodeName { return lhs.nodeName.localizedStandardCompare(rhs.nodeName) == .orderedAscending }
            return lhs.line.displayName.localizedStandardCompare(rhs.line.displayName) == .orderedAscending
        }
    }

    /// The line a route names: M13 rows use the hash id, M3 chains the line uuid.
    public static func find(_ id: String, in groups: [VPNLineGroup]) -> VPNLineEntry? {
        flatten(groups).first { $0.line.lineHashID == id || $0.line.id == id || (!$0.line.lineUUID.isEmpty && $0.line.lineUUID == id) }
    }
}

// MARK: Chains

/// A line's chain health, joined from M3's chain rows by line uuid.
public struct VPNLineChain: Sendable, Hashable {
    /// The composed chain the line is part of.
    public var chain: MonitoringChain
    /// The route that leaves this line, nil when it is the exit.
    public var route: MonitoringLineChain?

    public var state: MonitoringChainState {
        route.map(MonitoringChainState.init) ?? chain.state
    }

    /// The chain the line takes part in, by its uuid; nil for a line in no chain.
    public static func of(_ line: VPNLine, chains rows: [MonitoringLineChain]) -> VPNLineChain? {
        guard !line.lineUUID.isEmpty else { return nil }
        let uuid = line.lineUUID.lowercased()
        guard let chain = MonitoringChain.compose(rows).first(where: { $0.hops.contains { $0.lineUUID.lowercased() == uuid } }) else { return nil }
        let route = rows.first { $0.sourceLineUUID.lowercased() == uuid }
        return VPNLineChain(chain: chain, route: route)
    }

    /// The route's error in words, when it has one.
    public var problem: String? {
        guard let route else { return nil }
        if !route.lastError.isEmpty { return route.lastError.replacingOccurrences(of: "_", with: " ") }
        if let attempt = route.attempt, !attempt.error.isEmpty { return attempt.error }
        return nil
    }
}

/// The identities bound to a line, from the users list.
public enum VPNLineUsers {
    public static func bound(to line: VPNLine, users: [VPNUser]) -> [VPNUser] {
        users.filter { $0.bindings.contains { $0.lineHashID == line.lineHashID } }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

// MARK: Query fields

/// The users list's query fields, after the console's users table columns.
public enum VPNUserQueryFields: QueryFieldProvider {
    public typealias Row = VPNUser

    public static var fields: [LatticeQueryField<VPNUser>] {
        [
            LatticeQueryField(key: "email", aliases: ["identity", "user"], type: .string, get: { .string($0.email) }),
            LatticeQueryField(key: "name", type: .string, get: { .string($0.name) }),
            LatticeQueryField(key: "group", type: .string, get: { .string($0.group) }),
            LatticeQueryField(key: "status", aliases: ["state"], type: .enumeration, values: VPNIdentityState.order.map(\.rawValue),
                              valueAliases: ["over": "over_quota", "quota": "over_quota", "noline": "unbound", "suspended": "disabled"],
                              get: { .string(VPNIdentity.state($0, now: Date()).rawValue) }),
            LatticeQueryField(key: "protocol", aliases: ["proto"], type: .list, get: { .strings($0.credentials.map(\.protocol)) }),
            LatticeQueryField(key: "lines", type: .number, get: { .number(Double($0.bindings.filter(\.enabled).count)) }),
            LatticeQueryField(key: "used", type: .number, unit: .bytes, get: { $0.usage.map { .number(Double($0.usedPeriodBytes)) } ?? .none }),
            LatticeQueryField(key: "quota", type: .number, unit: .bytes, get: { $0.quotaBytes > 0 ? .number(Double($0.quotaBytes)) : .none }),
            LatticeQueryField(key: "expires", type: .time, get: { $0.expiresAt.map { .time($0) } ?? .none }),
            LatticeQueryField(key: "link", type: .bool, flag: true, get: { .bool($0.link != nil) }),
        ]
    }

    public static func text(_ row: VPNUser) -> [String] {
        [row.email, row.name, row.id, row.group, row.comment]
    }
}

/// The lines list's query fields, after the console's lines table.
public enum VPNLineQueryFields: QueryFieldProvider {
    public typealias Row = VPNLineEntry

    public static var fields: [LatticeQueryField<VPNLineEntry>] {
        [
            LatticeQueryField(key: "node", type: .string, get: { .string($0.nodeName) }),
            LatticeQueryField(key: "name", aliases: ["line", "tag"], type: .string, get: { .string($0.line.displayName) }),
            LatticeQueryField(key: "protocol", aliases: ["proto", "type"], type: .string, get: { .string($0.line.type) }),
            LatticeQueryField(key: "core", type: .string, get: { .string($0.line.core) }),
            LatticeQueryField(key: "state", aliases: ["status"], type: .enumeration,
                              values: ["down", "config_error", "restarting", "pending", "stale", "running", "unproven", "config_ok"],
                              valueAliases: ["error": "config_error"],
                              get: { .string(VPNLineState.of($0.line).rawValue.replacingOccurrences(of: " ", with: "_")) }),
            LatticeQueryField(key: "role", type: .enumeration, values: ["relay", "exit", "orphan"], get: { .string(VPNLineRole.of($0.line).rawValue) }),
            LatticeQueryField(key: "managed", type: .bool, flag: true, get: { .bool($0.line.managed) }),
            LatticeQueryField(key: "users", type: .number, get: { $0.line.userKnown ? .number(Double($0.line.userCount)) : .none }),
        ]
    }

    public static func text(_ row: VPNLineEntry) -> [String] {
        [row.line.displayName, row.line.tag, row.nodeName, row.line.type, row.line.lineHashID, row.line.publicHost, row.line.domain]
    }
}
