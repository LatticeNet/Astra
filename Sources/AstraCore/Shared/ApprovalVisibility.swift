import Foundation

/// Which approvals a credential can list and decide, mirrored from the
/// server's `approvalPrimaryScopeAllows` (server.go:7993) and
/// `approvalDecisionExtraScope` (server.go:9738). It drives the Needs you
/// footer, the badge note, the verdict's partial coverage and Approve
/// eligibility (section 6.12).
public enum ApprovalVisibility {
    /// Plugins whose approvals have a read rule of their own, in display order.
    public static let knownPlugins: [String] = [
        "sshguard", "agentupdate", "beacon", "nftpolicy", "selfdns", "nft", "cftunnel",
        "proxycore", "singbox-lineuser", "singbox-managedline", "substore-plan",
        "controlplane-witness", "agent.mirrors", "wireguard",
    ]

    /// The scopes that let a credential list an approval of `plugin`.
    public static func readRequirement(plugin: String) -> ScopeRequirement {
        switch plugin {
        case "nftpolicy":
            ScopeRequirement("netpolicy:admin")
        case "agentupdate":
            ScopeRequirement("node:admin", "network:plan")
        case "selfdns":
            ScopeRequirement("dns:admin", "network:plan")
        case "proxycore":
            ScopeRequirement("proxy:read", "network:plan", unconfined: true)
        case "singbox-lineuser", "singbox-managedline", "substore-plan":
            ScopeRequirement(groups: [["proxy:read", "proxy:admin"], ["network:plan"]], unconfined: true)
        case "cftunnel":
            ScopeRequirement("tunnel:admin")
        case "controlplane-witness":
            ScopeRequirement("notify:admin", "network:plan", unconfined: true)
        case "agent.mirrors":
            ScopeRequirement("node:admin", "network:plan", unconfined: true)
        case "beacon":
            ScopeRequirement("monitor:read", "network:plan")
        case "sshguard":
            ScopeRequirement("sshguard:read", "network:plan")
        default:
            ScopeRequirement("network:plan")
        }
    }

    public static func canList(plugin: String, nodeID: String, scopes: ScopeSet) -> Bool {
        scopes.allows(readRequirement(plugin: plugin), nodeID: nodeID)
    }

    public static func canList(_ approval: Approval, scopes: ScopeSet) -> Bool {
        canList(plugin: approval.plugin, nodeID: approval.nodeID, scopes: scopes)
    }

    /// The scope a decision needs beyond `network:apply`, or nil when none.
    public static func decisionScope(plugin: String, action: String) -> String? {
        if plugin == "nft" && action == "apply-ruleset:netguard-v1" { return "netguard:admin" }
        switch plugin {
        case "sshguard": return "sshguard:admin"
        case "nftpolicy": return "netpolicy:admin"
        case "agentupdate", "agent.mirrors": return "node:admin"
        case "selfdns": return "dns:admin"
        case "proxycore": return "proxy:admin"
        case "singbox-lineuser", "singbox-linemeta", "singbox-managedline": return "vpncore:admin"
        case "cftunnel": return "tunnel:admin"
        case "controlplane-witness": return "notify:admin"
        case "beacon": return "monitor:admin"
        case "substore-plan": return "proxy:admin"
        default: return nil
        }
    }

    public static func decisionScope(for approval: Approval) -> String? {
        decisionScope(plugin: approval.plugin, action: approval.action)
    }

    /// `network:apply` plus the plugin's decision scope.
    public static func decisionRequirement(for approval: Approval) -> ScopeRequirement {
        if let extra = decisionScope(for: approval) {
            return ScopeRequirement("network:apply", extra)
        }
        return ScopeRequirement("network:apply")
    }

    public static func canDecide(_ approval: Approval, scopes: ScopeSet) -> Bool {
        scopes.allows(decisionRequirement(for: approval), nodeID: approval.nodeID)
    }

    /// Plugins whose approvals this credential cannot list on any node, as
    /// display names ("SSH Guard", "Self-host DNS").
    public static func hiddenPlugins(scopes: ScopeSet) -> [String] {
        knownPlugins
            .filter { !scopes.allows(readRequirement(plugin: $0)) }
            .map(displayName(plugin:))
    }

    public static func displayName(plugin: String) -> String {
        switch plugin {
        case "sshguard": "SSH Guard"
        case "agentupdate": "Agent updates"
        case "beacon": "Beacon"
        case "nftpolicy": "Outbound policy"
        case "selfdns": "Self-host DNS"
        case "nft": "Inbound firewall"
        case "cftunnel": "Tunnels"
        case "proxycore": "Proxy"
        case "singbox-lineuser": "VPN line users"
        case "singbox-managedline": "VPN managed lines"
        case "singbox-linemeta": "VPN line metadata"
        case "substore-plan": "Sub-Store"
        case "controlplane-witness": "Notification witness"
        case "agent.mirrors": "Agent mirrors"
        case "wireguard": "WireGuard"
        default: plugin
        }
    }
}
