import SwiftUI
import UIKit

/// The plan seal in compact form (section 4.7): the seal symbol and the first
/// and last four hex characters of `plan_sha256`. It appears only where a plan
/// hash is bound to a decision.
struct SealLabel: View {
    let sha256: String
    var state: PlanSealState = .unverified
    var placement: Placement = .row

    enum Placement {
        /// Inside a row: no gesture, hidden at accessibility sizes, read on
        /// request through custom content.
        case row
        /// A header (TaskRun, AuditEvent): its own element with a Copy button.
        case standalone
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        switch placement {
        case .row:
            if !typeSize.isAccessibilitySize {
                seal(font: TextRole.sealInRow.font)
                    .accessibilityHidden(true)
            }
        case .standalone:
            HStack(spacing: Spacing.s) {
                seal(font: TextRole.sealInStrip.font)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Plan seal, \(PlanSeal.spoken(sha256, state: state))")
                Button("Copy plan hash", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = sha256
                }
                .labelStyle(.iconOnly)
                .frame(minWidth: Spacing.minimumTarget, minHeight: Spacing.minimumTarget)
            }
        }
    }

    private func seal(font: Font) -> some View {
        let style = StatusStyle.seal(state)
        let symbolColor: Color = switch state {
        case .verified: .statusOKFill
        case .mismatch: .statusFailFill
        case .unverified: .secondary
        case .noBody: Color(uiColor: .tertiaryLabel)
        }
        return HStack(spacing: Spacing.xs) {
            Image(systemName: style.symbol).foregroundStyle(symbolColor)
            Text(PlanSeal.short(sha256))
                .foregroundStyle(state == .noBody ? Color(uiColor: .tertiaryLabel) : .secondary)
        }
        .font(font)
    }
}

extension View {
    /// Attaches the seal phrase to a row so VoiceOver reads it on request
    /// rather than in the row label.
    func sealCustomContent(_ sha256: String, state: PlanSealState = .unverified) -> some View {
        accessibilityCustomContent(Text("Plan seal"), Text(PlanSeal.spoken(sha256, state: state)))
    }
}
