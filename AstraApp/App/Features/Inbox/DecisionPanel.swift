import SwiftUI

/// What the decision controls show, computed once by the sheet that owns them.
struct InboxDecisionControls {
    /// Approve is possible in principle (pending, fresh, decidable), so the
    /// "Apply after approval" toggle is shown.
    var showsToggle: Bool
    /// Why Approve is off, in words, with the symbol that names the cause.
    var reason: String?
    var reasonSymbol = "info.circle"
    var reasonTone: StatusTone = .quiet
    var canApprove: Bool
    var canReject: Bool
    /// "14" in "Approve and apply 14", for BatchReview.
    var count: Int?
    /// The rows "Reject all" would send, which can differ from the approve count.
    var rejectCount: Int?
    var rejectTitle = "Reject"
    var inFlight = false
    /// Neither button is offered at all (stale, decided, read-only).
    var hidesButtons: Bool { !canApprove && !canReject && !inFlight }

    func approveTitle(applyAfterApproval: Bool) -> String {
        let base = applyAfterApproval ? "Approve and apply" : "Approve only"
        return count.map { "\(base) \($0)" } ?? base
    }

    var rejectLabel: String {
        rejectCount.map { "\(rejectTitle) \($0)" } ?? rejectTitle
    }
}

/// The decision panel above the Review toolbar (M1-02): the visible "Apply
/// after approval" toggle and, when Approve is unavailable, the reason as
/// wrapping text. At accessibility sizes the toolbar is dropped and the
/// panel holds the buttons as a full-width stack.
struct DecisionPanel: View {
    @Binding var applyAfterApproval: Bool
    let controls: InboxDecisionControls
    /// In a compact height (landscape) the buttons sit in the navigation
    /// bar and the panel scrolls with the content instead of being pinned.
    var inline = false
    let approve: () -> Void
    let reject: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize && !inline
        if controls.showsToggle || controls.reason != nil || controls.inFlight || (stacked && !controls.hidesButtons) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if controls.inFlight {
                    HStack(spacing: Spacing.s) {
                        ProgressView()
                        Text("Sending the decision").foregroundStyle(.secondary)
                    }
                    .frame(minHeight: Spacing.minimumTarget)
                    .accessibilityElement(children: .combine)
                } else if let reason = controls.reason {
                    Label {
                        Text(reason)
                            .foregroundStyle(controls.reasonTone.isProblem ? controls.reasonTone.word : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: controls.reasonSymbol)
                            .foregroundStyle(controls.reasonTone.glyph)
                    }
                    .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                }
                if controls.showsToggle {
                    Toggle("Apply after approval", isOn: $applyAfterApproval)
                        .disabled(controls.inFlight)
                        .frame(minHeight: Spacing.minimumTarget)
                        .accessibilityHint(applyAfterApproval ? "Approving queues the apply task" : "Approving records the decision without queuing the apply")
                }
                if stacked && !controls.hidesButtons {
                    Button(action: approve) {
                        Text(controls.approveTitle(applyAfterApproval: applyAfterApproval))
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentFill)
                    .disabled(!controls.canApprove)
                    Button(role: .destructive, action: reject) {
                        Text(controls.rejectLabel)
                            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.statusFailText)
                    .disabled(!controls.canReject)
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(inline ? Color(uiColor: .secondarySystemGroupedBackground) : Color(uiColor: .systemGroupedBackground), in: .rect(cornerRadius: inline ? 22 : 0))
            .overlay(alignment: .top) { if !inline { Divider() } }
            // Pinned, it must leave room for the plan above it at AX5, as
            // the ConfirmSheet's pinned action does.
            .dynamicTypeSize(...(inline ? DynamicTypeSize.accessibility5 : DynamicTypeSize.accessibility1))
        }
    }
}

/// The two short buttons in the Review bottom toolbar: Reject, a flexible
/// spacer, and the prominent primary whose label follows the toggle.
struct InboxDecisionToolbar: ToolbarContent {
    let applyAfterApproval: Bool
    let controls: InboxDecisionControls
    /// A compact height moves the buttons into the navigation bar (4.11).
    var compactHeight = false
    let approve: () -> Void
    let reject: () -> Void

    var body: some ToolbarContent {
        if compactHeight {
            ToolbarItem(placement: .topBarTrailing) {
                Button(controls.rejectLabel, role: .destructive, action: reject)
                    .tint(Color.statusFailText)
                    .disabled(!controls.canReject)
                    .accessibilityShowsLargeContentViewer()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: approve) {
                    Text(controls.approveTitle(applyAfterApproval: applyAfterApproval)).fontWeight(.semibold)
                }
                .prominentAction()
                .disabled(!controls.canApprove)
                .accessibilityShowsLargeContentViewer()
            }
        } else {
            bottomBar
        }
    }

    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            // The fail text token is the red that keeps 4.5:1 on light and
            // dark bars; the fill token is for button backgrounds only.
            Button(controls.rejectLabel, role: .destructive, action: reject)
                .tint(Color.statusFailText)
                .disabled(!controls.canReject)
                .accessibilityShowsLargeContentViewer()
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button(action: approve) {
                Text(controls.approveTitle(applyAfterApproval: applyAfterApproval))
                    .fontWeight(.semibold)
            }
            .prominentAction()
            .disabled(!controls.canApprove)
            .accessibilityShowsLargeContentViewer()
        }
    }
}
