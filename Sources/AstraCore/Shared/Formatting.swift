import Foundation

public enum ByteFormatter {
    public static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var amount = Double(value)
        var index = 0
        while amount >= 1024, index < units.count - 1 {
            amount /= 1024
            index += 1
        }
        if index == 0 {
            return "\(value) \(units[index])"
        }
        return String(format: "%.1f %@", amount, units[index])
    }

    public static func speed(_ value: UInt64) -> String {
        "\(bytes(value))/s"
    }

    public static func speed(_ value: Double) -> String {
        let clamped = max(0, value)
        if clamped >= Double(UInt64.max) {
            return speed(UInt64.max)
        }
        return speed(UInt64(clamped.rounded()))
    }
}

public enum PercentFormatter {
    public static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    public static func fraction(_ value: Double?) -> String {
        guard let value else {
            return "--"
        }
        return percent(value * 100)
    }
}

public enum DurationFormatter {
    public static func seconds(_ value: TimeInterval) -> String {
        let seconds = Int(value.rounded())
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        return "\(hours)h \(minutes % 60)m"
    }
}

public enum CurrencyFormatter {
    public static func string(amountMajorUnits amount: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !code.isEmpty {
            formatter.currencyCode = code
        }
        if let formatted = formatter.string(from: NSNumber(value: amount)) {
            return formatted
        }
        return String(format: "%.2f %@", amount, code)
    }
}

public enum UptimeFormatter {
    /// Render an uptime in seconds as "12d 4h" / "4h 12m" / "12m".
    public static func string(seconds: UInt64) -> String {
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }
}

/// Hostnames, paths, keys and ids inside rows and sentences. At large text
/// sizes the text system would otherwise hyphenate "relay-fra-1" mid-word;
/// a zero-width space after each separator gives it a better place to break.
public enum IdentifierText {
    public static func breakable(_ identifier: String) -> String {
        var out = ""
        for character in identifier {
            out.append(character)
            if ".:/-_".contains(character) { out.append("\u{200B}") }
        }
        return out
    }
}
