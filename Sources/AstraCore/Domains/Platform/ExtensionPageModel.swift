import Foundation

/// Third-party extension pages drawn natively from a plugin manifest, the
/// model `PluginView.vue` renders (M8-03). Table and detail kinds render on
/// the phone; every other kind, and every manifest action, opens on the web.
public enum ExtensionPageModel {
    /// How the phone draws a view kind.
    public enum Kind: Sendable, Hashable {
        case table, detail
        /// form, kv, markdown, sandbox and anything unknown.
        case web

        public init(_ raw: String) {
            switch raw {
            case "table": self = .table
            case "detail": self = .detail
            default: self = .web
            }
        }
    }

    /// The column render hints the server allows; anything else is plain text.
    public static let allowedRenders: Set<String> = ["", "copy-secret", "bytes", "relative-time", "badge", "code"]

    /// One column as the phone draws it.
    public struct Column: Hashable, Sendable {
        public var key: String
        public var label: String
        public var render: String
    }

    /// One cell, already formatted. A secret is masked and never offered as text.
    public struct Cell: Hashable, Sendable {
        public var label: String
        public var text: String
        public var render: String
        public var isSecret: Bool { render == "copy-secret" }
        public var isCode: Bool { render == "code" }
    }

    /// One row: its cells in column order and a stable key.
    public struct Row: Hashable, Sendable, Identifiable {
        public var id: String
        public var cells: [Cell]

        /// The first non-secret value, used as the row title.
        public var title: String {
            cells.first { !$0.isSecret && !$0.text.isEmpty }?.text ?? id
        }
    }

    /// The page resolved from the plugin's contributions.
    public struct Page: Hashable, Sendable {
        public var pluginID: String
        public var pluginName: String
        public var view: PlatformViewContribution
        public var kind: Kind
        /// The scopes the source call needs: the method's, else the interface's, else the nav entry's.
        public var requiredScopes: [String]
        public var consolePath: String
        /// The source method's declared effect, or nil when the plugin's
        /// interfaces do not declare it.
        public var sourceEffect: String?

        public var hasSource: Bool { view.source.map { !$0.interface.isEmpty && !$0.method.isEmpty } ?? false }
        /// The phone calls a source only when it is declared a read: a
        /// manifest may bind a view to a write or plan method, and opening a
        /// page must never change anything.
        public var sourceIsRead: Bool { hasSource && sourceEffect == "read" }
    }

    /// The page for `route`, or nil when the plugin contributes none.
    public static func page(plugin: PlatformPlugin, route: String) -> Page? {
        guard let view = plugin.ui?.views.first(where: { $0.route == route }) else { return nil }
        var scopes: [String] = []
        var effect: String?
        if let source = view.source, !source.interface.isEmpty {
            let contract = plugin.interfaces.first { $0.service == source.interface }
            scopes = contract?.scopes(for: source.method) ?? []
            effect = contract?.effect(of: source.method)
        }
        if scopes.isEmpty {
            scopes = plugin.ui?.nav.first { $0.route == view.route }?.scopes ?? []
        }
        return Page(pluginID: plugin.id, pluginName: plugin.name.isEmpty ? plugin.id : plugin.name, view: view,
                    kind: Kind(view.kind), requiredScopes: scopes, consolePath: "/plugins/\(plugin.id)/\(route)",
                    sourceEffect: effect)
    }

    /// The rows of a source answer (`asRows`): a bare array, or `{rows: [...]}`.
    public static func rows(of data: PlatformJSONValue) -> [PlatformJSONValue] {
        switch data {
        case .array(let items): return items
        case .object:
            if case .array(let items)? = data["rows"] { return items }
            return []
        default: return []
        }
    }

    /// The declared columns, or the first row's keys when none are declared.
    public static func columns(view: PlatformViewContribution, rows: [PlatformJSONValue]) -> [Column] {
        if !view.columns.isEmpty {
            return view.columns.map { column in
                Column(key: column.key, label: column.label.isEmpty ? column.key : column.label,
                       render: allowedRenders.contains(column.render) ? column.render : "")
            }
        }
        guard case .object(let pairs)? = rows.first else { return [] }
        return pairs.map { Column(key: $0.0, label: $0.0, render: "") }
    }

    /// Table rows with formatted cells and keys unique per fetch.
    public static func tableRows(view: PlatformViewContribution, data: PlatformJSONValue, now: Date, locale: Locale) -> (columns: [Column], rows: [Row]) {
        let source = rows(of: data)
        let columns = columns(view: view, rows: source)
        let rows = source.enumerated().map { index, row in
            let primary = ["id", "node_id", "name", "key"].lazy.compactMap { row[$0]?.scalarText }.first ?? row.compactText
            return Row(id: "\(primary)#\(index)", cells: columns.map { column in
                Cell(label: column.label, text: format(row[column.key], render: column.render, now: now, locale: locale), render: column.render)
            })
        }
        return (columns, rows)
    }

    /// The description list of a detail page (`kvObject`): the first row of
    /// a rows answer, else the object itself. Declared columns pick and
    /// label the fields; otherwise every field shows in the order sent.
    public static func detailCells(view: PlatformViewContribution, data: PlatformJSONValue, now: Date, locale: Locale) -> [Cell] {
        let object: PlatformJSONValue?
        if case .object = data, data["rows"] == nil {
            object = data
        } else {
            object = rows(of: data).first
        }
        guard case .object(let pairs)? = object else { return [] }
        if !view.columns.isEmpty {
            return columns(view: view, rows: []).map { column in
                Cell(label: column.label, text: format(object?[column.key], render: column.render, now: now, locale: locale), render: column.render)
            }
        }
        return pairs.map { Cell(label: $0.0, text: format($0.1, render: "", now: now, locale: locale), render: "") }
    }

    /// A value as the console's render hints show it. Secrets keep only a
    /// recognisable scheme; nothing else of them reaches the screen.
    public static func format(_ value: PlatformJSONValue?, render: String, now: Date, locale: Locale) -> String {
        guard let value, value != .null else { return render == "copy-secret" ? "None" : "" }
        switch render {
        case "copy-secret":
            let text = value.compactText
            if text.isEmpty { return "None" }
            if let range = text.range(of: "://"), range.lowerBound > text.startIndex {
                return "\(text[..<range.lowerBound])://••••••"
            }
            return "••••••"
        case "bytes":
            if let number = value.number, number >= 0 { return ByteFormatter.bytes(UInt64(number)) }
            return value.compactText
        case "relative-time":
            if let date = value.date {
                let formatter = RelativeDateTimeFormatter()
                formatter.locale = locale
                formatter.unitsStyle = .full
                return formatter.localizedString(for: date, relativeTo: now)
            }
            return value.compactText
        default:
            return value.compactText
        }
    }
}

/// An ordered JSON value. Plugin answers are not versioned, so pages read
/// them generically; object keys keep the order the plugin sent them in,
/// which a dictionary would lose.
public indirect enum PlatformJSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PlatformJSONValue])
    case object([(String, PlatformJSONValue)])

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.number(a), .number(b)): a == b
        case let (.string(a), .string(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.object(a), .object(b)): a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(compactText)
    }

    public subscript(key: String) -> PlatformJSONValue? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.0 == key }?.1
    }

    public var number: Double? {
        switch self {
        case .number(let value): value
        case .string(let text): Double(text)
        default: nil
        }
    }

    /// A date from an RFC 3339 string or unix seconds.
    public var date: Date? {
        switch self {
        case .string(let text): AstraDateParser.date(from: text)
        case .number(let value): Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
        default: nil
        }
    }

    /// Text of a scalar; nil for arrays and objects.
    public var scalarText: String? {
        switch self {
        case .null: nil
        case .bool(let value): value ? "true" : "false"
        case .number(let value):
            value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .string(let text): text
        case .array, .object: nil
        }
    }

    /// The console's `toText`: scalars as text, containers as compact JSON.
    public var compactText: String {
        if let scalar = scalarText { return scalar }
        switch self {
        case .null: return ""
        case .array(let items): return "[" + items.map(\.jsonText).joined(separator: ",") + "]"
        case .object(let pairs): return "{" + pairs.map { "\(Self.quote($0.0)):\($0.1.jsonText)" }.joined(separator: ",") + "}"
        default: return ""
        }
    }

    private var jsonText: String {
        switch self {
        case .null: "null"
        case .string(let text): Self.quote(text)
        default: compactText
        }
    }

    private static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Parses JSON text, keeping object key order. Throws `.invalidResponse`
    /// on malformed input, which a page shows as companion behind.
    public static func parse(_ data: Data) throws -> PlatformJSONValue {
        var parser = PlatformJSONParser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.atEnd else { throw LatticeAPIError.invalidResponse }
        return value
    }
}

private struct PlatformJSONParser {
    let bytes: [UInt8]
    var index = 0

    var atEnd: Bool { index >= bytes.count }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    mutating func value(depth: Int) throws -> PlatformJSONValue {
        guard depth < 64, index < bytes.count else { throw LatticeAPIError.invalidResponse }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try object(depth: depth)
        case UInt8(ascii: "["): return try array(depth: depth)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return .number(try number())
        }
    }

    mutating func literal(_ word: String) throws {
        let expected = Array(word.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
            throw LatticeAPIError.invalidResponse
        }
        index += expected.count
    }

    mutating func number() throws -> Double {
        let start = index
        while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
        guard index > start, let text = String(bytes: bytes[start..<index], encoding: .utf8), let value = Double(text) else {
            throw LatticeAPIError.invalidResponse
        }
        return value
    }

    mutating func string() throws -> String {
        index += 1
        var scalars = String.UnicodeScalarView()
        var run: [UInt8] = []
        func flush() {
            if !run.isEmpty {
                scalars.append(contentsOf: String(decoding: run, as: UTF8.self).unicodeScalars)
                run.removeAll()
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                flush()
                return String(scalars)
            }
            if byte == UInt8(ascii: "\\") {
                flush()
                index += 1
                guard index < bytes.count else { break }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        // Pair only with a real low surrogate. Anything else leaves
                        // the high half as U+FFFD and the next escape is read on its own.
                        let mark = index
                        index += 2
                        if let low = try? hex4(), (0xDC00...0xDFFF).contains(low) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            index = mark
                        }
                    }
                    scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default: scalars.append(Unicode.Scalar(escape))
                }
                continue
            }
            run.append(byte)
            index += 1
        }
        throw LatticeAPIError.invalidResponse
    }

    mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count, let text = String(bytes: bytes[index..<index + 4], encoding: .utf8), let value = UInt32(text, radix: 16) else {
            throw LatticeAPIError.invalidResponse
        }
        index += 4
        return value
    }

    mutating func array(depth: Int) throws -> PlatformJSONValue {
        index += 1
        var items: [PlatformJSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            items.append(try value(depth: depth + 1))
            skipWhitespace()
            guard index < bytes.count else { throw LatticeAPIError.invalidResponse }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            throw LatticeAPIError.invalidResponse
        }
    }

    mutating func object(depth: Int) throws -> PlatformJSONValue {
        index += 1
        var pairs: [(String, PlatformJSONValue)] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(pairs)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw LatticeAPIError.invalidResponse }
            let key = try string()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw LatticeAPIError.invalidResponse }
            index += 1
            skipWhitespace()
            pairs.append((key, try value(depth: depth + 1)))
            skipWhitespace()
            guard index < bytes.count else { throw LatticeAPIError.invalidResponse }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
            throw LatticeAPIError.invalidResponse
        }
    }
}
