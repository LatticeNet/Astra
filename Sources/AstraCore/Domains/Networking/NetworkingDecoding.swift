import Foundation

// Lenient readers for the Networking views. The server leaves out empty
// fields (`omitempty`) and writes an unset time as Go's year 1, so every
// optional field falls back to its zero value and a year-1 time reads as no
// time. Only identifiers are required: a row without one cannot be opened.
extension KeyedDecodingContainer where K == LatticeCodingKey {
    func networkingRequired(_ key: String) throws -> String {
        try decode(String.self, forKey: LatticeCodingKey(key))
    }

    func networkingString(_ key: String) -> String {
        (try? decodeIfPresent(String.self, forKey: LatticeCodingKey(key))) ?? ""
    }

    func networkingInt(_ key: String) -> Int {
        if let value = try? decodeIfPresent(Int.self, forKey: LatticeCodingKey(key)) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: LatticeCodingKey(key)) { return Int(value) }
        return 0
    }

    func networkingBool(_ key: String) -> Bool {
        (try? decodeIfPresent(Bool.self, forKey: LatticeCodingKey(key))) ?? false
    }

    func networkingStrings(_ key: String) -> [String] {
        (try? decodeIfPresent([String].self, forKey: LatticeCodingKey(key))) ?? []
    }

    func networkingInts(_ key: String) -> [Int] {
        (try? decodeIfPresent([Int].self, forKey: LatticeCodingKey(key))) ?? []
    }

    /// A time, or nil when absent, unreadable or Go's zero time.
    func networkingDate(_ key: String) -> Date? {
        guard let date = try? DateValue.decodeIfPresent(from: self, forKey: LatticeCodingKey(key)) else { return nil }
        return NetworkingTime.plausible(date)
    }

    /// A nested object; a malformed one is a decoding error, never dropped.
    func networkingObject<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
        try decodeIfPresent(T.self, forKey: LatticeCodingKey(key))
    }

    /// A list of objects; absent or null reads as empty.
    func networkingList<T: Decodable>(_ type: T.Type, _ key: String) throws -> [T] {
        try decodeIfPresent([T].self, forKey: LatticeCodingKey(key)) ?? []
    }
}

public enum NetworkingTime {
    /// Times before 2000 are Go zero values or clock garbage, never real.
    public static func plausible(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSince1970 >= 946_684_800 else { return nil }
        return date
    }
}
