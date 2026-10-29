import SwiftUI

/// The verdict line (section 4.8): one sentence, marked as a header, and the
/// count buttons beneath it. It renders what `VerdictBuilder` produced; it
/// never decides what to say.
struct VerdictView: View {
    let verdict: Verdict
    let open: (VerdictSegment) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(verdict.sentence)
                .textRole(.verdict)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if !verdict.segments.isEmpty {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        ForEach(verdict.segments) { segment in
                            countButton(segment).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    FlowLayout {
                        ForEach(verdict.segments) { segment in
                            countButton(segment)
                        }
                    }
                }
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private func countButton(_ segment: VerdictSegment) -> some View {
        Button {
            open(segment)
        } label: {
            Text(segment.text)
                .textRole(.count)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .frame(minHeight: Spacing.minimumTarget - 12)
        }
        .buttonStyle(.bordered)
        .tint(.secondary)
        .frame(minHeight: Spacing.minimumTarget)
    }
}
