import Foundation

/// Confirms approval decisions. The app's `IntentAuth` conforms (as it does
/// to `WriteAuthenticator`); checks inject a stub so a cancelled confirmation
/// is proven to send zero requests (section 6.1).
public protocol DecisionAuthenticator: Sendable {
    func authenticate(reason: String) async -> DeviceAuthOutcome
}

/// The three decisions an operator makes on an approval (tier D).
public enum ApprovalsDecision: Sendable, Hashable {
    case approve(queueApply: Bool)
    case reject
    case dismiss(note: String)

    /// The status a decision moves a pending approval to.
    public var requestedStatus: String {
        switch self {
        case .approve: "approved"
        case .reject: "rejected"
        case .dismiss: "dismissed"
        }
    }

    public var verb: String {
        switch self {
        case .approve: "Approve"
        case .reject: "Reject"
        case .dismiss: "Dismiss"
        }
    }
}

/// Whether an approval may be decided, and why not (section 6.1, steps 4,
/// 5, 12 and 14). Pure, so the eligibility rules are pinned by checks.
public enum ApprovalsDecisionGate {
    /// The scopes a decision needs that `scopes` lacks: `network:apply` and
    /// the plugin's decision scope on the approval's node. Nil scopes are
    /// unknown, not missing, and block nothing (the server decides).
    public static func missingScopes(_ approval: Approval, scopes: ScopeSet?) -> [String] {
        guard let scopes else { return [] }
        return scopes.missing(ApprovalVisibility.decisionRequirement(for: approval), nodeID: approval.nodeID)
    }

    /// "Deciding needs network:apply and sshguard:admin".
    public static func scopeSentence(_ missing: [String]) -> String {
        "Deciding needs \(VerdictBuilder.listed(missing))"
    }

    /// Why Approve is off, or nil when it may run. A stale row reads as
    /// stale whether it is still pending or the server already retired it.
    /// Without this credential's actor the transition cannot be verified
    /// (step 9), so no decision is offered until `/api/me` has answered.
    public static func approveBlock(_ approval: Approval, hashVerified: Bool, companionBehind: Bool, scopes: ScopeSet?, identityLoaded: Bool = true, inFlight: Bool = false) -> String? {
        if companionBehind { return "This app is behind the server" }
        if approval.isStale && (approval.isPending || ApprovalsTransition.isStaleRetirement(approval)) { return "Stale: inspect only" }
        if !approval.isPending { return "No longer pending" }
        if !hashVerified || !approval.hasPlanBody { return "Plan does not match its hash" }
        let missing = missingScopes(approval, scopes: scopes)
        if !missing.isEmpty { return scopeSentence(missing) }
        if !identityLoaded { return "Identity not loaded" }
        if inFlight { return "A decision is in progress" }
        return nil
    }

    /// Why Reject is off, or nil. Rejecting a plan the phone cannot verify
    /// is safe, so a mismatch does not block it; a stale row is inspect-only.
    public static func rejectBlock(_ approval: Approval, companionBehind: Bool, scopes: ScopeSet?, identityLoaded: Bool = true, inFlight: Bool = false) -> String? {
        if companionBehind { return "This app is behind the server" }
        if approval.isStale && (approval.isPending || ApprovalsTransition.isStaleRetirement(approval)) { return "Stale: inspect only" }
        if !approval.isPending { return "No longer pending" }
        let missing = missingScopes(approval, scopes: scopes)
        if !missing.isEmpty { return scopeSentence(missing) }
        if !identityLoaded { return "Identity not loaded" }
        if inFlight { return "A decision is in progress" }
        return nil
    }

    /// `canDismiss`, as the server enforces it (`handleDismissApproval`) and
    /// the console offers it (`canDismissStale`, `canDismissWaiting`): the
    /// row's `waiting.dismissible` when it carries a waiting record (only
    /// approved rows do), otherwise a stale agent update. A pending SSH
    /// Guard row is never dismissible. Dismissed rows never qualify.
    public static func canDismiss(_ approval: Approval) -> Bool {
        if approval.isDismissed { return false }
        if let waiting = approval.waiting { return waiting.dismissible }
        return approval.isStale && approval.plugin == "agentupdate"
    }

    /// A stale agent-update row may be planned again (P tier) from Review.
    /// The server retires a stale agent update to `rejected` on its next
    /// listing read, so the status does not matter (console `canReplan`).
    public static func canReplan(_ approval: Approval) -> Bool {
        approval.isStale && approval.plugin == "agentupdate" && !approval.nodeID.isEmpty
    }

    /// Why a row of a batch is left out of "Approve all", or nil when it is in.
    public static func batchApproveExclusion(_ approval: Approval, scopes: ScopeSet?, identityLoaded: Bool = true) -> String? {
        approveBlock(approval, hashVerified: approval.planHashMatchesServer, companionBehind: false, scopes: scopes, identityLoaded: identityLoaded)
    }

    /// Why a row of a batch is left out of "Reject all", or nil.
    public static func batchRejectExclusion(_ approval: Approval, scopes: ScopeSet?, identityLoaded: Bool = true) -> String? {
        rejectBlock(approval, companionBehind: false, scopes: scopes, identityLoaded: identityLoaded)
    }

    /// The Face ID reason, which Touch ID devices and the passcode fallback
    /// show: "Approve Apply network policy on relay-fra-1, plan a000…a440".
    public static func authReason(_ decision: ApprovalsDecision, approval: Approval, nodeName: String) -> String {
        let action = ApprovalEvents.title(for: approval)
        let target = nodeName.isEmpty ? "" : " on \(nodeName)"
        switch decision {
        case .approve: return "Approve \(action)\(target), plan \(PlanSeal.short(approval.planSHA256))"
        case .reject: return "Reject \(action)\(target)"
        case .dismiss: return "Dismiss \(action)\(target)"
        }
    }

    /// The batch Face ID reason: "Approve 3 plans: Agent update to 0.3.10".
    /// `title` is the group's name without a count, so the count is said once.
    public static func batchAuthReason(_ decision: ApprovalsDecision, count: Int, title: String) -> String {
        let plans = count == 1 ? "1 plan" : "\(count) plans"
        return "\(decision.verb) \(plans): \(title)"
    }
}

/// Did the server record the transition this credential asked for? The
/// server answers 200 with the unchanged view when the approval was already
/// decided, so the answer alone proves nothing (section 6.1, step 9).
public enum ApprovalsTransition {
    /// The transition landed and names `actorID` as its decider. An empty
    /// actor id proves nothing: callers treat that as unconfirmed, never done.
    public static func verified(_ decision: ApprovalsDecision, before: Approval, after: Approval, actorID: String) -> Bool {
        let sameActor: (String) -> Bool = { recorded in !actorID.isEmpty && recorded == actorID }
        switch decision {
        case .approve:
            return landed(decision, before: before, after: after) && sameActor(after.approvedBy)
        case .reject:
            return landed(decision, before: before, after: after) && sameActor(after.rejectedBy)
        case .dismiss:
            return landed(decision, before: before, after: after)
        }
    }

    /// The transition landed, whoever made it.
    public static func landed(_ decision: ApprovalsDecision, before: Approval, after: Approval) -> Bool {
        switch decision {
        case .approve:
            // An apply that already ran or already failed still shows who approved it.
            let state = after.isApproved || after.status == "applied" || (after.isRejected && after.rejectedBy.isEmpty)
            return before.isPending && state && !after.approvedBy.isEmpty
        case .reject:
            return before.isPending && after.isRejected && !after.rejectedBy.isEmpty
        case .dismiss:
            // The view names no dismisser; the transition is ours when this
            // read saw it undismissed.
            return !before.isDismissed && after.isDismissed
        }
    }

    /// The server retired this agent update as stale: it writes `rejected`
    /// with the stale reason and neither `approved_by` nor `rejected_by`
    /// (`rejectAgentUpdateApprovalWithReason`). Nobody decided it.
    public static func isStaleRetirement(_ approval: Approval) -> Bool {
        approval.isRejected && approval.rejectedBy.isEmpty && approval.approvedBy.isEmpty && approval.isStale
    }

    /// Who decided the approval as it now stands, for "already decided by".
    public static func decider(_ approval: Approval) -> String {
        if isStaleRetirement(approval) { return "Lattice" }
        if approval.isRejected, !approval.rejectedBy.isEmpty { return approval.rejectedBy }
        if !approval.approvedBy.isEmpty { return approval.approvedBy }
        return "another operator"
    }

    /// The status word a person reads ("rejected", "approved", "applied").
    public static func statusWord(_ approval: Approval) -> String {
        if isStaleRetirement(approval) { return "retired as stale (the agent update policy changed)" }
        if approval.isRejected && approval.rejectedBy.isEmpty && !approval.approvedBy.isEmpty { return "approved, then failed to apply," }
        return approval.status.lowercased()
    }

    /// When the approval reached its current state.
    public static func decidedAt(_ approval: Approval) -> Date? {
        approval.rejectedAt ?? approval.updatedAt
    }
}

/// The hash-bound decision sequence of section 6.1, steps 7 to 12:
/// authenticate, send (the approve hash recomputed from the on-screen body
/// at send time), reload by id, and verify the transition. It never retries
/// a decision.
public struct DecisionFlow: Sendable {
    public let client: LatticeClient
    public let authenticator: any DecisionAuthenticator
    public var mode: TimeZoneMode
    public var locale: Locale

    public init(client: LatticeClient, authenticator: any DecisionAuthenticator, mode: TimeZoneMode = .local, locale: Locale = .current) {
        self.client = client
        self.authenticator = authenticator
        self.mode = mode
        self.locale = locale
    }

    /// How one decision ended. `approval` is the reloaded view when there is one.
    public enum Result: Sendable {
        /// Authentication was cancelled: nothing was sent.
        case cancelled
        /// Authentication failed: nothing was sent.
        case authenticationFailed(String)
        case finished(WriteOutcome, approval: Approval?)
    }

    /// Decides one approval. `approval` must be the view loaded by id whose
    /// body is on screen.
    public func decide(_ decision: ApprovalsDecision, on approval: Approval, actorID: String, reason: String) async -> Result {
        if let refusal = Self.precheck(decision, approval) {
            return .finished(refusal, approval: nil)
        }
        switch await authenticator.authenticate(reason: reason) {
        case .cancelled: return .cancelled
        case .failed(let message): return .authenticationFailed(message)
        case .confirmed: break
        }
        let (outcome, reloaded) = await send(decision, on: approval, actorID: actorID)
        return .finished(outcome, approval: reloaded)
    }

    /// How a batch decision ended.
    public enum BatchResult: Sendable {
        case cancelled
        case authenticationFailed(String)
        /// Per-row outcomes keyed by approval id, the reloaded views, and the
        /// summary outcome for the banner and haptic.
        case finished(rows: [String: WriteOutcome], approvals: [String: Approval], summary: WriteOutcome)
    }

    /// One Face ID, then each approval decided with its own `plan_sha256`
    /// and its own transition check, `maxInFlight` at a time (section 6.2).
    public func decideBatch(_ decision: ApprovalsDecision, on approvals: [Approval], actorID: String, reason: String, maxInFlight: Int = 2) async -> BatchResult {
        guard !approvals.isEmpty else { return .finished(rows: [:], approvals: [:], summary: .refused(.validation("Nothing to decide"), "Nothing to decide")) }
        switch await authenticator.authenticate(reason: reason) {
        case .cancelled: return .cancelled
        case .failed(let message): return .authenticationFailed(message)
        case .confirmed: break
        }
        var rows: [String: WriteOutcome] = [:]
        var reloaded: [String: Approval] = [:]
        await withTaskGroup(of: (String, WriteOutcome, Approval?).self) { group in
            var next = 0
            func enqueue() {
                guard next < approvals.count else { return }
                let approval = approvals[next]
                next += 1
                group.addTask {
                    if let refusal = Self.precheck(decision, approval) { return (approval.id, refusal, nil) }
                    let (outcome, view) = await send(decision, on: approval, actorID: actorID)
                    return (approval.id, outcome, view)
                }
            }
            for _ in 0..<max(1, maxInFlight) { enqueue() }
            while let (id, outcome, view) = await group.next() {
                rows[id] = outcome
                if let view { reloaded[id] = view }
                enqueue()
            }
        }
        let summary = Self.batchSummary(decision, approvals: approvals, rows: rows)
        return .finished(rows: rows, approvals: reloaded, summary: summary)
    }

    /// The banner outcome of a batch: green only when every row landed.
    public static func batchSummary(_ decision: ApprovalsDecision, approvals: [Approval], rows: [String: WriteOutcome]) -> WriteOutcome {
        let past = switch decision {
        case .approve: "approved"
        case .reject: "rejected"
        case .dismiss: "dismissed"
        }
        var succeeded: [ObjectRef] = []
        var failed: [ObjectFailure] = []
        // Sent but not confirmed either way: said apart from "not recorded".
        var unconfirmed = 0
        for approval in approvals {
            let object = ObjectRef(kind: "approval", id: approval.id, name: ApprovalEvents.nodeLabel(approval))
            switch rows[approval.id] {
            case .done?: succeeded.append(object)
            case let outcome?:
                if case .unknown = outcome { unconfirmed += 1 }
                failed.append(ObjectFailure(object: object, reason: outcome.message))
            case nil: failed.append(ObjectFailure(object: object, reason: "Not sent"))
            }
        }
        if failed.isEmpty {
            return .done(succeeded.count == 1 ? "1 plan \(past)" : "\(succeeded.count) plans \(past)")
        }
        let notRecorded = failed.count - unconfirmed
        if succeeded.isEmpty {
            if notRecorded == 0 {
                return .unknown(unconfirmed == 1 ? "Sent, but not confirmed: \(failed.first?.reason ?? "")" : "None of the \(unconfirmed) plans could be confirmed")
            }
            let reason = failed.first?.reason ?? "Not recorded"
            return .refused(.validation(reason), failed.count == 1 ? "Not recorded: \(reason)" : "None of the \(failed.count) plans were recorded")
        }
        var parts = ["\(succeeded.count) \(past)"]
        if unconfirmed > 0 { parts.append("\(unconfirmed) could not be confirmed") }
        if notRecorded > 0 { parts.append("\(notRecorded) not recorded") }
        return .partial(succeeded: succeeded, failed: failed, message: parts.joined(separator: ", "))
    }

    // MARK: Steps

    /// Refusals that need no request: a body that does not hash, an empty note.
    static func precheck(_ decision: ApprovalsDecision, _ approval: Approval) -> WriteOutcome? {
        switch decision {
        case .approve:
            do {
                _ = try approval.reviewedPlanSHA256()
            } catch {
                return .refused(.validation("Plan does not match its hash"), "Not sent: the plan does not match its hash. Reload and review again.")
            }
        case .dismiss(let note):
            if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .refused(.validation("A note is required"), "Not sent: write why this plan is dismissed.")
            }
        case .reject:
            break
        }
        return nil
    }

    /// Sends one decision and verifies it. Never retries.
    func send(_ decision: ApprovalsDecision, on approval: Approval, actorID: String) async -> (WriteOutcome, Approval?) {
        do {
            switch decision {
            case .approve(let queueApply):
                // Recomputed from the same on-screen body at send time.
                let hash = try approval.reviewedPlanSHA256()
                _ = try await client.approveApproval(approvalID: approval.id, queueApply: queueApply, planSHA256: hash)
            case .reject:
                _ = try await client.rejectApproval(approvalID: approval.id)
            case .dismiss(let note):
                _ = try await client.dismissApproval(approvalID: approval.id, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } catch is ApprovalReviewError {
            return (.refused(.validation("Plan does not match its hash"), "Not sent: the plan does not match its hash. Reload and review again."), nil)
        } catch {
            return await failure(LatticeAPIError(error), decision: decision, approval: approval, actorID: actorID)
        }
        return await verify(decision, before: approval, actorID: actorID)
    }

    /// Reloads by id and compares the recorded transition with the request.
    func verify(_ decision: ApprovalsDecision, before: Approval, actorID: String) async -> (WriteOutcome, Approval?) {
        guard let after = try? await client.fetchApproval(id: before.id) else {
            return (.unknown("Sent, but the approval could not be reloaded to confirm it. Check it before deciding again."), nil)
        }
        if ApprovalsTransition.verified(decision, before: before, after: after, actorID: actorID) {
            return (.done(Self.successMessage(decision, after: after)), after)
        }
        if actorID.isEmpty, ApprovalsTransition.landed(decision, before: before, after: after) {
            return (.unknown("Sent; this app could not confirm who decided it. The plan is now \(after.status)."), after)
        }
        return (alreadyDecided(after), after)
    }

    func alreadyDecided(_ after: Approval) -> WriteOutcome {
        let who = ApprovalsTransition.decider(after)
        let at = ApprovalsTransition.decidedAt(after)
        let time = at.map { " at \(TimeDisplay.clock($0, mode: mode, locale: locale))" } ?? ""
        let word = ApprovalsTransition.statusWord(after)
        let message = after.isDismissed
            ? "Not recorded: this plan was already dismissed\(time)."
            : "Not recorded: this plan was already \(word) by \(who)\(time)."
        return .refused(.alreadyDecided(status: after.status, by: who, at: at), message)
    }

    func failure(_ error: LatticeAPIError, decision: ApprovalsDecision, approval: Approval, actorID: String) async -> (WriteOutcome, Approval?) {
        switch error {
        case .conflict(let code, let message, _) where code == "approval_stale":
            if case .dismiss = decision {
                return (.refused(.notDismissible, "Not dismissible: approve or reject it."), try? await client.fetchApproval(id: approval.id))
            }
            if case .approve = decision {
                return (.refused(.approvalStale, "This plan changed since you opened it."), try? await client.fetchApproval(id: approval.id))
            }
            return (.refused(.validation(message), message), try? await client.fetchApproval(id: approval.id))
        case .notFound:
            return (.refused(.notFound, "Not found, or not visible to this token"), nil)
        case .forbidden(_, let message):
            return (.refused(.forbidden(scope: nil), message.isEmpty ? "The server refused the decision." : message), nil)
        case .conflict(_, let message, _):
            return (.refused(.validation(message), message), try? await client.fetchApproval(id: approval.id))
        case .server(let status, _, let message) where (400..<500).contains(status):
            return (.refused(.validation(message), message), try? await client.fetchApproval(id: approval.id))
        case .transport(let code) where Self.notSent(code):
            return (.refused(.notSent(error.localizedDescription), "Not sent: \(error.localizedDescription)"), nil)
        default:
            // The request may have landed (a timeout after send, a 5xx after
            // the commit point): read what the server now says instead of
            // retrying, and claim only what the reload proves.
            let (outcome, after) = await verify(decision, before: approval, actorID: actorID)
            if case .done = outcome { return (outcome, after) }
            let state = after.map { " The plan is now \($0.status)." } ?? ""
            return (.unknown("Could not confirm.\(state)"), after)
        }
    }

    static func notSent(_ code: URLError.Code) -> Bool {
        switch code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .badURL:
            true
        default:
            false
        }
    }

    /// Section 6.1, step 9, once the transition is verified.
    public static func successMessage(_ decision: ApprovalsDecision, after: Approval) -> String {
        switch decision {
        case .approve(let queueApply):
            if after.isRejected { return "Approved; the apply failed: \(after.reason)" }
            if after.status == "applied" { return "Approved and applied." }
            if let waiting = after.waiting {
                return waiting.blocked ? "Approved, waiting: \(waiting.reason)" : "Approved, apply in progress: \(waiting.reason)"
            }
            return queueApply ? "Approved and queued." : "Approved; apply not queued."
        case .reject:
            return "Rejected."
        case .dismiss:
            return "Dismissed."
        }
    }
}

public extension LatticeClient {
    /// Loads approvals by id, at most `maxInFlight` at a time (section 6.2).
    func approvalsFetchAll(ids: [String], maxInFlight: Int = 4) async -> [String: Result<Approval, LatticeAPIError>] {
        var results: [String: Result<Approval, LatticeAPIError>] = [:]
        await withTaskGroup(of: (String, Result<Approval, LatticeAPIError>).self) { group in
            var next = 0
            func enqueue() {
                guard next < ids.count else { return }
                let id = ids[next]
                next += 1
                group.addTask {
                    do {
                        return (id, .success(try await fetchApproval(id: id)))
                    } catch {
                        return (id, .failure(LatticeAPIError(error)))
                    }
                }
            }
            for _ in 0..<max(1, maxInFlight) { enqueue() }
            while let (id, result) = await group.next() {
                results[id] = result
                enqueue()
            }
        }
        return results
    }
}
