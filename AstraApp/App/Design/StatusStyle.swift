import SwiftUI

/// How a status is colored. Color is always the third channel after the
/// symbol and the word (section 4.2).
enum StatusTone: Sendable, Hashable {
    case ok, warn, fail, quiet
    /// A call to act ("needs you"), not a status color.
    case accent

    var glyph: Color {
        switch self {
        case .ok: .statusOKFill
        case .warn: .statusWarnFill
        case .fail: .statusFailFill
        case .quiet: .statusQuiet
        case .accent: .accentText
        }
    }

    /// Health is quiet: only problems color their word.
    var word: Color {
        switch self {
        case .warn: .statusWarnText
        case .fail: .statusFailText
        case .ok, .quiet: .secondary
        case .accent: .primary
        }
    }

    var isProblem: Bool { self == .warn || self == .fail }
}

/// Symbol, word and tone for one state of the vocabulary in section 4.2.
/// It maps only the Shared display-state enums, so modules render states the
/// same way everywhere.
struct StatusStyle: Sendable, Hashable {
    var word: String
    var symbol: String
    var tone: StatusTone

    static func node(_ honesty: NodeHonesty) -> StatusStyle {
        switch honesty {
        case .online: StatusStyle(word: "online", symbol: "checkmark.circle.fill", tone: .ok)
        case .degraded: StatusStyle(word: "degraded", symbol: "exclamationmark.triangle.fill", tone: .warn)
        case .offline: StatusStyle(word: "offline", symbol: "xmark.octagon.fill", tone: .fail)
        case .neverReported: StatusStyle(word: "never reported", symbol: "circle.dashed", tone: .quiet)
        case .disabled: StatusStyle(word: "disabled", symbol: "minus.circle", tone: .quiet)
        }
    }

    static func path(_ state: PathDisplayState) -> StatusStyle {
        switch state {
        case .up: StatusStyle(word: "up", symbol: "arrow.right.circle.fill", tone: .ok)
        case .degraded: StatusStyle(word: "degraded", symbol: "exclamationmark.triangle.fill", tone: .warn)
        case .down: StatusStyle(word: "down", symbol: "xmark.circle.fill", tone: .fail)
        case .paused: StatusStyle(word: "paused", symbol: "pause.circle", tone: .quiet)
        case .unknown: StatusStyle(word: "unknown", symbol: "questionmark.circle", tone: .quiet)
        }
    }

    /// `snoozedUntil` is formatted by the caller, which knows the time zone mode.
    static func incident(_ state: IncidentDisplayState, snoozedUntil: String? = nil) -> StatusStyle {
        switch state {
        case .openCritical: StatusStyle(word: "open", symbol: "exclamationmark.octagon.fill", tone: .fail)
        case .openWarning: StatusStyle(word: "open", symbol: "exclamationmark.triangle.fill", tone: .warn)
        case .openInfo: StatusStyle(word: "open", symbol: "info.circle", tone: .quiet)
        case .acknowledged: StatusStyle(word: "acknowledged", symbol: "person.crop.circle.badge.checkmark", tone: .quiet)
        case .snoozed:
            StatusStyle(word: snoozedUntil.map { "snoozed until \($0)" } ?? "snoozed", symbol: "moon.zzz", tone: .quiet)
        case .held: StatusStyle(word: "held", symbol: "wrench.and.screwdriver", tone: .quiet)
        case .pending: StatusStyle(word: "pending", symbol: "hourglass", tone: .quiet)
        case .resolved: StatusStyle(word: "resolved", symbol: "checkmark.circle", tone: .ok)
        }
    }

    /// The secondary glyph added to a flapping incident.
    static let flapping = StatusStyle(word: "flapping", symbol: "arrow.triangle.2.circlepath", tone: .quiet)

    static func task(_ state: TaskRunState) -> StatusStyle {
        switch state {
        case .pending: StatusStyle(word: "pending", symbol: "hourglass", tone: .quiet)
        case .queued: StatusStyle(word: "queued", symbol: "clock", tone: .quiet)
        case .leased: StatusStyle(word: "running", symbol: "play.circle", tone: .quiet)
        case .finished: StatusStyle(word: "finished", symbol: "checkmark.circle", tone: .ok)
        case .failed: StatusStyle(word: "failed", symbol: "xmark.circle.fill", tone: .fail)
        case .stalled: StatusStyle(word: "stalled", symbol: "exclamationmark.arrow.circlepath", tone: .warn)
        case .expired: StatusStyle(word: "expired", symbol: "clock.badge.xmark", tone: .warn)
        case .cancelled: StatusStyle(word: "cancelled", symbol: "slash.circle", tone: .quiet)
        }
    }

    static func approval(_ state: ApprovalDisplayState) -> StatusStyle {
        switch state {
        case .needsYou: StatusStyle(word: "needs you", symbol: "hand.raised.fill", tone: .accent)
        case .stale: StatusStyle(word: "stale", symbol: "clock.badge.exclamationmark", tone: .warn)
        case .waiting: StatusStyle(word: "waiting", symbol: "pause.circle", tone: .warn)
        case .applying: StatusStyle(word: "applying", symbol: "arrow.clockwise.circle", tone: .quiet)
        case .applied: StatusStyle(word: "applied", symbol: "checkmark.circle", tone: .ok)
        case .failed: StatusStyle(word: "failed", symbol: "xmark.circle.fill", tone: .fail)
        case .rejected: StatusStyle(word: "rejected", symbol: "xmark.circle", tone: .quiet)
        case .dismissed: StatusStyle(word: "dismissed", symbol: "archivebox", tone: .quiet)
        case .auto: StatusStyle(word: "auto", symbol: "gearshape", tone: .quiet)
        }
    }

    static func posture(_ posture: SSHGuardPostureState) -> StatusStyle {
        switch posture {
        case .secured: StatusStyle(word: "secured", symbol: "lock.shield", tone: .ok)
        case .passwordOpen: StatusStyle(word: "password login open", symbol: "lock.open.fill", tone: .fail)
        case .partial: StatusStyle(word: "partial", symbol: "shield.lefthalf.filled", tone: .warn)
        case .unknown: StatusStyle(word: "unknown", symbol: "questionmark.circle", tone: .quiet)
        }
    }

    /// `deadline` is the formatted revert deadline when the timer is running.
    static func coverage(_ coverage: SSHGuardCoverage, deadline: String? = nil) -> StatusStyle {
        switch coverage {
        case .confirmed: StatusStyle(word: "confirmed", symbol: "checkmark.shield", tone: .ok)
        case .armPending: StatusStyle(word: "arm pending", symbol: "hourglass", tone: .quiet)
        case .reverting(let date) where date != nil:
            StatusStyle(word: deadline.map { "confirm by \($0)" } ?? "confirm before the revert", symbol: "timer", tone: .warn)
        case .reverting: StatusStyle(word: "confirming", symbol: "arrow.uturn.backward.circle", tone: .warn)
        case .open: StatusStyle(word: "not armed", symbol: "circle", tone: .quiet)
        case .failed: StatusStyle(word: "failed", symbol: "xmark.shield", tone: .fail)
        case .excluded: StatusStyle(word: "excluded", symbol: "minus.circle", tone: .quiet)
        }
    }

    static func seal(_ state: PlanSealState) -> StatusStyle {
        switch state {
        case .unverified: StatusStyle(word: "not verified on this phone", symbol: "seal", tone: .quiet)
        case .verified: StatusStyle(word: "matches the plan", symbol: "checkmark.seal.fill", tone: .ok)
        case .mismatch: StatusStyle(word: "does not match the plan", symbol: "xmark.seal.fill", tone: .fail)
        case .noBody: StatusStyle(word: "no plan body", symbol: "seal", tone: .quiet)
        }
    }
}

/// The freshness and access vocabulary (section 4.2), used by footers and rows.
enum AccessState: Sendable, Hashable {
    case fresh(age: String)
    case updating
    /// nil when nothing has loaded yet.
    case stale(asOf: String?)
    /// nil when nothing has loaded yet.
    case offline(since: String?)
    case denied(scope: String)
    case partial(plugins: String)
    case companionBehind(surface: String)

    var text: String {
        switch self {
        case .fresh(let age): "Updated \(age) ago"
        case .updating: "Updating"
        case .stale(let time): time.map { "Stale. As of \($0)" } ?? "Not loaded yet"
        case .offline(let time): time.map { "Offline. Showing data from \($0)" } ?? "Offline. Nothing loaded yet"
        case .denied(let scope): "Hidden: this token lacks \(scope)"
        case .partial(let plugins): "Hidden from this token: \(plugins)"
        case .companionBehind(let surface): "This app is behind the server. \(surface) could not be read."
        }
    }

    var symbol: String? {
        switch self {
        case .fresh, .updating: nil
        case .stale: "clock.badge.exclamationmark"
        case .offline: "wifi.slash"
        case .denied: "lock"
        case .partial: "eye.slash"
        case .companionBehind: "exclamationmark.triangle"
        }
    }

    var tone: StatusTone {
        switch self {
        case .stale, .offline, .companionBehind: .warn
        case .fresh, .updating, .denied, .partial: .quiet
        }
    }
}

/// The leading status glyph, hierarchical, with its symbol transition.
struct StatusGlyph: View {
    let style: StatusStyle
    var font: Font = .title3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: style.symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(style.tone.glyph)
            .font(font)
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}
