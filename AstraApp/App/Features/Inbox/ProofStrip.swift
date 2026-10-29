import SwiftUI
import UIKit

/// The proof strip of Review and BatchReview (section 4.7): the plan seal
/// in full. The phone shows the filled seal only after it hashed the body
/// on screen itself and that hash equals `plan_sha256`.
struct ProofStrip: View {
    let sha256: String
    var state: PlanSealState = .unverified
    /// The hash this phone computed, shown when it does not match.
    var computed: String?

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsFullHash = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            header
            if typeSize.isAccessibilitySize && !showsFullHash {
                SealLabel(sha256: sha256, state: state, placement: .standalone)
                Button("Show full hash") { showsFullHash = true }
                    .frame(minHeight: Spacing.minimumTarget)
            } else {
                hashGroups
                if state == .mismatch, let computed, !computed.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("This iPhone computed").textRole(.footnote)
                        Text(PlanSeal.groups(computed).joined(separator: " "))
                            .font(TextRole.identifierInRow.font)
                            .foregroundStyle(Color.statusFailText)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text("Approve sends this hash. If the plan changed, the server refuses.")
                .textRole(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            if !(typeSize.isAccessibilitySize && !showsFullHash) {
                Button {
                    UIPasteboard.general.string = sha256
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy hash", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .frame(minHeight: Spacing.minimumTarget)
                .accessibilityLabel("Copy plan hash")
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
        }
    }

    private var header: some View {
        let style = StatusStyle.seal(state)
        let color: Color = switch state {
        case .verified: .statusOKFill
        case .mismatch: .statusFailFill
        case .unverified, .noBody: .secondary
        }
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Image(systemName: style.symbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .accessibilityHidden(true)
            Text(headline)
                .font(.headline)
                .foregroundStyle(state == .mismatch ? Color.statusFailText : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Plan seal. \(headline)")
        .accessibilityAddTraits(.isHeader)
    }

    private var headline: String {
        switch state {
        case .verified: "Matches the plan below"
        case .mismatch: "Does not match the plan below. Approve is off."
        case .unverified, .noBody: "Checking the plan below"
        }
    }

    /// The full hash in groups of four that wrap naturally; the first and
    /// last eight characters carry the weight, so it compares by eye with
    /// the console's digest.
    private var hashGroups: some View {
        let groups = PlanSeal.groups(sha256)
        var text = AttributedString()
        for (index, group) in groups.enumerated() {
            var run = AttributedString(group)
            let edge = index < 2 || index >= groups.count - 2
            run.font = TextRole.sealInStrip.font.weight(edge ? .semibold : .regular)
            run.foregroundColor = edge ? Color.primary : Color.secondary
            text += run
            if index < groups.count - 1 { text += AttributedString(" ") }
        }
        return Text(text)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityLabel("Plan hash, \(PlanSeal.spoken(sha256, state: state))")
    }
}
