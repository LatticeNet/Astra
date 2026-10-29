import Foundation
import LocalAuthentication

/// Local device owner authentication (Face ID, Touch ID or the passcode). This
/// is intent confirmation on the phone, not Lattice step-up (section 6.3).
///
/// A fresh `LAContext` per action, no reuse window; cancelled sends nothing;
/// when device authentication is unavailable the action is refused with the
/// system's message, never waved through. In demo mode only, `-AstraAuth
/// succeed|cancel` substitutes a stub so after-states can be captured.
struct IntentAuth: WriteAuthenticator, DecisionAuthenticator {
    enum Mode: Sendable, Hashable {
        case device
        case stub(DeviceAuthOutcome)
    }

    enum Failure: Error, Equatable, LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: "Authentication cancelled."
            case .failed(let message): message
            }
        }
    }

    let mode: Mode

    static let device = IntentAuth(mode: .device)

    func authenticate(reason: String) async -> DeviceAuthOutcome {
        switch mode {
        case .stub(let outcome):
            return outcome
        case .device:
            switch await Self.confirm(reason: reason) {
            case .success: return .confirmed
            case .failure(.cancelled): return .cancelled
            case .failure(.failed(let message)): return .failed(message)
            }
        }
    }

    /// Unchanged from v2: evaluates `.deviceOwnerAuthentication` with `reason`,
    /// which Touch ID devices and the passcode fallback display.
    @MainActor
    static func confirm(reason: String) async -> Result<Void, Failure> {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            let message = error?.localizedDescription ?? "Device authentication is not available."
            return .failure(.failed(message))
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ok ? .success(()) : .failure(.cancelled)
        } catch let la as LAError {
            if la.code == .userCancel || la.code == .appCancel || la.code == .systemCancel {
                return .failure(.cancelled)
            }
            return .failure(.failed(la.localizedDescription))
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }
}
