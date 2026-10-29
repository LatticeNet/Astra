import Foundation

/// What a step-up reveal is for. The server's step-up takes only a code; the
/// purpose names the secret in the RevealFlow copy (F-13).
public enum StepUpPurpose: Sendable, Hashable {
    case knockSequence
    case machineLink
    case taskScript
    case shareURL
    case vpnLink
    case vpnCredentials
    case passkeyChange
    case other(secretName: String)

    /// The secret in a sentence: "Reveal the {secretName} for edge-tyo-3".
    public var secretName: String {
        switch self {
        case .knockSequence: "knock sequence"
        case .machineLink: "console link"
        case .taskScript: "task script"
        case .shareURL: "share URL"
        case .vpnLink: "subscription link"
        case .vpnCredentials: "credentials"
        case .passkeyChange: "passkey change"
        case .other(let name): name
        }
    }
}

/// A second-factor grant from `POST /api/security/step-up`. Held in memory
/// only, reused until shortly before `expiresAt` (section 6.4).
public struct StepUpGrant: Sendable, Hashable, Decodable {
    public var grant: String
    public var expiresAt: Date

    public init(grant: String, expiresAt: Date) {
        self.grant = grant
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case grant
        case expiresAt = "expires_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        grant = try container.decode(String.self, forKey: .grant)
        guard let expiry = try DateValue.decodeIfPresent(from: container, forKey: .expiresAt) else {
            throw LatticeAPIError.invalidResponse
        }
        expiresAt = expiry
    }

    /// A grant is reused only while more than `margin` seconds remain.
    public func isUsable(now: Date, margin: TimeInterval = 5) -> Bool {
        expiresAt.timeIntervalSince(now) > margin
    }
}

/// The 30-second TOTP step. The server's replay protection is per account
/// across devices, so the phone remembers the step of the last code it sent.
public enum TOTPStep {
    public static let period: TimeInterval = 30

    public static func step(at date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / period).rounded(.down))
    }

    /// Seconds until the next code.
    public static func secondsRemaining(at date: Date) -> TimeInterval {
        period - date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
    }
}

private struct StepUpRequest: Encodable {
    var code: String
}

public extension LatticeClient {
    /// `POST /api/security/step-up {code}`. Session clients only: the server
    /// refuses bearer principals. A 401 here is a wrong code, which the
    /// caller maps to `.refused(.validation("Wrong code"))`, never an expired session.
    func stepUp(code: String) async throws -> StepUpGrant {
        try await perform(StepUpGrant.self, path: "/api/security/step-up", method: "POST", body: StepUpRequest(code: code))
    }
}
