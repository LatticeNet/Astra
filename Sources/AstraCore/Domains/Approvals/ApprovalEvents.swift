import Foundation

/// The version change an agent-update plan carries.
public struct ApprovalsVersionTransition: Sendable, Hashable {
    public var current: String
    public var target: String

    public init(current: String, target: String) {
        self.current = current
        self.target = target
    }
}

/// Port of `groupApprovalsIntoEvents` and its helpers
/// (`views/operations/approvalsModel.ts`, `lib/approvalKind.ts`), section 6.2.
/// The grouping key is strict: same writer, plugin, action prefix, known kind
/// and, for agent updates, the same version transition parsed from the plan.
public enum ApprovalEvents {
    /// The writer the server records when it proposes a plan itself.
    public static let systemWriter = "lattice-server"
    /// Approvals without an actor collapse into this writer.
    public static let unknownWriter = "unknown"
    /// How many node names a group row previews before "+N more".
    public static let nodePreviewLimit = 6

    /// One console event group of approvals.
    public struct Event: Sendable, Hashable, Identifiable {
        /// The console's key: `writer|plugin|actionPrefix|kind|current→target`.
        public var key: String
        /// The console's English title ("Fleet upgrade 0.3.9 → 0.3.10").
        public var title: String
        /// Sorted by node label, then id.
        public var approvals: [Approval]
        public var writer: String
        public var plugin: String
        public var actionPrefix: String
        public var transition: ApprovalsVersionTransition?
        public var newestCreatedAt: Date?

        public var id: String { key }
        public var isSystem: Bool { writer == ApprovalEvents.systemWriter }

        public init(key: String, title: String, approvals: [Approval]) {
            self.init(key: key, title: title, approvals: approvals, writer: ApprovalEvents.unknownWriter, plugin: approvals.first?.plugin ?? "", actionPrefix: "")
        }

        public init(
            key: String,
            title: String,
            approvals: [Approval],
            writer: String,
            plugin: String,
            actionPrefix: String,
            transition: ApprovalsVersionTransition? = nil,
            newestCreatedAt: Date? = nil
        ) {
            self.key = key
            self.title = title
            self.approvals = approvals
            self.writer = writer
            self.plugin = plugin
            self.actionPrefix = actionPrefix
            self.transition = transition
            self.newestCreatedAt = newestCreatedAt
        }
    }

    // MARK: Grouping

    /// Only rows an operator can still act on: pending, and approved but not applied.
    public static func isGroupable(_ approval: Approval) -> Bool {
        let status = approval.status
        return status == "pending" || status == "approved"
    }

    /// The normalized plan author; empty or blank actors become `unknown`.
    public static func writer(_ approval: Approval) -> String {
        let writer = approval.actorID.trimmingCharacters(in: .whitespacesAndNewlines)
        return writer.isEmpty ? unknownWriter : writer
    }

    /// The part of an action before the first ":".
    public static func actionPrefix(_ action: String) -> String {
        guard let colon = action.firstIndex(of: ":") else { return action.trimmingCharacters(in: .whitespaces) }
        return String(action[..<colon]).trimmingCharacters(in: .whitespaces)
    }

    /// The event key of one approval.
    public static func key(for approval: Approval) -> String {
        let prefix = actionPrefix(approval.action)
        let transition = approval.plugin == "agentupdate" ? parseAgentUpdatePlan(approval.plan).transition : nil
        return groupKey(writer: writer(approval), plugin: approval.plugin, actionPrefix: prefix, kind: kind(of: approval) ?? "", transition: transition)
    }

    /// Groups actionable approvals into events, newest event first.
    public static func group(_ approvals: [Approval]) -> [Event] {
        var order: [String] = []
        var groups: [String: Event] = [:]
        for approval in approvals where isGroupable(approval) {
            let writer = writer(approval)
            let prefix = actionPrefix(approval.action)
            let transition = approval.plugin == "agentupdate" ? parseAgentUpdatePlan(approval.plan).transition : nil
            let key = groupKey(writer: writer, plugin: approval.plugin, actionPrefix: prefix, kind: kind(of: approval) ?? "", transition: transition)
            if groups[key] == nil {
                order.append(key)
                groups[key] = Event(
                    key: key,
                    title: eventTitle(plugin: approval.plugin, actionPrefix: prefix, transition: transition),
                    approvals: [],
                    writer: writer,
                    plugin: approval.plugin,
                    actionPrefix: prefix,
                    transition: transition
                )
            }
            groups[key]?.approvals.append(approval)
            if let created = approval.createdAt, created > (groups[key]?.newestCreatedAt ?? .distantPast) {
                groups[key]?.newestCreatedAt = created
            }
        }
        var events = order.compactMap { groups[$0] }
        for index in events.indices {
            events[index].approvals.sort { lhs, rhs in
                let left = nodeLabel(lhs), right = nodeLabel(rhs)
                if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
                return lhs.id < rhs.id
            }
        }
        events.sort { lhs, rhs in
            let left = lhs.newestCreatedAt ?? .distantPast, right = rhs.newestCreatedAt ?? .distantPast
            if left != right { return left > right }
            return lhs.key < rhs.key
        }
        return events
    }

    /// The first distinct node labels of a group and how many more there are.
    public static func nodePreview(_ event: Event, limit: Int = nodePreviewLimit) -> (nodes: [String], extra: Int) {
        var seen: Set<String> = []
        var labels: [String] = []
        for approval in event.approvals {
            let id = approval.nodeID.isEmpty ? "global" : approval.nodeID
            guard seen.insert(id).inserted else { continue }
            labels.append(nodeLabel(approval))
        }
        return (Array(labels.prefix(limit)), max(0, labels.count - limit))
    }

    static func groupKey(writer: String, plugin: String, actionPrefix: String, kind: String, transition: ApprovalsVersionTransition?) -> String {
        let change = transition.map { "\($0.current)→\($0.target)" } ?? ""
        return [writer, plugin, actionPrefix, kind, change].joined(separator: "|")
    }

    // MARK: Agent-update plans

    /// Reads `current_version`, `target_version` and `node_name` from the
    /// flat `key: value` lines of an agent-update plan, tolerating quotes.
    public static func parseAgentUpdatePlan(_ plan: String) -> (transition: ApprovalsVersionTransition?, nodeName: String?) {
        var current = "", target = "", nodeName = ""
        for line in plan.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            guard isIdentifier(key) else { continue }
            let value = unquote(String(trimmed[trimmed.index(after: colon)...]))
            guard !value.isEmpty else { continue }
            switch key {
            case "current_version": current = value
            case "target_version": target = value
            case "node_name": nodeName = value
            default: break
            }
        }
        let transition = !current.isEmpty && !target.isEmpty ? ApprovalsVersionTransition(current: current, target: target) : nil
        return (transition, nodeName.isEmpty ? nil : nodeName)
    }

    private static func isIdentifier(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first), first.isASCII else { return false }
        return key.unicodeScalars.allSatisfy { $0.isASCII && ($0 == "_" || CharacterSet.alphanumerics.contains($0)) }
    }

    private static func unquote(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// The plan's `node_name` for an agent update, else the node id, else "global".
    public static func nodeLabel(_ approval: Approval) -> String {
        if approval.plugin == "agentupdate", let name = parseAgentUpdatePlan(approval.plan).nodeName {
            return name
        }
        return approval.nodeID.isEmpty ? "global" : approval.nodeID
    }

    // MARK: Titles

    /// "apply-metadata" becomes "Apply Metadata".
    public static func humanizeActionPrefix(_ prefix: String) -> String {
        let words = prefix.split(whereSeparator: { "-_: ".contains($0) }).map(String.init)
        guard !words.isEmpty else { return "Approval event" }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The console's English card title.
    public static func eventTitle(plugin: String, actionPrefix: String, transition: ApprovalsVersionTransition?) -> String {
        if plugin == "agentupdate" {
            return transition.map { "Fleet upgrade \($0.current) → \($0.target)" } ?? "Fleet upgrade"
        }
        if plugin == "singbox-linemeta" && actionPrefix == "apply-metadata" { return "Line metadata sync" }
        return humanizeActionPrefix(actionPrefix)
    }

    /// The known kind of an approval (`approvalKind`), or nil.
    public static func kind(of approval: Approval) -> String? {
        kind(plugin: approval.plugin, action: approval.action, method: approval.method)
    }

    public static func kind(plugin: String, action: String, method: String) -> String? {
        let prefix = actionPrefix(action)
        switch plugin {
        case "agentupdate": return prefix == "update-agent" ? "agentUpdate" : nil
        case "singbox-linemeta": return prefix == "apply-metadata" ? "lineMetaSync" : nil
        case "singbox-lineuser":
            guard prefix == "apply-line-user" else { return nil }
            switch method {
            case "apply_add": return "lineUserAdd"
            case "apply_update": return "lineUserUpdate"
            case "apply_remove": return "lineUserRemove"
            default: return "lineUserChange"
            }
        case "singbox-managedline": return prefix == "apply-managed-line" ? "managedLineRollout" : nil
        case "singbox-linechain":
            guard prefix == "apply-line-chain" else { return nil }
            switch method {
            case "chain_set_apply": return "lineChainSet"
            case "chain_remove_apply": return "lineChainRemove"
            default: return "lineChainChange"
            }
        case "proxycore": return prefix == "apply-config" ? "proxyCoreConfig" : nil
        case "selfdns": return prefix == "apply-config" ? "selfDnsConfig" : nil
        case "nftpolicy": return prefix == "apply-ruleset" ? "networkPolicy" : nil
        case "nft":
            guard prefix == "apply-ruleset" else { return nil }
            return action.trimmingCharacters(in: .whitespaces).hasPrefix("apply-ruleset:netguard-") ? "netguardRuleset" : "firewallRuleset"
        case "cftunnel": return prefix == "apply-config" ? "tunnelConfig" : nil
        case "wireguard": return prefix == "apply-config" ? "wireguardConfig" : nil
        case "sshguard":
            if prefix == "sshguard-arm" { return "sshGuardArm" }
            if prefix == "sshguard-confirm" { return "sshGuardConfirm" }
            return nil
        case "beacon": return prefix == "node.beacon" ? "nodeBeacon" : nil
        case "agent.mirrors": return prefix == "agent.mirrors" ? "agentMirrors" : nil
        case "controlplane-witness":
            if prefix == "witness-configure" { return "witnessConfigure" }
            if prefix == "witness-remove" { return "witnessRemove" }
            return nil
        default: return nil
        }
    }

    /// What a person reads for an approval (`operations.approvals.kinds` in
    /// the console's English locale), with the console's fallback for kinds
    /// nobody listed: "{action} ({plugin})".
    public static func title(for approval: Approval) -> String {
        switch kind(of: approval) {
        case "agentUpdate": return "Update the node agent"
        case "lineMetaSync": return "Sync line metadata"
        case "lineUserAdd": return "Add a VPN user to a line"
        case "lineUserUpdate": return "Update a VPN user on a line"
        case "lineUserRemove": return "Remove a VPN user from a line"
        case "lineUserChange": return "Change a VPN user on a line"
        case "managedLineRollout": return "Roll out a managed line"
        case "lineChainSet": return "Route a line through a downstream"
        case "lineChainRemove": return "Remove a line's downstream route"
        case "lineChainChange": return "Change a line's downstream route"
        case "proxyCoreConfig": return "Apply the proxy core config"
        case "selfDnsConfig": return "Apply the self-hosted DNS config"
        case "networkPolicy": return "Apply network policy"
        case "netguardRuleset": return "Apply NetGuard security groups"
        case "firewallRuleset": return "Apply the firewall ruleset"
        case "tunnelConfig": return "Apply the Cloudflare Tunnel config"
        case "wireguardConfig": return "Apply the WireGuard config"
        case "sshGuardArm": return "Arm SSH Guard"
        case "sshGuardConfirm": return "Confirm the SSH Guard arm"
        case "witnessConfigure": return "Set up the control-plane witness"
        case "witnessRemove": return "Remove the control-plane witness"
        case "nodeBeacon": return "Open, change or close a node's beacon"
        case "agentMirrors": return "Change the agent download mirrors"
        default:
            let words = fallbackWords(plugin: approval.plugin, action: approval.action)
            return "\(words.action) (\(words.plugin))"
        }
    }

    /// `approvalFallbackWords`: the action without the plugin id it repeats,
    /// in sentence case, and the plugin by the last part of its id.
    public static func fallbackWords(plugin rawPlugin: String, action: String) -> (action: String, plugin: String) {
        let plugin = rawPlugin.trimmingCharacters(in: .whitespaces)
        var prefix = actionPrefix(action)
        if !plugin.isEmpty, prefix.hasPrefix("\(plugin)/") { prefix = String(prefix.dropFirst(plugin.count + 1)) }
        let words = prefix.split(whereSeparator: { "/_-. ".contains($0) }).joined(separator: " ")
        let shortPlugin = plugin.split(separator: ".").last.map(String.init) ?? plugin
        let actionWords = words.isEmpty ? (shortPlugin.isEmpty ? "?" : shortPlugin) : words.prefix(1).uppercased() + words.dropFirst()
        return (actionWords, shortPlugin.isEmpty ? "?" : shortPlugin)
    }

    /// The server's identifier without its digest suffix: "sshguard · sshguard-arm".
    public static func rawLabel(_ approval: Approval) -> String {
        "\(approval.plugin) · \(actionPrefix(approval.action))"
    }

    /// The Inbox row for a group: "Agent update to 0.3.10 on 3 nodes".
    public static func summary(_ event: Event) -> String {
        let count = event.approvals.count
        let nodes = count == 1 ? "1 node" : "\(count) nodes"
        if event.plugin == "agentupdate", let transition = event.transition {
            return "Agent update to \(transition.target) on \(nodes)"
        }
        guard let first = event.approvals.first else { return event.title }
        return "\(title(for: first)) on \(nodes)"
    }

    /// The BatchReview title: "Agent update to 0.3.10, 3 plans".
    public static func batchTitle(_ event: Event) -> String {
        let count = event.approvals.count
        let plans = count == 1 ? "1 plan" : "\(count) plans"
        if event.plugin == "agentupdate", let transition = event.transition {
            return "Agent update to \(transition.target), \(plans)"
        }
        guard let first = event.approvals.first else { return "\(event.title), \(plans)" }
        return "\(title(for: first)), \(plans)"
    }

    /// The plugin glyph of section 4.12.
    public static func pluginSymbol(_ plugin: String) -> String {
        switch plugin {
        case "sshguard": "lock.shield"
        case "agentupdate", "agent.mirrors": "arrow.down.circle"
        case "beacon": "dot.radiowaves.left.and.right"
        case "nftpolicy": "arrow.up.forward.circle"
        case "selfdns": "globe"
        case "cftunnel": "point.topleft.down.to.point.bottomright.curvepath"
        case "nft": "shield.lefthalf.filled"
        case "wireguard": "network"
        case "controlplane-witness": "bell"
        default: "puzzlepiece.extension"
        }
    }
}
