import Foundation

/// Session step-up for reveals (section 6.4). The grant lives in memory until
/// `expires_at` and is reused for every reveal in that minute; it is never
/// written to disk.
@MainActor @Observable
final class StepUpCoordinator {
    enum Failure: Error, Equatable, LocalizedError {
        /// No usable grant is held: the Code step must run.
        case codeNeeded
        /// No session: the operator must sign in for reveals first.
        case noSession
        /// The current 30 s step already carried a code from this phone.
        case waitForNextCode(secondsLeft: Int)
        /// 401 from step-up. Never signs the session out.
        case wrongCode
        /// 403 from step-up: the account has no authenticator code (F-06).
        case noAuthenticator
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .codeNeeded: "Confirm with your code."
            case .noSession: "Reveals need a signed-in session."
            case .waitForNextCode: "Wait for the next code."
            case .wrongCode: "Wrong code. If you just used this code elsewhere, wait for the next one."
            case .noAuthenticator: "This account has no authenticator code. Set one up on the web first."
            case .refused(let message): message
            }
        }
    }

    private(set) var grant: StepUpGrant?
    /// The TOTP step of the last code this phone sent, for replay protection.
    private(set) var lastSentStep: Int64?
    private let session: SessionStore

    init(session: SessionStore) {
        self.session = session
    }

    /// The held grant when it has more than 5 s left, else `.codeNeeded`.
    func grant(for purpose: StepUpPurpose) async throws -> StepUpGrant {
        if let grant, grant.isUsable(now: Date()) { return grant }
        grant = nil
        throw session.revealClient == nil ? Failure.noSession : Failure.codeNeeded
    }

    /// Whether the Code step can be skipped.
    var holdsUsableGrant: Bool {
        grant?.isUsable(now: Date()) ?? false
    }

    /// Seconds until a new code may be sent, or nil when one may be sent now.
    func waitBeforeSending(now: Date = Date()) -> Int? {
        guard let lastSentStep, lastSentStep == TOTPStep.step(at: now) else { return nil }
        return Int(TOTPStep.secondsRemaining(at: now).rounded(.up))
    }

    /// Posts the code to `/api/security/step-up` on the session client.
    func submit(code: String) async throws -> StepUpGrant {
        guard let client = session.revealClient else { throw Failure.noSession }
        if let wait = waitBeforeSending() { throw Failure.waitForNextCode(secondsLeft: wait) }
        lastSentStep = TOTPStep.step(at: Date())
        do {
            let fresh = try await client.stepUp(code: code)
            grant = fresh
            return fresh
        } catch {
            switch LatticeAPIError(error) {
            case .unauthorized: throw Failure.wrongCode
            case .forbidden(_, let message) where message.hasPrefix("an authenticator passcode must be enabled"):
                throw Failure.noAuthenticator
            case let other: throw Failure.refused(other.localizedDescription)
            }
        }
    }

    /// A refusal with `step_up_required` drops the grant so the Code step runs again.
    func invalidate() {
        grant = nil
    }

    func reset() {
        grant = nil
        lastSentStep = nil
    }
}
