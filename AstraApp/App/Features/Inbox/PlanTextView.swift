import SwiftUI
import UIKit

/// The read-only, find-enabled plan view (M1-02). It shows exactly the
/// string it is given, the same string `PlanHasher` hashed; wrapping,
/// highlighting and the line gutter change layout only, never the text.
///
/// It never scrolls itself: it is sized to its whole height inside the
/// sheet's one vertical scroll view, and when lines do not wrap it sits in
/// a horizontal scroll view (a different axis).
struct PlanTextView: View {
    let text: String
    var wraps = true
    /// Match ranges to highlight, in UTF-16 offsets of `text`.
    var matches: [NSRange] = []
    /// The match the find bar is on.
    var currentMatch: Int?
    /// Reports the current match's rectangle in this view's coordinates.
    var onCurrentMatchRect: (@MainActor (CGRect) -> Void)?

    var body: some View {
        let plan = InboxPlanTextRepresentable(text: text, wraps: wraps, matches: matches, currentMatch: currentMatch, onCurrentMatchRect: onCurrentMatchRect)
        if wraps {
            plan
        } else {
            ScrollView(.horizontal) {
                plan
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }

    /// Every case-insensitive match of `query` in `text`, as UTF-16 ranges.
    static func ranges(of query: String, in text: String) -> [NSRange] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let haystack = text as NSString
        var found: [NSRange] = []
        var search = NSRange(location: 0, length: haystack.length)
        while search.length > 0 {
            let range = haystack.range(of: needle, options: [.caseInsensitive], range: search)
            guard range.location != NSNotFound else { break }
            found.append(range)
            let next = range.location + max(range.length, 1)
            search = NSRange(location: next, length: haystack.length - next)
        }
        return found
    }
}

/// The UIKit text view behind `PlanTextView`, with its line-number gutter.
struct InboxPlanTextRepresentable: UIViewRepresentable {
    let text: String
    let wraps: Bool
    let matches: [NSRange]
    let currentMatch: Int?
    let onCurrentMatchRect: (@MainActor (CGRect) -> Void)?

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> InboxPlanTextContainer {
        InboxPlanTextContainer()
    }

    func updateUIView(_ view: InboxPlanTextContainer, context: Context) {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        view.configure(
            text: text,
            font: UIFontMetrics(forTextStyle: .callout).scaledFont(for: .monospacedSystemFont(ofSize: 16, weight: .regular), compatibleWith: traits),
            wraps: wraps,
            matches: matches,
            currentMatch: currentMatch
        )
        view.onCurrentMatchRect = onCurrentMatchRect
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: InboxPlanTextContainer, context: Context) -> CGSize? {
        uiView.fittingSize(width: wraps ? proposal.width : nil)
    }
}

/// A non-scrolling text view and a gutter that numbers logical lines and
/// marks soft-wrapped continuations with a hook.
final class InboxPlanTextContainer: UIView {
    private let textView = UITextView(usingTextLayoutManager: false)
    private let gutter = InboxPlanGutterView()
    private var wraps = true
    private var font = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    private var currentMatchRange: NSRange?
    private var lastReportedRect: CGRect?
    var onCurrentMatchRect: (@MainActor (CGRect) -> Void)?

    private let insets = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 4)
    private let gutterGap: CGFloat = 10

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = insets
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        textView.accessibilityLabel = "Plan"
        addSubview(gutter)
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(text: String, font: UIFont, wraps: Bool, matches: [NSRange], currentMatch: Int?) {
        self.font = font
        self.wraps = wraps
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ])
        let length = (text as NSString).length
        for (index, range) in matches.enumerated() where NSMaxRange(range) <= length {
            let isCurrent = index == currentMatch
            attributed.addAttribute(.backgroundColor, value: UIColor(named: "AccentText")?.withAlphaComponent(isCurrent ? 0.45 : 0.18) ?? UIColor.systemBlue, range: range)
        }
        currentMatchRange = currentMatch.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        if textView.attributedText != attributed {
            textView.attributedText = attributed
        }
        textView.textContainer.widthTracksTextView = wraps
        textView.textContainer.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        gutter.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), compatibleWith: traitCollection)
        gutter.lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private var gutterWidth: CGFloat {
        let digits = max(2, String(gutter.lineCount).count)
        let sample = String(repeating: "8", count: digits) as NSString
        let width = sample.size(withAttributes: [.font: gutter.font]).width
        return ceil(width) + 4
    }

    /// The size the whole plan needs at `width` (nil: unwrapped, natural width).
    func fittingSize(width: CGFloat?) -> CGSize {
        let leading = gutterWidth + gutterGap
        if let width {
            let textWidth = max(40, width - leading)
            let size = textView.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
            return CGSize(width: width, height: ceil(size.height))
        }
        let manager = textView.layoutManager
        textView.textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: textView.textContainer)
        let used = manager.usedRect(for: textView.textContainer)
        return CGSize(width: ceil(leading + used.width + insets.left + insets.right + 8), height: ceil(used.height + insets.top + insets.bottom))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let leading = gutterWidth + gutterGap
        gutter.frame = CGRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        textView.frame = CGRect(x: leading, y: 0, width: max(0, bounds.width - leading), height: bounds.height)
        if !wraps {
            textView.textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        gutter.lines = lineMarks()
        gutter.setNeedsDisplay()
        reportCurrentMatch()
    }

    /// Where each line fragment sits and whether it starts a logical line.
    private func lineMarks() -> [InboxPlanGutterView.Mark] {
        let manager = textView.layoutManager
        let text = textView.textStorage.string as NSString
        var marks: [InboxPlanGutterView.Mark] = []
        var number = 0
        let glyphs = manager.glyphRange(for: textView.textContainer)
        manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, glyphRange, _ in
            let characterIndex = manager.characterIndexForGlyph(at: glyphRange.location)
            let startsLine = characterIndex == 0 || text.character(at: characterIndex - 1) == 10
            if startsLine { number += 1 }
            marks.append(.init(y: rect.minY + self.insets.top, height: rect.height, number: startsLine ? number : nil))
        }
        // An empty last line after a trailing newline still has a number.
        if text.length > 0, text.character(at: text.length - 1) == 10 {
            let extra = manager.extraLineFragmentRect
            if extra.height > 0 { marks.append(.init(y: extra.minY + insets.top, height: extra.height, number: number + 1)) }
        }
        return marks
    }

    private func reportCurrentMatch() {
        guard let range = currentMatchRange, let report = onCurrentMatchRect else { return }
        let manager = textView.layoutManager
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = manager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
        rect = rect.offsetBy(dx: textView.frame.minX + insets.left, dy: insets.top)
        guard rect != lastReportedRect else { return }
        lastReportedRect = rect
        DispatchQueue.main.async { report(rect) }
    }
}

/// Line numbers, hidden from VoiceOver: the text itself is the content.
final class InboxPlanGutterView: UIView {
    struct Mark {
        let y: CGFloat
        let height: CGFloat
        /// Nil on a soft-wrapped continuation, which shows a hook instead.
        let number: Int?
    }

    var lines: [Mark] = []
    var lineCount = 0
    var font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.tertiaryLabel]
        let hook = UIImage(systemName: "arrow.turn.down.right", withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small))?
            .withTintColor(.tertiaryLabel, renderingMode: .alwaysOriginal)
        for mark in lines {
            if let number = mark.number {
                let label = "\(number)" as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(at: CGPoint(x: bounds.width - size.width, y: mark.y + (mark.height - size.height) / 2), withAttributes: attributes)
            } else if let hook {
                let size = hook.size
                hook.draw(at: CGPoint(x: bounds.width - size.width, y: mark.y + (mark.height - size.height) / 2))
            }
        }
    }
}
