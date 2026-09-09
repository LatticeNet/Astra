import Foundation
import LocalAuthentication

/// Local device owner authentication (Face ID or passcode). This is intent
/// confirmation on the phone, not Lattice step-up.
enum IntentAuth: Sendable {
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
