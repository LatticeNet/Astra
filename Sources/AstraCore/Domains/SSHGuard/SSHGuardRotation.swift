import Foundation

/// Ports of the arm form and the knock rotation of the console's
/// `sshGuardModel.ts`: `parseMgmtSources`, `defaultGuardForm`,
/// `buildPlanRequest`, `validateForm`, `rotateEligibility`,
/// `rotationSshPort`, `rotationFallbackFor` and `buildRotationRequest`. Pure.
public enum SSHGuardRotation {
    public static let defaultConfirmWindowSec = 900
    public static let minConfirmWindowSec = 120
    /// A rotation asks for the longest window the server allows.
    public static let rotationConfirmWindowSec = 3600
    public static let knockSequenceLength = 3
    public static let knockPortRange = 20000...60000
    public static let legacyPort = 22

    // MARK: Addresses and ports

    /// Split and validate the management-source list. A bare address stays bare.
    public static func parseMgmtSources(_ raw: String) -> (values: [String], invalid: [String]) {
        var values: [String] = []
        var invalid: [String] = []
        var seen = Set<String>()
        for token in tokens(raw) where seen.insert(token).inserted {
            if isAddressOrCIDR(token) { values.append(token) } else { invalid.append(token) }
        }
        return (values, invalid)
    }

    /// A comma or space separated port list, order kept.
    public static func parsePortList(_ raw: String) -> (values: [Int], invalid: [String]) {
        var values: [Int] = []
        var invalid: [String] = []
        for token in tokens(raw) {
            if token.count <= 5, token.allSatisfy(\.isASCIIDigit), let port = Int(token), (1...65535).contains(port) {
                values.append(port)
            } else {
                invalid.append(token)
            }
        }
        return (values, invalid)
    }

    /// Exactly three distinct ports in the knock range.
    public static func isKnockSequence(_ ports: [Int]) -> Bool {
        ports.count == knockSequenceLength && Set(ports).count == ports.count && ports.allSatisfy { knockPortRange.contains($0) }
    }

    public static func isAddressOrCIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), let address = parts.first, !address.isEmpty else { return false }
        let isV6 = address.contains(":")
        if parts.count == 2 {
            let prefix = parts[1]
            guard (1...3).contains(prefix.count), prefix.allSatisfy(\.isASCIIDigit), let bits = Int(prefix), bits <= (isV6 ? 128 : 32) else { return false }
        }
        return isV6 ? isIPv6(address) : isIPv4(address)
    }

    private static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            (1...3).contains(part.count) && part.allSatisfy(\.isASCIIDigit) && (Int(part) ?? 256) <= 255
        }
    }

    /// Permissive on shape and strict on alphabet, as the console is.
    private static func isIPv6(_ value: String) -> Bool {
        guard value.allSatisfy({ $0.isHexDigit || $0 == ":" }) else { return false }
        return value.components(separatedBy: "::").count - 1 <= 1 && value.split(separator: ":", omittingEmptySubsequences: false).count <= 9
    }

    private static func tokens(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" }).map(String.init)
    }

    // MARK: Arm form

    /// What the operator sees and changes in the arm sheet (`GuardForm`
    /// without the advanced overrides, which stay on the web).
    public struct Form: Sendable, Hashable {
        public var nodeID: String
        /// 0 keeps the port sshd listens on.
        public var sshPort: Int
        public var keepLegacyPort: Bool
        public var mgmtSources: String
        public var enableKnock: Bool
        public var outOfBandFallback: Bool
        public var confirmWindowSec: Int

        public init(nodeID: String, sshPort: Int = 0, keepLegacyPort: Bool = true, mgmtSources: String = "",
                    enableKnock: Bool = true, outOfBandFallback: Bool = false, confirmWindowSec: Int = SSHGuardRotation.defaultConfirmWindowSec) {
            self.nodeID = nodeID
            self.sshPort = sshPort
            self.keepLegacyPort = keepLegacyPort
            self.mgmtSources = mgmtSources
            self.enableKnock = enableKnock
            self.outOfBandFallback = outOfBandFallback
            self.confirmWindowSec = confirmWindowSec
        }

        /// `defaultGuardForm`: knock on, no source, no fallback, the default
        /// window. It is refused by `validate` until a source or the fallback
        /// is added, on purpose.
        public static func defaults(nodeID: String) -> Form {
            Form(nodeID: nodeID)
        }

        /// The defaults, then what this node's last arm used: its knock
        /// choice, window, port and sources (read back from its plan).
        public static func prefilled(nodeID: String, lastArm: SSHGuardApprovalRef?, lastArmPlan: String?) -> Form {
            var form = defaults(nodeID: nodeID)
            guard let lastArm else { return form }
            form.enableKnock = parseKnockDeclared(lastArmPlan) ?? lastArm.knock
            if lastArm.confirmWindowSec >= SSHGuardRotation.minConfirmWindowSec {
                form.confirmWindowSec = lastArm.confirmWindowSec
            } else if let window = parseConfirmWindow(lastArmPlan) {
                form.confirmWindowSec = window
            }
            if let port = planPort(lastArmPlan), port != SSHGuardRotation.legacyPort {
                form.sshPort = port
            }
            if let sources = parseArmMgmtSources(lastArmPlan) {
                if sources.isEmpty, form.enableKnock {
                    // A knock arm with no source could only have stood on the terminal.
                    form.outOfBandFallback = true
                } else {
                    form.mgmtSources = sources.joined(separator: "\n")
                }
            }
            return form
        }
    }

    /// `buildPlanRequest`: everything the operator did not choose is left out.
    public static func planRequest(_ form: Form, acceptFindings: Bool = false) -> SSHGuardPlanRequest {
        var request = SSHGuardPlanRequest(nodeID: form.nodeID.trimmingCharacters(in: .whitespaces))
        if form.sshPort > 0 { request.sshPort = form.sshPort }
        if form.keepLegacyPort { request.keepLegacyPort = true }
        let sources = parseMgmtSources(form.mgmtSources).values
        if !sources.isEmpty { request.mgmtSources = sources }
        // Sent in both directions: the server's own default follows ssh_port.
        request.enableKnock = form.enableKnock
        if form.outOfBandFallback { request.outOfBandFallback = true }
        if form.confirmWindowSec > 0, form.confirmWindowSec != defaultConfirmWindowSec {
            request.confirmWindowSec = form.confirmWindowSec
        }
        if acceptFindings { request.acceptFindings = true }
        return request
    }

    /// `validateForm`: problems that block filing, as stable codes.
    public enum FormProblem: String, Sendable, Hashable, CaseIterable {
        case nodeRequired = "node_required"
        case portRange = "port_range"
        case portIsLegacy = "port_is_legacy"
        case sourcesInvalid = "sources_invalid"
        case windowTooShort = "window_too_short"
        case singleWayIn = "single_way_in"

        public var sentence: String {
            switch self {
            case .nodeRequired: "Choose a node."
            case .portRange: "The SSH port must be between 1 and 65535."
            case .portIsLegacy: "Port 22 is the port sshd already uses. Leave the port unchanged instead."
            case .sourcesInvalid: "Some management sources are not addresses or CIDR ranges."
            case .windowTooShort: "The confirm window must be at least 2 minutes."
            case .singleWayIn: "With knocking on and no management source, the knock sequence would be the only way in. Add a source or allow the Lattice terminal as the fallback."
            }
        }
    }

    public static func validate(_ form: Form) -> [FormProblem] {
        var problems: [FormProblem] = []
        if form.nodeID.trimmingCharacters(in: .whitespaces).isEmpty { problems.append(.nodeRequired) }
        if form.sshPort < 0 || form.sshPort > 65535 { problems.append(.portRange) }
        if form.sshPort == legacyPort { problems.append(.portIsLegacy) }
        let sources = parseMgmtSources(form.mgmtSources)
        if !sources.invalid.isEmpty { problems.append(.sourcesInvalid) }
        if form.confirmWindowSec > 0, form.confirmWindowSec < minConfirmWindowSec { problems.append(.windowTooShort) }
        if form.enableKnock, sources.values.isEmpty, !form.outOfBandFallback { problems.append(.singleWayIn) }
        return problems
    }

    // MARK: Plan text

    /// `parseKnockDeclared`: the `knock: true|false` header line of an arm plan.
    public static func parseKnockDeclared(_ plan: String?) -> Bool? {
        guard let value = headerValue("knock", in: plan) else { return nil }
        switch value {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// `parseConfirmWindow`: the `confirm_window_sec:` header line.
    public static func parseConfirmWindow(_ plan: String?) -> Int? {
        guard let value = headerValue("confirm_window_sec", in: plan), value.allSatisfy(\.isASCIIDigit), let seconds = Int(value), seconds > 0 else { return nil }
        return seconds
    }

    /// The `ssh_port:` header line, 0 included.
    public static func planPort(_ plan: String?) -> Int? {
        guard let value = headerValue("ssh_port", in: plan), value.allSatisfy(\.isASCIIDigit), let port = Int(value) else { return nil }
        return port
    }

    /// `parseArmMgmtSources`: the sources under "## Management sources", an
    /// empty list for "(none)", nil when the plan has no such section.
    public static func parseArmMgmtSources(_ plan: String?) -> [String]? {
        let lines = (plan ?? "").components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## Management sources") && isWordBoundary(after: "## Management sources", in: $0) }) else { return nil }
        var sources: [String] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("## ") { break }
            guard line.hasPrefix("-") else { continue }
            let value = line.dropFirst().trimmingCharacters(in: .whitespaces)
            guard line.dropFirst().first?.isWhitespace == true, !value.isEmpty, value != "(none)" else { continue }
            if isAddressOrCIDR(value) { sources.append(value) }
        }
        return sources
    }

    private static func isWordBoundary(after prefix: String, in line: String) -> Bool {
        guard let next = line.dropFirst(prefix.count).first else { return true }
        return !(next.isLetter || next.isNumber || next == "_")
    }

    /// A `key: value` line of the plan header, matched on a whole line.
    private static func headerValue(_ key: String, in plan: String?) -> String? {
        for line in (plan ?? "").components(separatedBy: .newlines) {
            guard line.hasPrefix("\(key):") else { continue }
            return line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: Rotation

    /// Why a node's knock cannot be rotated (`RotateRefusalCode`).
    public enum RotateRefusal: String, Sendable, Hashable {
        case selectOne = "select_one"
        case planned
        case noKnock = "no_knock"
        case previousPortsRequired = "previous_ports_required"
        case previousPortsInvalid = "previous_ports_invalid"
        case portUnknown = "port_unknown"
        case armUnresolved = "arm_unresolved"

        public var sentence: String {
            switch self {
            case .selectOne: "Rotate one node at a time."
            case .planned: "The sequence is written down but not on the node yet, so there is nothing to rotate from."
            case .noKnock: "This node is guarded without knocking, so there is no sequence to rotate."
            case .previousPortsRequired: "The control plane never installed a sequence here. Enter the three ports the node knocks on now."
            case .previousPortsInvalid: "Enter exactly three different ports between 20000 and 60000."
            case .portUnknown: "No source says which port sshd listens on, so the rotation cannot keep it."
            case .armUnresolved: "The arm that installed this sequence could not be read, so the rotation cannot repeat its fallback and port."
            }
        }
    }

    /// `RotateEligibility`: by digest (reveal the installed sequence), by
    /// the previous ports the operator typed, or refused.
    public enum RotateEligibility: Sendable, Hashable {
        case digest
        case previousPorts([Int])
        case refused(RotateRefusal)

        /// `rotateOpenable`: the sheet may open for it.
        public var isOpenable: Bool {
            switch self {
            case .digest, .previousPorts: true
            case .refused(let code): code == .previousPortsRequired || code == .previousPortsInvalid
            }
        }
    }

    static let installedKnowledge: Set<String> = ["installed", "installed_superseded"]

    /// `rotateEligibility`. `selected` is the knock knowledge of the chosen
    /// rows (the phone always passes one); `governingPlan` is the plan of
    /// the arm the server names as having installed the sequence.
    public static func eligibility(selected: [String], previousPorts: String, sshPort: Int?, governingPlan: String?) -> RotateEligibility {
        guard selected.count == 1, let knowledge = selected.first else { return .refused(.selectOne) }
        if knowledge == "planned" { return .refused(.planned) }
        if knowledge == "no_knock" { return .refused(.noKnock) }
        let installed = installedKnowledge.contains(knowledge)
        if installed, governingPlan == nil { return .refused(.armUnresolved) }
        guard sshPort != nil else { return .refused(.portUnknown) }
        if installed { return .digest }
        if previousPorts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .refused(.previousPortsRequired) }
        let parsed = parsePortList(previousPorts)
        guard parsed.invalid.isEmpty, isKnockSequence(parsed.values) else { return .refused(.previousPortsInvalid) }
        return .previousPorts(parsed.values)
    }

    /// `rotationSshPort`: the server's knock state, then the arm plan, then
    /// what sshd is seen listening on. 0 and 22 mean "keep the current port".
    public static func rotationSSHPort(serverPort: Int?, governingPlan: String?, observed: [Int]) -> Int? {
        if let serverPort, serverPort > 0 { return serverPort }
        if let port = planPort(governingPlan), port >= 0 { return port }
        return observed.first { $0 > 0 }
    }

    public enum Fallback: Sendable, Hashable {
        case terminal
        case sources([String])
    }

    /// `rotationFallbackFor`: the sources the governing arm admitted, or the
    /// terminal when it listed none.
    public static func fallback(forPlan plan: String?) -> Fallback {
        if let sources = parseArmMgmtSources(plan), !sources.isEmpty { return .sources(sources) }
        return .terminal
    }

    public enum RotationSource: Sendable, Hashable {
        case digest(String)
        case previousPorts([Int])
    }

    /// `buildRotationRequest`: knocking on, the longest window, the row's
    /// port unless it is 0 or 22, the digest or the previous ports, and the
    /// governing arm's fallback. The new sequence is drawn server-side.
    public static func rotationRequest(nodeID: String, sshPort: Int, from source: RotationSource, fallback: Fallback) -> SSHGuardPlanRequest {
        var request = SSHGuardPlanRequest(nodeID: nodeID.trimmingCharacters(in: .whitespaces), enableKnock: true, confirmWindowSec: rotationConfirmWindowSec)
        if sshPort > 0, sshPort != legacyPort { request.sshPort = sshPort }
        switch source {
        case .digest(let digest): request.rotateFromSHA256 = digest
        case .previousPorts(let ports): request.previousKnockPorts = ports
        }
        switch fallback {
        case .sources(let sources): request.mgmtSources = sources
        case .terminal: request.outOfBandFallback = true
        }
        return request
    }

    /// `governingArm`: the arm the server names in the knock state; without
    /// its word, the newest applied arm that declared a knock. An id the
    /// list does not hold resolves to nothing, never to a stand-in.
    public static func governingArm(_ approvals: [Approval], nodeID: String, serverApprovalID: String?) -> Approval? {
        let arms = approvals.filter { $0.plugin == "sshguard" && $0.nodeID == nodeID && $0.action == "sshguard-arm:v1" }
        if let serverApprovalID, !serverApprovalID.isEmpty {
            return arms.first { $0.id == serverApprovalID }
        }
        return arms
            .filter { $0.status == "applied" && parseKnockDeclared($0.plan) == true }
            .max { newer($1, than: $0) }
    }

    private static func newer(_ a: Approval, than b: Approval) -> Bool {
        let at = a.updatedAt ?? a.createdAt ?? .distantPast
        let bt = b.updatedAt ?? b.createdAt ?? .distantPast
        return at != bt ? at > bt : a.id > b.id
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
