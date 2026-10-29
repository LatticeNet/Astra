import Foundation

/// The SSH Guard writes (section 3.2): arm and rotate are plan filings with
/// the findings loop, confirm is a plan filing, exclusion is a T3 capability
/// write through M2's `fleetDecideCapability`. Reveals are in `knockReveal`.
public enum SSHGuardIntents {
    public static let planScopes = ["sshguard:admin", "network:plan"]
    public static let acceptFindingsID = "accept_findings"

    static let acceptFindings = ConfirmToggle(
        id: acceptFindingsID,
        label: "Accept findings",
        consequence: "Files the plan even though the server flagged the problems above. The acceptance is recorded in the audit log.",
        revealedByConflict: true
    )

    /// Files an arm plan. `accept_findings` is added only when the operator
    /// ticked the toggle on the findings step.
    public static func arm(_ node: ObjectRef, form: SSHGuardRotation.Form) -> WriteIntent {
        let request = SSHGuardRotation.planRequest(form)
        return WriteIntent(
            tier: .plan,
            verb: "Arm SSH Guard on",
            object: node,
            scopes: planScopes,
            consequence: armConsequence(node: node, request: request),
            affected: [node],
            toggles: [acceptFindings],
            changes: [.approvals, .sshguard],
            perform: { client, choices in
                try await file(request.accepting(choices.isAccepted(acceptFindingsID)), node: node, client: client)
            }
        )
    }

    /// Files a rotation: an arm that keeps the current sequence alive beside
    /// a new one until the confirm applies.
    public static func rotate(_ node: ObjectRef, request: SSHGuardPlanRequest) -> WriteIntent {
        WriteIntent(
            tier: .plan,
            verb: "Rotate knock sequence on",
            object: node,
            scopes: planScopes,
            consequence: "Files an arm plan that draws a new knock sequence on the server. The current sequence keeps opening \(node.name) until the confirm applies, within \(windowWords(request.confirmWindowSec ?? SSHGuardRotation.rotationConfirmWindowSec)) of the arm applying.",
            affected: [node],
            toggles: [acceptFindings],
            changes: [.approvals, .sshguard],
            perform: { client, choices in
                try await file(request.accepting(choices.isAccepted(acceptFindingsID)), node: node, client: client)
            }
        )
    }

    /// Files the confirm plan. Callers open `actionable_approval_id` in
    /// Review instead when the status names one (`SSHGuardConfirmTarget`).
    public static func confirm(_ node: ObjectRef, deadline: Date?) -> WriteIntent {
        WriteIntent(
            tier: .plan,
            verb: "Confirm SSH Guard on",
            object: node,
            scopes: planScopes,
            consequence: "Files the confirm plan, whose only effect is to cancel the automatic revert. It must be approved and applied before the deadline\(deadline == nil ? "" : " shown above"), or \(node.name) undoes the hardening by itself.",
            affected: [node],
            changes: [.approvals, .sshguard],
            perform: { client, _ in
                let answer = try await client.sshGuardConfirm(nodeID: node.id)
                return .filed(approvalIDs: [answer.approval.id], refused: [], notes: ["Filed the confirm plan for \(node.name)"])
            }
        )
    }

    /// Excludes the node from SSH Guard through its capability record.
    public static func exclude(_ node: ObjectRef, reason: String = "Excluded from SSH Guard on iPhone") -> WriteIntent {
        WriteIntent(
            tier: .t3,
            verb: "Exclude from SSH Guard",
            object: node,
            scopes: ["node:admin"],
            consequence: "SSH Guard can no longer plan for \(node.name): new arm plans are refused. What is already applied on the node stays, and a running revert timer still needs its confirm.",
            affected: [node],
            idempotent: true,
            changes: [.sshguard, .nodes, .gates],
            perform: { client, _ in
                _ = try await client.fleetDecideCapability(FleetCapabilityDecisionRequest(nodeID: node.id, capability: "sshguard", state: "excluded", reason: reason))
                return .done("Excluded \(node.name) from SSH Guard")
            }
        )
    }

    /// Reveals the knock sequence on the session with a step-up grant. The
    /// digest is handed to `capture` so a rotation can name the installed
    /// sequence; the ports stay in the one-time step.
    public static func knockReveal(_ node: ObjectRef, capture: (@Sendable (String) -> Void)? = nil) -> RevealIntent {
        RevealIntent(purpose: .knockSequence, object: node, scopes: ["sshguard:read", "network:plan"]) { client, grant in
            let reveal = try await client.sshGuardRevealKnock(nodeID: node.id, grant: grant)
            capture?(reveal.sequenceSHA256)
            return RevealedSecret(title: "Knock sequence", value: reveal.shownValue)
        }
    }

    static func file(_ request: SSHGuardPlanRequest, node: ObjectRef, client: LatticeClient) async throws -> WriteOutcome {
        let answer = try await client.sshGuardPlan(request)
        let warnings = answer.findings.filter { !$0.isBlocking }.map(\.message)
        let filed = request.isRotation ? "Filed the rotation plan for \(node.name)" : "Filed the arm plan for \(node.name)"
        return .filed(approvalIDs: answer.filedApprovalIDs, refused: [], notes: [filed] + warnings)
    }

    static func armConsequence(node: ObjectRef, request: SSHGuardPlanRequest) -> String {
        let window = windowWords(request.confirmWindowSec ?? SSHGuardRotation.defaultConfirmWindowSec)
        return "Files an arm plan that hardens sshd on \(node.name) and starts a revert timer. Nothing changes until the plan is approved; once it applies, \(node.name) undoes every change by itself unless a confirm applies within \(window)."
    }

    /// "15 minutes", "1 hour".
    public static func windowWords(_ seconds: Int) -> String {
        if seconds % 3600 == 0 {
            let hours = seconds / 3600
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        let minutes = Int((Double(seconds) / 60).rounded(.up))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
