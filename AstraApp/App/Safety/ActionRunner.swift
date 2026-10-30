import SwiftUI

/// A place that can present a write's gate: RootTabs, or the root of a sheet
/// (whose gates push onto that sheet's own stack).
struct ActionHostID: Hashable, Sendable {
    let id = UUID()
    let isSheet: Bool
}

/// A T2 write waiting for its confirmation dialog.
struct PendingDialog: Identifiable {
    let id = UUID()
    let host: ActionHostID
    let intent: WriteIntent
}

/// A T3, T4 or plan write waiting in its ConfirmSheet or ConfirmPage.
struct PendingConfirm: Identifiable {
    let id = UUID()
    let host: ActionHostID
    let intent: WriteIntent
    let client: LatticeClient
}

/// A reveal waiting in its RevealFlow.
struct PendingReveal: Identifiable {
    let id = UUID()
    let host: ActionHostID
    let intent: RevealIntent
}

/// Runs every write and every reveal (sections 6.5 and 8.3). It presents the
/// tier's gate in the topmost action host, drives `WriteFlow`, then reports
/// the outcome with the banner and a haptic and bumps the ChangeLog.
@MainActor @Observable
final class ActionRunner {
    /// True while a write, reveal or decision is in flight; deep links and
    /// `Router.present` wait for it.
    private(set) var isBusy = false
    private(set) var pendingDialog: PendingDialog?
    private(set) var pendingConfirm: PendingConfirm?
    private(set) var pendingReveal: PendingReveal?
    private(set) var haptic: HapticPulse?
    /// The `-AstraAuth` stub. It is read per call and only while the session
    /// is in demo, so leaving demo puts Face ID back on every gate.
    var demoAuthenticator: IntentAuth?
    var authenticator: IntentAuth {
        session.isDemo ? (demoAuthenticator ?? .device) : .device
    }
    /// Opens filed approvals in Review (one) or BatchReview (several); set by the shell.
    @ObservationIgnored var openFiled: ((_ approvalIDs: [String], _ refused: [ObjectFailure]) -> Void)?

    private var hosts: [ActionHostID] = []
    @ObservationIgnored private var dialogContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var confirmContinuation: CheckedContinuation<WriteOutcome?, Never>?
    @ObservationIgnored private var revealContinuation: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var idleActions: [@MainActor () -> Void] = []

    private let session: SessionStore
    private let changes: ChangeLog
    private let banner: BannerCenter
    private let network: NetworkMonitor

    init(session: SessionStore, changes: ChangeLog, banner: BannerCenter, network: NetworkMonitor) {
        self.session = session
        self.changes = changes
        self.banner = banner
        self.network = network
    }

    /// The outcome a cancelled confirmation returns. Nothing was sent.
    static let cancelled = WriteOutcome.refused(.notSent("Cancelled"), "Cancelled")

    // MARK: Hosts

    func register(_ host: ActionHostID) {
        hosts.removeAll { $0 == host }
        hosts.append(host)
    }

    func unregister(_ host: ActionHostID) {
        hosts.removeAll { $0 == host }
        if pendingConfirm?.host == host { finishConfirm(nil) }
        if pendingDialog?.host == host { answerDialog(false) }
        if pendingReveal?.host == host { finishReveal() }
    }

    private var topHost: ActionHostID? { hosts.last }

    /// Runs `action` now, or when the current write finishes.
    func whenIdle(_ action: @escaping @MainActor () -> Void) {
        if isBusy { idleActions.append(action) } else { action() }
    }

    // MARK: Writes

    /// Presents the tier's gate, performs the write, and reports the outcome.
    @discardableResult
    func run(_ intent: WriteIntent) async -> WriteOutcome {
        if !network.isSatisfied {
            return report(.refused(.notSent("No connection"), "No connection. \(intent.title) was not sent."), intent: intent)
        }
        guard let client = session.client(for: intent.client) else {
            let message = intent.client == .session ? "Needs a signed-in session." : "Not connected to a server."
            return report(.refused(.notSent(message), message), intent: intent)
        }
        if let missing = session.missing(intent.requirement, on: intent.client), !missing.isEmpty {
            let scope = missing.joined(separator: ", ")
            return report(.refused(.forbidden(scope: scope), "Needs \(scope)."), intent: intent)
        }
        guard !isBusy, let host = topHost else { return Self.cancelled }
        isBusy = true
        defer { becomeIdle() }

        let outcome: WriteOutcome?
        switch intent.tier {
        case .t1:
            outcome = await commitDirectly(intent, client: client)
        case .t2:
            pendingDialog = PendingDialog(host: host, intent: intent)
            autoConfirmDialogIfAsked()
            let confirmed = await withCheckedContinuation { dialogContinuation = $0 }
            outcome = confirmed ? await commitDirectly(intent, client: client) : nil
        case .t3, .t4, .plan:
            pendingConfirm = PendingConfirm(host: host, intent: intent, client: client)
            outcome = await withCheckedContinuation { confirmContinuation = $0 }
        }
        guard let outcome else { return Self.cancelled }
        return report(outcome, intent: intent)
    }

    /// `-AstraAutoConfirm YES` (demo only) confirms the first T2 dialog of the
    /// launch once it has been on screen, so after-states can be captured. The
    /// ConfirmSheet does the same for T3, T4 and plans.
    @ObservationIgnored private var dialogAutoConfirmed = false

    private func autoConfirmDialogIfAsked() {
        guard LaunchOverrides.current.autoConfirm, session.isDemo, !dialogAutoConfirmed, let dialog = pendingDialog else { return }
        dialogAutoConfirmed = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, self.pendingDialog?.id == dialog.id else { return }
            self.answerDialog(true)
        }
    }

    /// Called by the T2 dialog.
    func answerDialog(_ confirmed: Bool) {
        pendingDialog = nil
        dialogContinuation?.resume(returning: confirmed)
        dialogContinuation = nil
    }

    /// Called by the ConfirmSheet or ConfirmPage when it closes; nil means cancelled.
    func finishConfirm(_ outcome: WriteOutcome?) {
        pendingConfirm = nil
        confirmContinuation?.resume(returning: outcome)
        confirmContinuation = nil
    }

    private func commitDirectly(_ intent: WriteIntent, client: LatticeClient) async -> WriteOutcome? {
        switch await WriteFlow(intent: intent, client: client, authenticator: authenticator).commit(choices: ConfirmChoices()) {
        case .finished(let outcome): outcome
        case .cancelled: nil
        case .authenticationFailed(let message): .refused(.notSent(message), message)
        case .dryRunChanged: .refused(.notSent("What would change is different now. Review again."), "What would change is different now. Review again.")
        }
    }

    /// Records the change, plays the haptic, and shows the banner.
    @discardableResult
    private func report(_ outcome: WriteOutcome, intent: WriteIntent) -> WriteOutcome {
        changes.record(intent.changes)
        haptic = HapticPulse(event: .outcome(outcome, tier: intent.tier))
        if case .refused(.forbidden, _) = outcome { session.noteForbidden() }
        var message = BannerMessage(text: outcome.message, tone: Self.tone(for: outcome))
        switch outcome {
        case .done:
            if let inverse = intent.inverse {
                message.undo = { [weak self] in
                    Task { await self?.runInverse(inverse()) }
                }
            }
        case .filed(let ids, let refused, _):
            if !ids.isEmpty { openFiled?(ids, refused) }
        default:
            break
        }
        banner.show(message)
        return outcome
    }

    /// Undo inherits the inverse's tier: T1 and T2 run from the banner without
    /// another dialog; T3 and T4 authenticate first (section 6.6).
    private func runInverse(_ intent: WriteIntent) async {
        guard !isBusy, let client = session.client(for: intent.client) else { return }
        isBusy = true
        defer { becomeIdle() }
        let flow = WriteFlow(intent: intent, client: client, authenticator: authenticator)
        switch await flow.commit(choices: ConfirmChoices()) {
        case .finished(let outcome):
            changes.record(intent.changes)
            haptic = HapticPulse(event: .outcome(outcome, tier: intent.tier == .t1 ? .t1 : .t2))
            banner.show(BannerMessage(text: outcome.message, tone: Self.tone(for: outcome)))
        case .authenticationFailed(let message):
            banner.show(BannerMessage(text: message, tone: .warn))
        case .cancelled, .dryRunChanged:
            break
        }
    }

    private static func tone(for outcome: WriteOutcome) -> StatusTone {
        switch outcome {
        case .done: .quiet
        case .filed(_, let refused, _): refused.isEmpty ? .quiet : .warn
        case .partial, .unknown: .warn
        case .refused: .fail
        }
    }

    private func becomeIdle() {
        isBusy = false
        let actions = idleActions
        idleActions = []
        actions.forEach { $0() }
    }

    // MARK: Reveals

    /// Opens the RevealFlow (code step, then value step). The revealed value
    /// never leaves the sheet.
    func reveal(_ intent: RevealIntent) async {
        guard !isBusy, let host = topHost else { return }
        if !network.isSatisfied {
            banner.show(BannerMessage(text: "No connection. Nothing was revealed.", tone: .warn))
            return
        }
        isBusy = true
        defer { becomeIdle() }
        pendingReveal = PendingReveal(host: host, intent: intent)
        await withCheckedContinuation { revealContinuation = $0 }
    }

    func finishReveal() {
        pendingReveal = nil
        revealContinuation?.resume()
        revealContinuation = nil
    }

    // MARK: Decisions

    /// Decisions (D) run in `DecisionFlow`, not here, but they hold the
    /// runner busy so deep links and sheets wait for them (section 6.1, step 13).
    func beginDecision() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    func endDecision(haptic event: HapticEvent?) {
        if let event { haptic = HapticPulse(event: event) }
        becomeIdle()
    }
}
