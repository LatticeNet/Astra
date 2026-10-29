import Foundation

public enum RelativeDateFormatter {
    public static func string(from date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 0 {
            return shortDuration(-interval) + " from now"
        }
        if interval < 5 {
            return "just now"
        }
        return shortDuration(interval) + " ago"
    }

    /// Compact human duration: "45s", "12m", "3h", "2d".
    public static func shortDuration(_ seconds: TimeInterval) -> String {
        let value = Int(seconds.rounded())
        if value < 60 { return "\(value)s" }
        let minutes = value / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        return "\(days)d"
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

    /// A relative age: "12 min. ago", "in 3 days".
    public static func relative(_ date: Date, now: Date, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
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
