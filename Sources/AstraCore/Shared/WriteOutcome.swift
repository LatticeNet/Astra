import Foundation

/// Why the server, or the flow, refused a write (section 6.7).
public enum RefusalCode: Sendable, Hashable {
    case stepUpRequired
    case secretRevealScopeRequired
    /// On approve: the plan changed since it was opened.
    case approvalStale
    case alreadyDecided(status: String, by: String, at: Date?)
    /// On dismiss, `approval_stale` means the row is not dismissible.
    case notDismissible
    case forbidden(scope: String?)
    case conflict(findings: [String])
    /// Generated checks refuse edits and deletes.
    case managed(by: String)
    case versionConflict
    case notFound
    case validation(String)
    /// The request never left the phone (no connection, host not found).
    /// Not in section 6.7; added so a write that was not sent never reads as unknown.
    case notSent(String)
}

/// One object a bulk or plan write could not change, and why.
public struct ObjectFailure: Sendable, Hashable {
    public var object: ObjectRef
    public var reason: String

    public init(object: ObjectRef, reason: String) {
        self.object = object
        self.reason = reason
    }
}

/// A value shown once in the secret step (F-14). Never logged, cached,
/// restored or put in diagnostics; its description is redacted.
public struct RevealedSecret: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Kind: Sendable, Hashable {
        /// Copy only.
        case text
        /// Share URLs and VPN subscription links: Copy and Share.
        case shareableLink
        /// A provider console link: opens in `SFSafariViewController`, never `openURL`.
        case consoleLink
    }

    /// "Knock sequence", "Node token".
    public var title: String
    public var value: String
    public var kind: Kind

    public init(title: String, value: String, kind: Kind = .text) {
        self.title = title
        self.value = value
        self.kind = kind
    }

    public var description: String { "RevealedSecret(\(title), redacted)" }
    public var debugDescription: String { description }
}

/// How a write ended (sections 6.7 and 8.3).
public enum WriteOutcome: Sendable {
    case done(String, secret: RevealedSecret? = nil)
    case partial(succeeded: [ObjectRef], failed: [ObjectFailure], message: String)
    case refused(RefusalCode, String)
    /// Sent, but the answer was lost: re-read, never retry a non-idempotent call.
    case unknown(String)
    case filed(approvalIDs: [String], refused: [ObjectFailure], notes: [String])

    /// The banner text.
    public var message: String {
        switch self {
        case .done(let message, _): message
        case .partial(_, _, let message): message
        case .refused(_, let message): message
        case .unknown(let message): message
        case .filed(let ids, let refused, let notes):
            notes.first ?? Self.filedMessage(filed: ids.count, refused: refused.count)
        }
    }

    /// True only for a clean success, which alone may use green and `.success`.
    public var isCleanSuccess: Bool {
        switch self {
        case .done: true
        case .filed(_, let refused, _): refused.isEmpty
        case .partial, .refused, .unknown: false
        }
    }

    private static func filedMessage(filed: Int, refused: Int) -> String {
        let plans = filed == 1 ? "1 plan filed" : "\(filed) plans filed"
        return refused == 0 ? plans : "\(plans), \(refused) refused"
    }
}
