import Foundation

/// Typed values for the list query, a port of the console's
/// `lib/query/values.ts`: numbers with the units a field is measured in,
/// durations, times, wildcards and agent versions. Nil means the text is not
/// a value of that kind, and the engine turns that into a positioned error.
public enum LatticeQueryValues {
    private static let sizeUnits: [String: Double] = [
        "b": 1,
        "k": 1024, "kb": 1000, "kib": 1024,
        "m": pow(1024, 2), "mb": pow(1000, 2), "mib": pow(1024, 2),
        "g": pow(1024, 3), "gb": pow(1000, 3), "gib": pow(1024, 3),
        "t": pow(1024, 4), "tb": pow(1000, 4), "tib": pow(1024, 4),
    ]

    private static let durationUnits: [(String, Double)] = [
        // Longest spelling first, as the console's alternation `sec|min|s|m|h|d|w` reads them.
        ("sec", 1), ("min", 60), ("s", 1), ("m", 60), ("h", 3_600), ("d", 86_400), ("w", 604_800),
    ]

    private static let moment = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3})\d*)?)?)?(Z|[+-]\d{2}:?\d{2})?$"#,
        options: [.caseInsensitive]
    )

    private static let version = try! NSRegularExpression(pattern: #"^v?\d+(\.\d+)*(-[0-9a-z.]+)?$"#, options: [.caseInsensitive])

    private static let boolWords: [String: Bool] = [
        "true": true, "yes": true, "on": true, "y": true, "1": true,
        "false": false, "no": false, "off": false, "n": false, "0": false,
    ]

    /// A number in the field's unit. Percent takes `80` or `80%`. Sizes and
    /// rates take `512`, `10MiB`, `1.5GB`, `10M` (single letters are binary)
    /// and a rate may end in `/s` or `ps`.
    public static func parseNumber(_ text: String, unit: LatticeQueryNumberUnit = .plain) -> Double? {
        let source = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars)
        var i = 0
        if i < source.count, source[i] == "+" || source[i] == "-" { i += 1 }
        let digitsStart = i
        while i < source.count, isDigit(source[i]) { i += 1 }
        let integerDigits = i - digitsStart
        if i < source.count, source[i] == "." {
            let dot = i
            i += 1
            let fractionStart = i
            while i < source.count, isDigit(source[i]) { i += 1 }
            // `\d+(\.\d*)?|\.\d+`: a lone dot needs digits on one side.
            if integerDigits == 0, i == fractionStart { i = dot }
        }
        guard i > digitsStart, integerDigits > 0 || i - digitsStart > 1 else { return nil }
        let numberText = String(String.UnicodeScalarView(source[0..<i]))
        guard let value = Double(numberText.hasSuffix(".") ? numberText + "0" : numberText), value.isFinite else { return nil }
        var suffix = String(String.UnicodeScalarView(source[i...])).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if suffix.isEmpty { return value }
        switch unit {
        case .percent:
            return suffix == "%" ? value : nil
        case .plain:
            return nil
        case .bytes, .rate:
            if unit == .rate {
                if suffix.hasSuffix("/s") {
                    suffix.removeLast(2)
                } else if suffix.hasSuffix("ps") {
                    suffix.removeLast(2)
                }
            }
            return sizeUnits[suffix].map { value * $0 }
        }
    }

    /// Seconds in `30s`, `10m`, `2h`, `3d`, `1w` or a run of them (`1h30m`).
    /// A bare number is seconds, the unit the agent reports uptime in.
    public static func parseDuration(_ text: String) -> Double? {
        let source = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars)
        guard !source.isEmpty else { return nil }
        var i = 0
        if let (value, end) = readDecimal(source, from: 0), end == source.count { return value }
        var total = 0.0
        while i < source.count {
            guard let (value, end) = readDecimal(source, from: i) else { return nil }
            let rest = String(String.UnicodeScalarView(source[end...]))
            guard let (spelling, factor) = durationUnits.first(where: { rest.hasPrefix($0.0) }) else { return nil }
            total += value * factor
            i = end + spelling.unicodeScalars.count
        }
        return total
    }

    /// `\d+(\.\d+)?` at `from`, with the index after it.
    private static func readDecimal(_ source: [Unicode.Scalar], from: Int) -> (Double, Int)? {
        var i = from
        while i < source.count, isDigit(source[i]) { i += 1 }
        guard i > from else { return nil }
        if i + 1 < source.count, source[i] == ".", isDigit(source[i + 1]) {
            i += 1
            while i < source.count, isDigit(source[i]) { i += 1 }
        }
        guard let value = Double(String(String.UnicodeScalarView(source[from..<i]))) else { return nil }
        return (value, i)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57
    }

    /// A moment as epoch milliseconds: `2026-10-01`, `2026-10-01T12:00`, full
    /// ISO. Without a zone the moment is local time, for a bare date as much
    /// as for a date and time. A date the calendar does not have is refused.
    public static func parseTime(_ text: String, timeZone: TimeZone = .current) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = trimmed as NSString
        guard let match = moment.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
        let parts = (1...6).map { Int(group($0) ?? "0") ?? 0 }
        let (year, month, day, hour, minute, second) = (parts[0], parts[1], parts[2], parts[3], parts[4], parts[5])
        let fraction = group(7) ?? "0"
        let millis = Int(fraction.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
        guard (1...12).contains(month), day >= 1, day <= daysIn(month: month, year: year) else { return nil }
        guard hour <= 23, minute <= 59, second <= 59 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        let zone = group(8)
        if let zone {
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
            guard let date = calendar.date(from: components) else { return nil }
            let offset: Int
            if zone.uppercased() == "Z" {
                offset = 0
            } else {
                let digits = zone.unicodeScalars.filter { isDigit($0) }.map { Int($0.value) - 48 }
                let minutes = (digits[0] * 10 + digits[1]) * 60 + digits[digits.count - 2] * 10 + digits[digits.count - 1]
                offset = zone.hasPrefix("-") ? -minutes : minutes
            }
            return (date.timeIntervalSince1970 * 1_000).rounded() + Double(millis) - Double(offset * 60_000)
        }
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else { return nil }
        return (date.timeIntervalSince1970 * 1_000).rounded() + Double(millis)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// `parseBool`: yes, no, on, off, true, false, y, n, 1, 0.
    public static func parseBool(_ text: String) -> Bool? {
        boolWords[text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    /// A pattern with `*` as its only wildcard, anchored at both ends, case-insensitive.
    public static func globMatches(_ pattern: String, _ text: String) -> Bool {
        let pattern = Array(pattern.lowercased())
        let text = Array(text.lowercased())
        var p = 0
        var t = 0
        var star = -1
        var resume = 0
        while t < text.count {
            if p < pattern.count, pattern[p] != "*", pattern[p] == text[t] {
                p += 1
                t += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p
                resume = t
                p += 1
            } else if star >= 0 {
                p = star + 1
                resume += 1
                t = resume
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }

    /// Agent versions compare segment by segment, numerically: 0.3.10 is
    /// newer than 0.3.9. A leading `v` is ignored, and a prerelease
    /// (`-alpha.2`) sorts before its release.
    public static func compareVersions(_ a: String, _ b: String) -> Int {
        func split(_ version: String) -> (core: [String], pre: String) {
            var clean = version.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.first == "v" || clean.first == "V" { clean.removeFirst() }
            guard let dash = clean.firstIndex(of: "-") else {
                return (clean.components(separatedBy: "."), "")
            }
            return (String(clean[..<dash]).components(separatedBy: "."), String(clean[clean.index(after: dash)...]))
        }
        let x = split(a)
        let y = split(b)
        for i in 0..<max(x.core.count, y.core.count) {
            let p = i < x.core.count ? x.core[i] : "0"
            let q = i < y.core.count ? y.core[i] : "0"
            let diff: Int
            if let pn = jsNumber(p), let qn = jsNumber(q) {
                diff = pn < qn ? -1 : (pn > qn ? 1 : 0)
            } else {
                diff = localeCompare(p, q, numeric: false)
            }
            if diff != 0 { return diff }
        }
        if x.pre == y.pre { return 0 }
        if x.pre.isEmpty { return 1 }
        if y.pre.isEmpty { return -1 }
        return localeCompare(x.pre, y.pre, numeric: true)
    }

    /// A version as typed: digits first, or a v and digits.
    public static func looksLikeVersion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil
    }

    /// Relevance of one word in one text: exact 100, prefix 70, substring 50, subsequence 20.
    public static func textScore(_ haystack: String, _ needle: String, fuzzy: Bool) -> Double {
        if needle.isEmpty { return 0 }
        if haystack == needle { return 100 }
        if haystack.hasPrefix(needle) { return 70 }
        if haystack.contains(needle) { return 50 }
        if fuzzy, subsequence(haystack, needle) { return 20 }
        return 0
    }

    /// Every character of the needle, in order: "gmhk" finds "gomami-hkg".
    public static func subsequence(_ haystack: String, _ needle: String) -> Bool {
        var remaining = needle[...]
        for character in haystack where remaining.first == character {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }

    /// Edit distance, capped: enough to suggest `status` for `stauts`.
    public static func editDistance(_ a: String, _ b: String, cap: Int = 3) -> Int {
        let a = Array(a.utf16)
        let b = Array(b.utf16)
        if abs(a.count - b.count) > cap { return cap + 1 }
        var previous = Array(0...b.count)
        guard !a.isEmpty else { return previous[b.count] }
        for i in 1...a.count {
            var row = [i]
            var best = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                let value = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + cost)
                row.append(value)
                best = min(best, value)
            }
            if best > cap { return cap + 1 }
            previous = row
        }
        return previous[b.count]
    }

    /// JavaScript's `Number(text)` for the plain decimal texts versions hold:
    /// empty is zero, anything that is not a number is nil.
    static func jsNumber(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        guard trimmed.unicodeScalars.allSatisfy({ isDigit($0) || $0 == "." || $0 == "+" || $0 == "-" || $0 == "e" || $0 == "E" }) else { return nil }
        return Double(trimmed)
    }

    /// `String.prototype.localeCompare` with the root collation, optionally numeric.
    static func localeCompare(_ a: String, _ b: String, numeric: Bool, ignoreCase: Bool = false) -> Int {
        var options: String.CompareOptions = []
        if numeric { options.insert(.numeric) }
        if ignoreCase { options.formUnion([.caseInsensitive, .diacriticInsensitive]) }
        switch a.compare(b, options: options, range: nil, locale: collationLocale) {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }

    private static let collationLocale = Locale(identifier: "en")
}
