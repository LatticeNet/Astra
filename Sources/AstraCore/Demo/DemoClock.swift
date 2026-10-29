import Foundation

/// The one clock a demo launch serves times from. Fixture bodies hold tokens
/// (`{{now}}`, `{{now-12s}}`, `{{now+3d}}`), never literal timestamps;
/// `-AstraDemoNow <RFC3339>` pins the anchor for reproducible screenshots.
public struct DemoClock: Sendable {
    public let anchor: Date
    public let isPinned: Bool

    public init(anchor: Date = Date(), isPinned: Bool = false) {
        self.anchor = anchor
        self.isPinned = isPinned
    }

    /// A clock pinned to an RFC 3339 instant, or nil when it does not parse.
    public init?(pinned rfc3339: String) {
        guard let date = AstraDateParser.date(from: rfc3339) else { return nil }
        self.init(anchor: date, isPinned: true)
    }

    private static let token = try! NSRegularExpression(pattern: #"\{\{now(?:([+-])(\d+)([smhd]))?\}\}"#)

    /// Replaces every time token with an RFC 3339 UTC time relative to the anchor.
    public func substitute(_ body: String) -> String {
        let source = body as NSString
        var result = ""
        var cursor = 0
        for match in Self.token.matches(in: body, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += AstraDateParser.string(from: date(for: match, in: source))
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }

    private func date(for match: NSTextCheckingResult, in source: NSString) -> Date {
        guard match.range(at: 1).location != NSNotFound else { return anchor }
        let sign: Double = source.substring(with: match.range(at: 1)) == "-" ? -1 : 1
        let amount = Double(source.substring(with: match.range(at: 2))) ?? 0
        let unit: Double = switch source.substring(with: match.range(at: 3)) {
        case "m": 60
        case "h": 3_600
        case "d": 86_400
        default: 1
        }
        return anchor.addingTimeInterval(sign * amount * unit)
    }
}
