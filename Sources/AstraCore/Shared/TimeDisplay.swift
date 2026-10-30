import Foundation

/// The row-level spellings of `TimeDisplay`, kept so every screen reads ages
/// one way ("12 min. ago", "3h") whichever entry point it calls (6.16).
public enum RelativeDateFormatter {
    /// A relative age through `TimeDisplay.relative`.
    public static func string(from date: Date, now: Date = Date(), locale: Locale = .current) -> String {
        TimeDisplay.relative(date, now: now, locale: locale)
    }

    /// A compact duration through `TimeDisplay.shortDuration`.
    public static func shortDuration(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        TimeDisplay.shortDuration(seconds, locale: locale)
    }
}

/// Which zone times are shown in (Settings > Display, section 6.16).
public enum TimeZoneMode: String, Codable, Sendable, CaseIterable {
    case local
    case utc

    public var timeZone: TimeZone {
        switch self {
        case .local: .current
        case .utc: TimeZone(identifier: "UTC") ?? .gmt
        }
    }

    /// The other mode, for the secondary line of a detail row.
    public var other: TimeZoneMode {
        self == .local ? .utc : .local
    }
}

/// Pure time formatting. Every function takes the zone mode and locale
/// explicitly, so the locale's 12 or 24-hour setting applies and checks can
/// pin both. UTC text always says "UTC", never a bare "Z".
public enum TimeDisplay {
    /// A clock time: "14:05" or "2:05 PM", with " UTC" in UTC mode.
    public static func clock(_ date: Date, mode: TimeZoneMode, locale: Locale) -> String {
        suffixed(date.formatted(style(mode: mode, locale: locale).hour().minute()), mode: mode)
    }

    /// A date and clock time: "Oct 28, 14:05", with " UTC" in UTC mode.
    public static func dateTime(_ date: Date, mode: TimeZoneMode, locale: Locale) -> String {
        suffixed(date.formatted(style(mode: mode, locale: locale).month(.abbreviated).day().hour().minute()), mode: mode)
    }

    /// The same instant in the other zone, for a detail row's secondary line.
    public static func otherZone(_ date: Date, mode: TimeZoneMode, locale: Locale) -> String {
        dateTime(date, mode: mode.other, locale: locale)
    }

    /// Server prose with each RFC 3339 stamp ("No report since
    /// 2026-10-29T03:20:00Z; ...") shown as `dateTime` in the chosen zone.
    /// Node and waiting reasons embed stamps (stamp, node_status.go).
    public static func localizingStamps(in text: String, mode: TimeZoneMode, locale: Locale) -> String {
        guard text.contains("T"), let regex = try? Regex(#"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})"#) else { return text }
        return text.replacing(regex) { match in
            let raw = String(text[match.range])
            return AstraDateParser.date(from: raw).map { dateTime($0, mode: mode, locale: locale) } ?? raw
        }
    }

    /// A relative age: "12 min. ago", "in 3 days".
    public static func relative(_ date: Date, now: Date, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// A compact duration for rows, in the locale's abbreviations: "45s",
    /// "12m", "3h", "2d". It counts whole units, so 1 h 50 min reads "1h".
    public static func shortDuration(_ seconds: TimeInterval, locale: Locale) -> String {
        let value = max(0, seconds.rounded())
        let unit: TimeInterval = value >= 86_400 ? 86_400 : value >= 3_600 ? 3_600 : value >= 60 ? 60 : 1
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        return formatter.string(from: (value / unit).rounded(.down) * unit) ?? ""
    }

    /// A duration for VoiceOver and age phrases: "12 minutes", "3 hours".
    public static func duration(_ seconds: TimeInterval, locale: Locale) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        return formatter.string(from: max(0, seconds)) ?? ""
    }

    private static func style(mode: TimeZoneMode, locale: Locale) -> Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.locale(locale)
        style.timeZone = mode.timeZone
        return style
    }

    private static func suffixed(_ text: String, mode: TimeZoneMode) -> String {
        mode == .utc ? text + " UTC" : text
    }
}
