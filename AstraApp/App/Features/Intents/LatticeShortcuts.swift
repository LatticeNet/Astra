import AppIntents
import Foundation

/// The App Shortcuts for the two intents (M14). Phrases carry no entity
/// parameter on purpose: a parameterized phrase would hand every node name to
/// the system's Siri vocabulary, so Siri asks "Which node?" instead and lists
/// the choices only after the device is unlocked.
struct LatticeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenNodeIntent(),
            phrases: [
                "Open a node in \(.applicationName)",
                "Show a node in \(.applicationName)",
            ],
            shortTitle: "Open Node",
            systemImageName: "server.rack"
        )
        AppShortcut(
            intent: ReviewApprovalIntent(),
            phrases: [
                "Review an approval in \(.applicationName)",
                "Review a \(.applicationName) approval",
            ],
            shortTitle: "Review Approval",
            systemImageName: "hand.raised"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .navy
}

// MARK: - Query support shared by the two entity queries

/// Why a parameter picker has nothing to list. Shortcuts shows it and Siri
/// speaks it, so an empty picker never stands in for "nothing waits" or
/// "no nodes" when the truth is a lock, no connection or a narrow token.
enum IntentsQueryError: Error, CustomLocalizedStringResourceConvertible {
    case locked
    case notConnected
    /// The token lacks `scope`, so the server hides `what`.
    case hidden(what: String, scope: String)
    /// The body did not decode: the app is behind the server.
    case companionBehind(surface: String)
    case loadFailed(what: String, reason: String)

    init(_ error: any Error, what: String, scope: String) {
        let error = LatticeAPIError(error)
        switch error {
        case .forbidden where !error.isStepUpRequired:
            self = .hidden(what: what, scope: scope)
        case .invalidResponse:
            self = .companionBehind(surface: what.prefix(1).uppercased() + what.dropFirst())
        default:
            self = .loadFailed(what: what, reason: error.errorDescription ?? "Unknown error.")
        }
    }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .locked:
            "Lattice is locked. Open Lattice to choose, or turn off Require Face ID to open."
        case .notConnected:
            "Lattice is not connected to a server. Open Lattice to sign in."
        case .hidden(let what, let scope):
            "Hidden: this token lacks \(scope), so it cannot list \(what)."
        case .companionBehind(let surface):
            "This app is behind the server. \(surface) could not be read."
        case .loadFailed(let what, let reason):
            "Could not load \(what). \(reason)"
        }
    }
}

@MainActor
enum IntentsGate {
    /// "Require Face ID to open" gates the app's data, not only its windows.
    /// Shortcuts and Siri run the queries without a scene, so no ShieldWindow
    /// stands in front of them; with the lock on they fetch nothing.
    static var locked: Bool { DeviceLockSettings.requireFaceID }

    /// The client a picker may read with, or why it may not.
    static func client() throws(IntentsQueryError) -> LatticeClient {
        if locked { throw IntentsQueryError.locked }
        guard let client = AppServices.shared.session.client else { throw IntentsQueryError.notConnected }
        return client
    }
}

/// Word matching for typed searches and spoken answers. Siri transcribes
/// "relay fra 2" or "relay fra two" for a node named relay-fra-2, so both
/// sides are cut into words and every word of the answer must appear.
enum IntentsMatch {
    private static let numerals = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
    ]

    static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded
            .split { (character: Character) in !(character.isLetter || character.isNumber) }
            .map(String.init)
    }

    /// True when every word of `query` appears among the haystack's words:
    /// a word as part of one ("tyo", "frank"), a number as a whole word, so
    /// "fra 1" does not also find fra-10. A spoken numeral counts as its digit.
    static func matches(_ query: [String], in haystack: [String]) -> Bool {
        let hay = haystack.flatMap(words)
        return query.allSatisfy { word in
            let number = numerals[word] ?? (word.allSatisfy(\.isNumber) ? word : nil)
            return hay.contains { candidate in
                if let number, candidate == number { return true }
                return word.contains(where: \.isLetter) && candidate.contains(word)
            }
        }
    }
}
