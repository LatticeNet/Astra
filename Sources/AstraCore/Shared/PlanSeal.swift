import Foundation

/// Whether the phone checked a plan's hash itself (section 4.7).
public enum PlanSealState: Sendable, Hashable {
    /// Server-supplied hash, not checked on this phone.
    case unverified
    /// The phone hashed the on-screen body and it equals `plan_sha256`.
    case verified
    case mismatch
    /// A listing row without a body; never actionable.
    case noBody
}

/// Formatting for the plan seal, the signature element (section 4.7).
public enum PlanSeal {
    /// "3f9a…c210": the first and last four lowercase hex characters.
    public static func short(_ sha256: String) -> String {
        let hex = sha256.lowercased()
        guard hex.count > 8 else { return hex }
        return "\(hex.prefix(4))…\(hex.suffix(4))"
    }

    /// The full hash in groups of four characters, for the proof strip.
    public static func groups(_ sha256: String) -> [String] {
        let hex = Array(sha256.lowercased())
        return stride(from: 0, to: hex.count, by: 4).map { String(hex[$0..<min($0 + 4, hex.count)]) }
    }

    /// The VoiceOver phrase: "starts 3 f 9 a, ends c 2 1 0, not verified on this phone".
    public static func spoken(_ sha256: String, state: PlanSealState) -> String {
        let hex = sha256.lowercased()
        let spell: (Substring) -> String = { $0.map(String.init).joined(separator: " ") }
        let status = switch state {
        case .verified: "matches the plan on this phone"
        case .mismatch: "does not match the plan"
        case .unverified, .noBody: "not verified on this phone"
        }
        guard hex.count > 8 else { return "\(spell(Substring(hex))), \(status)" }
        return "starts \(spell(hex.prefix(4))), ends \(spell(hex.suffix(4))), \(status)"
    }
}
