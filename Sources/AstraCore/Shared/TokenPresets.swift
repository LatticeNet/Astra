import Foundation

/// How the phone serves one console action (section 3): native read, a write
/// at a tier, plan filing, a decision, a step-up reveal, or the web.
public enum ParityMode: String, Sendable, Hashable, CaseIterable {
    case native = "N"
    case nativeT1 = "N-T1"
    case nativeT2 = "N-T2"
    case nativeT3 = "N-T3"
    case nativeT4 = "N-T4"
    case nativePlan = "N-P"
    case nativeDecision = "N-D"
    case nativeStepUp = "N-S"
    case web = "W"

    public var isNative: Bool { self != .web }
}

/// One row of the parity matrix (section 3.2) as data.
public struct ParityMatrixRow: Sendable, Hashable {
    public var page: String
    public var action: String
    public var endpoint: String
    /// Every scope the row needs; a combined mode ("N-T3 + P") lists both gates' scopes.
    public var scopes: [String]
    public var modes: [ParityMode]

    public init(page: String, action: String, endpoint: String, scopes: [String], modes: [ParityMode]) {
        self.page = page
        self.action = action
        self.endpoint = endpoint
        self.scopes = scopes
        self.modes = modes
    }

    public var isNative: Bool { modes.contains { $0.isNative } }
}

/// The parity matrix rows whose scopes `TokenPresets` must cover.
public enum ParityMatrix {
    /// Section 3.2 row by row, the reads of 3.1 that carry their own scope,
    /// and the native vpn-core user actions of 3.3. A decision row lists
    /// network:apply only; the plugin's extra decision scope comes from
    /// `ApprovalVisibility`. Session-only rows list no scope.
    public static let rows: [ParityMatrixRow] = [
        // Section 3.1, reads with a scope of their own.
        ParityMatrixRow(page: "Plugins", action: "List plugins", endpoint: "GET /api/plugins", scopes: ["audit:read"], modes: [.native]),
        ParityMatrixRow(page: "System", action: "Read health and series", endpoint: "GET /api/system/health", scopes: ["*"], modes: [.native]),
        // Section 3.2.
        ParityMatrixRow(page: "Overview", action: "Acknowledge incident", endpoint: "POST /api/incidents/ack", scopes: ["monitor:admin"], modes: [.nativeT1]),
        ParityMatrixRow(page: "Overview", action: "Snooze incident", endpoint: "POST /api/incidents/snooze", scopes: ["monitor:admin"], modes: [.nativeT1]),
        ParityMatrixRow(page: "Nodes", action: "Enroll node", endpoint: "POST /api/nodes/enroll-token", scopes: ["node:admin"], modes: [.web]),
        ParityMatrixRow(page: "Nodes", action: "Disable node", endpoint: "POST /api/nodes/disable", scopes: ["node:admin"], modes: [.nativeT3]),
        ParityMatrixRow(page: "Nodes", action: "Enable node", endpoint: "POST /api/nodes/disable (disabled:false)", scopes: ["node:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Nodes", action: "Bulk disable", endpoint: "POST /api/nodes/disable per node", scopes: ["node:admin"], modes: [.nativeT3]),
        ParityMatrixRow(page: "Nodes", action: "Bulk enable", endpoint: "POST /api/nodes/disable (disabled:false) per node", scopes: ["node:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Nodes", action: "Rotate token", endpoint: "POST /api/nodes/rotate-token", scopes: ["node:admin"], modes: [.nativeT3]),
        ParityMatrixRow(page: "Nodes", action: "Open terminal", endpoint: "POST /api/terminal/sessions", scopes: ["terminal:open"], modes: [.web]),
        ParityMatrixRow(page: "Node detail", action: "Edit identity (name, tags, role)", endpoint: "POST /api/nodes/update", scopes: ["node:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Node detail", action: "Capability enroll or exclude", endpoint: "POST /api/nodes/capabilities", scopes: ["node:admin"], modes: [.nativeT3]),
        ParityMatrixRow(page: "Node detail", action: "Geo set", endpoint: "POST /api/nodes/geo", scopes: ["node:admin"], modes: [.web]),
        ParityMatrixRow(page: "Node detail", action: "Geo clear", endpoint: "POST /api/nodes/geo", scopes: ["node:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Node detail", action: "Geo resolve", endpoint: "POST /api/nodes/geo/resolve", scopes: ["node:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Node detail", action: "IP-discovery override", endpoint: "POST /api/nodes/ip-config", scopes: ["node:admin", "network:plan"], modes: [.web]),
        ParityMatrixRow(page: "Node detail", action: "Agent debug", endpoint: "POST /api/nodes/debug", scopes: ["node:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Node detail", action: "Generate reconfigure command", endpoint: "POST /api/nodes/reconfigure-command", scopes: ["node:admin"], modes: [.web]),
        ParityMatrixRow(page: "Node detail", action: "Rotate token", endpoint: "POST /api/nodes/rotate-token", scopes: ["node:admin"], modes: [.nativeT3]),
        ParityMatrixRow(page: "Node detail", action: "Delete node", endpoint: "POST /api/nodes/delete/plan then /delete {node_id}", scopes: ["node:admin"], modes: [.nativeT4]),
        ParityMatrixRow(page: "Node detail", action: "Auto-update policy", endpoint: "POST /api/nodes/agent-updates", scopes: ["node:admin"], modes: [.web]),
        ParityMatrixRow(page: "Node detail", action: "Agent update plan, force plan", endpoint: "POST /api/nodes/agent-updates/plan", scopes: ["node:admin", "network:plan"], modes: [.nativePlan]),
        ParityMatrixRow(page: "Node detail", action: "Beacon plan", endpoint: "POST /api/nodes/beacon/plan {node_id, action, port?, bind?, endpoint?}", scopes: ["monitor:admin", "node:admin", "network:plan"], modes: [.nativePlan]),
        // netguard:admin is needed only when the plan carries a NetGuard companion; the
        // beacon plan then answers 403 and the sheet names the scope.
        ParityMatrixRow(page: "Node detail", action: "Beacon rotate", endpoint: "POST /api/nodes/beacon/rotate", scopes: ["monitor:admin", "node:admin"], modes: [.nativeT3]),
        ParityMatrixRow(page: "Node groups", action: "Create or edit (selector or members)", endpoint: "POST /api/groups", scopes: ["group:admin"], modes: [.web]),
        ParityMatrixRow(page: "Node groups", action: "Preview selector", endpoint: "POST /api/groups/preview", scopes: ["group:read"], modes: [.web]),
        ParityMatrixRow(page: "Node groups", action: "Add or remove static members", endpoint: "POST /api/groups/members", scopes: ["group:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Node groups", action: "Delete", endpoint: "POST /api/groups/delete", scopes: ["group:admin"], modes: [.nativeT4]),
        ParityMatrixRow(page: "Node groups", action: "Reorder, seed", endpoint: "/api/groups/reorder, /seed", scopes: ["group:admin"], modes: [.web]),
        ParityMatrixRow(page: "Map", action: "Locate missing nodes", endpoint: "POST /api/nodes/geo/resolve (missing_only)", scopes: ["node:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Inventory", action: "Create or edit machine profile", endpoint: "POST /api/machines, /update", scopes: ["inventory:admin"], modes: [.web]),
        ParityMatrixRow(page: "Inventory", action: "Delete machine", endpoint: "POST /api/machines/delete", scopes: ["inventory:admin"], modes: [.nativeT4]),
        ParityMatrixRow(page: "Inventory", action: "Renew", endpoint: "POST /api/machines/renew", scopes: ["inventory:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Inventory", action: "Upsert vendor", endpoint: "POST /api/machine-vendors", scopes: ["inventory:admin"], modes: [.web]),
        ParityMatrixRow(page: "Inventory", action: "Delete vendor", endpoint: "POST /api/machine-vendors/delete", scopes: ["inventory:admin"], modes: [.web]),
        ParityMatrixRow(page: "Inventory", action: "Preview then send reminders", endpoint: "POST /api/machines/reminders/run", scopes: ["inventory:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Inventory", action: "Reveal console or detail link", endpoint: "POST /api/machines/reveal-link", scopes: ["inventory:admin"], modes: [.nativeStepUp]),
        ParityMatrixRow(page: "Upcoming", action: "Record renewal", endpoint: "POST /api/machines/renew", scopes: ["inventory:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Monitoring", action: "Check create or edit", endpoint: "POST /api/monitors, /update", scopes: ["monitor:admin"], modes: [.web]),
        ParityMatrixRow(page: "Monitoring", action: "Check pause or resume", endpoint: "POST /api/monitors/update {id, version, enabled}", scopes: ["monitor:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Monitoring", action: "Check delete", endpoint: "POST /api/monitors/delete", scopes: ["monitor:admin"], modes: [.nativeT4]),
        ParityMatrixRow(page: "Monitoring", action: "Definition create, update, preview", endpoint: "/api/monitors/definitions[/update\\|/preview]", scopes: ["monitor:admin"], modes: [.web]),
        ParityMatrixRow(page: "Monitoring", action: "Definition delete", endpoint: "POST /api/monitors/definitions/delete {id, version, monitor_ids}", scopes: ["monitor:admin"], modes: [.nativeT4]),
        ParityMatrixRow(page: "Monitoring", action: "Definition forget", endpoint: "POST /api/monitors/definitions/forget", scopes: ["monitor:admin"], modes: [.web]),
        ParityMatrixRow(page: "Monitoring", action: "Latency probe plan", endpoint: "PUT /api/monitors/latency", scopes: ["monitor:admin"], modes: [.web]),
        ParityMatrixRow(page: "Monitoring", action: "Retention", endpoint: "POST /api/monitors/settings/update", scopes: ["monitor:admin"], modes: [.web]),
        ParityMatrixRow(page: "Monitoring", action: "Beacon replan", endpoint: "POST /api/nodes/beacon/plan (action: change)", scopes: ["monitor:admin", "node:admin", "network:plan"], modes: [.nativePlan]),
        ParityMatrixRow(page: "Monitoring", action: "Incident ack, unack, snooze, end snooze", endpoint: "/api/incidents/ack\\|unack\\|snooze", scopes: ["monitor:admin"], modes: [.nativeT1]),
        ParityMatrixRow(page: "Monitoring", action: "Maintenance window start now (presets)", endpoint: "POST /api/maintenance-windows {name, node_ids or group_ids, starts_at, ends_at, reason?}", scopes: ["monitor:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Monitoring", action: "Maintenance window end", endpoint: "POST /api/maintenance-windows (full window, ends_at now)", scopes: ["monitor:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Monitoring", action: "Maintenance window delete", endpoint: "POST /api/maintenance-windows/delete", scopes: ["monitor:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Monitoring", action: "Maintenance window edit", endpoint: "POST /api/maintenance-windows", scopes: ["monitor:admin"], modes: [.web]),
        ParityMatrixRow(page: "Approvals", action: "Approve and apply", endpoint: "POST /api/network/approvals/approve queue_apply:true", scopes: ["network:apply"], modes: [.nativeDecision]),
        ParityMatrixRow(page: "Approvals", action: "Approve without applying", endpoint: "same, queue_apply:false", scopes: ["network:apply"], modes: [.nativeDecision]),
        ParityMatrixRow(page: "Approvals", action: "Reject", endpoint: "POST /api/network/approvals/reject", scopes: ["network:apply"], modes: [.nativeDecision]),
        ParityMatrixRow(page: "Approvals", action: "Dismiss", endpoint: "POST /api/network/approvals/dismiss {approval_id, note}", scopes: ["network:apply"], modes: [.nativeDecision]),
        ParityMatrixRow(page: "Approvals", action: "Batch approve or reject", endpoint: "the same endpoints per id", scopes: ["network:apply"], modes: [.nativeDecision]),
        ParityMatrixRow(page: "Approvals", action: "Replan stale agent update", endpoint: "POST /api/nodes/agent-updates/plan", scopes: ["node:admin", "network:plan"], modes: [.nativePlan]),
        ParityMatrixRow(page: "Tasks", action: "Create script task", endpoint: "POST /api/tasks", scopes: ["task:run"], modes: [.web]),
        ParityMatrixRow(page: "Tasks", action: "Rerun", endpoint: "POST /api/tasks/rerun", scopes: ["task:run"], modes: [.nativeT3]),
        ParityMatrixRow(page: "Tasks", action: "Rerun one node", endpoint: "POST /api/tasks/rerun-node {id, node_id}", scopes: ["task:run"], modes: [.nativeT3]),
        ParityMatrixRow(page: "Tasks", action: "Cancel", endpoint: "POST /api/tasks/cancel", scopes: ["task:run"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Tasks", action: "Delete", endpoint: "POST /api/tasks/delete", scopes: ["task:run"], modes: [.nativeT4]),
        ParityMatrixRow(page: "Tasks", action: "Reveal script", endpoint: "POST /api/tasks/reveal-script", scopes: ["task:read"], modes: [.nativeStepUp]),
        ParityMatrixRow(page: "Terminal", action: "Create session", endpoint: "POST /api/terminal/sessions", scopes: ["terminal:open"], modes: [.web]),
        ParityMatrixRow(page: "Terminal", action: "Type, resize, attach", endpoint: "/input, /resize, WebSocket /attach", scopes: ["terminal:open"], modes: [.web]),
        ParityMatrixRow(page: "Terminal", action: "Close session", endpoint: "POST /api/terminal/sessions/{id}/close", scopes: ["terminal:open"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Audit", action: "Verify chain", endpoint: "GET /api/audit/verify", scopes: ["audit:read"], modes: [.native]),
        ParityMatrixRow(page: "Audit", action: "Export CSV, NDJSON, head", endpoint: "built on device from /api/audit", scopes: ["audit:read"], modes: [.native]),
        ParityMatrixRow(page: "Outbound policy", action: "Group policy upsert or delete", endpoint: "POST /api/group-policies[/delete]", scopes: ["netpolicy:admin"], modes: [.web]),
        ParityMatrixRow(page: "Outbound policy", action: "Plan all group policies", endpoint: "POST /api/group-policies/plan {}", scopes: ["netpolicy:admin"], modes: [.nativePlan]),
        ParityMatrixRow(page: "Outbound policy", action: "Edit node policy", endpoint: "POST /api/netpolicy", scopes: ["netpolicy:admin"], modes: [.web]),
        ParityMatrixRow(page: "Outbound policy", action: "Plan node policy", endpoint: "POST /api/netpolicy/plan", scopes: ["netpolicy:admin"], modes: [.nativePlan]),
        ParityMatrixRow(page: "Outbound policy", action: "Convert manual policy", endpoint: "POST /api/netpolicy/convert {target_node_id, name?, priority?}", scopes: ["netpolicy:admin"], modes: [.nativeT3, .nativePlan]),
        ParityMatrixRow(page: "Self-host DNS", action: "Deployment upsert or delete", endpoint: "POST /api/dns/deployments[/delete]", scopes: ["dns:admin"], modes: [.web]),
        ParityMatrixRow(page: "Self-host DNS", action: "Plan", endpoint: "POST /api/dns/plan (accept_lockout_risk)", scopes: ["dns:admin"], modes: [.nativePlan]),
        ParityMatrixRow(page: "Self-host DNS", action: "Publish IPs to the provider", endpoint: "POST /api/dns/publish {id}", scopes: ["dns:admin"], modes: [.nativeT3]),
        ParityMatrixRow(page: "Self-host DNS", action: "Measure certificate", endpoint: "POST /api/dns/measure-cert", scopes: ["dns:admin", "monitor:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "DDNS", action: "Save profile", endpoint: "POST /api/ddns", scopes: ["ddns:admin"], modes: [.web]),
        ParityMatrixRow(page: "DDNS", action: "Delete", endpoint: "POST /api/ddns/delete", scopes: ["ddns:admin"], modes: [.nativeT4]),
        ParityMatrixRow(page: "DDNS", action: "Run now", endpoint: "POST /api/ddns/run", scopes: ["ddns:admin"], modes: [.nativeT3]),
        ParityMatrixRow(page: "Geo-Routing", action: "Upsert", endpoint: "POST /api/geo-routing", scopes: ["geo:admin"], modes: [.web]),
        ParityMatrixRow(page: "Geo-Routing", action: "Delete", endpoint: "POST /api/geo-routing/delete", scopes: ["geo:admin"], modes: [.nativeT4]),
        ParityMatrixRow(page: "Geo-Routing", action: "Preview config", endpoint: "POST /api/geo-routing/plan (preview)", scopes: ["geo:read"], modes: [.native]),
        ParityMatrixRow(page: "Tunnels", action: "Create", endpoint: "POST /api/tunnels", scopes: ["tunnel:admin"], modes: [.web]),
        ParityMatrixRow(page: "Tunnels", action: "Delete", endpoint: "POST /api/tunnels/delete", scopes: ["tunnel:admin"], modes: [.nativeT4]),
        ParityMatrixRow(page: "Tunnels", action: "Plan", endpoint: "POST /api/tunnels/plan", scopes: ["tunnel:admin"], modes: [.nativePlan]),
        ParityMatrixRow(page: "SSH Guard", action: "Arm", endpoint: "POST /api/sshguard/plan {node_id, ssh_port, enable_knock?, mgmt_sources?, confirm_window_sec?, out_of_band_fallback?, accept_findings?}", scopes: ["sshguard:admin", "network:plan"], modes: [.nativePlan]),
        ParityMatrixRow(page: "SSH Guard", action: "Confirm (cancels automatic revert)", endpoint: "POST /api/sshguard/confirm", scopes: ["sshguard:admin", "network:plan"], modes: [.nativePlan]),
        ParityMatrixRow(page: "SSH Guard", action: "Reveal knock sequence", endpoint: "POST /api/sshguard/knock/reveal", scopes: ["sshguard:read", "network:plan"], modes: [.nativeStepUp]),
        ParityMatrixRow(page: "SSH Guard", action: "Rotate knock", endpoint: "knock state POST /api/sshguard/knock, S reveal of the digest when needed, then POST /api/sshguard/plan with rotate_from_sha256", scopes: ["sshguard:admin", "network:plan"], modes: [.nativePlan, .nativeStepUp]),
        ParityMatrixRow(page: "SSH Guard", action: "Exclude a node via capability", endpoint: "POST /api/nodes/capabilities", scopes: ["node:admin"], modes: [.nativeT3]),
        ParityMatrixRow(page: "Plugins", action: "Lifecycle activate or disable", endpoint: "POST /api/plugins/lifecycle", scopes: ["plugin:admin"], modes: [.nativeT3]),
        ParityMatrixRow(page: "Plugins", action: "Lifecycle verified to installed", endpoint: "POST /api/plugins/lifecycle", scopes: ["plugin:admin"], modes: [.web]),
        ParityMatrixRow(page: "Plugins", action: "Verify uploaded bundle", endpoint: "POST /api/plugins/verify", scopes: ["plugin:verify"], modes: [.web]),
        ParityMatrixRow(page: "Publishing", action: "Delete binding", endpoint: "POST /api/storage/bindings/delete", scopes: ["kv:write", "static:write"], modes: [.nativeT4]),
        ParityMatrixRow(page: "Publishing", action: "Revoke storage token", endpoint: "POST /api/storage/tokens/revoke", scopes: ["kv:write", "static:write"], modes: [.nativeT4]),
        ParityMatrixRow(page: "Publishing", action: "Share create", endpoint: "POST /api/subscription-shares", scopes: ["proxy:admin"], modes: [.web]),
        ParityMatrixRow(page: "Publishing", action: "Share edit expiry or interval", endpoint: "PATCH /api/subscription-shares/{id}", scopes: ["proxy:admin"], modes: [.web]),
        ParityMatrixRow(page: "Publishing", action: "Share rotate", endpoint: "POST /api/subscription-shares/{id}/rotate", scopes: ["proxy:admin"], modes: [.nativeT3]),
        ParityMatrixRow(page: "Publishing", action: "Share refresh", endpoint: "POST /api/subscription-shares/{id}/refresh", scopes: ["proxy:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Publishing", action: "Share delete", endpoint: "DELETE /api/subscription-shares/{id}", scopes: ["proxy:admin"], modes: [.nativeT4]),
        ParityMatrixRow(page: "Publishing", action: "Reveal share URL", endpoint: "POST /api/subscription-shares/{id}/reveal", scopes: ["proxy:admin"], modes: [.nativeStepUp]),
        ParityMatrixRow(page: "Publishing", action: "Create bucket, binding, token", endpoint: "/api/storage/{buckets,bindings,tokens}", scopes: [], modes: [.web]),
        ParityMatrixRow(page: "Store", action: "Put KV entry or static object", endpoint: "POST /api/kv, /api/static", scopes: ["kv:write", "static:write"], modes: [.web]),
        ParityMatrixRow(page: "Store", action: "Delete entry", endpoint: "/api/kv/delete, /api/static/delete", scopes: ["kv:write", "static:write"], modes: [.web]),
        ParityMatrixRow(page: "Evidence", action: "Start capture session", endpoint: "POST /api/trace/sessions {name, filter, level, ttl_seconds}", scopes: ["log:read"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Evidence", action: "Stop capture session", endpoint: "POST /api/trace/sessions/stop", scopes: ["log:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Evidence", action: "Trace policy", endpoint: "/api/trace/policy", scopes: ["log:admin"], modes: [.web]),
        ParityMatrixRow(page: "Evidence", action: "Log sources", endpoint: "/api/logs/sources[/delete]", scopes: ["log:admin"], modes: [.web]),
        ParityMatrixRow(page: "Evidence", action: "Evidence budgets", endpoint: "/api/evidence/settings", scopes: ["*"], modes: [.web]),
        ParityMatrixRow(page: "Notifications", action: "Channel upsert", endpoint: "POST /api/notify/channels", scopes: ["notify:admin"], modes: [.web]),
        ParityMatrixRow(page: "Notifications", action: "Channel delete", endpoint: "POST /api/notify/channels/delete", scopes: ["notify:admin"], modes: [.nativeT4]),
        ParityMatrixRow(page: "Notifications", action: "Channel test", endpoint: "POST /api/notify/channels/test", scopes: ["notify:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Notifications", action: "Test send", endpoint: "POST /api/notify/test", scopes: ["notify:send"], modes: [.web]),
        ParityMatrixRow(page: "Notifications", action: "Rule upsert or delete", endpoint: "/api/notify/rules[/delete]", scopes: ["notify:admin"], modes: [.web]),
        ParityMatrixRow(page: "Notifications", action: "Witness plan", endpoint: "POST /api/notify/witness/plan", scopes: ["notify:admin"], modes: [.nativePlan]),
        ParityMatrixRow(page: "Webhooks", action: "Create, edit, rotate secret", endpoint: "/api/notify/webhooks[/rotate]", scopes: ["notify:admin"], modes: [.web]),
        ParityMatrixRow(page: "Webhooks", action: "Delete", endpoint: "POST /api/notify/webhooks/delete", scopes: ["notify:admin"], modes: [.nativeT4]),
        ParityMatrixRow(page: "Webhooks", action: "Test", endpoint: "POST /api/notify/webhooks/test", scopes: ["notify:admin"], modes: [.nativeT2]),
        ParityMatrixRow(page: "Agent Updates", action: "Policy upsert or delete", endpoint: "/api/nodes/agent-updates[/delete]", scopes: ["node:admin"], modes: [.web]),
        ParityMatrixRow(page: "Agent Updates", action: "Plan one node or all behind", endpoint: "POST /api/nodes/agent-updates/plan {node_id, force} per node", scopes: ["node:admin", "network:plan"], modes: [.nativePlan]),
        ParityMatrixRow(page: "Agent Updates", action: "Artifacts import or delete", endpoint: "/api/nodes/agent-updates/artifacts/*", scopes: ["node:admin"], modes: [.web]),
        ParityMatrixRow(page: "Agent Updates", action: "Mirror plan", endpoint: "POST /api/nodes/agent-updates/mirrors/plan", scopes: ["node:admin", "network:plan"], modes: [.web]),
        ParityMatrixRow(page: "Security", action: "Change password", endpoint: "POST /api/auth/password", scopes: [], modes: [.web]),
        ParityMatrixRow(page: "Security", action: "TOTP enroll, activate, disable", endpoint: "/api/2fa/totp/*", scopes: [], modes: [.web]),
        ParityMatrixRow(page: "Security", action: "Passkey add", endpoint: "/api/security/webauthn/register/*", scopes: [], modes: [.web]),
        ParityMatrixRow(page: "Security", action: "Passkey rename", endpoint: "/api/security/webauthn/credentials/rename", scopes: [], modes: [.nativeT2]),
        ParityMatrixRow(page: "Security", action: "Passkey delete", endpoint: "/api/security/webauthn/credentials/delete", scopes: [], modes: [.nativeT4, .nativeStepUp]),
        ParityMatrixRow(page: "Capability Gates", action: "Toggle enforced", endpoint: "POST /api/capabilities", scopes: ["node:admin"], modes: [.nativeT3]),
        ParityMatrixRow(page: "Access", action: "User create, update, delete", endpoint: "/api/users[/update\\|/delete]", scopes: ["user:admin"], modes: [.web]),
        ParityMatrixRow(page: "Access", action: "Token create", endpoint: "POST /api/tokens", scopes: ["token:admin"], modes: [.web]),
        ParityMatrixRow(page: "Access", action: "Token revoke", endpoint: "POST /api/tokens/revoke", scopes: ["token:admin"], modes: [.nativeT4]),
        ParityMatrixRow(page: "Access", action: "Token delete", endpoint: "POST /api/tokens/delete", scopes: ["token:admin"], modes: [.nativeT4]),
        ParityMatrixRow(page: "Access", action: "OIDC provider upsert, delete, test", endpoint: "/api/auth/oidc/providers[/delete\\|/test]", scopes: ["oidc:admin"], modes: [.web]),
        ParityMatrixRow(page: "Login", action: "Password plus TOTP, PAT, sign out", endpoint: "/api/login, /api/login/totp, /api/logout", scopes: [], modes: [.native]),
        // Section 3.3, vpn-core user links.
        ParityMatrixRow(page: "vpn-core Users", action: "Reveal subscription link", endpoint: "POST /api/vpn/users/{id}/link/reveal", scopes: ["vpncore:admin"], modes: [.nativeStepUp]),
        ParityMatrixRow(page: "vpn-core Users", action: "Reveal credentials", endpoint: "POST /api/proxy/users/reveal-credentials", scopes: ["proxy:admin"], modes: [.nativeStepUp]),
        ParityMatrixRow(page: "vpn-core Users", action: "Rotate subscription link", endpoint: "POST /api/vpn/users/{id}/link/rotate", scopes: ["vpncore:admin"], modes: [.nativeT3]),
        ParityMatrixRow(page: "vpn-core Users", action: "Revoke subscription link", endpoint: "DELETE /api/vpn/users/{id}/link", scopes: ["vpncore:admin"], modes: [.nativeT4]),
        ParityMatrixRow(page: "vpn-core Users", action: "Create, bind, cutover", endpoint: "POST /api/plugins/call", scopes: ["vpncore:admin"], modes: [.web]),
    ]

    public static var nativeRows: [ParityMatrixRow] { rows.filter(\.isNative) }
}

/// A suggested token for the console's token form (F-05).
public struct TokenPreset: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var scopes: [String]
    /// A warning shown with the preset, if any.
    public var warning: String?

    public init(id: String, title: String, scopes: [String], warning: String? = nil) {
        self.id = id
        self.title = title
        self.scopes = scopes
        self.warning = warning
    }

    /// The scopes as one copyable line, comma separated.
    public var copyText: String { scopes.joined(separator: ",") }
}

/// The three presets of section 6.12, derived from the parity matrix.
public enum TokenPresets {
    /// Scopes no preset carries, and which the phone must never hold by default.
    public static let deliberatelyExcluded: Set<String> = [
        "token:admin", "user:admin", "plugin:admin", "oidc:admin", "notify:send", "secrets:reveal",
    ]

    public static let triage = TokenPreset(
        id: "triage",
        title: "Triage",
        scopes: [
            "node:read", "group:read", "inventory:read", "monitor:read", "monitor:admin",
            "audit:read", "task:read", "netpolicy:read", "geo:read", "log:read",
        ]
    )

    public static let `operator` = TokenPreset(
        id: "operator",
        title: "Operator",
        scopes: triage.scopes + [
            "network:plan", "network:apply", "node:admin", "group:admin", "sshguard:admin",
            "inventory:admin", "ddns:admin", "dns:admin", "geo:admin", "tunnel:admin",
            "netpolicy:admin", "netguard:read", "notify:admin", "proxy:read", "proxy:admin",
            "log:admin", "kv:read", "kv:write", "static:read", "static:write",
        ]
    )

    public static let operatorPlusRoot = TokenPreset(
        id: "operator-root",
        title: "Operator plus root",
        scopes: `operator`.scopes + ["task:run", "terminal:open"],
        warning: "This token can run scripts as root on every node it can see and open root shells through the API."
    )

    public static let all: [TokenPreset] = [triage, TokenPresets.operator, operatorPlusRoot]

    /// Scopes some native parity row needs that no preset or exclusion covers.
    /// A check asserts this is empty. Coverage is evaluated as the server
    /// does, so `sshguard:read` is covered by `sshguard:admin`. A row that
    /// needs `*` (System) is for a full administrator, never a preset.
    public static func uncoveredScopes(rows: [ParityMatrixRow] = ParityMatrix.nativeRows) -> Set<String> {
        let held = ScopeSet(scopes: operatorPlusRoot.scopes)
        let needed = Set(rows.flatMap(\.scopes)).subtracting(["*"])
        return needed.filter { !held.allows($0) && !deliberatelyExcluded.contains($0) }
    }
}
