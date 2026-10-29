import Foundation

/// A small JSON value for building fixture bodies from `DemoWorld`, so every
/// route reads from the same invented fleet. Object keys keep their order,
/// which keeps bodies stable and close to the server's own field order.
/// Times are written as `DemoClock` tokens (`{{now-5m}}`), never literals.
public indirect enum DemoJSON: Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByFloatLiteral {
    case object([(String, DemoJSON)])
    case array([DemoJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    /// JSON text written as is, such as a body stored in `DemoState`.
    case raw(String)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: DemoJSON...) { self = .array(elements) }

    /// An object from ordered pairs; `nil` values are left out, as the
    /// server's `omitempty` fields are.
    public static func object(_ pairs: KeyValuePairs<String, DemoJSON?>) -> DemoJSON {
        .object(pairs.compactMap { key, value in value.map { (key, $0) } })
    }

    /// A time token relative to the demo clock: `.time("-5m")` is `{{now-5m}}`.
    public static func time(_ offset: String = "") -> DemoJSON {
        .string("{{now\(offset)}}")
    }

    public static func strings(_ values: [String]) -> DemoJSON {
        .array(values.map(DemoJSON.string))
    }

    public static func == (lhs: DemoJSON, rhs: DemoJSON) -> Bool { lhs.text == rhs.text }
    public func hash(into hasher: inout Hasher) { hasher.combine(text) }

    /// The compact JSON text.
    public var text: String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .object(let pairs):
            out += "{"
            for (index, pair) in pairs.enumerated() {
                if index > 0 { out += "," }
                Self.writeString(pair.0, to: &out)
                out += ":"
                pair.1.write(to: &out)
            }
            out += "}"
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                item.write(to: &out)
            }
            out += "]"
        case .string(let value):
            Self.writeString(value, to: &out)
        case .number(let value):
            out += value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .bool(let value):
            out += value ? "true" : "false"
        case .null:
            out += "null"
        case .raw(let text):
            out += text
        }
    }

    private static func writeString(_ value: String, to out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let control where control.value < 0x20:
                out += String(format: "\\u%04x", control.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}
