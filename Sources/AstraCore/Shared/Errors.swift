import Foundation

/// Every failure a Lattice request can end in. HTTP statuses map to the first
/// seven cases from the server's error envelope (section 8.3); the last three
/// come from the client itself.
public enum LatticeAPIError: Error, Sendable, Equatable, LocalizedError {
    /// 401. A 401 from `/api/security/step-up` is a wrong code, and its caller maps it (6.4).
    case unauthorized(message: String)
    /// 403 with the envelope's code (`step_up_required`, `secret_reveal_scope_required`,
    /// or `forbidden` for the server's plain errors) and its message. The server's
    /// envelope names no scope, so callers take the missing scope from what they asked for.
    case forbidden(code: String, message: String)
    /// 404.
    case notFound
    /// 409 with the envelope's code, its message, and any lint findings, one message each.
    case conflict(code: String, message: String, findings: [String])
    /// Any other non-2xx status.
    case server(status: Int, code: String?, message: String)
    /// Timeout, offline, TLS. Whether the request was sent is recorded by the runner.
    case transport(URLError.Code)
    /// The body could not be decoded: the app is behind the server.
    case invalidResponse
    /// The configured server URL cannot address this path.
    case invalidURL(String)
    /// `/api/login` answered without a `lattice_session` cookie.
    case missingSessionCookie
    /// `/api/login` asked for a second factor; continue with `loginTOTP`.
    case totpRequired(challengeID: String)

    /// The plain-error refusal of `requireStepUpGrant` (server_stepup.go). It
    /// guards passkey and sing-box writes with code `forbidden`, so its message
    /// is the only way to tell it from a scope refusal.
    static let stepUpRequiredMessage = "second-factor step-up required"

    /// A 403 that asks for a fresh step-up grant, coded or plain.
    public var isStepUpRequired: Bool {
        guard case .forbidden(let code, let message) = self else { return false }
        return code == "step_up_required" || message.hasPrefix(Self.stepUpRequiredMessage)
    }

    /// Maps a thrown error to a Lattice error, so callers handle one type.
    public init(_ error: any Error) {
        switch error {
        case let error as LatticeAPIError:
            self = error
        case let error as URLError:
            self = .transport(error.code)
        case is DecodingError:
            self = .invalidResponse
        default:
            self = .server(status: 0, code: nil, message: error.localizedDescription)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let message):
            message.isEmpty ? "Lattice credentials are unauthorized or expired." : message
        case .forbidden(let code, let message):
            message.isEmpty ? "Forbidden (\(code))." : message
        case .notFound:
            "Not found."
        case .conflict(let code, let message, let findings):
            if !findings.isEmpty { findings.joined(separator: "\n") } else if !message.isEmpty { message } else { "Conflict (\(code))." }
        case .server(let status, let code, let message):
            Self.describe(status: status, code: code, message: message)
        case .transport(let code):
            Self.describe(transport: code)
        case .invalidResponse:
            "The Lattice response could not be decoded."
        case .invalidURL(let value):
            "Invalid URL: \(value)"
        case .missingSessionCookie:
            "Lattice login did not return a session cookie."
        case .totpRequired:
            "Lattice requires a TOTP code for this login."
        }
    }

    private static func describe(status: Int, code: String?, message: String) -> String {
        if !message.isEmpty { return message }
        if let code, !code.isEmpty { return code }
        return "HTTP \(status)"
    }

    private static func describe(transport code: URLError.Code) -> String {
        switch code {
        case .timedOut: "The server did not answer in time."
        case .notConnectedToInternet, .networkConnectionLost: "No connection."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: "Cannot reach the server."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            "The server's TLS certificate was refused."
        default: "Network error \(code.rawValue)."
        }
    }
}
