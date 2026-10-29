import SwiftUI

/// The haptics map of section 4.9. Feedback is only for outcomes the operator
/// caused; passive updates never vibrate, and a cancelled Face ID plays nothing.
enum HapticEvent: Sendable, Hashable {
    case approveLanded
    case rejectOrDismissLanded
    case batchLanded
    case partial
    case failure
    case lightAction
    case writeLanded
    case planFiled
    case selection

    var feedback: SensoryFeedback {
        switch self {
        case .approveLanded, .batchLanded, .writeLanded, .planFiled: .success
        case .rejectOrDismissLanded: .impact(weight: .medium)
        case .partial: .warning
        case .failure: .error
        case .lightAction: .impact(weight: .light)
        case .selection: .selection
        }
    }

    /// The feedback for a write's outcome at its tier.
    static func outcome(_ outcome: WriteOutcome, tier: WriteTier) -> HapticEvent {
        switch outcome {
        case .done: tier == .t1 ? .lightAction : .writeLanded
        case .filed(_, let refused, _): refused.isEmpty ? .planFiled : .partial
        case .partial: .partial
        case .refused, .unknown: .failure
        }
    }
}

/// A haptic request with an identity, so the same event can fire twice in a row.
struct HapticPulse: Equatable {
    let event: HapticEvent
    let id = UUID()
}

extension View {
    /// Plays `pulse` when it changes.
    func haptics(_ pulse: HapticPulse?) -> some View {
        sensoryFeedback(trigger: pulse) { _, new in new?.event.feedback }
    }
}
