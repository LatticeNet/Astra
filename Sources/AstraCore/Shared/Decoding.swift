import Foundation

public enum LatticeDecoder {
    public static func decodeNodes(from data: Data) throws -> [LatticeNode] {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(LatticeErrorEnvelope.self, from: data) {
            throw envelope.error.asAPIError()
        }
        if let nodes = try? decoder.decode([LatticeNode].self, from: data) {
            return nodes.sortedByID()
        }
        throw LatticeAPIError.invalidResponse
    }

    static func decodeLogin(from data: Data) throws -> LatticeLoginResponse {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(LatticeErrorEnvelope.self, from: data) {
            throw envelope.error.asAPIError()
        }
        if let response = try? decoder.decode(LatticeLoginResponse.self, from: data) {
            return response
        }
        throw LatticeAPIError.invalidResponse
    }
}

private extension Array where Element == LatticeNode {
    func sortedByID() -> [LatticeNode] {
        sorted {
            $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }
}

enum DateValue {
    static func decodeIfPresent<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> Date? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return AstraDateParser.date(from: value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            let seconds = value > 10_000_000_000 ? value / 1_000 : value
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    static func decodeRequired<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> Date {
        if let value = try decodeIfPresent(from: container, forKey: key) {
            return value
        }
        return Date(timeIntervalSince1970: 0)
    }
}

/// RFC 3339 dates as Go writes them: fractional seconds only when they are
/// not zero. The format styles are Sendable values built once, because
/// building a formatter per value dominated decoding polled lists.
enum AstraDateParser {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    static func date(from value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("0001-01-01") else {
            return nil
        }
        return (try? fractional.parse(trimmed)) ?? (try? whole.parse(trimmed))
    }

    static func string(from date: Date) -> String {
        whole.format(date)
    }
}

/// Decodes list endpoints that answer with a bare array in one form and an
/// envelope (`{"tasks": [...], "total": ...}`) in another, such as
/// `/api/tasks`, `/api/machines`, `/api/monitors` and `/api/task-results`.
public enum LatticeListDecoder {
    public static func decode<Element: Decodable>(_ type: Element.Type, from data: Data, key: String) throws -> [Element] {
        let decoder = JSONDecoder()
        if let items = try? decoder.decode([Element].self, from: data) {
            return items
        }
        decoder.userInfo[.latticeListKey] = key
        do {
            return try decoder.decode(KeyedList<Element>.self, from: data).items
        } catch {
            throw LatticeAPIError.invalidResponse
        }
    }
}

private struct KeyedList<Element: Decodable>: Decodable {
    var items: [Element]

    init(from decoder: Decoder) throws {
        let key = decoder.userInfo[.latticeListKey] as? String ?? "items"
        let container = try decoder.container(keyedBy: LatticeCodingKey.self)
        items = try container.decodeIfPresent([Element].self, forKey: LatticeCodingKey(key)) ?? []
    }
}

/// A coding key built from any string, for envelopes whose key is chosen at run time.
struct LatticeCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension CodingUserInfoKey {
    static let latticeListKey = CodingUserInfoKey(rawValue: "astra.list.key")!
}

/// Finds the exact bytes of each element of a JSON array, so an export can
/// write what the server sent instead of a re-encoding with its keys
/// reordered. Reads the top-level array, or the array under `key` of a
/// top-level object. Returns nil when the text is not shaped that way.
public enum JSONArraySlicer {
    public static func elements(of data: Data, key: String? = nil) -> [Data]? {
        let bytes = [UInt8](data)
        var scanner = Scanner(bytes: bytes)
        scanner.skipWhitespace()
        guard let first = scanner.peek() else { return nil }
        if first == UInt8(ascii: "[") {
            return scanner.arrayElements().map { $0.map { Data(bytes[$0]) } }
        }
        guard let key, first == UInt8(ascii: "{") else { return nil }
        scanner.index += 1
        while true {
            scanner.skipWhitespace()
            guard let next = scanner.peek() else { return nil }
            if next == UInt8(ascii: "}") { return nil }
            if next == UInt8(ascii: ",") {
                scanner.index += 1
                continue
            }
            guard let name = scanner.string() else { return nil }
            scanner.skipWhitespace()
            guard scanner.peek() == UInt8(ascii: ":") else { return nil }
            scanner.index += 1
            scanner.skipWhitespace()
            if name == key {
                guard scanner.peek() == UInt8(ascii: "[") else { return nil }
                return scanner.arrayElements().map { $0.map { Data(bytes[$0]) } }
            }
            guard scanner.skipValue() else { return nil }
        }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipWhitespace() {
            while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
        }

        /// A string at the cursor, decoded; the cursor ends after its closing quote.
        mutating func string() -> String? {
            let start = index
            guard skipString() else { return nil }
            let slice = Data(bytes[start..<index])
            return try? JSONDecoder().decode(String.self, from: slice)
        }

        mutating func skipString() -> Bool {
            guard peek() == UInt8(ascii: "\"") else { return false }
            index += 1
            while let byte = peek() {
                index += 1
                if byte == UInt8(ascii: "\\") {
                    index += 1
                } else if byte == UInt8(ascii: "\"") {
                    return true
                }
            }
            return false
        }

        /// Skips one value of any kind; false on malformed input.
        mutating func skipValue() -> Bool {
            skipWhitespace()
            guard let byte = peek() else { return false }
            switch byte {
            case UInt8(ascii: "\""):
                return skipString()
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                var depth = 0
                while let current = peek() {
                    switch current {
                    case UInt8(ascii: "\""):
                        guard skipString() else { return false }
                        continue
                    case UInt8(ascii: "["), UInt8(ascii: "{"):
                        depth += 1
                    case UInt8(ascii: "]"), UInt8(ascii: "}"):
                        depth -= 1
                        if depth == 0 {
                            index += 1
                            return true
                        }
                    default:
                        break
                    }
                    index += 1
                }
                return false
            default:
                // A number, true, false or null runs to the next delimiter.
                let start = index
                while let current = peek(), ![UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}"), 0x20, 0x09, 0x0A, 0x0D].contains(current) {
                    index += 1
                }
                return index > start
            }
        }

        /// The byte ranges of the elements of the array at the cursor.
        mutating func arrayElements() -> [Range<Int>]? {
            guard peek() == UInt8(ascii: "[") else { return nil }
            index += 1
            var ranges: [Range<Int>] = []
            while true {
                skipWhitespace()
                guard let byte = peek() else { return nil }
                if byte == UInt8(ascii: "]") {
                    index += 1
                    return ranges
                }
                if byte == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                let start = index
                guard skipValue() else { return nil }
                ranges.append(start..<index)
            }
        }
    }
}
