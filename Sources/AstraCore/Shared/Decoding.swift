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

enum AstraDateParser {
    static func date(from value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("0001-01-01") else {
            return nil
        }
        return fractionalDateFormatter().date(from: trimmed)
            ?? internetDateFormatter().date(from: trimmed)
    }

    static func string(from date: Date) -> String {
        internetDateFormatter().string(from: date)
    }

    private static func internetDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private static func fractionalDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
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
