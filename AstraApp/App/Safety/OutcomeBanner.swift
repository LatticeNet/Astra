import SwiftUI
import UIKit

/// What the banner says after a write (F-16).
struct BannerMessage: Identifiable {
    let id = UUID()
    let text: String
    var tone: StatusTone = .quiet
    /// Present only when the write has a verified inverse.
    var undo: (@MainActor () -> Void)?
    /// A chevron to the object, for partial results.
    var open: (@MainActor () -> Void)?
}

/// Owns the one banner on screen and its timer: 10 s, paused while touched or
/// focused by VoiceOver, and kept until dismissed while VoiceOver or Switch
/// Control runs.
@MainActor @Observable
final class BannerCenter {
    private(set) var current: BannerMessage?
    /// The banner's frame in window coordinates, so the banner window claims
    /// touches only there.
    @ObservationIgnored var bannerFrame: CGRect?
    var isHeld = false {
        didSet { if !isHeld { scheduleDismissal() } }
    }
    @ObservationIgnored private var timer: Task<Void, Never>?

    func show(_ message: BannerMessage) {
        current = message
        let announcement = message.undo == nil ? message.text : "\(message.text). Undo available"
        AccessibilityNotification.Announcement(announcement).post()
        scheduleDismissal()
    }

    func dismiss() {
        timer?.cancel()
        current = nil
    }

    private func scheduleDismissal() {
        timer?.cancel()
        guard current != nil, !isHeld,
              !UIAccessibility.isVoiceOverRunning, !UIAccessibility.isSwitchControlRunning else { return }
        let id = current?.id
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.current?.id == id else { return }
            self.current = nil
        }
    }
}

/// The banner itself: an opaque rounded rectangle, never glass (section 4.11).
/// Lives in the scene-level `BannerWindow`, above every sheet.
struct OutcomeBannerView: View {
    let center: BannerCenter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @AccessibilityFocusState private var focused: Bool

    var body: some View {
        VStack {
            Spacer()
            if let message = center.current {
                banner(message)
                    .padding(.horizontal, Spacing.l)
                    .padding(.bottom, Spacing.xxl * 2)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .id(message.id)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth, value: center.current?.id)
    }

    private func banner(_ message: BannerMessage) -> some View {
        let accessible = typeSize.isAccessibilitySize
        let layout = accessible
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.s))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.m))
        return layout {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                if message.tone.isProblem {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(message.tone.glyph)
                        .accessibilityHidden(true)
                }
                Text(message.text)
                    .foregroundStyle(message.tone.isProblem ? message.tone.word : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !accessible { Spacer(minLength: 0) }
            HStack(spacing: Spacing.m) {
                if let undo = message.undo {
                    Button("Undo") {
                        center.dismiss()
                        undo()
                    }
                    .fontWeight(.semibold)
                    .frame(minHeight: Spacing.minimumTarget)
                }
                if let open = message.open {
                    Button {
                        center.dismiss()
                        open()
                    } label: {
                        Image(systemName: "chevron.right")
                            .frame(minWidth: Spacing.minimumTarget, minHeight: Spacing.minimumTarget)
                    }
                    .accessibilityLabel("Show details")
                }
                Button {
                    center.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: Spacing.minimumTarget, minHeight: Spacing.minimumTarget)
                }
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(uiColor: .separator), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { center.bannerFrame = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityFocused($focused)
        .onChange(of: focused) { center.isHeld = focused }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !center.isHeld { center.isHeld = true } }
                .onEnded { _ in center.isHeld = false }
        )
    }
}
