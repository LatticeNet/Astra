import Foundation

/// The result of asking the device owner to confirm (Face ID or passcode).
public enum DeviceAuthOutcome: Sendable, Hashable {
    case confirmed
    case cancelled
    case failed(String)
}

/// Confirms T3 and T4 writes. The app's `IntentAuth` conforms; checks inject
/// a stub, so a cancelled confirmation is proven to send nothing.
public protocol WriteAuthenticator: Sendable {
    func authenticate(reason: String) async -> DeviceAuthOutcome
}

/// How one pass through a write's gates ended.
public enum WriteFlowResult: Sendable {
    /// The operator cancelled authentication. Nothing was sent.
    case cancelled
    /// Device authentication is unavailable or failed. Nothing was sent.
    case authenticationFailed(String)
    /// The dry run changed since the operator reviewed it. Nothing was sent;
    /// show the new report and ask again.
    case dryRunChanged(DryRunReport)
    case finished(WriteOutcome)
}

/// The pure sequencing of a `WriteIntent` (section 8.3): authenticate when
/// the tier needs it, re-check the dry run immediately before sending,
/// perform, and turn errors into outcomes, verifying the post-state when the
/// answer was lost. The ConfirmSheet drives the steps; this type owns the order.
public struct WriteFlow: Sendable {
    public let intent: WriteIntent
    public let client: LatticeClient
    public let authenticator: any WriteAuthenticator

    public init(intent: WriteIntent, client: LatticeClient, authenticator: any WriteAuthenticator) {
        self.intent = intent
        self.client = client
        self.authenticator = authenticator
    }

    /// T3 and T4 need Face ID; T1, T2 and plan filing do not.
    public static func requiresAuthentication(_ tier: WriteTier) -> Bool {
        tier == .t3 || tier == .t4
    }

    /// The dry run to show on the Confirm step, or nil when the intent has none.
    public func dryRun() async throws -> DryRunReport? {
        guard let dryRun = intent.dryRun else { return nil }
        return try await dryRun(client)
    }

    /// Runs the gates after the operator pressed the primary action.
    /// `reviewed` is the dry run the operator saw, if any.
    public func commit(choices: ConfirmChoices, reviewed: DryRunReport? = nil) async -> WriteFlowResult {
        if Self.requiresAuthentication(intent.tier) {
            switch await authenticator.authenticate(reason: intent.title) {
            case .confirmed: break
            case .cancelled: return .cancelled
            case .failed(let message): return .authenticationFailed(message)
            }
        }
        if let reviewed, let dryRun = intent.dryRun {
            do {
                let fresh = try await dryRun(client)
                if fresh.fingerprint != reviewed.fingerprint {
                    return .dryRunChanged(fresh)
                }
            } catch {
                // The write itself was never sent, so even a lost answer here is a refusal.
                let apiError = LatticeAPIError(error)
                let message = "Could not check what would change: \(apiError.localizedDescription)"
                return .finished(Self.refusal(for: apiError) ?? .refused(.notSent(message), message))
            }
        }
        do {
            return .finished(try await intent.perform(client, choices))
        } catch {
            return .finished(await outcome(after: LatticeAPIError(error)))
        }
    }

    /// The outcome for an error thrown by `perform`. A lost answer becomes
    /// `.unknown` with the intent's verification sentence; it is never retried.
    func outcome(after error: LatticeAPIError) async -> WriteOutcome {
        if Self.answerLostAfterSending(error) {
            guard let verify = intent.verify else {
                return .unknown("Could not confirm \(intent.title). Check its state before trying again.")
            }
            do {
                return .unknown("Could not confirm. \(try await verify(client))")
            } catch {
                return .unknown("Could not confirm \(intent.title), and its state could not be read.")
            }
        }
        if let refusal = Self.refusal(for: error) {
            return refusal
        }
        return .refused(.validation(error.localizedDescription), error.localizedDescription)
    }

    /// Maps a server refusal to an outcome; nil for a lost answer.
    public static func refusal(for error: LatticeAPIError) -> WriteOutcome? {
        let message = error.localizedDescription
        switch error {
        case .forbidden(let code, _):
            if error.isStepUpRequired { return .refused(.stepUpRequired, message) }
            if code == "secret_reveal_scope_required" { return .refused(.secretRevealScopeRequired, message) }
            // The envelope never names a scope; the caller knows which one it asked for.
            return .refused(.forbidden(scope: nil), message)
        case .conflict(let code, _, let findings):
            if !findings.isEmpty { return .refused(.conflict(findings: findings), message) }
            switch code {
            case "approval_stale": return .refused(.approvalStale, message)
            case "version_conflict": return .refused(.versionConflict, message)
            default: return .refused(.validation(message), message)
            }
        case .notFound:
            return .refused(.notFound, message)
        case .transport(let code):
            return failedBeforeSending(code) ? .refused(.notSent(message), message) : nil
        case .unauthorized, .server, .invalidResponse, .invalidURL, .missingSessionCookie, .totpRequired:
            return .refused(.validation(message), message)
        }
    }

    /// True when the request left the phone but its answer did not come back:
    /// a lost connection or timeout, or a proxy that gave up waiting for the
    /// server. The write may already have been applied, so it is verified,
    /// never refused or retried. A 502 or 503 that carries a Lattice envelope
    /// code is the server's own refusal.
    public static func answerLostAfterSending(_ error: LatticeAPIError) -> Bool {
        switch error {
        case .transport(let code):
            !failedBeforeSending(code)
        case .server(let status, let code, _):
            switch status {
            case 504, 522, 524: true
            case 502, 503: code == nil
            default: false
            }
        default:
            false
        }
    }

    /// Transport failures that happen before the request leaves the phone.
    public static func failedBeforeSending(_ code: URLError.Code) -> Bool {
        switch code {
        case .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
             .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .appTransportSecurityRequiresSecureConnection:
            true
        default:
            false
        }
    }
}
