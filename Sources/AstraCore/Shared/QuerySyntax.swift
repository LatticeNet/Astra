import Foundation

// Ports of the console's query grammar (`lib/query/syntax.ts`, `engine.ts`,
// `values.ts`), section 6.14. Lists filter on device with a compiled query;
// the golden is `Checks/AstraCoreCheck/Fixtures/query-vectors.json`.

/// `:` contains, `=` exact, and the four comparisons.
public enum LatticeQueryOperator: String, Sendable, Hashable, CaseIterable {
    case contains = ":"
    case exact = "="
    case greater = ">"
    case greaterOrEqual = ">="
    case less = "<"
    case lessOrEqual = "<="
}

/// One value of a term, with its source offsets.
public struct LatticeQueryValue: Sendable, Hashable {
    public var text: String
    public var quoted: Bool
    public var start: Int
    public var end: Int

    public init(text: String, quoted: Bool, start: Int, end: Int) {
        self.text = text
        self.quoted = quoted
        self.start = start
        self.end = end
    }
}

/// `field:value`, `field=value`, `field>value`, with `|` alternatives.
public struct LatticeQueryTerm: Sendable, Hashable {
    /// The key as typed, lowercased.
    public var field: String
    public var op: LatticeQueryOperator
    public var values: [LatticeQueryValue]
    public var start: Int
    public var end: Int
    /// The word as typed, for a key that turns out to be text after all.
    public var raw: String

    public init(field: String, op: LatticeQueryOperator, values: [LatticeQueryValue], start: Int, end: Int, raw: String) {
        self.field = field
        self.op = op
        self.values = values
        self.start = start
        self.end = end
        self.raw = raw
    }
}

/// `sort:-cpu,name`.
public struct LatticeQuerySortKey: Sendable, Hashable {
    public var field: String
    public var descending: Bool

    public init(field: String, descending: Bool) {
        self.field = field
        self.descending = descending
    }
}

/// The parsed tree.
public indirect enum LatticeQueryNode: Sendable, Hashable {
    case and([LatticeQueryNode])
    case or([LatticeQueryNode])
    case not(LatticeQueryNode)
    case term(LatticeQueryTerm)
    case text(String, quoted: Bool)
}

/// A parse or compile error with the offending source range (`QueryErrorCode`).
public struct LatticeQueryError: Error, Sendable, Hashable {
    public enum Code: String, Sendable, Hashable, CaseIterable {
        case unclosedParen, unexpectedParen, unclosedQuote, danglingOperator, nothingToNegate
        case emptyGroup, notArity, callArity, sortNested, emptyValue, unknownField, unknownValue
        case unknownFlag, unknownSort, badNumber, badDuration, badTime, badBool, badVersion
        case noCompare, needsCompare
    }

    public var code: Code
    public var start: Int
    public var end: Int
    public var params: [String: String]

    public init(code: Code, start: Int, end: Int, params: [String: String] = [:]) {
        self.code = code
        self.start = start
        self.end = end
        self.params = params
    }
}

/// A query as typed and parsed: the tree and the sort keys.
public struct LatticeQuery: Sendable, Hashable {
    public var source: String
    public var tree: LatticeQueryNode?
    public var sorts: [LatticeQuerySortKey]

    public init(source: String, tree: LatticeQueryNode?, sorts: [LatticeQuerySortKey]) {
        self.source = source
        self.tree = tree
        self.sorts = sorts
    }

    /// The empty query: every row, in the page's order.
    public static let empty = LatticeQuery(source: "", tree: nil, sorts: [])

    public var isEmpty: Bool { tree == nil && sorts.isEmpty }

    /// `parseQuery`.
    public static func parse(_ input: String) -> Result<LatticeQuery, LatticeQueryError> {
        // M0a: implement. Port syntax.ts (tokenizer, precedence, NOT and -term, parentheses, sort:).
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success(.empty) }
        return .success(LatticeQuery(source: input, tree: .text(trimmed, quoted: false), sorts: []))
    }

    /// `withoutSorts`: the query text with its `sort:` terms removed.
    public static func withoutSorts(_ input: String) -> String {
        // M0a: implement.
        input
    }
}

/// The kind of value a field holds, which decides how terms compare.
public enum LatticeQueryFieldType: String, Sendable, Hashable, CaseIterable {
    case string, list, enumeration = "enum", bool, number, duration, time, version
}

/// Which suffixes a number value may carry (`values.ts` `NumberUnit`).
public enum LatticeQueryNumberUnit: String, Sendable, Hashable, CaseIterable {
    case plain, percent, bytes, rate
}

/// A row's value for one field.
public enum LatticeQueryFieldValue: Sendable, Hashable {
    case none
    case string(String)
    case strings([String])
    case number(Double)
    case numbers([Double])
    case bool(Bool)
    case time(Date)
}

/// One field of a domain's query schema (`engine.ts` `QueryField`).
public struct LatticeQueryField<Row>: Sendable {
    /// The canonical name, lowercase.
    public var key: String
    public var aliases: [String]
    public var type: LatticeQueryFieldType
    public var unit: LatticeQueryNumberUnit
    /// For enum fields: the vocabulary, in the order `sort:` uses.
    public var values: [String]
    /// Words that stand for a value: `never` for `never_reported`.
    public var valueAliases: [String: String]
    /// A bool field listed under `is:`.
    public var flag: Bool
    /// False when the field does not sort.
    public var sortable: Bool
    public var get: @Sendable (Row) -> LatticeQueryFieldValue
    /// A matcher for `:` and `=` that knows more than the value; nil falls back to the value.
    public var match: (@Sendable (Row, String, Bool) -> Bool?)?

    public init(
        key: String,
        aliases: [String] = [],
        type: LatticeQueryFieldType,
        unit: LatticeQueryNumberUnit = .plain,
        values: [String] = [],
        valueAliases: [String: String] = [:],
        flag: Bool = false,
        sortable: Bool = true,
        get: @escaping @Sendable (Row) -> LatticeQueryFieldValue,
        match: (@Sendable (Row, String, Bool) -> Bool?)? = nil
    ) {
        self.key = key
        self.aliases = aliases
        self.type = type
        self.unit = unit
        self.values = values
        self.valueAliases = valueAliases
        self.flag = flag
        self.sortable = sortable
        self.get = get
        self.match = match
    }
}

/// A domain's query schema: its fields and the texts a bare word searches.
/// Nodes use the fields of `lib/query/nodeFields.ts`.
public protocol QueryFieldProvider {
    associatedtype Row
    static var fields: [LatticeQueryField<Row>] { get }
    static func text(_ row: Row) -> [String]
    /// One more way a bare word may match a row; false by default.
    static func bare(_ row: Row, word: String) -> Bool
}

public extension QueryFieldProvider {
    static func bare(_ row: Row, word: String) -> Bool { false }
}

/// A query compiled against a schema (`engine.ts` `CompiledQuery`).
public struct LatticeCompiledQuery<Row>: Sendable {
    public var source: String
    /// Whether a row passes; `now` is what ages are measured against.
    public var test: @Sendable (Row, Date) -> Bool
    /// Relevance from the bare words outside a negation; nil when there are none.
    public var score: (@Sendable (Row) -> Double)?
    public var sorts: [(field: LatticeQueryField<Row>, descending: Bool)]
    /// Fields the query named that the schema does not know; shown as warning tokens and ignored.
    public var unknownFields: [String]
    /// The query asks for nothing: every row, in the page's order.
    public var isEmpty: Bool

    public init(
        source: String,
        test: @escaping @Sendable (Row, Date) -> Bool,
        score: (@Sendable (Row) -> Double)? = nil,
        sorts: [(field: LatticeQueryField<Row>, descending: Bool)] = [],
        unknownFields: [String] = [],
        isEmpty: Bool
    ) {
        self.source = source
        self.test = test
        self.score = score
        self.sorts = sorts
        self.unknownFields = unknownFields
        self.isEmpty = isEmpty
    }
}

/// `compileQuery` and `applyQuery`.
public enum LatticeQueryEngine {
    public static func compile<Provider: QueryFieldProvider>(
        _ input: String,
        provider: Provider.Type
    ) -> Result<LatticeCompiledQuery<Provider.Row>, LatticeQueryError> {
        // M0a: implement. Port engine.ts: field lookup with aliases, value coercion
        // through values.ts, text scoring, sorts. This placeholder matches bare text only.
        let needle = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let query = LatticeCompiledQuery<Provider.Row>(
            source: input,
            test: { row, _ in
                needle.isEmpty || Provider.text(row).contains { $0.lowercased().contains(needle) }
            },
            isEmpty: needle.isEmpty
        )
        return .success(query)
    }

    /// Filters and orders `rows`.
    public static func apply<Row>(_ query: LatticeCompiledQuery<Row>, to rows: [Row], now: Date) -> [Row] {
        // M0a: implement sorting and relevance ordering.
        query.isEmpty ? rows : rows.filter { query.test($0, now) }
    }
}
